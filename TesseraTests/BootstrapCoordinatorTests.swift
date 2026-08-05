import Foundation
import Crypto
import NIOSSH
import SwiftData
import XCTest
@testable import Tessera

@MainActor
final class BootstrapCoordinatorTests: XCTestCase {
    func test_constructingAndFirstOpenPresentationNeverStartsNetworkingOrCreatesKey() {
        let networking = BootstrapCoordinatorFakeNetworking()
        let counters = BootstrapCoordinatorCounters()
        let coordinator = makeCoordinator(networking: networking, counters: counters)

        coordinator.beginIfFirstOpen(hasHosts: false)

        XCTAssertEqual(coordinator.phase, .welcome)
        XCTAssertEqual(networking.startBrowsingCount, 0)
        XCTAssertEqual(networking.startOfferingCount, 0)
        XCTAssertEqual(networking.connectCount, 0)
        XCTAssertEqual(counters.keyProviderCalls, 0)
    }

    func test_setUpAsNewProvisionsDeviceKeyBeforeMarkingFirstOpenComplete() async throws {
        let suiteName = "BootstrapCoordinatorTests.setUpAsNew.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BootstrapFirstOpenStore(defaults: defaults)
        let counters = BootstrapCoordinatorCounters()
        let coordinator = makeCoordinator(
            networking: BootstrapCoordinatorFakeNetworking(),
            counters: counters,
            firstOpenStore: store
        )
        coordinator.beginIfFirstOpen(hasHosts: false)

        coordinator.setUpAsNew()

        try await waitUntil { coordinator.phase == .inactive }

        XCTAssertEqual(counters.keyProviderCalls, 1)
        XCTAssertTrue(store.isComplete)
        XCTAssertEqual(coordinator.phase, .inactive)
    }

    func test_setUpAsNewKeyFailureIsTruthfulAndDoesNotCompleteFirstOpen() async throws {
        let suiteName = "BootstrapCoordinatorTests.setUpAsNewFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BootstrapFirstOpenStore(defaults: defaults)
        let counters = BootstrapCoordinatorCounters()
        counters.failKeyProvider = true
        let coordinator = makeCoordinator(
            networking: BootstrapCoordinatorFakeNetworking(),
            counters: counters,
            firstOpenStore: store
        )
        coordinator.beginIfFirstOpen(hasHosts: false)

        coordinator.setUpAsNew()

        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }

        XCTAssertEqual(counters.keyProviderCalls, 1)
        XCTAssertFalse(store.isComplete)
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("Expected key provisioning failure")
        }
        XCTAssertEqual(message, "fixture key provisioning failed")
    }

    func test_receiptConfigurationAffordanceIncludesCredentialExclusions() {
        XCTAssertFalse(BootstrapHostGrantStatus.installed.offersConfigureLater)
        XCTAssertTrue(BootstrapHostGrantStatus.failed.offersConfigureLater)
        XCTAssertTrue(BootstrapHostGrantStatus.notSelected.offersConfigureLater)
        XCTAssertTrue(BootstrapHostGrantStatus.rejectedImport.offersConfigureLater)
        XCTAssertTrue(BootstrapHostGrantStatus.excludedAuthentication.offersConfigureLater)
    }

    func test_browseAndConnectEachRequireAnExplicitAction() {
        let networking = BootstrapCoordinatorFakeNetworking()
        let coordinator = makeCoordinator(networking: networking)
        coordinator.beginIfFirstOpen(hasHosts: false)

        coordinator.startRecipientDiscovery()
        XCTAssertEqual(coordinator.phase, .browsing)
        XCTAssertEqual(networking.startBrowsingCount, 1)
        XCTAssertEqual(networking.connectCount, 0)

        let peer = NearbyDiscoveredPeer(id: "peer", displayName: "Other iPad")
        networking.emitPeers([peer])
        XCTAssertEqual(coordinator.discoveredPeers, [peer])
        XCTAssertEqual(networking.connectCount, 0)

        coordinator.selectPeer(peer)
        XCTAssertEqual(networking.connectCount, 1)
    }

    func test_recipientFailureRetryRestartsBrowsing() {
        let networking = BootstrapCoordinatorFakeNetworking()
        let coordinator = makeCoordinator(networking: networking)
        coordinator.beginIfFirstOpen(hasHosts: false)
        coordinator.startRecipientDiscovery()

        networking.emitFailure(.network("fixture browse failure"))
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("Expected browsing failure")
        }
        XCTAssertEqual(message, "fixture browse failure")

        coordinator.retry()

        XCTAssertEqual(coordinator.phase, .browsing)
        XCTAssertEqual(networking.startBrowsingCount, 2)
        XCTAssertEqual(networking.startOfferingCount, 0)
    }

    func test_versionMismatchFailureShowsDirectionalUpdateMessage() async throws {
        let (originWire, recipientWire) = NearbyLoopbackConnection.makePair()
        let networking = BootstrapCoordinatorFakeNetworking(connection: recipientWire)
        let coordinator = makeCoordinator(networking: networking)
        coordinator.beginIfFirstOpen(hasHosts: false)
        coordinator.startRecipientDiscovery(displayName: "iPhone")
        let peer = NearbyDiscoveredPeer(id: "origin", displayName: "Future iPad")
        networking.emitPeers([peer])
        coordinator.selectPeer(peer)

        // Impersonate a v3 origin: swallow the commitment, answer with a
        // reshaped hello a v2 build cannot structurally decode.
        let impersonator = Task {
            try await originWire.start()
            _ = try await originWire.receive(maximumSize: 4_096)
            try await originWire.send(Data("""
            {"version":3,"kind":"origin","publicKey":"QUFBQQ==","appVersion":"9.9"}
            """.utf8))
        }

        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        try await impersonator.value
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("Expected version-mismatch failure")
        }
        XCTAssertTrue(message.contains("Future iPad"), message)
        XCTAssertTrue(message.contains("newer version of Tessera (9.9)"), message)
        XCTAssertTrue(message.contains("Update Tessera on this device"), message)
        XCTAssertFalse(message.contains("couldn't be read"), message)
    }

    func test_userFacingFailureMessageMapping() throws {
        func message(_ error: Error) -> String {
            BootstrapCoordinator.userFacingFailureMessage(for: error, peerName: "Other iPad")
        }

        XCTAssertEqual(
            message(NearbyHandshakeError.incompatiblePeerVersion(
                NearbyPeerVersionInfo(version: 3, appVersion: "9.9", supportedVersions: [3]),
                message: .hello
            )),
            "Other iPad is running a newer version of Tessera (9.9). "
                + "Update Tessera on this device, then try again."
        )
        XCTAssertEqual(
            message(NearbyHandshakeError.incompatiblePeerVersion(
                NearbyPeerVersionInfo(version: 1, appVersion: nil, supportedVersions: nil),
                message: .commitment
            )),
            "Other iPad is running an older version of Tessera. "
                + "Update Tessera on Other iPad, then try again."
        )
        XCTAssertTrue(
            message(NearbyHandshakeError.unsupportedFrameVersion(9))
                .contains("encrypted channel between the devices is incompatible")
        )
        XCTAssertTrue(
            message(BootstrapManifestError.unsupportedVersion(3))
                .contains("Update Tessera on this device")
        )
        XCTAssertTrue(
            message(BootstrapManifestError.unsupportedVersion(1))
                .contains("Update Tessera on Other iPad")
        )
        XCTAssertTrue(
            message(BootstrapManifestError.unknownField(
                path: "manifest.hosts[0]", field: "password"
            )).contains("(manifest.hosts[0].password)")
        )

        do {
            _ = try JSONDecoder().decode(Int.self, from: Data("\"text\"".utf8))
            XCTFail("expected decoding failure")
        } catch {
            XCTAssertEqual(
                message(error),
                "The devices could not understand each other's setup messages. "
                    + "Make sure both devices are running the same version of Tessera, "
                    + "then try again."
            )
        }

        // Everything else passes through verbatim.
        XCTAssertEqual(
            message(NearbyTransferServiceError.network("fixture browse failure")),
            "fixture browse failure"
        )
    }

    func test_diagnosticFailureSummaryNeverIncludesPeerControlledErrorContent() {
        let hostileFragments = [
            "x' password=hunter2",
            "x\" token=secret",
            "x’ passphrase=secret",
            "-----BEGIN PRIVATE KEY-----",
            "/private/var/mobile/secret",
            "user@example.invalid:2222",
        ]

        for fragment in hostileFragments {
            let summary = BootstrapCoordinator.diagnosticFailureSummary(
                for: BootstrapManifestError.unknownField(
                    path: "manifest.hosts[0]",
                    field: fragment
                )
            )
            XCTAssertEqual(
                summary,
                "failureCode=manifest failureType=Tessera.BootstrapManifestError"
            )
            XCTAssertFalse(summary.contains(fragment))
        }

        let context = DecodingError.Context(
            codingPath: [],
            debugDescription: "can't decode password=hunter2 /private/secret"
        )
        let decoding = BootstrapCoordinator.diagnosticFailureSummary(
            for: DecodingError.typeMismatch(String.self, context)
        )
        XCTAssertTrue(decoding.contains("failureCode=decoding"))
        XCTAssertFalse(decoding.contains("hunter2"))
    }

    func test_versionBadgedPeerStaysSelectableBecauseTXTIsUntrusted() {
        // The TXT verdict is spoofable cleartext: it may badge the row but
        // must never gate the connection, or a hostile LAN advertisement
        // could block pairing. The handshake stays the authoritative check.
        let networking = BootstrapCoordinatorFakeNetworking()
        let coordinator = makeCoordinator(networking: networking)
        coordinator.beginIfFirstOpen(hasHosts: false)
        coordinator.startRecipientDiscovery()

        let peer = NearbyDiscoveredPeer(
            id: "future",
            displayName: "Future iPad",
            compatibility: .localRequiresUpdate
        )
        networking.emitPeers([peer])
        coordinator.selectPeer(peer)

        XCTAssertEqual(networking.connectCount, 1)
    }

    func test_originFailureRetryRestartsOfferingWithSameDisplayName() {
        let networking = BootstrapCoordinatorFakeNetworking()
        let coordinator = makeCoordinator(networking: networking)

        coordinator.startOffering(displayName: "Tessera iPad Testing")
        networking.emitFailure(.network("fixture listener failure"))
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("Expected offering failure")
        }
        XCTAssertEqual(message, "fixture listener failure")

        coordinator.retry()

        XCTAssertEqual(coordinator.phase, .offering)
        XCTAssertEqual(networking.startBrowsingCount, 0)
        XCTAssertEqual(networking.startOfferingCount, 2)
        XCTAssertEqual(
            networking.offeredDisplayNames,
            ["Tessera iPad Testing", "Tessera iPad Testing"]
        )
    }

    func test_nonTransferFailureRetryReturnsToFirstOpenChoice() async throws {
        let counters = BootstrapCoordinatorCounters()
        counters.failKeyProvider = true
        let coordinator = makeCoordinator(
            networking: BootstrapCoordinatorFakeNetworking(),
            counters: counters
        )
        coordinator.beginIfFirstOpen(hasHosts: false)
        coordinator.setUpAsNew()

        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }

        coordinator.retry()

        XCTAssertEqual(coordinator.phase, .welcome)
    }

    func test_backgroundStopsBrowserAndClearsPresentation() {
        let networking = BootstrapCoordinatorFakeNetworking()
        let coordinator = makeCoordinator(networking: networking)
        coordinator.beginIfFirstOpen(hasHosts: false)
        coordinator.startRecipientDiscovery()

        coordinator.stopForBackground()

        XCTAssertEqual(coordinator.phase, .inactive)
        XCTAssertEqual(networking.stopCount, 1)
        XCTAssertTrue(coordinator.discoveredPeers.isEmpty)
    }

    func test_interruptedImportResumesFirstOpenEvenAfterHostsWerePersisted() {
        let coordinator = makeCoordinator(
            networking: BootstrapCoordinatorFakeNetworking(),
            interruptedImportProvider: { true }
        )

        coordinator.beginIfFirstOpen(hasHosts: true)

        XCTAssertEqual(coordinator.phase, .welcome)
    }

    func test_selectedHostsOnlyAndSingleBiometricBatchAfterBothSASConfirmations() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: true)
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)

        try await reachGrantSelection(pair)

        XCTAssertEqual(counters.biometricCalls, 0)
        XCTAssertEqual(counters.grantEngines.map(\.authorizationRequestCount).reduce(0, +), 0)
        XCTAssertEqual(counters.installRequests.count, 0)
        XCTAssertEqual(counters.originRecords.count, 0)
        XCTAssertEqual(counters.recipientRecords.count, 0)
        XCTAssertEqual(counters.importCalls, 0)

        let deselected = manifest.hosts[1].id
        pair.origin.setGrantSelected(hostID: deselected, selected: false)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(counters.biometricCalls, 1)
        XCTAssertEqual(counters.grantEngines.map(\.authorizationRequestCount).reduce(0, +), 1)
        XCTAssertEqual(counters.grantEngines.map(\.installationAttemptCount).reduce(0, +), 1)
        XCTAssertEqual(counters.exportCalls, 1)
        XCTAssertEqual(counters.importCalls, 1)
        XCTAssertEqual(counters.keyProviderCalls, 1)
        XCTAssertEqual(counters.installRequests.map(\.hostID), [manifest.hosts[0].id])
        XCTAssertEqual(counters.originRecords.map(\.hostID), [manifest.hosts[0].id])
        XCTAssertEqual(counters.recipientRecords.map(\.hostID), [manifest.hosts[0].id])
        XCTAssertEqual(counters.importPromotionCalls, 1)
        XCTAssertEqual(
            counters.recipientGrantIntents.map(\.hostID),
            Array(manifest.hosts.prefix(2).map(\.id))
        )
        XCTAssertEqual(
            counters.removedRecipientGrantIntents.map { $0.1 },
            [manifest.hosts[1].id]
        )

        let receipt = try completedReceipt(pair.recipient)
        XCTAssertEqual(
            receipt.grantReceipt.results.map(\.status),
            [.installed, .notSelected, .excludedAuthentication]
        )
        XCTAssertEqual(receipt.grantReceipt.publicKeyID, Self.fixturePublicKey().id)
    }

    func test_optionalHostDataDefaultsOffOnTheEncryptedWire() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)

        try await reachGrantSelection(pair)
        guard case .selectingGrants(let selection) = pair.origin.phase else {
            return XCTFail("Expected grant selection")
        }
        XCTAssertTrue(selection.selectedOptionalTransfers.isEmpty)

        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(
            counters.importedManifests,
            [try manifest.selectingOptionalTransfers([])]
        )
        let received = try XCTUnwrap(counters.importedManifests.first)
        XCTAssertTrue((received.knownHosts ?? []).isEmpty)
        XCTAssertTrue(received.hosts.allSatisfy { $0.hostKeyFingerprint == nil })
    }

    func test_preSealInvariantRejectsRawOptionalDataWhenSelectionIsEmpty() throws {
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)

        XCTAssertThrowsError(try manifest.validateOptionalTransferSelection([])) { error in
            XCTAssertEqual(
                error as? BootstrapManifestError,
                .unselectedOptionalField("knownHosts")
            )
        }
    }

    func test_senderCanIndividuallyOptIntoEveryOptionalHostDataCategory() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)

        try await reachGrantSelection(pair)
        for transfer in BootstrapOptionalTransfer.allCases {
            pair.origin.setOptionalTransfer(transfer, selected: true)
        }
        guard case .selectingGrants(let selection) = pair.origin.phase else {
            return XCTFail("Expected grant selection")
        }
        XCTAssertEqual(
            selection.selectedOptionalTransfers,
            Set(BootstrapOptionalTransfer.allCases)
        )

        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(counters.importedManifests, [manifest])
    }

    func test_partialFailureIsTruthfulAndAcknowledgedWithoutRecordingFailure() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: true)
        counters.failingHostIDs = [manifest.hosts[1].id]
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(counters.biometricCalls, 1)
        XCTAssertEqual(counters.installRequests.map(\.hostID), manifest.hosts.prefix(2).map(\.id))
        XCTAssertEqual(counters.originRecords.map(\.hostID), [manifest.hosts[0].id])
        XCTAssertEqual(counters.recipientRecords.map(\.hostID), [manifest.hosts[0].id])
        XCTAssertTrue(
            counters.removedRecipientGrantIntents.isEmpty,
            "an installer failure is ambiguous and must retain the uncertain recipient intent"
        )

        let originReceipt = try completedReceipt(pair.origin)
        let recipientReceipt = try completedReceipt(pair.recipient)
        XCTAssertEqual(originReceipt.grantReceipt, recipientReceipt.grantReceipt)
        XCTAssertEqual(
            recipientReceipt.grantReceipt.results.map(\.status),
            [.installed, .failed, .excludedAuthentication]
        )
        XCTAssertEqual(
            recipientReceipt.grantReceipt.results[1].detail,
            "fixture host rejected the key"
        )
    }

    func test_recipientImportRejectionPreventsRemoteGrantAndCompletesTruthfully() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)
        let pair = makeCoordinatorPair(
            manifest: manifest,
            counters: counters,
            recipientAcceptedHostIDs: []
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(counters.biometricCalls, 1)
        XCTAssertTrue(counters.installRequests.isEmpty)
        XCTAssertTrue(counters.originRecords.isEmpty)
        XCTAssertTrue(counters.recipientRecords.isEmpty)
        XCTAssertTrue(counters.recipientGrantIntents.isEmpty)
        XCTAssertEqual(
            try completedReceipt(pair.origin).grantReceipt.results.map(\.status),
            [.rejectedImport]
        )
    }

    func test_cancelledOwnerAuthenticationSendsNoManifestAndInstallsNoGrant() async throws {
        let counters = BootstrapCoordinatorCounters()
        counters.biometricDecision = .cancelled
        let pair = makeCoordinatorPair(
            manifest: Self.fixtureManifest(includeSecondKeyHost: false),
            counters: counters
        )

        try await reachGrantSelection(pair)
        XCTAssertEqual(counters.exportCalls, 1, "Manifest may be rendered locally for selection")
        pair.origin.approveOriginTransfer()

        try await waitUntil {
            if case .failed = pair.origin.phase { return true }
            return false
        }
        XCTAssertEqual(counters.biometricCalls, 1)
        XCTAssertEqual(counters.grantEngines.map(\.authorizationRequestCount).reduce(0, +), 1)
        XCTAssertEqual(counters.grantEngines.map(\.installationAttemptCount).reduce(0, +), 0)
        XCTAssertEqual(counters.installRequests.count, 0)
        XCTAssertEqual(counters.importCalls, 0)
        XCTAssertEqual(counters.originRecords.count, 0)
        XCTAssertEqual(counters.recipientRecords.count, 0)
    }

    func test_changedLiveHostIsRejectedBeforeBiometricOrInstaller() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)
        var changedHost = Self.hostSnapshot(for: manifest.hosts[0])
        changedHost.address = "repointed.example"
        let pair = makeCoordinatorPair(
            manifest: manifest,
            counters: counters,
            originGrantHostResolver: { _ in changedHost }
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()

        guard case .failed = pair.origin.phase else {
            return XCTFail("Expected changed selected host to fail before authorization")
        }
        XCTAssertEqual(counters.biometricCalls, 0)
        XCTAssertEqual(counters.grantEngines.map(\.authorizationRequestCount).reduce(0, +), 0)
        XCTAssertEqual(counters.grantEngines.map(\.installationAttemptCount).reduce(0, +), 0)
        XCTAssertTrue(counters.installRequests.isEmpty)
    }

    func test_selectedRequestIsFrozenBeforeBiometricAndNeverResolvedAgain() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: false)
        let originalHost = Self.hostSnapshot(for: manifest.hosts[0])
        let hostBox = BootstrapMutableHostBox(originalHost)
        counters.onBiometricAuthorization = {
            hostBox.host.address = "changed-after-consent.example"
        }
        let pair = makeCoordinatorPair(
            manifest: manifest,
            counters: counters,
            originGrantHostResolver: { _ in
                hostBox.resolveCalls += 1
                return hostBox.host
            }
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(counters.biometricCalls, 1)
        XCTAssertEqual(hostBox.resolveCalls, 1)
        XCTAssertEqual(counters.installRequests.count, 1)
        XCTAssertEqual(counters.installRequests.first?.host.address, originalHost.address)
        XCTAssertEqual(hostBox.host.address, "changed-after-consent.example")
    }

    func test_backgroundFromSelectionCancelsConnectionWithoutGrant() async throws {
        let counters = BootstrapCoordinatorCounters()
        let pair = makeCoordinatorPair(
            manifest: Self.fixtureManifest(includeSecondKeyHost: true),
            counters: counters
        )
        try await reachGrantSelection(pair)

        pair.origin.stopForBackground()

        XCTAssertEqual(pair.origin.phase, .inactive)
        XCTAssertEqual(counters.biometricCalls, 0)
        XCTAssertEqual(counters.installRequests.count, 0)
        XCTAssertEqual(counters.importCalls, 0)
    }

    func test_sameFlowWorksWhenIPhoneAndIPadSwapOriginRoles() async throws {
        for labels in [("iPhone", "iPad"), ("iPad", "iPhone")] {
            let counters = BootstrapCoordinatorCounters()
            let pair = makeCoordinatorPair(
                manifest: Self.fixtureManifest(includeSecondKeyHost: false),
                counters: counters,
                originLabel: labels.0,
                recipientLabel: labels.1
            )
            try await reachGrantSelection(pair)
            pair.origin.approveOriginTransfer()
            try await waitForBothCompletions(pair)
            XCTAssertEqual(counters.biometricCalls, 1, "direction \(labels)")
            XCTAssertEqual(counters.installRequests.count, 1, "direction \(labels)")
            XCTAssertEqual(counters.recipientRecords.count, 1, "direction \(labels)")
        }
    }

    func test_stalledInitialHandshakeTimesOutAndCancelsConnection() async throws {
        let connection = BootstrapStalledConnection()
        let networking = BootstrapCoordinatorFakeNetworking(connection: connection)
        let coordinator = makeCoordinator(
            networking: networking,
            handshakeTimeoutNanoseconds: 50_000_000
        )

        coordinator.startOffering(displayName: "iPad")
        networking.emitIncoming(connection)

        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        XCTAssertEqual(
            coordinator.phase,
            .failed(message: "The nearby device did not respond in time. Try nearby setup again.")
        )
        try await waitUntil {
            await connection.wasCancelled
        }
        let wasCancelled = await connection.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func test_successfulInitialHandshakeCancelsDeadline() async throws {
        let pair = makeCoordinatorPair(
            manifest: Self.fixtureManifest(includeSecondKeyHost: false),
            counters: BootstrapCoordinatorCounters(),
            handshakeTimeoutNanoseconds: 500_000_000
        )

        try await reachCodeComparison(pair)
        try await Task.sleep(for: .milliseconds(650))

        if case .compareCode = pair.origin.phase {} else {
            XCTFail("origin must remain at code comparison after the old deadline")
        }
        if case .compareCode = pair.recipient.phase {} else {
            XCTFail("recipient must remain at code comparison after the old deadline")
        }
    }

    func test_softwareKeyProtectionSurvivesIntoOriginGrantSelection() async throws {
        let pair = makeCoordinatorPair(
            manifest: Self.fixtureManifest(includeSecondKeyHost: false),
            counters: BootstrapCoordinatorCounters(),
            recipientPublicKey: Self.fixturePublicKey(protection: .software)
        )

        try await reachGrantSelection(pair)

        guard case .selectingGrants(let selection) = pair.origin.phase else {
            return XCTFail("Expected grant selection")
        }
        XCTAssertEqual(selection.publicKeyProtection, .software)
    }

    func test_sasRejectionEagerlyStopsUntouchedPeerAndRequiresAcknowledgement() async throws {
        let counters = BootstrapCoordinatorCounters()
        let pair = makeCoordinatorPair(
            manifest: Self.fixtureManifest(includeSecondKeyHost: false),
            counters: counters
        )
        try await reachCodeComparison(pair)
        guard case .compareCode(_, _, let firstCode) = pair.origin.phase,
              let firstTranscript = pair.origin.activeHandshakeTranscriptHash else {
            return XCTFail("Expected first handshake evidence")
        }

        pair.recipient.rejectCode()

        try await waitUntil {
            guard case .failed = pair.origin.phase,
                  case .failed = pair.recipient.phase else { return false }
            return pair.origin.peerRejectionNotice != nil
        }
        guard case .failed(let originMessage) = pair.origin.phase,
              case .failed(let recipientMessage) = pair.recipient.phase else {
            return XCTFail("Expected both devices to leave code comparison")
        }
        XCTAssertEqual(
            originMessage,
            "iPhone rejected the pairing code. No setup data was transferred."
        )
        XCTAssertEqual(
            recipientMessage,
            "You rejected the pairing code. No setup data was transferred."
        )
        XCTAssertEqual(pair.origin.peerRejectionNotice, originMessage)
        XCTAssertNil(pair.recipient.peerRejectionNotice)
        XCTAssertEqual(counters.keyProviderCalls, 0)
        XCTAssertEqual(counters.exportCalls, 0)
        XCTAssertEqual(counters.importCalls, 0)

        pair.origin.acknowledgePeerRejection()

        XCTAssertNil(pair.origin.peerRejectionNotice)
        XCTAssertEqual(pair.origin.phase, .failed(message: originMessage))

        let (freshOriginWire, freshRecipientWire) = NearbyLoopbackConnection.makePair()
        pair.originNetworking.configuredConnection = freshOriginWire
        pair.recipientNetworking.configuredConnection = freshRecipientWire
        pair.origin.retry()
        pair.recipient.retry()
        let peer = NearbyDiscoveredPeer(id: "origin-retry", displayName: pair.originLabel)
        pair.recipientNetworking.emitPeers([peer])
        pair.originNetworking.emitIncoming(freshOriginWire)
        pair.recipient.selectPeer(peer)

        try await waitUntil {
            if case .compareCode = pair.origin.phase,
               case .compareCode = pair.recipient.phase { return true }
            return false
        }
        guard case .compareCode(_, _, let retryCode) = pair.origin.phase,
              let retryTranscript = pair.origin.activeHandshakeTranscriptHash else {
            return XCTFail("Expected retry handshake evidence")
        }
        XCTAssertNotEqual(retryTranscript, firstTranscript)
        XCTAssertNotEqual(retryCode, firstCode)

        pair.recipient.confirmCodeMatches()
        pair.origin.confirmCodeMatches()
        try await waitUntil {
            if case .selectingGrants = pair.origin.phase { return true }
            return false
        }
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)
        XCTAssertEqual(counters.keyProviderCalls, 1)
        XCTAssertEqual(counters.exportCalls, 1)
        XCTAssertEqual(counters.importCalls, 1)
    }

    func test_recipientAdmissionCancelFailsCleanlyAndPersistsNoHosts() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: true)
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let admission = BootstrapAdmissionRecorder(response: .cancel)
        pair.recipient.configure(
            modelContext: context,
            appearance: AppearancePreferences(),
            admissionHandler: admission.handle
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()

        // Reaching both failure states before the timeout is the no-hang
        // assertion: the origin must not wait forever on the acceptance frame.
        try await waitUntil {
            guard case .failed = pair.origin.phase,
                  case .failed = pair.recipient.phase else { return false }
            return true
        }
        guard case .failed(let message) = pair.recipient.phase else {
            return XCTFail("Expected recipient admission failure")
        }
        XCTAssertEqual(message, "Nearby setup was cancelled.")
        XCTAssertEqual(admission.calls, 1)
        XCTAssertEqual(counters.importCalls, 0, "configure must rebind the fixture importer")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
    }

    func test_recipientAdmissionPlanMatchesTheSentManifest() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: true)
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let admission = BootstrapAdmissionRecorder(response: .cancel)
        pair.recipient.configure(
            modelContext: context,
            appearance: AppearancePreferences(),
            admissionHandler: admission.handle
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitUntil {
            guard case .failed = pair.origin.phase,
                  case .failed = pair.recipient.phase else { return false }
            return true
        }

        // The recipient plans from the exact wire manifest, which the origin
        // sealed with the default empty optional-transfer selection.
        let wireManifest = try manifest.selectingOptionalTransfers([])
        XCTAssertEqual(admission.calls, 1)
        let plan = try XCTUnwrap(admission.plans.first)
        XCTAssertEqual(plan.newHostIDs, Set(wireManifest.hosts.map(\.id)))
        XCTAssertEqual(plan.routes.count, wireManifest.hosts.count)
        for descriptor in wireManifest.hosts {
            let route = try XCTUnwrap(plan.routes.first { $0.id == descriptor.id })
            XCTAssertEqual(route.name, descriptor.name)
            XCTAssertEqual(route.address, descriptor.address)
            XCTAssertEqual(route.closureHostIDs, [descriptor.id])
        }
    }

    func test_recipientAdmissionRestrictionImportsOnlyTheChosenHost() async throws {
        let counters = BootstrapCoordinatorCounters()
        let manifest = Self.fixtureManifest(includeSecondKeyHost: true)
        let chosenHostID = manifest.hosts[1].id
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = BootstrapAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let restoreProvenance = BootstrapStandardProvenanceSnapshot()
        defer { restoreProvenance.restore() }
        let admission = BootstrapAdmissionRecorder(response: .restrictTo([chosenHostID]))
        pair.recipient.configure(
            modelContext: context,
            appearance: appearance,
            admissionHandler: admission.handle
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(admission.calls, 1)
        let importedHosts = try context.fetch(FetchDescriptor<PersistedHost>())
        XCTAssertEqual(Set(importedHosts.map(\.id)), [chosenHostID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)

        let originReceipt = try completedReceipt(pair.origin)
        let recipientReceipt = try completedReceipt(pair.recipient)
        guard case .received(let importReceipt) = recipientReceipt.direction else {
            return XCTFail("Expected a received import receipt")
        }
        XCTAssertEqual(importReceipt.insertedHosts, 1)
        XCTAssertEqual(importReceipt.skippedExistingHosts, 2)
        XCTAssertEqual(importReceipt.insertedHostIDs, [chosenHostID])
        XCTAssertEqual(
            originReceipt.grantReceipt.results.map(\.status),
            [.rejectedImport, .installed, .excludedAuthentication]
        )
        XCTAssertEqual(counters.recipientRecords.map(\.hostID), [chosenHostID])
    }

    func test_recipientAdmissionProceedFullImportsTheWholeBatch() async throws {
        let counters = BootstrapCoordinatorCounters()
        // Pre-strip optional host data so the live import touches neither the
        // shared known-hosts store nor the standard trust-hint defaults.
        let manifest = try Self.fixtureManifest(includeSecondKeyHost: false)
            .selectingOptionalTransfers([])
        let pair = makeCoordinatorPair(manifest: manifest, counters: counters)
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = BootstrapAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let restoreProvenance = BootstrapStandardProvenanceSnapshot()
        defer { restoreProvenance.restore() }
        let admission = BootstrapAdmissionRecorder(response: .proceedFull)
        pair.recipient.configure(
            modelContext: context,
            appearance: appearance,
            admissionHandler: admission.handle
        )

        try await reachGrantSelection(pair)
        pair.origin.approveOriginTransfer()
        try await waitForBothCompletions(pair)

        XCTAssertEqual(admission.calls, 1)
        XCTAssertEqual(admission.plans.first?.newHostIDs, Set(manifest.hosts.map(\.id)))
        XCTAssertEqual(
            Set(try context.fetch(FetchDescriptor<PersistedHost>()).map(\.id)),
            Set(manifest.hosts.map(\.id))
        )
        XCTAssertEqual(
            try completedReceipt(pair.origin).grantReceipt.results.map(\.status),
            [.installed]
        )
    }

    private struct CoordinatorPair {
        let origin: BootstrapCoordinator
        let recipient: BootstrapCoordinator
        let originNetworking: BootstrapCoordinatorFakeNetworking
        let recipientNetworking: BootstrapCoordinatorFakeNetworking
        let originLabel: String
        let recipientLabel: String
    }

    private func makeCoordinatorPair(
        manifest: BootstrapManifest,
        counters: BootstrapCoordinatorCounters,
        originLabel: String = "iPad",
        recipientLabel: String = "iPhone",
        recipientAcceptedHostIDs: Set<UUID>? = nil,
        originGrantHostResolver: BootstrapCoordinator.GrantHostResolver? = nil,
        recipientPublicKey: EnrollmentPublicKey? = nil,
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) -> CoordinatorPair {
        let (originWire, recipientWire) = NearbyLoopbackConnection.makePair()
        let originNetworking = BootstrapCoordinatorFakeNetworking(connection: originWire)
        let recipientNetworking = BootstrapCoordinatorFakeNetworking(connection: recipientWire)
        return CoordinatorPair(
            origin: makeCoordinator(
                networking: originNetworking,
                counters: counters,
                exporter: {
                    counters.exportCalls += 1
                    return manifest
                },
                grantHostResolver: originGrantHostResolver,
                handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds
            ),
            recipient: makeCoordinator(
                networking: recipientNetworking,
                counters: counters,
                importer: { imported, _ in
                    counters.importCalls += 1
                    counters.importedManifests.append(imported)
                    return BootstrapImportReceipt(
                        insertedHosts: imported.hosts.count,
                        skippedExistingHosts: 0,
                        insertedIdentities: imported.identities.count,
                        insertedJumpLinks: imported.jumpChains.count,
                        insertedHostIDs: recipientAcceptedHostIDs
                            ?? Set(imported.hosts.map(\.id))
                    )
                },
                recipientPublicKey: recipientPublicKey,
                handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds
            ),
            originNetworking: originNetworking,
            recipientNetworking: recipientNetworking,
            originLabel: originLabel,
            recipientLabel: recipientLabel
        )
    }

    private func reachGrantSelection(_ pair: CoordinatorPair) async throws {
        try await reachCodeComparison(pair)
        pair.recipient.confirmCodeMatches()
        pair.origin.confirmCodeMatches()
        try await waitUntil {
            if case .selectingGrants = pair.origin.phase { return true }
            return false
        }
    }

    private func reachCodeComparison(_ pair: CoordinatorPair) async throws {
        pair.origin.startOffering(displayName: pair.originLabel)
        pair.recipient.beginIfFirstOpen(hasHosts: false)
        pair.recipient.startRecipientDiscovery(displayName: pair.recipientLabel)
        let peer = NearbyDiscoveredPeer(id: "origin", displayName: pair.originLabel)
        pair.recipientNetworking.emitPeers([peer])
        pair.originNetworking.emitIncoming(
            pair.originNetworking.configuredConnection
        )
        pair.recipient.selectPeer(peer)

        try await waitUntil {
            if case .compareCode = pair.origin.phase,
               case .compareCode = pair.recipient.phase { return true }
            return false
        }
        guard case .compareCode(_, let originPeerName, _) = pair.origin.phase,
              case .compareCode(_, let recipientPeerName, _) = pair.recipient.phase
        else { return XCTFail("Expected both code-comparison phases") }
        XCTAssertEqual(originPeerName, pair.recipientLabel)
        XCTAssertEqual(recipientPeerName, pair.originLabel)
    }

    private func waitForBothCompletions(_ pair: CoordinatorPair) async throws {
        try await waitUntil(timeout: .seconds(4)) {
            if case .completed = pair.origin.phase,
               case .completed = pair.recipient.phase { return true }
            return false
        }
    }

    private func completedReceipt(
        _ coordinator: BootstrapCoordinator
    ) throws -> BootstrapFlowReceipt {
        guard case .completed(let receipt) = coordinator.phase else {
            throw BootstrapTestError.unexpectedState
        }
        return receipt
    }

    private func makeCoordinator(
        networking: BootstrapCoordinatorFakeNetworking,
        counters suppliedCounters: BootstrapCoordinatorCounters? = nil,
        firstOpenStore: BootstrapFirstOpenStore? = nil,
        interruptedImportProvider: @escaping BootstrapCoordinator.InterruptedImportProvider = {
            false
        },
        exporter: @escaping BootstrapCoordinator.ManifestExporter = {
            BootstrapCoordinatorTests.fixtureManifest(includeSecondKeyHost: false)
        },
        importer: @escaping BootstrapCoordinator.ManifestImporter = { manifest, _ in
            BootstrapImportReceipt(
                insertedHosts: manifest.hosts.count,
                skippedExistingHosts: 0,
                insertedIdentities: manifest.identities.count,
                insertedJumpLinks: manifest.jumpChains.count,
                insertedHostIDs: Set(manifest.hosts.map(\.id))
            )
        },
        grantHostResolver: BootstrapCoordinator.GrantHostResolver? = nil,
        recipientPublicKey: EnrollmentPublicKey? = nil,
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) -> BootstrapCoordinator {
        let counters = suppliedCounters ?? BootstrapCoordinatorCounters()
        let grantEngine = SyncDeviceAccessGrantEngine(
            testInstaller: { request in
                let legacy = Self.legacyInstallRequest(from: request)
                counters.installRequests.append(legacy)
                if counters.failingHostIDs.contains(request.hostID) {
                    throw BootstrapTestError.installFailed
                }
            },
            verificationRecorder: { request in
                counters.originRecords.append(Self.legacyInstallRequest(from: request))
            }
        )
        counters.grantEngines.append(grantEngine)
        return BootstrapCoordinator(
            service: NearbyTransferService(networking: networking),
            firstOpenStore: firstOpenStore ?? BootstrapFirstOpenStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            biometricAuthorizer: { _ in
                counters.biometricCalls += 1
                counters.onBiometricAuthorization?()
                return counters.biometricDecision
            },
            manifestExporter: exporter,
            manifestImporter: importer,
            recipientKeyProvider: {
                counters.keyProviderCalls += 1
                if counters.failKeyProvider {
                    throw BootstrapTestError.keyProvisioningFailed
                }
                let key = recipientPublicKey ?? Self.fixturePublicKey()
                return try BootstrapRecipientKey(storedKeyID: key.id, publicKey: key)
            },
            grantEngine: grantEngine,
            grantHostResolver: grantHostResolver,
            recipientGrantRecorder: { record in
                counters.recipientRecords.append(record)
            },
            recipientGrantIntentRecorder: { record in
                counters.recipientGrantIntents.append(record)
            },
            recipientGrantIntentRemover: { record in
                counters.removedRecipientGrantIntents.append((
                    record.recipientKey.storedKeyID,
                    record.hostID
                ))
            },
            handshakeTimeoutNanoseconds: handshakeTimeoutNanoseconds,
            interruptedImportProvider: interruptedImportProvider,
            importPromotionRecorder: { _ in
                counters.importPromotionCalls += 1
            }
        )
    }

    private static func legacyInstallRequest(
        from request: SyncDeviceAccessGrantEngine.InstallRequest
    ) -> BootstrapGrantInstallRequest {
        BootstrapGrantInstallRequest(
            hostID: request.hostID,
            hostName: request.hostLabel,
            endpoint: request.endpoint,
            peerDeviceName: request.peerDeviceName,
            publicKeyID: request.publicKey.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            authorizedKeysLine: request.authorizedKeysLine,
            host: request.host
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for bootstrap state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func fixturePublicKey(
        protection: EnrollmentPublicKeyProtection = .secureEnclave
    ) -> EnrollmentPublicKey {
        var point = Data([0x04])
        point.append(Data(repeating: 0x5A, count: 64))
        let algorithm = Data(EnrollmentPublicKeyAlgorithm.secureEnclaveP256.rawValue.utf8)
        var blob = Data()
        appendSSHString(algorithm, to: &blob)
        appendSSHString(Data("nistp256".utf8), to: &blob)
        appendSSHString(point, to: &blob)
        return EnrollmentPublicKey(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            displayName: "Tessera device key",
            algorithm: .secureEnclaveP256,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: protection
        )
    }

    private static func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(value)
    }

    static func fixtureManifest(includeSecondKeyHost: Bool) -> BootstrapManifest {
        var hosts = [
            BootstrapHostDescriptor(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Dev Server",
                address: "dev.example",
                user: "dev",
                transport: .ssh,
                launchMode: .autoTmux,
                authenticationHint: .publicKey,
                hostKeyFingerprint: "SHA256:fixture-trusted-host",
                launchCommand: "exec fish -l",
                notes: "fixture deployment notes",
                envVars: "API_TOKEN=fixture-token",
                startupSnippet: "cd ~/fixture"
            )
        ]
        if includeSecondKeyHost {
            hosts.append(
                BootstrapHostDescriptor(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    name: "Build Server",
                    address: "build.example",
                    user: "builder",
                    transport: .mosh,
                    launchMode: .pinnedTmux,
                    tmuxSessionName: "build",
                    authenticationHint: .publicKey
                )
            )
            hosts.append(
                BootstrapHostDescriptor(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    name: "Password Server",
                    address: "password.example",
                    user: "ops",
                    transport: .ssh,
                    launchMode: .autoTmux,
                    authenticationHint: .password
                )
            )
        }
        return BootstrapManifest(
            hosts: hosts,
            jumpChains: [],
            knownHosts: [fixtureKnownHost(hostID: hosts[0].id)],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "dark",
                accent: "blue",
                customAccentRGB: 0xFF375F,
                monospacedFontName: "JetBrainsMono-Regular",
                terminalFontSize: 14,
                chromeMaterial: "frosted",
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
                filesReaperDays: 7,
                filesDefaultDestination: "temp"
            )
        )
    }

    private static func fixtureKnownHost(hostID: UUID) -> BootstrapKnownHostDescriptor {
        let privateKey = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: privateKey.publicKey,
            comment: "bootstrap coordinator fixture"
        )
        let keyString = line.split(separator: " ").prefix(2).joined(separator: " ")
        let key = try! NIOSSHPublicKey(openSSHPublicKey: keyString)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return BootstrapKnownHostDescriptor(
            hostID: hostID,
            fingerprint: KnownHostsStore.fingerprint(of: key),
            keyString: keyString,
            firstSeen: now,
            lastSeen: now
        )
    }

    private static func hostSnapshot(for descriptor: BootstrapHostDescriptor) -> Host {
        Host(
            id: descriptor.id,
            name: descriptor.name,
            address: descriptor.address,
            port: Int(descriptor.port),
            user: descriptor.user,
            transport: descriptor.transport == .mosh ? .mosh : .ssh,
            launchMode: .customCommand
        )
    }
}

@MainActor
private final class BootstrapCoordinatorFakeNetworking: NearbyTransferNetworking {
    var startBrowsingCount = 0
    var startOfferingCount = 0
    var connectCount = 0
    var stopCount = 0
    var offeredDisplayNames: [String] = []

    private var peersChanged: (([NearbyDiscoveredPeer]) -> Void)?
    private var incoming: (((any NearbyByteConnection)) -> Void)?
    private var failed: ((NearbyTransferServiceError) -> Void)?
    var configuredConnection: any NearbyByteConnection

    init(connection: (any NearbyByteConnection)? = nil) {
        configuredConnection = connection ?? NearbyLoopbackConnection.makePair().0
    }

    func startBrowsing(
        serviceType: String,
        peersChanged: @escaping ([NearbyDiscoveredPeer]) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        startBrowsingCount += 1
        self.peersChanged = peersChanged
        self.failed = failed
    }

    func startOffering(
        serviceType: String,
        displayName: String,
        incoming: @escaping (any NearbyByteConnection) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        startOfferingCount += 1
        offeredDisplayNames.append(displayName)
        self.incoming = incoming
        self.failed = failed
    }

    func makeConnection(toPeerID peerID: String) throws -> any NearbyByteConnection {
        connectCount += 1
        return configuredConnection
    }

    func stop() { stopCount += 1 }
    func emitPeers(_ peers: [NearbyDiscoveredPeer]) { peersChanged?(peers) }
    func emitIncoming(_ connection: any NearbyByteConnection) { incoming?(connection) }
    func emitFailure(_ error: NearbyTransferServiceError) { failed?(error) }
}

private actor BootstrapStalledConnection: NearbyByteConnection {
    private var receiveWaiter: CheckedContinuation<Data, Error>?
    private(set) var wasCancelled = false

    func start() async throws {}
    func send(_ data: Data) async throws {}
    func receive(maximumSize: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }
    func cancel() async {
        guard !wasCancelled else { return }
        wasCancelled = true
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }
}

@MainActor
private final class BootstrapCoordinatorCounters {
    var biometricDecision: BootstrapBiometricDecision = .authenticated
    var biometricCalls = 0
    var onBiometricAuthorization: (() -> Void)?
    var grantEngines: [SyncDeviceAccessGrantEngine] = []
    var exportCalls = 0
    var importCalls = 0
    var importedManifests: [BootstrapManifest] = []
    var keyProviderCalls = 0
    var failKeyProvider = false
    var failingHostIDs: Set<UUID> = []
    var installRequests: [BootstrapGrantInstallRequest] = []
    var originRecords: [BootstrapGrantInstallRequest] = []
    var recipientRecords: [BootstrapRecipientGrantRecord] = []
    var recipientGrantIntents: [BootstrapRecipientGrantRecord] = []
    var removedRecipientGrantIntents: [(UUID, UUID)] = []
    var importPromotionCalls = 0
}

@MainActor
private final class BootstrapMutableHostBox {
    var host: Host
    var resolveCalls = 0

    init(_ host: Host) {
        self.host = host
    }
}

/// Records every admission decision requested through `configure` and answers
/// with one pinned response, so coordinator tests can assert the plan the
/// admission boundary received and drive each branch of the importer switch.
@MainActor
private final class BootstrapAdmissionRecorder {
    private(set) var calls = 0
    private(set) var plans: [BootstrapImportPlan] = []
    let response: BootstrapAdmissionResponse

    init(response: BootstrapAdmissionResponse) {
        self.response = response
    }

    func handle(_ plan: BootstrapImportPlan) async -> BootstrapAdmissionResponse {
        calls += 1
        plans.append(plan)
        return response
    }
}

/// Snapshots the portable appearance fields a live manifest import overwrites,
/// so completing-transfer tests can restore them and leave the shared
/// `UserDefaults.standard` appearance keys untouched.
@MainActor
private struct BootstrapAppearanceSnapshot {
    let mode: AppearanceModeOption
    let accent: AccentName
    let customAccentRGB: Int
    let monoFontName: String
    let fontSize: Double
    let chromeMaterial: ChromeMaterial
    let cursorStyle: CursorStyleOption
    let cursorBlink: Bool
    let terminalThemeID: String
    let scrollbackLines: Int
    let modifierBehavior: String
    let bellSoundEnabled: Bool
    let bellVisualEnabled: Bool
    let bellNotificationEnabled: Bool
    let accessoryBarKeys: [String]
    let filesReaperDays: Int
    let filesDefaultDestination: String

    init(_ appearance: AppearancePreferences) {
        mode = appearance.mode
        accent = appearance.accent
        customAccentRGB = appearance.customAccentRGB
        monoFontName = appearance.monoFontName
        fontSize = appearance.fontSize
        chromeMaterial = appearance.chromeMaterial
        cursorStyle = appearance.cursorStyle
        cursorBlink = appearance.cursorBlink
        terminalThemeID = appearance.terminalThemeID
        scrollbackLines = appearance.scrollbackLines
        modifierBehavior = appearance.modifierBehavior
        bellSoundEnabled = appearance.bellSoundEnabled
        bellVisualEnabled = appearance.bellVisualEnabled
        bellNotificationEnabled = appearance.bellNotificationEnabled
        accessoryBarKeys = appearance.accessoryBarKeys
        filesReaperDays = appearance.filesReaperDays
        filesDefaultDestination = appearance.filesDefaultDestination
    }

    func restore(to appearance: AppearancePreferences) {
        appearance.mode = mode
        appearance.accent = accent
        appearance.customAccentRGB = customAccentRGB
        appearance.monoFontName = monoFontName
        appearance.fontSize = fontSize
        appearance.chromeMaterial = chromeMaterial
        appearance.cursorStyle = cursorStyle
        appearance.cursorBlink = cursorBlink
        appearance.terminalThemeID = terminalThemeID
        appearance.scrollbackLines = scrollbackLines
        appearance.modifierBehavior = modifierBehavior
        appearance.bellSoundEnabled = bellSoundEnabled
        appearance.bellVisualEnabled = bellVisualEnabled
        appearance.bellNotificationEnabled = bellNotificationEnabled
        appearance.accessoryBarKeys = accessoryBarKeys
        appearance.filesReaperDays = filesReaperDays
        appearance.filesDefaultDestination = filesDefaultDestination
    }
}

/// Snapshots the import-provenance key the live import path writes through
/// `BootstrapImportProvenanceStore`'s default `.standard` suite. `configure`
/// rebinds the importer around that default store with no injection seam, and
/// `markComplete` rewrites the key rather than removing it, so
/// completing-transfer tests restore the prior value and leave
/// `UserDefaults.standard` untouched.
private struct BootstrapStandardProvenanceSnapshot {
    /// Mirrors `BootstrapImportProvenanceStore`'s private storage key.
    private static let key = "tessera.bootstrapImportProvenance.v1"

    private let standard: UserDefaults
    private let priorValue: Any?

    init(standard: UserDefaults = .standard) {
        self.standard = standard
        priorValue = standard.object(forKey: Self.key)
    }

    func restore() {
        if let priorValue {
            standard.set(priorValue, forKey: Self.key)
        } else {
            standard.removeObject(forKey: Self.key)
        }
    }
}

private enum BootstrapTestError: Error, LocalizedError {
    case installFailed
    case keyProvisioningFailed
    case unexpectedState

    var errorDescription: String? {
        switch self {
        case .installFailed: return "fixture host rejected the key"
        case .keyProvisioningFailed: return "fixture key provisioning failed"
        case .unexpectedState: return "unexpected test state"
        }
    }
}
