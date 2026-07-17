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

    func test_keyBackedHost_isRejectedWhenMetadataExistsButPrivateMaterialIsMissing() {
        let keyID = UUID()
        let host = makeHost(identity: makeIdentity(.key(keyID)))
        let document = document(snapshots: [snapshot(hostID: host.id)])

        let plan = resolve(
            document,
            hosts: [host],
            storedKeyIDs: [keyID],
            privateMaterialKeyIDs: []
        )

        XCTAssertEqual(plan.sessions.count, 0)
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_keyBackedHost_failsClosedForMismatchedPrivateMaterial() {
        let keyID = UUID()
        let key = StoredKey(id: keyID, algorithm: .ed25519)
        let host = makeHost(identity: makeIdentity(.key(keyID)))

        XCTAssertFalse(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { $0 == keyID ? key : nil },
                privateMaterialIntegrity: { _ in .mismatched },
                passwordAvailability: { _ in .missing },
                legacyDevKeyExists: { _ in false }
            )
        )
    }

    func test_keyBackedHost_doesNotPromptDuringEligibilityForProtectedMaterial() {
        let keyID = UUID()
        let key = StoredKey(id: keyID, algorithm: .ed25519)
        let host = makeHost(identity: makeIdentity(.key(keyID)))

        XCTAssertTrue(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { $0 == keyID ? key : nil },
                privateMaterialIntegrity: { _ in .authenticationRequired },
                passwordAvailability: { _ in .missing },
                legacyDevKeyExists: { _ in false }
            )
        )
    }

    func test_keyBackedHost_allowsAuthenticationToResolveTransientIntegrityFailure() {
        let keyID = UUID()
        let key = StoredKey(id: keyID, algorithm: .ed25519)
        let host = makeHost(identity: makeIdentity(.key(keyID)))

        XCTAssertTrue(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { $0 == keyID ? key : nil },
                privateMaterialIntegrity: { _ in .unavailable },
                passwordAvailability: { _ in .missing },
                legacyDevKeyExists: { _ in false }
            )
        )
    }

    func test_keyBackedHost_rejectsDefinitivelyInvalidIntegrityResults() {
        let keyID = UUID()
        let key = StoredKey(id: keyID, algorithm: .ed25519)
        let host = makeHost(identity: makeIdentity(.key(keyID)))
        let rejected: [KeyMaterialIntegrity] = [
            .missing,
            .mismatched,
            .invalid,
            .unsupportedAlgorithm,
        ]

        for integrity in rejected {
            XCTAssertFalse(
                SessionRestoreEligibility.isRestorable(
                    host: host,
                    storedKey: { $0 == keyID ? key : nil },
                    privateMaterialIntegrity: { _ in integrity },
                    passwordAvailability: { _ in .missing },
                    legacyDevKeyExists: { _ in false }
                ),
                "Expected \(integrity) to remain ineligible for restore"
            )
        }
    }

    func test_legacyRSAHostIsNeverSessionRestorable() {
        let keyID = UUID()
        let key = StoredKey(id: keyID, algorithm: .rsa)
        let host = makeHost(identity: makeIdentity(.key(keyID)))

        XCTAssertFalse(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { $0 == keyID ? key : nil },
                privateMaterialIntegrity: { _ in .valid },
                passwordAvailability: { _ in .missing },
                legacyDevKeyExists: { _ in false }
            )
        )
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

    func test_passwordHost_preservesSnapshotAcrossTransientKeychainFailure() {
        let identity = makeIdentity(.password)
        let host = makeHost(identity: identity)

        XCTAssertTrue(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { _ in nil },
                passwordAvailability: { _ in .unavailable }
            )
        )
        XCTAssertFalse(
            SessionRestoreEligibility.isRestorable(
                host: host,
                storedKey: { _ in nil },
                passwordAvailability: { _ in .invalid }
            )
        )
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
                    passwordAvailability: { _ in .missing },
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
        // Distinct createdAt = user-opened duplicates, not one
        // session's replacement lineage.
        let first = snapshot(hostID: host.id)
        let second = snapshot(hostID: host.id, createdAtOffset: 1)

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

    func test_sameLineageSnapshots_collapseAcrossLaunchModes() {
        // Foreground replacement restores re-parent a snapshot but
        // inherit its createdAt, so identical (host, createdAt) =
        // one session's lineage — even for customCommand, which has
        // no singleton key. This is what stops a failed host's
        // snapshots snowballing into N concurrent bootstraps.
        let keyID = UUID()
        let host = makeHost(
            launchMode: .customCommand,
            identity: makeIdentity(.key(keyID))
        )
        let first = snapshot(hostID: host.id)
        let clone = snapshot(hostID: host.id)

        let plan = resolve(
            document(snapshots: [first, clone], selectedID: clone.liveSessionID),
            hosts: [host],
            storedKeyIDs: [keyID]
        )

        XCTAssertEqual(plan.sessions.count, 1)
        XCTAssertEqual(plan.sessions.first?.sourceSnapshotIDs, [
            first.liveSessionID,
            clone.liveSessionID,
        ])
        XCTAssertEqual(plan.selectedSnapshotID, clone.liveSessionID)
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
                snapshot(hostID: host.id, createdAtOffset: 1),
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
        privateMaterialKeyIDs: Set<UUID>? = nil,
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
                    privateMaterialExists: {
                        (privateMaterialKeyIDs ?? storedKeyIDs).contains($0)
                    },
                    passwordAvailability: {
                        passwordIdentityIDs.contains($0) ? .available : .missing
                    },
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
        displayName: String = "snapshot",
        createdAtOffset: TimeInterval = 0
    ) -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            liveSessionID: UUID(),
            persistedHostID: hostID,
            displayName: displayName,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + createdAtOffset)
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
