import XCTest
@testable import Tessera
import TmuxControlCore

final class SessionRestoreStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var key: String!
    private var store: SessionRestoreStore!

    override func setUp() {
        super.setUp()
        suiteName = "tessera-session-restore-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        key = "restore-\(UUID().uuidString)"
        store = SessionRestoreStore(defaults: defaults, key: key)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        key = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCompactPresentationTreatsAskAsRestoreOnLaunchWithoutChangingOtherPolicies() {
        XCTAssertEqual(
            SessionRestorePresentationPolicy.effective(stored: .ask, usesCompactShell: true),
            .always
        )
        XCTAssertEqual(
            SessionRestorePresentationPolicy.effective(stored: .always, usesCompactShell: true),
            .always
        )
        XCTAssertEqual(
            SessionRestorePresentationPolicy.effective(stored: .never, usesCompactShell: true),
            .never
        )
        XCTAssertEqual(
            SessionRestorePresentationPolicy.effective(stored: .ask, usesCompactShell: false),
            .ask
        )
    }

    func test_saveAndLoad_roundTripsDocument() {
        let selected = UUID()
        let snapshot = makeSnapshot(liveSessionID: selected)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

        store.save(
            sessions: [snapshot],
            selectedSessionID: selected,
            savedAt: savedAt
        )

        let loaded = store.load()
        XCTAssertEqual(loaded?.schemaVersion, SessionRestoreDocument.currentSchemaVersion)
        XCTAssertEqual(loaded?.savedAt, savedAt)
        XCTAssertEqual(loaded?.sessions, [snapshot])
        XCTAssertEqual(loaded?.selectedSessionID, selected)
    }

    func test_save_dropsUnknownSelectedID() {
        let snapshot = makeSnapshot()

        store.save(sessions: [snapshot], selectedSessionID: UUID())

        XCTAssertNil(store.load()?.selectedSessionID)
    }

    func test_clear_removesStoredDocument() {
        store.save(sessions: [makeSnapshot()], selectedSessionID: nil)

        store.clear()

        XCTAssertNil(store.load())
    }

    func test_load_invalidJSON_clearsAndReturnsNil() {
        defaults.set(Data("not json".utf8), forKey: key)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: key))
    }

    func test_load_unknownSchema_clearsAndReturnsNil() throws {
        let document = SessionRestoreDocument(
            schemaVersion: SessionRestoreDocument.currentSchemaVersion + 1,
            savedAt: Date(),
            sessions: [makeSnapshot()],
            selectedSessionID: nil
        )
        defaults.set(try JSONEncoder().encode(document), forKey: key)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: key))
    }

    func test_effectivePlainShellModeRoundTripsWithoutChangingSavedHostPreference() {
        let snapshot = SessionRestoreSnapshot(
            liveSessionID: UUID(),
            persistedHostID: UUID(),
            displayName: "no-tmux host",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            effectiveLaunchMode: .customCommand
        )

        store.save(sessions: [snapshot], selectedSessionID: snapshot.liveSessionID)

        XCTAssertEqual(store.load()?.sessions.first?.effectiveLaunchMode, .customCommand)
    }

    func test_tmuxUnavailableKnowledgeSurvivesRestoreDeclineAndLaterSuccessClearsIt() {
        let persistedHostID = UUID()
        let host = Host(
            id: persistedHostID,
            name: "no-tmux host",
            address: "no-tmux.example",
            user: "test",
            launchMode: .autoTmux
        )
        let snapshot = SessionRestoreSnapshot(
            liveSessionID: UUID(),
            persistedHostID: persistedHostID,
            displayName: host.name,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            effectiveLaunchMode: .customCommand
        )

        HostRuntimeStateStore.recordTmuxUnavailable(for: host, defaults: defaults)
        store.save(sessions: [snapshot], selectedSessionID: snapshot.liveSessionID)

        // "Not Now" clears the session snapshot, not learned host runtime state.
        store.clear()

        XCTAssertNil(store.load())
        XCTAssertTrue(
            HostRuntimeStateStore.isTmuxKnownUnavailable(for: host, defaults: defaults)
        )
        XCTAssertFalse(
            HostCardRuntimeBadges.showsTmux(
                savedPreference: true,
                activeSessionUsesTmux: nil,
                tmuxKnownUnavailable: true
            )
        )

        HostRuntimeStateStore.recordTmuxAvailable(for: host, defaults: defaults)

        XCTAssertFalse(
            HostRuntimeStateStore.isTmuxKnownUnavailable(for: host, defaults: defaults)
        )
        XCTAssertTrue(
            HostCardRuntimeBadges.showsTmux(
                savedPreference: true,
                activeSessionUsesTmux: nil,
                tmuxKnownUnavailable: false
            )
        )
    }

    func test_wslTailscaleMTUWarningPersistsUntilConclusiveSafeProbe() {
        let host = Host(
            address: "wsl.example",
            user: "test"
        )
        let warning = WSLTailscaleMTUWarning(
            defaultInterfaceMTU: 1_280,
            tailscaleInterfaceMTU: 1_280
        )

        HostRuntimeStateStore.recordNetworkPathAssessment(
            .warning(warning),
            for: host,
            defaults: defaults
        )
        XCTAssertEqual(
            HostRuntimeStateStore.wslTailscaleMTUWarning(
                for: host,
                defaults: defaults
            ),
            warning
        )

        HostRuntimeStateStore.recordNetworkPathAssessment(
            .unavailable,
            for: host,
            defaults: defaults
        )
        XCTAssertEqual(
            HostRuntimeStateStore.wslTailscaleMTUWarning(
                for: host,
                defaults: defaults
            ),
            warning
        )

        HostRuntimeStateStore.recordNetworkPathAssessment(
            .notAtRisk,
            for: host,
            defaults: defaults
        )
        XCTAssertNil(
            HostRuntimeStateStore.wslTailscaleMTUWarning(
                for: host,
                defaults: defaults
            )
        )
    }

    private func makeSnapshot(
        liveSessionID: UUID = UUID(),
        persistedHostID: UUID = UUID(),
        name: String = "host"
    ) -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            liveSessionID: liveSessionID,
            persistedHostID: persistedHostID,
            displayName: name,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

final class OnboardingFixRegressionTests: XCTestCase {
    func test_editingSecondHostClearsAllFirstHostPasswordMaterial() {
        let firstHostID = UUID()
        let secondHostID = UUID()
        let jumpHostID = UUID()
        var draft = HostEditorCredentialDraft()
        draft.beginEditing(hostID: firstHostID)
        draft.password = String(repeating: "a", count: 48)
        draft.jumpPasswords[jumpHostID] = String(repeating: "b", count: 18)

        draft.beginEditing(hostID: secondHostID)

        XCTAssertEqual(draft.hostID, secondHostID)
        XCTAssertTrue(draft.password.isEmpty)
        XCTAssertTrue(draft.jumpPasswords.isEmpty)
    }

    func test_reenteringSameHostDoesNotEraseInProgressPasswordDraft() {
        let hostID = UUID()
        var draft = HostEditorCredentialDraft()
        draft.beginEditing(hostID: hostID)
        draft.password = String(repeating: "x", count: 20)

        draft.beginEditing(hostID: hostID)

        XCTAssertEqual(draft.password.count, 20)
    }

    func test_generateKeyDraftSurvivesResponsiveViewRemount() {
        let presentation = KeysPagePresentationState()
        presentation.presentGenerator(initialProtection: true)
        presentation.generateDraft.name = "half typed"
        presentation.generateDraft.algorithm = .ecdsaP256

        _ = KeysPageView(presentation: presentation)
        _ = KeysPageView(presentation: presentation)

        XCTAssertTrue(presentation.showGenerateModal)
        XCTAssertEqual(presentation.generateDraft.name, "half typed")
        XCTAssertEqual(presentation.generateDraft.algorithm, .ecdsaP256)
        XCTAssertTrue(presentation.generateDraft.protectWithUserPresence)
    }

    func test_publicKeyCopyPayloadContainsOnlyExactPublicTextAndFeedback() {
        let publicLine = "ssh-ed25519 AAAATEST tessera"

        let payload = PublicKeyCopyPayload(publicKey: publicLine)

        XCTAssertEqual(payload.pasteboardValue, publicLine)
        XCTAssertEqual(payload.feedback, "Public key copied")
        XCTAssertFalse(payload.pasteboardValue.contains("PRIVATE KEY"))
    }

    func test_publicKeySharePayloadContainsOnlyExactPublicText() {
        let publicLine = "ssh-ed25519 AAAATEST tessera"

        let payload = PublicKeySharePayload(publicKey: publicLine)

        XCTAssertEqual(payload.shareValue, publicLine)
        XCTAssertFalse(payload.shareValue.contains("PRIVATE KEY"))
    }

    func test_hostKeyRejectionUsesIntentionalNotConnectedPresentation() {
        let reason = HostKeyRejectedError().localizedDescription

        XCTAssertEqual(
            SessionLaunchFailurePresentation.resolve(reason: reason),
            SessionLaunchFailurePresentation(title: "not connected", isCancellation: true)
        )
        XCTAssertFalse(reason.contains("HostKeyRejectedError"))
    }

    /// The jump-host wording carries a hop label, so the recogniser cannot
    /// compare whole strings — it renders the same catalog entry around a
    /// placeholder and matches what sits on either side. Any label has to work,
    /// including one that contains the sentence's own words.
    func test_jumpHostKeyRejectionAlsoPresentsAsNotConnected() {
        for hopLabel in ["bastion", "host key", "a"] {
            let reason = MoshBootstrapError.hostKeyRejected(hopLabel: hopLabel)
                .localizedDescription

            XCTAssertEqual(
                SessionLaunchFailurePresentation.resolve(reason: reason),
                SessionLaunchFailurePresentation(title: "not connected", isCancellation: true),
                "hop label \(hopLabel)"
            )
        }
    }

    func test_realTransportErrorRemainsConnectionFailure() {
        XCTAssertEqual(
            SessionLaunchFailurePresentation.resolve(reason: "Connection timed out"),
            SessionLaunchFailurePresentation(title: "connection failed", isCancellation: false)
        )
    }

    /// The old recogniser matched the bare phrase anywhere in the reason, so a
    /// transport error that merely mentions a cancelled connection would have
    /// been dressed up as a deliberate decision.
    func test_unrelatedCancellationWordingIsNotTreatedAsHostKeyRejection() {
        XCTAssertEqual(
            SessionLaunchFailurePresentation.resolve(
                reason: "The connection cancelled itself while reading the banner."
            ),
            SessionLaunchFailurePresentation(title: "connection failed", isCancellation: false)
        )
    }

    @MainActor
    func test_liveSessionLabelsEffectivePlainFallbackWithoutMutatingRequestedMode() {
        let host = Host(name: "server", address: "10.0.0.1", user: "test")
        var live = LiveSession(
            session: .ssh(SSHSession(host: host)),
            hostName: "server",
            hostKey: "ssh:test@10.0.0.1:22",
            launchMode: HostLaunchMode.autoTmux
        )

        live.effectiveLaunchMode = HostLaunchMode.customCommand

        XCTAssertEqual(live.launchMode, HostLaunchMode.autoTmux)
        XCTAssertFalse(live.autoTmux)
        XCTAssertEqual(live.displayLabel(in: [live]), "server")
    }

    @MainActor
    func test_recentHostSuppressesSavedTmuxBadgeForEffectivePlainFallback() {
        let persistedHostID = UUID()
        let host = Host(name: "server", address: "10.0.0.1", user: "test")
        var live = LiveSession(
            session: .ssh(SSHSession(host: host)),
            hostName: "server",
            persistedHostID: persistedHostID,
            hostKey: "ssh:test@10.0.0.1:22",
            launchMode: HostLaunchMode.autoTmux
        )
        live.effectiveLaunchMode = HostLaunchMode.customCommand

        let activeTmuxUsage = HostCardRuntimeBadges.activeTmuxUsage(in: [live])
        XCTAssertEqual(activeTmuxUsage[persistedHostID], false)
        XCTAssertFalse(
            HostCardRuntimeBadges.showsTmux(
                savedPreference: true,
                activeSessionUsesTmux: activeTmuxUsage[persistedHostID],
                tmuxKnownUnavailable: false
            )
        )
        XCTAssertTrue(
            HostCardRuntimeBadges.showsTmux(
                savedPreference: true,
                activeSessionUsesTmux: nil,
                tmuxKnownUnavailable: false
            )
        )
    }
}

@MainActor
final class ConnectionActivityStoreTests: XCTestCase {
    func test_activityPersistsAndNeverMovesBackward() throws {
        let suite = "ConnectionActivityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "activity"
        let hostID = UUID()
        let keyID = UUID()
        let later = Date(timeIntervalSince1970: 1_700_000_200)
        let earlier = Date(timeIntervalSince1970: 1_700_000_100)

        let store = ConnectionActivityStore(defaults: defaults, storageKey: storageKey)
        store.recordHostConnection(hostID, at: later)
        store.recordHostConnection(hostID, at: earlier)
        store.recordKeyUse(keyID, at: later)
        store.recordKeyUse(keyID, at: earlier)

        let reloaded = ConnectionActivityStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reloaded.lastConnectedAt(for: hostID), later)
        XCTAssertEqual(reloaded.lastUsedAt(for: keyID), later)
    }

    func test_activityRemovalAndCorruptMetadataFailSafe() throws {
        let suite = "ConnectionActivityStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostID = UUID()
        let keyID = UUID()
        let store = ConnectionActivityStore(defaults: defaults, storageKey: "activity")
        store.recordHostConnection(hostID)
        store.recordKeyUse(keyID)
        store.removeHost(hostID)
        store.removeKey(keyID)

        XCTAssertNil(store.lastConnectedAt(for: hostID))
        XCTAssertNil(store.lastUsedAt(for: keyID))

        defaults.set(Data("not json".utf8), forKey: "corrupt")
        let corrupt = ConnectionActivityStore(defaults: defaults, storageKey: "corrupt")
        XCTAssertNil(corrupt.lastConnectedAt(for: hostID))
        XCTAssertNil(corrupt.lastUsedAt(for: keyID))
    }

    func test_recentOrderingUsesSuccessfulDatesAndStableTieBreaks() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let neverConnected = UUID()
        let newest = Date(timeIntervalSince1970: 1_700_000_200)
        let tied = Date(timeIntervalSince1970: 1_700_000_100)

        XCTAssertEqual(
            RecentHostOrdering.sortedIDs(
                hostIDs: [neverConnected, third, second, first],
                sortOrder: [first: 2, second: 1, third: 3, neverConnected: 0],
                lastConnectedAt: [first: tied, second: tied, third: newest],
                limit: 3
            ),
            [third, second, first]
        )
    }

    func test_renderReadyAttributionIgnoresReplayAndQuickConnect() {
        let savedHostID = UUID()
        let saved = LiveSession(
            session: .ssh(SSHSession(host: Host(address: "saved.example"))),
            hostName: "saved",
            persistedHostID: savedHostID,
            hostKey: "saved",
            launchMode: .autoTmux
        )
        let quick = LiveSession(
            session: .ssh(SSHSession(host: Host(address: "quick.example"))),
            hostName: "quick",
            persistedHostID: nil,
            hostKey: "quick",
            launchMode: .autoTmux
        )

        XCTAssertEqual(
            ConnectionActivityAttribution.newlyReadyHostIDs(
                oldReadyIDs: [],
                newReadyIDs: [saved.id, quick.id],
                connectedSessionIDs: [saved.id, quick.id],
                sessions: [saved, quick]
            ),
            [savedHostID]
        )
        XCTAssertTrue(
            ConnectionActivityAttribution.newlyReadyHostIDs(
                oldReadyIDs: [saved.id],
                newReadyIDs: [saved.id],
                connectedSessionIDs: [saved.id],
                sessions: [saved]
            ).isEmpty
        )
        XCTAssertTrue(
            ConnectionActivityAttribution.newlyReadyHostIDs(
                oldReadyIDs: [],
                newReadyIDs: [saved.id],
                connectedSessionIDs: [],
                sessions: [saved]
            ).isEmpty
        )
    }
}

@MainActor
final class TmuxOwnedGeometryFileStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxOwnedGeometryFileStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tmux-owned-geometry.json")
    }

    private func record(_ generation: UInt64, _ columns: Int = 92) -> TmuxOwnedGeometryRecord {
        .init(generation: generation, sizes: [.init(columns: columns, rows: 38)])
    }

    /// A relaunch reads what the dead process kept: per host and tmux
    /// session, each generation's grids together.
    func test_aNewProcessReadsTheRecordsKeptPerHostAndSession() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = Host(name: "dev", address: "dev.example", port: 22, user: "dev", password: "")
        let other = Host(name: "dev", address: "other.example", port: 22, user: "dev", password: "")

        let first = TmuxOwnedGeometryFileStore(url: url)
        first.store(for: host).keep(record(3), "main")
        first.store(for: host).keep(record(3, 100), "main")
        first.store(for: host).keep(record(4), "main")
        first.store(for: other).keep(record(9), "main")
        first.flushForTesting()

        let relaunched = TmuxOwnedGeometryFileStore(url: url)
        XCTAssertEqual(relaunched.store(for: host).records("main"), [
            record(4), .init(generation: 3, sizes: [.init(columns: 92, rows: 38), .init(columns: 100, rows: 38)]),
        ])
        XCTAssertEqual(relaunched.store(for: other).records("main"), [record(9)])
        XCTAssertEqual(relaunched.store(for: host).records("other"), [])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("dev.example") || text.contains("main"), "only hashed keys are stored")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func test_onlyTheNewestGenerationsAndSessionsStay() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = Host(name: "dev", address: "dev.example", port: 22, user: "dev", password: "")
        let store = TmuxOwnedGeometryFileStore(url: url)
        let limit = TmuxOwnedGeometryRecord.restoreLimit
        for generation in 1...UInt64(limit + 3) { store.store(for: host).keep(record(generation), "main") }
        XCTAssertEqual(store.store(for: host).records("main").map(\.generation),
                       Array((4...UInt64(limit + 3)).reversed()))

        for index in 0..<TmuxOwnedGeometryFileStore.sessionLimit { store.store(for: host).keep(record(1), "s\(index)") }
        XCTAssertEqual(store.store(for: host).records("main"), [], "the least recently kept session goes")
        XCTAssertEqual(store.store(for: host).records("s0"), [record(1)])
        store.flushForTesting()
    }

    /// `store(for:)` reads the file off main ahead of the first attach; a
    /// keep that needed the file first is never undone by that read.
    func test_aPreloadNeverUndoesAKeep() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = Host(name: "dev", address: "dev.example", port: 22, user: "dev", password: "")
        let earlier = TmuxOwnedGeometryFileStore(url: url)
        earlier.store(for: host).keep(record(3), "main")
        earlier.flushForTesting()

        let store = TmuxOwnedGeometryFileStore(url: url)
        store.store(for: host).keep(record(4), "main")
        store.flushForTesting()
        // The preload's result reaches main behind everything queued so far.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(store.store(for: host).records("main"), [record(4), record(3)])

        let preloaded = TmuxOwnedGeometryFileStore(url: url)
        let records = preloaded.store(for: host).records
        preloaded.flushForTesting()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(records("main"), [record(4), record(3)])
    }

    /// Android's `TmuxOwnedGeometryStore.key` derives the same digest.
    func test_theKeyIsTheDigestOfHostAndSession() {
        XCTAssertEqual(TmuxOwnedGeometryFileStore.key(hostKey: "dev@dev.example:22", session: "main"),
                       "e5dd6243ef3e958d54310afd3c5bed0e07c2144b60a91430d2c54840656a2143")
    }

    func test_anUnreadableFileKeepsNothing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let host = Host(name: "dev", address: "dev.example", port: 22, user: "dev", password: "")
        XCTAssertEqual(TmuxOwnedGeometryFileStore(url: url).store(for: host).records("main"), [])
    }
}
