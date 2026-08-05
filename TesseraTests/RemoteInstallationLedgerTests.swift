import XCTest
@testable import Tessera

final class RemoteInstallationLedgerTests: XCTestCase {
    func testLegacyInstallationDecodesWithSafeContinuityDefaults() throws {
        let hostID = UUID()
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy: [String: Any] = [
            "hostID": hostID.uuidString,
            "hostLabel": "helios",
            "endpoint": "dev@helios:22",
            "installedAt": installedAt.timeIntervalSinceReferenceDate,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(
            KeySecurityRecord.RemoteInstallation.self,
            from: data
        )

        XCTAssertEqual(decoded.hostID, hostID)
        XCTAssertEqual(decoded.direction, .localInstallation)
        XCTAssertEqual(decoded.flow, .manual)
        XCTAssertEqual(decoded.verificationState, .verified)
        XCTAssertNil(decoded.peerDeviceName)
        XCTAssertNil(decoded.authorizedKeysLine)
        XCTAssertNil(decoded.routeIdentity)
    }

    func testEnrollmentLedgerPersistsGrantorAuditAndPublicRevokeMaterial() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()

        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            peerDeviceName: "Dev One's iPhone",
            direction: .grantedToPeer,
            flow: .enrollment,
            publicKeyFingerprint: "SHA256:example",
            authorizedKeysLine: "ecdsa-sha2-nistp256 AAAA peer"
        )

        let tracked = try XCTUnwrap(store.allRemoteInstallations().first)
        XCTAssertEqual(tracked.keyID, keyID)
        XCTAssertEqual(tracked.installation.hostID, hostID)
        XCTAssertEqual(tracked.installation.direction, .grantedToPeer)
        XCTAssertEqual(tracked.installation.flow, .enrollment)
        XCTAssertEqual(tracked.installation.verificationState, .verified)
        XCTAssertEqual(tracked.installation.peerDeviceName, "Dev One's iPhone")
        XCTAssertEqual(
            tracked.installation.authorizedKeysLine,
            "ecdsa-sha2-nistp256 AAAA peer"
        )
    }

    func testUncertainMutationOverwritesVerifiedAndVerifiedReceiptPromotesIt() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()

        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            peerDeviceName: "iPhone",
            direction: .grantedToPeer,
            flow: .bootstrap,
            verificationState: .verified,
            publicKeyFingerprint: "SHA256:peer",
            authorizedKeysLine: "ssh-ed25519 AAAA-peer"
        )
        store.markRemoteInstallationUncertain(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "ignored replacement",
            endpoint: "ignored:22"
        )

        var installation = try XCTUnwrap(store.allRemoteInstallations().first).installation
        XCTAssertEqual(installation.verificationState, .uncertain)
        XCTAssertEqual(installation.peerDeviceName, "iPhone")
        XCTAssertEqual(installation.direction, .grantedToPeer)
        XCTAssertEqual(installation.flow, .bootstrap)
        XCTAssertEqual(installation.publicKeyFingerprint, "SHA256:peer")
        XCTAssertEqual(installation.authorizedKeysLine, "ssh-ed25519 AAAA-peer")

        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            peerDeviceName: "iPhone",
            direction: .grantedToPeer,
            flow: .bootstrap,
            verificationState: .verified,
            publicKeyFingerprint: "SHA256:peer",
            authorizedKeysLine: "ssh-ed25519 AAAA-peer"
        )
        installation = try XCTUnwrap(store.allRemoteInstallations().first).installation
        XCTAssertEqual(installation.verificationState, .verified)
    }

    func testLedgerContextRecordsUncertainThenVerifiedAndRemovesAfterRevoke() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()
        let routeIdentity = "frozen-route"
        let context = RemoteAuthorizedKeysInstaller.LedgerContext(
            metadata: store,
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            routeIdentity: routeIdentity,
            peerDeviceName: "iPad",
            direction: .receivedFromPeer,
            flow: .bootstrap,
            publicKeyFingerprint: "SHA256:key",
            authorizedKeysLine: "ssh-ed25519 AAAA-key"
        )

        context.record(.uncertain)
        XCTAssertEqual(
            store.record(for: keyID).remoteInstallations.first?.verificationState,
            .uncertain
        )
        XCTAssertEqual(
            store.record(for: keyID).remoteInstallations.first?.routeIdentity,
            routeIdentity
        )
        context.record(.verified)
        XCTAssertEqual(
            store.record(for: keyID).remoteInstallations.first?.verificationState,
            .verified
        )
        context.markUncertainPreservingAuditFields()
        XCTAssertEqual(
            store.record(for: keyID).remoteInstallations.first?.verificationState,
            .uncertain
        )
        context.removeAfterVerifiedRevocation()
        XCTAssertTrue(store.record(for: keyID).remoteInstallations.isEmpty)
        XCTAssertNotNil(store.record(for: keyID).lastRemoteRevocationAt)
    }

    func testDiscardingUninstalledIntentDoesNotClaimRemoteRevocation() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()
        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "pending",
            endpoint: "pending:22",
            routeIdentity: "pending-route",
            direction: .receivedFromPeer,
            flow: .bootstrap,
            verificationState: .uncertain,
            publicKeyFingerprint: "SHA256:pending",
            authorizedKeysLine: "ssh-ed25519 AAAA-pending"
        )

        store.discardRemoteInstallationIntent(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "pending-route",
            publicKeyFingerprint: "SHA256:pending",
            authorizedKeysLine: "ssh-ed25519 AAAA-pending",
            direction: .receivedFromPeer,
            flow: .bootstrap
        )

        XCTAssertTrue(store.record(for: keyID).remoteInstallations.isEmpty)
        XCTAssertNil(store.record(for: keyID).lastRemoteRevocationAt)
    }

    func testDelayedIntentDiscardCannotDeletePromotedOrReplacementRow() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()
        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            routeIdentity: "route-a",
            direction: .receivedFromPeer,
            flow: .enrollment,
            verificationState: .uncertain,
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a"
        )
        store.markRemoteInstallationVerificationState(
            .verified,
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            routeIdentity: "route-a"
        )

        store.discardRemoteInstallationIntent(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-a",
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a",
            direction: .receivedFromPeer,
            flow: .enrollment
        )
        XCTAssertEqual(
            store.record(for: keyID).remoteInstallations.first?.verificationState,
            .verified
        )

        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "new helios",
            endpoint: "dev@new-helios:22",
            routeIdentity: "route-b",
            direction: .receivedFromPeer,
            flow: .bootstrap,
            verificationState: .uncertain,
            publicKeyFingerprint: "SHA256:key-b",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-b"
        )
        store.discardRemoteInstallationIntent(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-a",
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a",
            direction: .receivedFromPeer,
            flow: .enrollment
        )
        let replacement = try XCTUnwrap(
            store.record(for: keyID).remoteInstallations.first
        )
        XCTAssertEqual(replacement.routeIdentity, "route-b")
        XCTAssertEqual(replacement.flow, .bootstrap)
    }

    func testConflictingPlacementDetectionBindsRouteKeyAndDirection() throws {
        let suite = "RemoteInstallationLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySecurityMetadataStore(defaults: defaults, storageKey: "ledger")
        let keyID = UUID()
        let hostID = UUID()
        store.recordRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            hostLabel: "helios",
            endpoint: "dev@helios:22",
            routeIdentity: "route-a",
            direction: .grantedToPeer,
            flow: .enrollment,
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a"
        )

        XCTAssertFalse(store.hasConflictingRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-a",
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a",
            direction: .grantedToPeer
        ))
        XCTAssertTrue(store.hasConflictingRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-b",
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a",
            direction: .grantedToPeer
        ))
        XCTAssertTrue(store.hasConflictingRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-a",
            publicKeyFingerprint: "SHA256:key-b",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-b",
            direction: .grantedToPeer
        ))
        XCTAssertTrue(store.hasConflictingRemoteInstallation(
            keyID: keyID,
            hostID: hostID,
            routeIdentity: "route-a",
            publicKeyFingerprint: "SHA256:key-a",
            authorizedKeysLine: "ssh-ed25519 AAAA-key-a",
            direction: .receivedFromPeer
        ))
    }

    func testRouteIdentityBindsEveryOrderedEndpointWithoutSecrets() {
        let outerID = UUID()
        let innerID = UUID()
        let destinationID = UUID()
        let outer = Host(
            id: outerID,
            name: "outer label",
            address: "outer.example",
            port: 2201,
            user: "jump-a",
            password: "outer secret",
            transport: .ssh
        )
        let inner = Host(
            id: innerID,
            address: "10.0.0.7",
            port: 2202,
            user: "jump-b",
            password: "inner secret",
            transport: .mosh
        )
        var destination = Host(
            id: destinationID,
            name: "production",
            address: "db.internal",
            port: 2222,
            user: "deploy",
            password: "destination secret",
            transport: .ssh,
            jumpChain: [outer, inner]
        )

        let original = RemoteAccessRouteIdentity.value(for: destination)
        XCTAssertFalse(original.contains("secret"))
        XCTAssertFalse(original.contains("production"))
        XCTAssertFalse(original.contains("outer label"))

        destination.password = "rotated secret"
        destination.name = "renamed"
        XCTAssertEqual(RemoteAccessRouteIdentity.value(for: destination), original)

        destination.address = "other.internal"
        XCTAssertNotEqual(RemoteAccessRouteIdentity.value(for: destination), original)
        destination.address = "db.internal"
        destination.jumpChain = [inner, outer]
        XCTAssertNotEqual(RemoteAccessRouteIdentity.value(for: destination), original)
        destination.jumpChain = [outer, inner]
        destination.jumpChain[0].user = "other-user"
        XCTAssertNotEqual(RemoteAccessRouteIdentity.value(for: destination), original)
    }
}
