import XCTest
@testable import Tessera

final class SessionRestoreResolverTests: XCTestCase {
    func test_deletedHost_isSkipped() {
        let document = document(snapshots: [snapshot(hostID: UUID())])

        let plan = resolve(document, hosts: [])

        XCTAssertEqual(plan.sessions.count, 0)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_keyBackedHost_isAcceptedWhenStoredKeyExists() {
        let keyID = UUID()
        let host = makeHost(identity: makeIdentity(.key(keyID)))
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let plan = resolve(
            document,
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 1)
        XCTAssertEqual(plan.sessions.first?.host.id, host.id)
    }

    func test_passwordHost_requiresKeychainPassword() {
        let identity = makeIdentity(.password)
        let host = makeHost(identity: identity)
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let missing = resolve(document, hosts: [host], passwordIdentityIDs: [])
        let present = resolve(document, hosts: [host], passwordIdentityIDs: [identity.id])

        XCTAssertEqual(missing.sessions.count, 0)
        XCTAssertEqual(missing.skippedCount, 1)
        XCTAssertEqual(present.sessions.count, 1)
    }

    func test_noneIdentity_isSkipped() {
        let host = makeHost(identity: makeIdentity(.none))
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let plan = resolve(document, hosts: [host])

        XCTAssertEqual(plan.sessions.count, 0)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_transientPasswordSession_isSkippedWhenHostHasNoRestorableIdentity() {
        let host = makeHost(identity: nil)
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let plan = resolve(document, hosts: [host])

        XCTAssertEqual(plan.sessions.count, 0)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_legacyDevKeyHost_isAcceptedWhenFileExists() {
        let host = makeHost(identity: makeIdentity(.legacyDevKey("dev-key")))
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let plan = SessionRestoreResolver.resolve(
            document,
            hosts: [host],
            isCredentialRestorable: { candidate in
                SessionRestoreEligibility.isRestorable(
                    host: candidate,
                    storedKey: { _ in nil },
                    passwordExists: { _ in false },
                    legacyDevKeyExists: { $0 == "dev-key" }
                )
            }
        )

        XCTAssertEqual(plan.sessions.count, 1)
    }

    func test_renameUsesCurrentHostName() {
        let keyID = UUID()
        let host = makeHost(name: "old", identity: makeIdentity(.key(keyID)))
        let snap = snapshot(hostID: host.id, displayName: "old")
        host.name = "new"

        let plan = resolve(
            document(snapshots: [snap]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.first?.displayName, "new")
    }

    func test_restoreUsesCurrentHostConfiguration() {
        let keyID = UUID()
        let host = makeHost(identity: makeIdentity(.key(keyID)))
        host.address = "old.example"
        host.user = "olduser"
        host.transport = .ssh
        host.launchMode = .customCommand

        let snap = snapshot(hostID: host.id)
        host.address = "new.example"
        host.user = "newuser"
        host.transport = .mosh
        host.launchMode = .autoTmux

        let plan = resolve(
            document(snapshots: [snap]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )
        let resolved = plan.sessions.first?.host

        XCTAssertEqual(resolved?.address, "new.example")
        XCTAssertEqual(resolved?.effectiveUser, "newuser")
        XCTAssertEqual(resolved?.transport, .mosh)
        XCTAssertEqual(resolved?.launchMode, .autoTmux)
    }

    func test_identityChangedToIneligible_causesSkip() {
        let keyID = UUID()
        let host = makeHost(identity: makeIdentity(.key(keyID)))
        let snap = snapshot(hostID: host.id)
        host.identity = makeIdentity(.none)

        let plan = resolve(
            document(snapshots: [snap]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 0)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_duplicateCustomCommandSnapshots_restoreAsDuplicates() {
        let keyID = UUID()
        let host = makeHost(
            launchMode: .customCommand,
            identity: makeIdentity(.key(keyID))
        )
        let first = snapshot(hostID: host.id)
        let second = snapshot(hostID: host.id)

        let plan = resolve(
            document(snapshots: [first, second]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 2)
        XCTAssertEqual(plan.sessions.flatMap(\.sourceSnapshotIDs), [
            first.liveSessionID,
            second.liveSessionID,
        ])
    }

    func test_duplicateAutoTmuxSnapshots_collapseToSingleton() {
        let keyID = UUID()
        let host = makeHost(
            launchMode: .autoTmux,
            identity: makeIdentity(.key(keyID))
        )
        let first = snapshot(hostID: host.id)
        let second = snapshot(hostID: host.id)

        let plan = resolve(
            document(snapshots: [first, second], selectedID: second.liveSessionID),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 1)
        XCTAssertEqual(plan.sessions.first?.sourceSnapshotIDs, [
            first.liveSessionID,
            second.liveSessionID,
        ])
        XCTAssertEqual(plan.selectedSnapshotID, second.liveSessionID)
    }

    func test_duplicatePinnedTmuxSnapshots_collapseByPinnedSessionName() {
        let keyID = UUID()
        let host = makeHost(
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            identity: makeIdentity(.key(keyID))
        )

        let plan = resolve(
            document(snapshots: [
                snapshot(hostID: host.id),
                snapshot(hostID: host.id),
            ]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 1)
        XCTAssertEqual(plan.sessions.first?.sourceSnapshotIDs.count, 2)
    }

    func test_duplicatePinnedTmuxWithoutName_matchesCurrentConnectDuplicates() {
        let keyID = UUID()
        let host = makeHost(
            launchMode: .pinnedTmux,
            tmuxSessionName: "",
            identity: makeIdentity(.key(keyID))
        )

        let plan = resolve(
            document(snapshots: [
                snapshot(hostID: host.id),
                snapshot(hostID: host.id),
            ]),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 2)
    }

    @MainActor
    func test_quickConnectSessionsHaveNoPersistedHostMarker() {
        let host = Host(name: "quick", address: "example.com", port: 22, user: "me")
        let live = LiveSession(
            session: .ssh(SSHSession(host: host)),
            hostName: "quick",
            hostKey: "ssh:me@example.com:22",
            launchMode: .autoTmux
        )

        XCTAssertNil(live.persistedHostID)
    }

    private func resolve(
        _ document: SessionRestoreDocument,
        hosts: [PersistedHost],
        storedKeyIDs: Set<UUID> = [],
        passwordIdentityIDs: Set<UUID> = []
    ) -> SessionRestorePlan {
        SessionRestoreResolver.resolve(
            document,
            hosts: hosts,
            isCredentialRestorable: { host in
                SessionRestoreEligibility.isRestorable(
                    host: host,
                    storedKey: { id in
                        storedKeyIDs.contains(id) ? StoredKey(id: id) : nil
                    },
                    passwordExists: { passwordIdentityIDs.contains($0) },
                    legacyDevKeyExists: { _ in false }
                )
            }
        )
    }

    private func document(
        snapshots: [SessionRestoreSnapshot],
        selectedID: UUID? = nil
    ) -> SessionRestoreDocument {
        SessionRestoreDocument(
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sessions: snapshots,
            selectedSessionID: selectedID
        )
    }

    private func snapshot(
        hostID: UUID,
        displayName: String = "snapshot"
    ) -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            liveSessionID: UUID(),
            persistedHostID: hostID,
            displayName: displayName,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeHost(
        id: UUID = UUID(),
        name: String = "host",
        address: String = "host.example",
        user: String = "me",
        transport: HostTransport = .ssh,
        launchMode: HostLaunchMode = .autoTmux,
        tmuxSessionName: String? = nil,
        identity: Identity?
    ) -> PersistedHost {
        let host = PersistedHost(
            id: id,
            name: name,
            address: address,
            port: 22,
            autoTmux: launchMode != .customCommand,
            transport: transport,
            launchMode: launchMode,
            tmuxSessionName: tmuxSessionName,
            sortOrder: 0,
            identity: identity
        )
        host.user = user
        return host
    }

    private func makeIdentity(_ mode: CredentialMode) -> Identity {
        Identity(
            name: "identity",
            user: "",
            credentialMode: mode
        )
    }
}
