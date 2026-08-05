import XCTest
@testable import Tessera

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

    func test_hostKeyRejectionUsesIntentionalNotConnectedPresentation() {
        let reason = HostKeyRejectedError().localizedDescription

        XCTAssertEqual(
            SessionLaunchFailurePresentation.resolve(reason: reason),
            SessionLaunchFailurePresentation(title: "not connected", isCancellation: true)
        )
        XCTAssertFalse(reason.contains("HostKeyRejectedError"))
    }

    func test_realTransportErrorRemainsConnectionFailure() {
        XCTAssertEqual(
            SessionLaunchFailurePresentation.resolve(reason: "Connection timed out"),
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
