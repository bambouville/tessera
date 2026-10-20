import SwiftUI
import SwiftData
import Crypto
import Security
import LocalAuthentication
import MoshBridge
import PortForwarding
import TesseraCore
import TmuxControl
#if DEBUG
import class SwiftTerm.Terminal
import class SwiftTerm.TerminalView
import TmuxControlCore
import Combine
import NIOSSH
#endif
import UserNotifications

#if DEBUG
/// Typed inputs for the simulator-only Continuity UI oracle. Keeping the
/// descriptor and optional saved-host seed together prevents the UI harness
/// from silently testing a different route than the injected activity.
struct ContinuityDebugHarnessScenario {
    enum SavedHostSeed {
        case none
        case exact(UUID)
        case endpoint(UUID)
    }

    let descriptor: SessionActivityDescriptor
    let savedHostSeed: SavedHostSeed
    let pausesAfterResolution: Bool
    let replaysAfterLockedReceive: Bool

    static func make(value: String) -> ContinuityDebugHarnessScenario? {
        let usesMosh = value.contains("mosh")
        let usesTmux = value.contains("tmux")
        let transport: HostTransport = usesMosh ? .mosh : .ssh
        let launchMode: HostLaunchMode = usesTmux ? .pinnedTmux : .customCommand

        let descriptorID: UUID
        let seed: SavedHostSeed
        let address: String
        switch value {
        case "match-exact-ssh-tmux":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F11")!
            seed = .exact(descriptorID)
            address = "exact-ssh-tmux.continuity.invalid"
        case "match-endpoint-mosh-tmux":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F22")!
            seed = .endpoint(
                UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F32")!
            )
            address = "endpoint-mosh-tmux.continuity.invalid"
        case "match-exact-plain-ssh":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F13")!
            seed = .exact(descriptorID)
            address = "exact-plain-ssh.continuity.invalid"
        case "match-endpoint-plain-mosh":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F24")!
            seed = .endpoint(
                UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F34")!
            )
            address = "endpoint-plain-mosh.continuity.invalid"
        case "locked-ssh-tmux":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F40")!
            seed = .none
            address = "locked.continuity.invalid"
        case "ssh-tmux", "mosh-tmux", "plain-ssh", "plain-mosh":
            descriptorID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9F09")!
            seed = .none
            address = "continuity.invalid"
        default:
            return nil
        }

        let endpoint = SessionActivityEndpoint(
            hostID: descriptorID,
            name: "continuity harness",
            user: "dev",
            address: address,
            port: 22,
            transport: transport,
            hostKeyFingerprint: "U0hBMjU2OmNvbnRpbnVpdHktaGFybmVzcw=="
        )
        return ContinuityDebugHarnessScenario(
            descriptor: SessionActivityDescriptor(
                endpoint: endpoint,
                launchMode: launchMode,
                tmuxSessionName: usesTmux ? "continuity-harness" : nil
            ),
            savedHostSeed: seed,
            pausesAfterResolution: value.hasPrefix("match-"),
            replaysAfterLockedReceive: value.hasPrefix("locked-")
        )
    }
}

/// Simulator-only live continuation harness: seeds a real saved host (with a
/// password or locally generated key credential) and injects a matching descriptor so the exact
/// production fast path — resolve, connect, launch, render-ready, overlay
/// dismissal — runs against a disposable integration fixture.
struct ContinuityLiveHarnessConfiguration: Codable {
    static let hostID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9FEE")!

    var name: String
    var user: String
    var address: String
    var port: Int
    var password: String?
    /// Public-key QA never receives private material or a fallback password.
    var generateSourceKey: Bool?
    var injectDescriptor: Bool?
    /// Optional fixture pin obtained through the authenticated VPS control
    /// channel, not from the app-facing connection under test.
    var verifiedFixtureHostKey: String?
    var transport: HostTransport
    var launchMode: HostLaunchMode
    var tmuxSessionName: String?

    static func load() -> ContinuityLiveHarnessConfiguration? {
        guard let raw = ProcessInfo.processInfo.environment[
            "TESSERA_CONTINUITY_LIVE_HARNESS"
        ], let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var descriptor: SessionActivityDescriptor {
        SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: Self.hostID,
                name: name,
                user: user,
                address: address,
                port: port,
                transport: transport
            ),
            launchMode: launchMode,
            tmuxSessionName: tmuxSessionName
        )
    }
}
#endif

@main
struct TesseraApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var appearance: AppearancePreferences
    @State private var appLockController: AppLockController
    @State private var onboardingController: OnboardingController
    @State private var appPhase: AppPhase
    @State private var bellController: BellController
    @State private var tunnelsRegistry: TunnelsRegistry
    @State private var swipePadStore: SwipePadProfileStore
    @State private var shortcutStore: ShortcutStore
    @State private var dictationController: SpeechDictationController
    @State private var hostBackgrounds: HostTerminalBackgroundStore
    @State private var connectionActivity: ConnectionActivityStore
    @State private var activityBroadcaster: ActivityBroadcaster
    @State private var continuationCoordinator: ContinuationCoordinator
    @State private var crossDevicePairingCoordinator: CrossDevicePairingCoordinator
    @State private var bootstrapCoordinator: BootstrapCoordinator
    @State private var enrollmentCoordinator: EnrollmentCoordinator
    @State private var hostAccessStore: HostAccessStore
    #if DEBUG
    @State private var bootstrapNetworkHarness: BootstrapNetworkHarness?
    #endif
    @State private var isInitialColdLaunch: Bool

    /// The single on-disk SwiftData container, wired to `TesseraMigrationPlan`.
    /// Built once in `init` so the DEBUG seeder and the live scene share one
    /// model list + migration plan (no second container over the same store).
    private let modelContainer: ModelContainer

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_QR_REVIEW"] != nil {
                PairingReviewHarness()
            } else if let bootstrapNetworkHarness {
                BootstrapNetworkHarnessView(harness: bootstrapNetworkHarness)
            } else {
                productionRootView
            }
            #else
            productionRootView
            #endif
        }
        .modelContainer(modelContainer)
    }

    private var productionRootView: some View {
            RootView(
                appearance: appearance,
                appLockController: appLockController,
                onboardingController: onboardingController,
                appPhase: appPhase,
                bellController: bellController,
                tunnelsRegistry: tunnelsRegistry,
                swipePadStore: swipePadStore,
                shortcutStore: shortcutStore,
                dictationController: dictationController,
                hostBackgrounds: hostBackgrounds,
                connectionActivity: connectionActivity,
                activityBroadcaster: activityBroadcaster,
                continuationCoordinator: continuationCoordinator,
                crossDevicePairingCoordinator: crossDevicePairingCoordinator,
                bootstrapCoordinator: bootstrapCoordinator,
                enrollmentCoordinator: enrollmentCoordinator,
                hostAccessStore: hostAccessStore,
                isInitialColdLaunch: $isInitialColdLaunch
            )
            .background(AppSwitcherPrivacyGate(appearance: appearance).frame(width: 0, height: 0))
            .onChange(of: scenePhase) { _, newPhase in
                appLockController.handleScenePhaseChange(newPhase)
                let isActive = (newPhase == .active)
                appPhase.update(newPhase)
                if newPhase == .active {
                    hostAccessStore.applicationDidBecomeActive()
                }
                if newPhase == .background {
                    bootstrapCoordinator.stopForBackground()
                    crossDevicePairingCoordinator.applicationDidLockOrBackground()
                    enrollmentCoordinator.applicationDidEnterBackground()
                }

                let phase = describe(newPhase)
                DiagnosticLogStore.appendApp("scene-phase phase=\(phase) forwardingRunning=\(tunnelsRegistry.globalRunningCount)")
                ForwardingBackgroundKeepAlive.shared.update(
                    isActive: isActive,
                    runningCount: tunnelsRegistry.globalRunningCount,
                    reason: "scenePhase=\(phase)"
                )
            }
    }

    private func describe(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    /// Seed the dev key + a few demo hosts on first launch. DEBUG-only.
    init() {
        BrokenPipeGuard.install()
        LiteralTextInputPolicy.install()
        UNUserNotificationCenter.current().delegate = TesseraNotificationDelegate.shared
        TmuxDiagnostics.sink = { message in
            DiagnosticLogStore.appendTmux(message)
        }

        let appearance = AppearancePreferences()
        _appearance = State(initialValue: appearance)
        _appLockController = State(initialValue: AppLockController(appearance: appearance))
        _onboardingController = State(initialValue: OnboardingController(appearance: appearance))
        let appPhase = AppPhase()
        _appPhase = State(initialValue: appPhase)
        _bellController = State(initialValue: BellController(appearance: appearance, appPhase: appPhase))
        _tunnelsRegistry = State(initialValue: TunnelsRegistry())
        _swipePadStore = State(initialValue: SwipePadProfileStore())
        _shortcutStore = State(initialValue: ShortcutStore())
        _dictationController = State(initialValue: SpeechDictationController(appearance: appearance))
        _hostBackgrounds = State(initialValue: HostTerminalBackgroundStore())
        _connectionActivity = State(initialValue: ConnectionActivityStore.shared)
        _activityBroadcaster = State(initialValue: ActivityBroadcaster())
        _continuationCoordinator = State(initialValue: ContinuationCoordinator())
        _crossDevicePairingCoordinator = State(initialValue: CrossDevicePairingCoordinator())
        #if DEBUG
        let bootstrapNetworkHarness = BootstrapNetworkHarness.fromEnvironment()
        let usesCompactNavigationHarness = ProcessInfo.processInfo.environment[
            "TESSERA_COMPACT_NAVIGATION_HARNESS"
        ] == "1"
        let usesHostAccessHarness = ProcessInfo.processInfo.environment[
            "TESSERA_HOST_ACCESS_HARNESS"
        ] == "1"
        _bootstrapNetworkHarness = State(initialValue: bootstrapNetworkHarness)
        _bootstrapCoordinator = State(
            initialValue: bootstrapNetworkHarness?.coordinator ?? BootstrapCoordinator()
        )
        #else
        _bootstrapCoordinator = State(initialValue: BootstrapCoordinator())
        #endif
        _enrollmentCoordinator = State(initialValue: EnrollmentCoordinator())
        #if DEBUG
        // The continuity harness drives Handoff mechanics end to end, and
        // DEBUG harnesses never exercise production admission — run it with
        // an entitled store so the free-limit purchase prompt can't hijack
        // the prefill flows under test.
        let hostAccessClient: StoreKitClient =
            ProcessInfo.processInfo.environment["TESSERA_CONTINUITY_HARNESS"] != nil
            ? HostAccessHarnessClient(state: .legacy)
            : LiveStoreKitClient()
        _hostAccessStore = State(initialValue: HostAccessStore(client: hostAccessClient))
        #else
        _hostAccessStore = State(initialValue: HostAccessStore(client: LiveStoreKitClient()))
        #endif
        _isInitialColdLaunch = State(initialValue: appearance.requireFaceIDToUnlock)

        do {
            #if DEBUG
            modelContainer = try TesseraModelContainer.make(
                inMemory: bootstrapNetworkHarness != nil
                    || usesCompactNavigationHarness
                    || usesHostAccessHarness
            )
            #else
            modelContainer = try TesseraModelContainer.make()
            #endif
        } catch {
            // Crash loudly rather than silently falling back to an empty store:
            // a migration failure here means the schema/plan are wrong, and we
            // want to catch that in TestFlight before it ships and resets real
            // users' hosts. (The previous `.modelContainer(for:)` modifier also
            // fatal-errored on build failure.)
            fatalError("[Tessera] Failed to build SwiftData ModelContainer: \(error)")
        }

        registerEmbeddedFonts()

        // Brand the compact-root tab bar labels: the iPad sidebar's navigation
        // rows are JetBrains Mono, so the iPhone's equivalent chrome matches.
        // Appearance is a no-op if the embedded font failed to register.
        if let tabFont = UIFont(name: "JetBrainsMono-Regular", size: 10) {
            let attributes: [NSAttributedString.Key: Any] = [.font: tabFont]
            UITabBarItem.appearance().setTitleTextAttributes(attributes, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(attributes, for: .selected)
        }

        #if DEBUG
        // Before any other seeding: the restore harness wipes its own fixtures
        // and writes the document the first composition is about to read, and
        // `attemptStartupRestoreIfReady` must see a settled world rather than
        // one still being built underneath it.
        MainActor.assumeIsolated {
            SessionRestoreDebugHarness.applyIfRequested(into: modelContainer)
        }
        if bootstrapNetworkHarness == nil && !usesCompactNavigationHarness && !usesHostAccessHarness {
            seedDevStateIfNeeded(into: modelContainer)
            DiagnosticLogStore.appendApp(
                "moshbridge-probe probe=\(MoshBridgeProbe.probe()) primitive=\(MoshBridgeProbe.primitiveProbe()) crypto=\(MoshBridgeProbe.cryptoProbe())"
            )
        }
        #endif
        #if DEBUG
        if bootstrapNetworkHarness == nil && !usesCompactNavigationHarness && !usesHostAccessHarness {
            reconcileStoredKeySecurity(
                into: modelContainer,
                globalOwnerPresencePreference: appearance.requireBiometricForKeyUse
            )
        }
        #else
        reconcileStoredKeySecurity(
            into: modelContainer,
            globalOwnerPresencePreference: appearance.requireBiometricForKeyUse
        )
        #endif
    }
}

/// Repairs legacy software-key accessibility/ACLs and records integrity facts
/// without loading or logging any private material unless a checked migration
/// is actually required. User intent is preserved independently from the
/// current keychain boundary so reconciliation never silently changes a choice.
@MainActor
private func reconcileStoredKeySecurity(
    into container: ModelContainer,
    globalOwnerPresencePreference: Bool
) {
    let context = ModelContext(container)
    let persistence = KeyLifecyclePersistence.live(context)
    let metadata = KeySecurityMetadataStore()

    let deletionReport = StoredKeyLifecycle.reconcilePendingDeletions(
        persistence: persistence,
        metadata: metadata
    )
    if deletionReport.completed > 0 || deletionReport.failed > 0 {
        DiagnosticLogStore.appendKeys(
            "deletion-reconcile completed=\(deletionReport.completed) failed=\(deletionReport.failed)"
        )
    }

    do {
        let keys = try context.fetch(FetchDescriptor<StoredKey>())
        do {
            let report = try KeyStore.integrityReport(
                metadataKeyIDs: Set(keys.map(\.id))
            )
            DiagnosticLogStore.appendKeys(
                "integrity-scan metadataOnly=\(report.metadataOnlyKeyIDs.count) orphaned=\(report.orphanedKeyIDs.count) invalidAccounts=\(report.invalidAccountCount)"
            )
        } catch {
            // Some physical devices gate a match-all attributes query when the
            // service contains a presence-protected item. Inventory is useful
            // for orphan cleanup, but it must never prevent exact, noninteractive
            // reconciliation of every known key below.
            DiagnosticLogStore.appendKeys(
                "integrity-inventory unavailable error='\(error.localizedDescription)'"
            )
        }

        var repairFailures = 0
        var preferenceBoundaryMismatches = 0
        var mismatchedMaterial = 0
        for key in keys {
            do {
                let protection = try KeyStore.materialProtection(forKeyID: key.id)
                switch protection {
                case .missing:
                    metadata.markMaterialIntegrity(.missing, for: key.id)
                    continue

                case .userPresence:
                    metadata.markBoundaryProtection(.userPresence, for: key.id)
                    let reconciledPreference = KeyOwnerPresencePolicy
                        .reconciledKeyPreference(
                            currentPreference: key.requiresBiometric,
                            isSecureEnclave: key.isSecureEnclave,
                            boundaryProtection: .userPresence
                        )
                    if reconciledPreference != key.requiresBiometric {
                        key.requiresBiometric = reconciledPreference
                    }
                    if !reconciledPreference {
                        // `requiresBiometric` is the user's requested policy,
                        // not a cache of Keychain attributes. Older builds only
                        // changed this SwiftData flag, so deriving it from the
                        // surviving ACL here re-enables a setting the user had
                        // turned off. Preserve intent; authentication paths veto
                        // all prompting while OFF and fail noninteractively if
                        // the older ACL still withholds the key bytes.
                        preferenceBoundaryMismatches += 1
                    }

                case .deviceUnlocked(let deviceOnly):
                    if key.isSecureEnclave {
                        // Secure Enclave keys are deliberately device-unlocked
                        // at the immutable hardware boundary. Preserve the
                        // mutable user preference; Tessera's shared app gate
                        // enforces it before every supported key-use path.
                        let reconciledPreference = KeyOwnerPresencePolicy
                            .reconciledKeyPreference(
                                currentPreference: key.requiresBiometric,
                                isSecureEnclave: true,
                                boundaryProtection: .deviceUnlocked
                            )
                        if reconciledPreference != key.requiresBiometric {
                            key.requiresBiometric = reconciledPreference
                        }
                        metadata.markBoundaryProtection(.deviceUnlocked, for: key.id)
                    } else if globalOwnerPresencePreference
                                && key.requiresBiometric {
                        try KeyStore.updateProtection(
                            forKeyID: key.id,
                            to: .userPresence,
                            isSecureEnclave: false
                        )
                        metadata.markBoundaryProtection(.userPresence, for: key.id)
                    } else {
                        if deviceOnly {
                            try KeyStore.migrateSoftwareKeyAccessibilityIfNeeded(
                                forKeyID: key.id,
                                isSecureEnclave: false
                            )
                        }
                        metadata.markBoundaryProtection(.deviceUnlocked, for: key.id)
                    }
                }

                let integrity = KeyStore.privateMaterialIntegrity(
                    forKeyID: key.id,
                    algorithm: key.algorithm,
                    isSecureEnclave: key.isSecureEnclave,
                    expectedAuthorizedKeysLine: key.authorizedKeysLine
                )
                metadata.markMaterialIntegrity(integrity, for: key.id)
                if integrity == .mismatched || integrity == .invalid {
                    mismatchedMaterial += 1
                }
            } catch {
                repairFailures += 1
            }
        }
        if context.hasChanges {
            try persistence.save(.integrityReconciliation)
        }
        if mismatchedMaterial > 0 {
            DiagnosticLogStore.appendKeys(
                "integrity-material rejected=\(mismatchedMaterial)"
            )
        }
        if repairFailures > 0 {
            DiagnosticLogStore.appendKeys(
                "integrity-repair failures=\(repairFailures)"
            )
        }
        if preferenceBoundaryMismatches > 0 {
            DiagnosticLogStore.appendKeys(
                "protection-preference mismatches=\(preferenceBoundaryMismatches)"
            )
        }
    } catch {
        // Counts and typed status are safe; never include key IDs, queries, or
        // data in this diagnostic boundary.
        DiagnosticLogStore.appendKeys(
            "integrity-scan failed error='\(error.localizedDescription)'"
        )
    }
}

struct RootView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Bindable var appearance: AppearancePreferences
    @Bindable var appLockController: AppLockController
    @Bindable var onboardingController: OnboardingController
    @Bindable var appPhase: AppPhase
    @Bindable var bellController: BellController
    @Bindable var tunnelsRegistry: TunnelsRegistry
    @Bindable var swipePadStore: SwipePadProfileStore
    @Bindable var shortcutStore: ShortcutStore
    @Bindable var dictationController: SpeechDictationController
    @Bindable var hostBackgrounds: HostTerminalBackgroundStore
    @Bindable var connectionActivity: ConnectionActivityStore
    @Bindable var activityBroadcaster: ActivityBroadcaster
    @Bindable var continuationCoordinator: ContinuationCoordinator
    @Bindable var crossDevicePairingCoordinator: CrossDevicePairingCoordinator
    @Bindable var bootstrapCoordinator: BootstrapCoordinator
    @Bindable var enrollmentCoordinator: EnrollmentCoordinator
    @Bindable var hostAccessStore: HostAccessStore
    @Binding var isInitialColdLaunch: Bool
    @State private var didInjectContinuityHarness = false

    var body: some View {
        ZStack {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_SETUP_FLOW_HARNESS"] == "1" {
                SetupFlowPresentationHarness()
            } else if ProcessInfo.processInfo.environment["TESSERA_COMPACT_NAVIGATION_HARNESS"] == "1" {
                CompactNavigationTransitionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_IPHONE_KEYBOARD_HARNESS"] == "1" {
                IPhoneKeyboardHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_ACCESSORY_EDITOR_HARNESS"] == "1" {
                AccessoryEditorHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_IPHONE_SESSION_HARNESS"] == "1" {
                IPhoneCompanionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_EMPTY_CAPTURE_HARNESS"] == "1" {
                TmuxEmptyCaptureHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SPLIT_BATCH_HARNESS"] == "1" {
                SplitBatchHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_NETWORK_PATH_WARNING_HARNESS"] == "1" {
                NetworkPathWarningHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TERMINAL_CANVAS_HARNESS"] == "1" {
                TerminalCanvasHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SESSION_QUEUE_HARNESS"] == "1" {
                SessionQueueHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_HARDWARE_KEY_HARNESS"] == "1" {
                HardwareKeyHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_V2_HARNESS"] == "1" {
                AgentCenterV2FixtureView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_HARNESS"] == "1" {
                AgentAttentionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] == "1" {
                TmuxWindowCloseHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] == "1" {
                TmuxWindowListHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_GRID_AUTHORITY_HARNESS"] == "1" {
                GridAuthorityEventHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_UPLOAD_HARNESS"] == "1" {
                UploadIngressHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_FILES_HARNESS"] == "1" {
                FilesPanelHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SCROLL_HARNESS"] == "1" {
                TerminalScrollHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TOUCH_SCROLL_HARNESS"] == "1" {
                TerminalTouchScrollHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1" {
                LiveScrollVisualHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_HOST_ACCESS_HARNESS"] == "1" {
                HostAccessHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SWIPEPAD_OVERFLOW_HARNESS"] == "1" {
                SwipePadOverflowHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SWIPEPAD_STATUS_HARNESS"] == "1" {
                SwipePadStatusHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SWIPEPAD_DICTATION_HARNESS"] == "1" {
                SwipePadDictationHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_SWIPEPAD_FAN_HARNESS"] == "1" {
                SwipePadFanHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_HARNESS"] == "1" {
                MarkdownPreviewHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_APPEARANCE_HARNESS"] == "1" {
                AppearanceSettingsHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TUNNEL_BROWSER_HARNESS"] == "1" {
                TunnelBrowserHarnessView()
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .environment(appearance)
        .environment(appLockController)
        .environment(\.terminalInputAllowed, { !appLockController.isLocked })
        .environment(onboardingController)
        .environment(appPhase)
        .environment(bellController)
        .environment(tunnelsRegistry)
        .environment(swipePadStore)
        .environment(shortcutStore)
        .environment(dictationController)
        .environment(hostBackgrounds)
        .environment(connectionActivity)
        .environment(activityBroadcaster)
        .environment(continuationCoordinator)
        .environment(crossDevicePairingCoordinator)
        .environment(bootstrapCoordinator)
        .environment(enrollmentCoordinator)
        .environment(hostAccessStore)
        .environment(\.designTokens, appearance.tokens(systemColorScheme: systemScheme))
        .preferredColorScheme(swiftUIScheme(for: appearance.mode))
        .task { prewarmTerminalBackgrounds() }
        .onChange(of: appearance.requireFaceIDToUnlock) { _, _ in
            appLockController.reconcileRequirement(enforceNewlyEnabled: true)
        }
        .onChange(of: appearance.handoffSessionsEnabled) { _, enabled in
            activityBroadcaster.setEnabled(enabled)
        }
        .onChange(of: appLockController.isLocked) { _, isLocked in
            activityBroadcaster.setLocked(isLocked)
            if isLocked {
                continuationCoordinator.applicationDidLock()
                crossDevicePairingCoordinator.applicationDidLockOrBackground()
                if bootstrapCoordinator.isPresented {
                    bootstrapCoordinator.cancel()
                }
                if enrollmentCoordinator.phase.isPresented {
                    enrollmentCoordinator.applicationDidLock()
                }
            } else {
                continuationCoordinator.replayAfterUnlock()
            }
        }
        .onChange(of: appPhase.isActive) { _, isActive in
            activityBroadcaster.setApplicationActive(isActive)
        }
        .onContinueUserActivity(ActivityBroadcaster.activityType) { activity in
            _ = continuationCoordinator.receive(
                activity,
                isLocked: appLockController.isLocked
            )
        }
        .onAppear {
            activityBroadcaster.setEnabled(appearance.handoffSessionsEnabled)
            activityBroadcaster.setLocked(appLockController.isLocked)
            activityBroadcaster.setApplicationActive(appPhase.isActive)
            // Starts the one-shot StoreKit product/entitlement pipeline
            // alongside the other controller starts; the store owns its
            // transaction-update task from here on.
            #if DEBUG
            // The host-access harness injects its own scripted store into
            // the harness subtree; the app-level live client must not query
            // (or finish transactions on) the real storefront for those
            // launches.
            if ProcessInfo.processInfo.environment["TESSERA_HOST_ACCESS_HARNESS"] != "1" {
                hostAccessStore.start()
            }
            #else
            hostAccessStore.start()
            #endif
            injectContinuityHarnessIfRequested()
        }
    }

    /// Force-decode every background picture a session could mount this run
    /// (global + per-host overrides, each at its in-use blur) into the image
    /// cache, off-main — so opening the first session hits the cache instead
    /// of decoding a full-size JPEG inside SwiftUI body evaluation.
    private func prewarmTerminalBackgrounds() {
        var requests: [(id: String, blur: Double)] = []
        if appearance.terminalBackgroundUsesImage,
           let id = appearance.terminalBackgroundImageID {
            requests.append((id: id, blur: appearance.terminalBackgroundBlur))
        }
        for override in hostBackgrounds.overrides.values where override.mode == .image {
            if let id = override.imageID {
                requests.append((id: id, blur: override.blur))
            }
        }
        TerminalBackgroundImageStore.prewarm(requests)
    }

    /// Simulator Handoff is unavailable. This DEBUG-only input drives the same
    /// coordinator path as a real activity without granting connection intent:
    /// a never-seen descriptor opens the prefilled editor, while a supplied
    /// base64 descriptor can exercise exact/endpoint matching against seeded
    /// test data. No production launch reads this environment variable.
    private func injectContinuityHarnessIfRequested() {
        #if DEBUG
        if !didInjectContinuityHarness,
           let live = ContinuityLiveHarnessConfiguration.load() {
            didInjectContinuityHarness = true
            guard live.injectDescriptor != false else { return }
            Task { @MainActor in
                if let line = live.verifiedFixtureHostKey {
                    guard let key = try? NIOSSHPublicKey(openSSHPublicKey: line) else {
                        NSLog("[ContinuityLiveHarness] invalid fixture host key")
                        return
                    }
                    await KnownHostsStore.shared.trust(
                        key, for: "\(live.address):\(live.port)"
                    )
                }
                // ContentView needs time to mount observation and seed the
                // saved host before the descriptor arrives.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let data = try? live.descriptor.handoffData() else {
                    NSLog("[ContinuityLiveHarness] descriptor encode failed")
                    return
                }
                let accepted = continuationCoordinator.receive(
                    data: data,
                    isLocked: appLockController.isLocked
                )
                NSLog("[ContinuityLiveHarness] injected accepted=\(accepted)")
            }
            return
        }
        guard !didInjectContinuityHarness,
              let value = ProcessInfo.processInfo.environment[
                "TESSERA_CONTINUITY_HARNESS"
              ],
              !value.isEmpty
        else { return }
        didInjectContinuityHarness = true

        Task { @MainActor in
            // Let ContentView mount its observation before publishing input.
            try? await Task.sleep(nanoseconds: 250_000_000)
            let data: Data?
            let scenario: ContinuityDebugHarnessScenario?
            if let supplied = Data(base64Encoded: value) {
                data = supplied
                scenario = nil
            } else {
                scenario = ContinuityDebugHarnessScenario.make(value: value)
                data = try? scenario?.descriptor.handoffData()
            }
            guard let data else {
                DiagnosticLogStore.appendApp(
                    "continuity harness result=rejected reason=invalid-payload"
                )
                return
            }
            _ = continuationCoordinator.receive(
                data: data,
                isLocked: scenario?.replaysAfterLockedReceive == true
                    ? true
                    : appLockController.isLocked
            )
            if scenario?.replaysAfterLockedReceive == true {
                // Make the locked boundary externally observable to XCUITest:
                // the credential editor must remain absent before this replay.
                try? await Task.sleep(for: .seconds(5))
                continuationCoordinator.replayAfterUnlock()
            }
        }
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        // The restore gate needs a launch that already has a host open before
        // restore evaluates — a share target, an agent notification tap, a
        // continuity handoff. Empty unless that case asked for it.
        #if DEBUG
        ContentView(debugInitialSessions: SessionRestoreDebugHarness.preopenedSessions)
            .allowsHitTesting(!appLockController.isLocked)
        #else
        ContentView()
            .allowsHitTesting(!appLockController.isLocked)
        #endif

        if appLockController.isLocked {
            LockScreenView(
                isInitialColdLaunch: isInitialColdLaunch,
                onInitialColdLaunchPrompted: {
                    isInitialColdLaunch = false
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 1.05)))
            .zIndex(10)
        }
    }

    private func swiftUIScheme(for mode: AppearanceModeOption) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

#if DEBUG
/// Host-free oracle for the takeover veil. The controller's one Equatable
/// presentation (S3′) drives both the top chip and the veil; a tap goes
/// through the session command facade to the shared reducer.
@MainActor
private struct GridAuthorityEventHarnessView: View {
    @State private var tmux = TmuxController(controlPath: .sideChannel)
    @State private var session = GridAuthorityHarnessSession()
    @State private var facade: AppleSessionCommandFacade?

    private let tokens = TerminalTheme.find(id: "void").chromeTokens()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("mac mini  ·  tmux")
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                    Spacer()
                    if let peer = tmux.gridAuthority.peerDisplayName {
                        Text("on \(peer)")
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .overlay(Capsule().stroke(tokens.borderStrong, lineWidth: 0.5))
                            .accessibilityIdentifier("grid-authority.direct-chip")
                    }
                }
                .foregroundStyle(tokens.fgMuted)
                .padding(.horizontal, 20)
                .frame(height: 48)

                Text(verbatim: "terminal must pause while another device holds the grid")
                    .font(Typography.tesseraMono(size: 14))
                    .foregroundStyle(tokens.fg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(28)
            }

            if let peer = tmux.gridAuthorityPresentation.peerName {
                ContinuedElsewhereOverlay(
                    T: tokens,
                    peerDisplayName: peer,
                    isReclaiming: tmux.gridAuthorityPresentation.isReclaiming,
                    awaitingConnection: tmux.gridAuthorityPresentation.isAwaitingConnection,
                    onTakeBack: takeBackControl,
                    onCancel: { tmux.cancelGridAuthorityIntent() }
                )
                .padding(.top, 48)
                .accessibilityIdentifier("grid-authority.portable-overlay")
            }
        }
        .task {
            facade = session.sessionCommands(tmux: tmux)
            seedForeignAuthority()
        }
    }

    private func seedForeignAuthority() {
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(
            id: "GRID-AUTHORITY-HARNESS-SELF",
            displayName: "iPad"
        )
        tmux.updateClientSize(cols: 166, rows: 54)
        // The harness stands for a displayed tab. A controller starts hidden
        // until a show or an adoption says it is on screen, and a hidden one
        // draws no veil.
        tmux.gridAuthorityAdoptShown()
        tmux.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        // A completed attach handshake: the control channel is live, so a
        // tap starts its claim at once (the attach read stays unanswered).
        tmux.ingest(Array(
            "%session-changed $0 harness\r\n%begin 0 1 0\r\n%end 0 1 0\r\n%window-add @0\r\n".utf8
        ))
        tmux.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : v1 GRID-AUTHORITY-HARNESS-PEER 1 another-device\r\n".utf8
        ))
    }

    private func takeBackControl() {
        _ = facade?.dispatch(.reclaimTmuxGridAuthority(reason: .user))
    }
}

@MainActor
private final class GridAuthorityHarnessSession: TerminalSession {
    let host = Host(
        name: "authority harness",
        address: "authority.invalid",
        launchMode: .autoTmux
    )
    var state: SessionState = .connected
    let outputStream = AsyncStream<[UInt8]> { _ in }
    var remoteWorkingDirectory: String?
    var pendingPathInjection: String?

    func connect() {}
    func send(_ bytes: [UInt8]) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}
}
#endif

#if DEBUG
private struct AccessoryEditorHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance

    var body: some View {
        ScrollView {
            KeyboardSettingsView()
                .padding(24)
        }
        .onAppear {
            appearance.accessoryBarKeys = [
                AccessoryChip.esc,
                .ctrl,
                .alt,
                .tab,
                .left,
                .down,
                .up,
                .right,
                .pipe,
                .tilde,
            ].map(\.rawValue)
        }
    }
}
#endif

#if DEBUG
/// Host-free interaction harness for prompt overflow when all four trained
/// directions are live. It proves the non-directional puck tap opens More
/// while a down drag still sends the configured down macro; no terminal or
/// provider connection is created.
struct SwipePadOverflowHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(SpeechDictationController.self) private var dictation
    @Environment(SwipePadProfileStore.self) private var profileStore

    @State private var tmux = TmuxController()
    @State private var agentContext = SwipePadAgentContext()
    @State private var moreOpenCount = 0
    @State private var lastSentBytes = "none"

    private static let profileID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000004"
    )!
    private static let sessionID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000005"
    )!
    private static let puckCenter = CGPoint(x: 640, y: 420)

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "SWIPEPAD OVERFLOW HIT TEST")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text(verbatim: "more \(moreOpenCount) · sent \(lastSentBytes)")
                    .font(Typography.tesseraMono(size: 14))
                    .accessibilityIdentifier("swipepad-overflow-outcome")
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            SwipePadOverlay(
                onSend: { bytes in
                    lastSentBytes = bytes
                        .map { String(format: "%02x", $0) }
                        .joined(separator: " ")
                },
                tmux: tmux,
                agentContext: agentContext,
                onShowMore: { moreOpenCount += 1 },
                profileStore: profileStore,
                dictationController: dictation
            )
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: configure)
        .onDisappear {
            profileStore.remove(profileWithID: Self.profileID)
        }
    }

    private func configure() {
        appearance.swipePadEnabled = true
        appearance.voiceDictationEnabled = true
        if ProcessInfo.processInfo.environment[
            "TESSERA_SWIPEPAD_USE_DEFAULT_POSITION"
        ] == "1" {
            appearance.swipePadCorner = "bottomRight"
            appearance.swipePadLastX = -1
            appearance.swipePadLastY = -1
        } else {
            appearance.swipePadLastX = Double(Self.puckCenter.x)
            appearance.swipePadLastY = Double(Self.puckCenter.y)
        }

        let profile = SwipePadProfile(
            id: Self.profileID,
            name: "overflow harness",
            matchProcess: "overflow-harness",
            bindings: [
                .right: SwipePadBinding(macro: "1↵", label: "one"),
                .left: SwipePadBinding(macro: "2↵", label: "two"),
                .up: SwipePadBinding(macro: "3↵", label: "three"),
                .down: SwipePadBinding(macro: "5↵", label: "five"),
            ],
            isBuiltIn: false
        )
        profileStore.upsert(profile)

        let prompt = AgentPrompt(
            signature: "overflow-harness-prompt",
            summary: "pick",
            options: (1...5).map {
                AgentPromptOption(
                    id: $0,
                    label: "Option \($0)",
                    responseMacro: "\($0)↵",
                    isDefault: $0 == 1
                )
            }
        )
        agentContext.publish(
            SwipePadAgentSnapshot(
                agentID: AgentInstanceID(sessionID: Self.sessionID, paneID: nil),
                profileID: profile.id,
                profileName: profile.name,
                status: .waitingForInput,
                prompt: prompt,
                statusChangedAt: .now,
                detectedAt: .now,
                providerSessionID: "overflow-harness",
                agentPID: 4242
            )
        )
    }
}
#endif

#if DEBUG
/// Host-free reproduction for a transient empty tmux viewport capture.
///
/// The production inline controller first renders a recognizable window, then
/// switches to a second window whose capture response contains zero rows. tmux
/// 3.6a returns one empty string per terminal row even for a genuinely blank
/// pane, so this response shape is always invalid. The shipped failure painted
/// the empty response as authoritative, clearing SwiftTerm to a black canvas
/// with only its restored cursor. A hardened controller keeps the prior pixels
/// intact and retries into the recovered second-window capture.
struct TmuxEmptyCaptureHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @State private var terminalBox = TerminalBox(traceLabel: "tmux-empty-capture-harness")
    @State private var controller = TmuxController()
    @State private var probe = TmuxEmptyCaptureHarnessProbe()

    var body: some View {
        TerminalSurfaceBound(
            initialData: [],
            onMade: { view in
                terminalBox.attach(view)
                terminalBox.markRenderReady()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    _ = view.resignFirstResponder()
                    let terminal = view.getTerminal()
                    let cols = max(1, terminal.cols)
                    let rows = max(1, terminal.rows)
                    terminalBox.feed(Self.seedBytes(cols: cols, rows: rows)[...])
                    reproduceEmptyCapture(cols: cols, rows: rows)
                }
            },
            onReady: {},
            onSend: { _ in },
            onResize: { _, _ in },
            onTitle: { _ in },
            onUserActivity: nil,
            onBell: nil,
            mouseReportingImpliesAltScreen: false,
            suppressDirectColorQueryResponses: true,
            tmuxShortcutsEnabled: false,
            onTmuxShortcut: { _ in },
            onFindShortcut: nil,
            onSwitcherShortcut: nil,
            onOpenSettings: nil,
            suppressFirstResponderReclaim: true,
            onHardwareKey: nil
        )
        .ignoresSafeArea()
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            appearance.cursorBlink = false
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return
            }
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscapeLeft),
                errorHandler: { error in
                    NSLog("[Tessera][TmuxEmptyCaptureHarness] landscape request failed: \(error)")
                }
            )
        }
    }

    private func reproduceEmptyCapture(cols: Int, rows: Int) {
        let runToken = ProcessInfo.processInfo.environment[
            "TESSERA_TMUX_EMPTY_CAPTURE_RUN_TOKEN"
        ] ?? "unscoped"
        probe.feedCount = 0
        probe.swapCount = 0
        probe.preserved = false

        controller.feedTerminal = { [terminalBox] bytes in
            probe.feedCount += 1
            terminalBox.feed(bytes)
        }
        controller.displayWillSwap = { [terminalBox, appearance] _, _, _ in
            probe.swapCount += 1
            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
        }
        controller.terminalIsInAltScreen = { [terminalBox] in
            terminalBox.view?.getTerminal().isCurrentBufferAlternate ?? false
        }
        let pending = PendingReplies()
        controller.sendBytes = { bytes in
            pending.commands.append(contentsOf: String(decoding: bytes, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }

        // Answer commands by identity: positional replies broke when c8b95e525
        // added deferred per-pane subscription registrations.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Self.responseFrame(1, flags: 0))
        drainPendingReplies(pending)
        controller.updateClientSize(cols: cols, rows: rows)
        // Inline size replay is a two-command transaction: refresh-client
        // followed by the targetless select-window fence that makes this
        // client tmux's latest size authority. Drain all pending replies
        // before the harness answers render-ledger queries.
        drainPendingReplies(pending)

        // Latch a complete, already-rendered first window without a network.
        controller.ingest(Array("%window-add @1\r\n".utf8))
        answerThrough(
            pending,
            matching: { $0 == TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: WindowId(1)) },
            body: ["one"]
        )
        controller.ingest(Array("%output %31 \(Self.seedRefreshText)\r\n".utf8))

        // Switch to @2, resolve valid metadata, then reproduce the diagnostic
        // log's impossible successful capture with zero body rows.
        controller.ingest(Array("%window-add @2\r\n".utf8))
        answerThrough(
            pending,
            matching: { $0 == TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: WindowId(2)) },
            body: ["two"]
        )
        controller.ingest(Array("%window-pane-changed @2 %32\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        answerThrough(
            pending,
            matching: { $0 == RenderCommands.renderedPaneMetadata(target: WindowId(2)) },
            body: ["%32\t2\t10\tsecond pane\ttwo\thost\t0"]
        )
        answerThrough(pending, matching: { $0 == RenderCommands.viewport(target: WindowId(2)) })

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            probe.preserved = controller.renderedWindowId == nil
                && controller.renderedPaneId == nil
                && probe.feedCount == 1
                // The shared ledger binds `.live` immediately before the
                // first authenticated W1 `%output`; that initial bind is the
                // one expected swap. The invalid W2 capture must not add a
                // second bind or feed.
                && probe.swapCount == 1
            NSLog(
                "%@",
                "[Tessera][TmuxEmptyCaptureHarness] phase=preserved token=\(runToken) ok=\(probe.preserved) feedCount=\(probe.feedCount) swapCount=\(probe.swapCount)"
            )
        }

        // Keep the rejected-capture interval visible long enough for a cold
        // simulator to settle and capture the preserved first-window pixels
        // before satisfying the controller's pending retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard probe.preserved else {
                NSLog(
                    "%@",
                    "[Tessera][TmuxEmptyCaptureHarness] verdict=bug-present token=\(runToken) feedCount=\(probe.feedCount) swapCount=\(probe.swapCount)"
                )
                return
            }
            recoverEmptyCapture(cols: cols, rows: rows, runToken: runToken, pending: pending)
        }
    }

    private func recoverEmptyCapture(
        cols: Int,
        rows: Int,
        runToken: String,
        pending: PendingReplies,
        remainingPolls: Int = 20
    ) {
        guard answerThrough(
            pending,
            matching: { $0 == RenderCommands.renderedPaneMetadata(target: WindowId(2)) },
            body: ["%32\t2\t10\tsecond pane\ttwo\thost\t0"]
        ) else {
            guard remainingPolls > 0 else {
                NSLog(
                    "%@",
                    "[Tessera][TmuxEmptyCaptureHarness] verdict=failed token=\(runToken) reason=no-retry pending=\(pending.commands.count)"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                recoverEmptyCapture(
                    cols: cols, rows: rows, runToken: runToken,
                    pending: pending, remainingPolls: remainingPolls - 1
                )
            }
            return
        }
        answerThrough(
            pending,
            matching: { $0 == RenderCommands.viewport(target: WindowId(2)) },
            body: Self.recoveredLines(cols: cols, rows: rows)
        )
        let recovered = controller.renderedWindowId == WindowId(2)
            && controller.renderedPaneId == PaneId(32)
            && probe.feedCount == 2
            && probe.swapCount == 2
        NSLog(
            "%@",
            "[Tessera][TmuxEmptyCaptureHarness] verdict=\(recovered ? "recovered" : "failed") token=\(runToken) window=\(controller.renderedWindowId?.description ?? "nil") pane=\(controller.renderedPaneId?.description ?? "nil") feedCount=\(probe.feedCount) swapCount=\(probe.swapCount) cols=\(cols) rows=\(rows)"
        )
    }

    private final class PendingReplies {
        var commands: [String] = []
        var nextNumber = 2
    }

    @discardableResult
    private func answerThrough(
        _ pending: PendingReplies,
        matching predicate: (String) -> Bool,
        body: [String] = []
    ) -> Bool {
        while !pending.commands.isEmpty {
            let matches = predicate(pending.commands.removeFirst())
            answerPendingReply(pending, body: matches ? body : [])
            if matches { return true }
        }
        return false
    }

    private func drainPendingReplies(_ pending: PendingReplies) {
        while !pending.commands.isEmpty {
            pending.commands.removeFirst()
            answerPendingReply(pending)
        }
    }

    private func answerPendingReply(_ pending: PendingReplies, body: [String] = []) {
        let number = pending.nextNumber
        pending.nextNumber += 1
        controller.ingest(Self.responseFrame(number, body: body))
    }

    private static let seedRefreshText =
        "\\033[H\\033[48;2;18;44;76m\\033[38;2;235;245;255m"
        + " LIVE OUTPUT BEFORE EMPTY CAPTURE "
        + "\\033[K\\033[0m"

    private static func seedBytes(cols: Int, rows: Int) -> [UInt8] {
        var bytes = Array("\u{1B}[48;2;18;44;76m\u{1B}[38;2;235;245;255m\u{1B}[2J\u{1B}[H".utf8)
        for row in 1...rows {
            let line = fittedLine(
                prefix: String(format: " WINDOW ONE SAFE CONTENT %02d  ", row),
                pattern: "0123456789abcdef",
                cols: cols
            )
            bytes.append(contentsOf: line.utf8)
            bytes.append(contentsOf: Array("\u{1B}[K".utf8))
            if row < rows {
                bytes.append(contentsOf: [0x0D, 0x0A])
            }
        }
        bytes.append(contentsOf: Array("\u{1B}[0m".utf8))
        return bytes
    }

    private static func recoveredLines(cols: Int, rows: Int) -> [String] {
        (1...rows).map { row in
            "\u{1B}[48;2;20;74;48m\u{1B}[38;2;235;255;240m"
                + fittedLine(
                    prefix: String(format: " RECOVERED WINDOW TWO %02d  ", row),
                    pattern: "fedcba9876543210",
                    cols: cols
                )
                + "\u{1B}[K"
        }
    }

    private static func fittedLine(prefix: String, pattern: String, cols: Int) -> String {
        let targetWidth = max(0, cols - 1)
        var line = String(prefix.prefix(targetWidth))
        while line.utf8.count < targetWidth {
            line += pattern
        }
        if line.utf8.count > targetWidth {
            line = String(line.prefix(targetWidth))
        }
        return line
    }

    private static func responseFrame(
        _ number: Int,
        body: [String] = [],
        flags: Int = 1
    ) -> [UInt8] {
        var wire = "%begin 0 \(number) \(flags)\r\n"
        for line in body {
            wire += "\(line)\r\n"
        }
        wire += "%end 0 \(number) \(flags)\r\n"
        return Array(wire.utf8)
    }
}

private final class TmuxEmptyCaptureHarnessProbe {
    var feedCount = 0
    var swapCount = 0
    var preserved = false
}

/// Host-free native scheduler-pressure regression; never connects to a host.
private struct SessionQueueHarnessView: View {
    @State private var model = SessionQueueHarnessModel()
    var body: some View {
        VStack {
            Text(model.status).font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24).padding(.horizontal, 16)
                .accessibilityIdentifier("session-queue-status")
            TerminalSurfaceBound(
                initialData: [], onMade: { model.terminal = $0 }, onReady: { model.terminalReady = true },
                onSend: { _ in }, onResize: { _, _ in }, onTitle: { _ in },
                onUserActivity: nil, onBell: nil, mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true, tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in }, onFindShortcut: nil, onSwitcherShortcut: nil,
                onOpenSettings: nil, suppressFirstResponderReclaim: true, onHardwareKey: nil
            )
        }
        .background(.black).foregroundStyle(.white)
        .task { await model.run() }
    }
}

/// Host-free pressure rig. Real Apple admission, SessionEngine, event delivery,
/// and native terminal surface; only the network source is synthetic. Sequence
/// and monotonic timestamps measure loss/order and end-to-end delivery age.
@MainActor @Observable
private final class SessionQueueHarnessModel {
    var status = "starting"
    @ObservationIgnored weak var terminal: TerminalView?
    @ObservationIgnored var terminalReady = false
    @ObservationIgnored private var paintedPackets = 0
    @ObservationIgnored private var received = 0
    @ObservationIgnored private var maximumAgeMs = 0.0
    @ObservationIgnored private var latestAgeMs = 0.0
    @ObservationIgnored private var orderFailures = 0
    @ObservationIgnored private var expected = [UInt64(0), UInt64(0)]
    @ObservationIgnored private var maximumInputAgeMs = 0.0
    @ObservationIgnored private var inputsSent = 0
    @ObservationIgnored private var inputsApplied = 0

    func run() async {
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (!terminalReady || terminal == nil), ContinuousClock.now < readinessDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard terminalReady, terminal != nil, !Task.isCancelled else {
            status = "terminal-not-ready done=false"
            return
        }
        let sources = [SessionQueueHarnessSource(), SessionQueueHarnessSource()]
        let usesTmux = ProcessInfo.processInfo.environment["TESSERA_QUEUE_TMUX"] == "1"
        let controllers = sources.map { _ in TmuxController() }
        if usesTmux {
            for (index, controller) in controllers.enumerated() {
                controller.feedTerminalWithContext = { [weak self] bytes, _ in
                    if index == 0, let self, let terminal = self.terminal {
                        terminal.feed(byteArray: bytes)
                        self.paintedPackets += 1
                    }
                }
                controller.sendBytes = { [weak source = sources[index]] in source?.receiveControlCommand($0) }
                controller.ingest(Array("\u{1B}P1000p%window-add @0\r\n".utf8))
            }
        }
        let facades = sources.enumerated().map {
            AppleSessionCommandFacade(session: $0.element, tmux: usesTmux ? controllers[$0.offset] : nil)
        }
        let streams = facades.map(\.events)
        for source in sources {
            source.onSend = { [weak self] bytes in
                guard let self, bytes.count == 8 else { return }
                let nanos = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                self.inputsApplied += 1
                self.maximumInputAgeMs = max(self.maximumInputAgeMs,
                    Double(DispatchTime.now().uptimeNanoseconds - nanos) / 1e6)
            }
        }
        for facade in facades { facade.connect() }
        while facades.contains(where: { $0.state != .connected }), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .seconds(1))
        let burst = Int(ProcessInfo.processInfo.environment["TESSERA_QUEUE_BURST"] ?? "16") ?? 16
        let rounds = min(9_000, max(1, Int(ProcessInfo.processInfo.environment["TESSERA_QUEUE_ROUNDS"] ?? "900") ?? 900))
        let total = burst * rounds * sources.count
        let producers = sources.map { $0.start(burst: burst, rounds: rounds, tmux: usesTmux) }
        // Model sustained UI work in small, cooperative 2 ms turns. The
        // physical diagnostics have much larger UI scheduling delays; this makes
        // the executor-contention condition reproducible on a fast Mac
        // without tying acceptance to that Mac's GPU or CPU speed.
        let pressure = Task { @MainActor in
            while !Task.isCancelled {
                let end = ContinuousClock.now.advanced(by: .milliseconds(2))
                while ContinuousClock.now < end {}
                await Task.yield()
            }
        }
        defer { producers.forEach { $0.cancel() }; pressure.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for (index, stream) in streams.enumerated() {
                group.addTask { @MainActor in
                    let iterator = stream.mainActorDelivery().makeAsyncIterator()
                    while let event = await iterator.next() {
                        if Task.isCancelled { return }
                        guard case .terminalBytes(_, let bytes, _) = event, bytes.count >= 16 else { continue }
                        let sequence = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                        let nanos = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
                        if sequence == UInt64.max {
                            if await controllers[index].ingestCooperatively(Array(bytes.dropFirst(16))) {
                                iterator.consumerDidYield()
                            }
                            continue
                        }
                        if sequence != self.expected[index] { self.orderFailures += 1 }
                        self.expected[index] = sequence + 1
                        self.received += 1
                        if usesTmux {
                            if await controllers[index].ingestCooperatively(Array(bytes.dropFirst(16))) {
                                iterator.consumerDidYield()
                            }
                        } else if index == 0, let terminal = self.terminal {
                            terminal.feed(byteArray: Array(bytes.dropFirst(16))[...])
                            self.paintedPackets += 1
                        }
                        self.latestAgeMs = Double(DispatchTime.now().uptimeNanoseconds - nanos) / 1e6
                        self.maximumAgeMs = max(self.maximumAgeMs, self.latestAgeMs)
                    }
                }
            }
            group.addTask { @MainActor in
                for tick in 0..<Int((Double(rounds) * 0.016 + 45) * 4) {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    if tick % 4 == 0 {
                        for facade in facades {
                            var nanos = DispatchTime.now().uptimeNanoseconds
                            self.inputsSent += 1
                            facade.sendInput(withUnsafeBytes(of: &nanos) { Array($0) })
                        }
                    }
                    let depth = facades.reduce(0) { $0 + $1._orderedLaneCountForTesting }
                    let done = self.received == total && self.inputsApplied == self.inputsSent && self.paintedPackets == total / 2
                    self.status = "received=\(self.received)/\(total) painted=\(self.paintedPackets)/\(total / 2) queued=\(depth) ageMs=\(Int(self.latestAgeMs)) maxAgeMs=\(Int(self.maximumAgeMs)) orderFailures=\(self.orderFailures) inputs=\(self.inputsApplied)/\(self.inputsSent) maxInputMs=\(Int(self.maximumInputAgeMs)) done=\(done)"
                    if tick % 4 == 0 || self.received == total { NSLog("[SessionQueueHarness] %@", self.status) }
                    if done { return }
                }
            }
            // The status task is bounded, even if a regression strands bytes.
            await group.next()
            group.cancelAll()
        }
    }
}

@MainActor
private final class SessionQueueHarnessSource: AppleSessionBackendEventSource {
    private struct SyntheticNetworkPacket: Sendable {
        let attemptID: UUID
        let bytes: [UInt8]
    }

    let host: Host
    var state: SessionState = .idle { didSet { states.send(state) } }
    var remoteWorkingDirectory: String?
    var pendingPathInjection: String?
    var appleActiveSessionAttemptID: UUID?
    var onSend: (([UInt8]) -> Void)?
    private var controlReplyNumber = 100
    private let states = CurrentValueSubject<SessionState, Never>(.idle)
    let outputStream = AsyncStream<[UInt8]> { $0.finish() }
    let appleAttemptOutputEvents: AsyncStream<SessionAttemptOutputChunk>
    private let ingressSSH: SSHSession
    private let syntheticNetworkOutput: AsyncStream<SyntheticNetworkPacket>.Continuation
    private var syntheticNetworkPump: Task<Void, Never>?
    var appleSessionStateEvents: AnyPublisher<SessionState, Never> { states.eraseToAnyPublisher() }
    var appleWorkingDirectoryEvents: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var appleHostKeyChallengeEvents: AnyPublisher<HostKeyVerificationRequest?, Never> { Just(nil).eraseToAnyPublisher() }
    var appleOutputQueueDiagnostics: AsyncDeliveryDiagnostics? { ingressSSH.appleOutputQueueDiagnostics }

    init() {
        let host = Host(id: UUID(), transport: .ssh)
        let ingressSSH = SSHSession(host: host)
        let (syntheticNetwork, syntheticNetworkOutput) = AsyncStream.makeStream(
            of: SyntheticNetworkPacket.self,
            bufferingPolicy: .unbounded
        )
        let usesLegacyPublication = ProcessInfo.processInfo.environment[
            "TESSERA_QUEUE_LEGACY_PUBLICATION"
        ] == "1"

        self.host = host
        self.ingressSSH = ingressSSH
        appleAttemptOutputEvents = ingressSSH.appleAttemptOutputEvents
        self.syntheticNetworkOutput = syntheticNetworkOutput
        // The synthetic remote can fill this independent network FIFO without
        // awaiting UI work. Its detached reader then crosses the exact SSH
        // publication seam used by Citadel, while the opt-in legacy branch
        // recreates the removed per-packet MainActor hop for same-binary A/B.
        syntheticNetworkPump = Task.detached(priority: .userInitiated) { [weak ingressSSH] in
            for await packet in syntheticNetwork {
                if Task.isCancelled { return }
                guard let ingressSSH else { return }
                if usesLegacyPublication {
                    await MainActor.run {
                        ingressSSH._publishPTYOutputForTesting(
                            packet.bytes,
                            attemptID: packet.attemptID
                        )
                    }
                } else {
                    ingressSSH._publishPTYOutputForTesting(
                        packet.bytes,
                        attemptID: packet.attemptID
                    )
                }
            }
        }
    }

    deinit {
        syntheticNetworkOutput.finish()
        syntheticNetworkPump?.cancel()
    }

    func prepareAppleSessionAttempt(_ attemptID: UUID) { appleActiveSessionAttemptID = attemptID }
    func connect() { state = .connected }
    func send(_ bytes: [UInt8]) { onSend?(bytes) }
    func resize(cols: Int, rows: Int) {}
    func disconnect() {
        state = .disconnected
        syntheticNetworkOutput.finish()
        syntheticNetworkPump?.cancel()
        syntheticNetworkPump = nil
    }
    /// Synthetic remote tmux: observe actual send-keys bytes at the transport
    /// boundary and return matching guards through the SAME output stream as
    /// pane data. No independent parser ingress task can reorder replies.
    func receiveControlCommand(_ bytes: [UInt8]) {
        guard let attempt = appleActiveSessionAttemptID else { return }
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("send-keys "), let range = line.range(of: " -H ") {
                let input = line[range.upperBound...].split(separator: " ").compactMap { UInt8($0, radix: 16) }
                send(input)
            }
            controlReplyNumber += 1
            var marker = UInt64.max
            var timestamp = UInt64(0)
            var reply = withUnsafeBytes(of: &marker) { Array($0) }
            reply += withUnsafeBytes(of: &timestamp) { Array($0) }
            reply += Array("%begin 0 \(controlReplyNumber) 1\r\n%end 0 \(controlReplyNumber) 1\r\n".utf8)
            syntheticNetworkOutput.yield(.init(attemptID: attempt, bytes: reply))
        }
    }
    func start(burst: Int, rounds: Int, tmux: Bool) -> Task<Void, Never> {
        let syntheticNetworkOutput = syntheticNetworkOutput
        let attempt = appleActiveSessionAttemptID!
        return Task.detached {
            var sequence: UInt64 = 0
            for _ in 0..<rounds {
                if Task.isCancelled { return }
                for _ in 0..<burst {
                    var nanos = DispatchTime.now().uptimeNanoseconds
                    var bytes = withUnsafeBytes(of: &sequence) { Array($0) }
                    bytes += withUnsafeBytes(of: &nanos) { Array($0) }
                    let text = String(repeating: "terminal output ", count: 5)
                    if tmux {
                        bytes += Array("%output %0 \\033[32mrow \(sequence) \\033[0m\(text)\\015\\012\r\n".utf8)
                    } else {
                        bytes += Array("\u{1B}[32mrow \(sequence) \u{1B}[0m\(text)\r\n".utf8)
                    }
                    syntheticNetworkOutput.yield(.init(attemptID: attempt, bytes: bytes))
                    sequence += 1
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}

/// Visual regression harness for terminal canvas bleed. Mirrors production
/// canvas insets without opening a transport (TESSERA_TERMINAL_CANVAS_HARNESS).
struct TerminalCanvasHarnessView: View {
    private let fullScreenBackdrop =
        ProcessInfo.processInfo.environment["TESSERA_TERMINAL_CANVAS_FULL_SCREEN"] != "0"

    private static let background: ResolvedTerminalBackground? = {
        let size = CGSize(width: 1_600, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors: [UIColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen,
                .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
            ]
            let stripeWidth = size.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(
                    x: CGFloat(index) * stripeWidth,
                    y: 0,
                    width: stripeWidth,
                    height: size.height
                ))
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.95),
              let imported = TerminalBackgroundImageStore.importImage(data: data)
        else { return nil }
        return ResolvedTerminalBackground(
            imageID: imported.id,
            dim: 0.15,
            fillMode: .fill
        )
    }()

    var body: some View {
        ZStack {
            if fullScreenBackdrop, let background = Self.background {
                TerminalBackdrop(background: background, baseColor: .black)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 48)

                ZStack(alignment: .topLeading) {
                    if !fullScreenBackdrop, let background = Self.background {
                        TerminalBackdrop(
                            background: background,
                            baseColor: .black,
                            bleed: EdgeInsets(
                                top: 0,
                                leading: SessionView.cornerInset,
                                bottom: 0,
                                trailing: SessionView.cornerInset
                            )
                        )
                    }

                    GeometryReader { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(0..<24, id: \.self) { row in
                                Text(String(repeating: "canvas row \(row)  ", count: 10))
                                    .font(Typography.tesseraMonoFixed(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, SessionView.cornerInset)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return
            }
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscapeLeft),
                errorHandler: { error in
                    NSLog("[Tessera][TerminalCanvasHarness] landscape request failed: \(error)")
                }
            )
        }
    }
}

/// Host-free presentation harness for the in-app upload ingress sheet.
/// Launch with `TESSERA_UPLOAD_HARNESS=1`; its mock bridge publishes twelve
/// progress steps across six seconds so button fill and warnings are stable
/// enough for screenshots and UI automation.
private struct UploadIngressHarnessView: View {
    private let request: UploadRequest
    @State private var model: UploadSheetModel
    @State private var queue: TransferQueue
    @State private var status = "ready"

    init() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tessera-upload-harness-large-video.mov")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Data(repeating: 0x54, count: 8 * 1_024 * 1_024).write(to: fileURL)
        }
        request = UploadRequest(
            stagedURL: fileURL,
            displayName: "Summer Trip — 4K.mov",
            fileSize: 8 * 1_024 * 1_024,
            sourceHint: "Photos"
        )
        let sheetModel = UploadSheetModel()
        sheetModel.candidates = [
            UploadHostCandidate(
                id: UUID(),
                label: "qi@perch",
                isConnected: true,
                isConnecting: false,
                isActiveSession: true,
                sessionCwd: "/home/qi/projects/tessera"
            )
        ]
        _model = State(initialValue: sheetModel)
        let bridge = MockFileBridge()
        bridge.latencyNanos = 6_000_000_000
        bridge.uploadProgressSteps = 12
        _queue = State(initialValue: TransferQueue(bridge: bridge))
    }

    var body: some View {
        UploadSheetView(
            request: request,
            model: model,
            onUpload: { candidate, destination, pastePath in
                let item: TransferItem
                switch destination {
                case .sessionCwd(let directory):
                    item = queue.enqueueUpload(localURL: request.stagedURL, toDirectory: directory)
                case .temp:
                    item = queue.enqueuePasteUpload(localURL: request.stagedURL)
                }
                status = "uploading"
                return UploadExecution(
                    item: item,
                    queue: queue,
                    hostID: candidate.id,
                    displayName: request.displayName,
                    stagedURL: request.stagedURL,
                    pastePath: pastePath
                )
            },
            onContinueInBackground: { execution in
                if ProcessInfo.processInfo.environment["TESSERA_UPLOAD_BACKGROUND_REJECT"] == "1" {
                    return false
                }
                let copyPath: Bool
                if case .foreground(let pastePath) = execution.delivery {
                    copyPath = pastePath
                } else {
                    copyPath = false
                }
                execution.delivery = .background(copyPath: copyPath)
                queue.markContinuedInBackground(execution.item)
                status = copyPath ? "background-copy" : "background"
                return true
            },
            onCancel: { status = "dismissed" }
        )
        .overlay(alignment: .topTrailing) {
            Text(verbatim: status)
                .font(Typography.tesseraMonoFixed(size: 10, weight: .medium))
                .opacity(0.01)
                .accessibilityIdentifier("upload.harness.status")
        }
        .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))
    }
}

/// Presentation harness for the floating Files card — launch with
/// `SIMCTL_CHILD_TESSERA_FILES_HARNESS=1 xcrun simctl launch …`. Renders a
/// high-contrast striped fake "terminal" behind the card so backdrop-loss
/// bugs (context menu turning the glass transparent) are unmistakable in
/// simctl screenshots. No SSH — the panel runs on `MockFileBridge`.
/// DEBUG bisect surface — a plain UIKit label owning a real
/// `UIContextMenuInteraction`, with no SwiftUI involvement in the menu at all.
/// DEBUG harness for the Markdown preview. Renders a document whose tables
/// are the shape that used to collapse into one run-on block — and then
/// blank out — so the renderer can be checked without a host or a share.
struct MarkdownPreviewHarnessView: View {
    @State private var fileURL: URL?

    /// `TESSERA_MARKDOWN_HARNESS_BLOCKS` grows the sample to the size that
    /// scrolls badly in the field (the reported document parsed to 443
    /// blocks), so the cost of realising one block is measurable.
    private static var syntheticBlockCount: Int {
        Int(ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_HARNESS_BLOCKS"] ?? "") ?? 0
    }

    /// `TESSERA_MARKDOWN_HARNESS_KIND` pins the document to one block shape
    /// so a run measures that shape alone. Default is the mixed register.
    private static var syntheticKind: String {
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_HARNESS_KIND"] ?? "mixed"
    }

    /// Long paragraphs, code, and tables in the proportions the reported
    /// register had — or, with `TESSERA_MARKDOWN_HARNESS_KIND`, one shape
    /// repeated so its per-block cost stands alone.
    private static func syntheticSource(blocks: Int) -> String {
        var out = ["# Synthetic register\n"]
        let sentence = """
        The document is satisfied only when all 400 ledger rows pass, all 82 \
        command keys have an accepted real-provider occurrence as defined \
        above, both catalog equalities still hold for the tested build, every \
        artifact reference resolves, all R6 rows survive restart/replay, and \
        no secret appears in retained evidence.
        """
        func heading(_ index: Int) -> String { "## Section \(index)\n" }
        func code(_ index: Int) -> String {
            "```swift\nlet row\(index) = ledger.row(at: \(index))\n```\n"
        }
        func table(_ index: Int) -> String {
            """
            | Case | Owner | Status |
            | --- | --- | --- |
            | EV-\(index) | inbox delivery | open |
            | EV-\(index)b | resident-side | closed |
            """ + "\n"
        }
        func paragraph(_ index: Int) -> String {
            "\(sentence) Paragraph \(index) of the register.\n"
        }

        let kind = Self.syntheticKind
        for index in 0..<blocks {
            switch kind {
            case "heading": out.append(heading(index))
            case "code": out.append(code(index))
            case "table": out.append(table(index))
            case "paragraph": out.append(paragraph(index))
            default:
                switch index % 8 {
                case 0: out.append(heading(index))
                case 3: out.append(code(index))
                case 6: out.append(table(index))
                default: out.append(paragraph(index))
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static let sample = """
    # Independent pre-run blocker register

    This register is diagnostic, not a reduced completion target.

    | Case | Owner | Status | Note |
    | --- | --- | --- | --- |
    | EV-EMP-01 | offer/proposal inbox delivery | open | accept leg |
    | EV-EQ-01/02 | resident-side event delivery | closed | planning fallback |
    | EV-GOV-01 | shipped employment floor | open | recipe/product review |
    | EV-MKT-03 | conversation.create inbox rows | open | patroned bank-manager yield |

    ## Audit-test traceability

    | Lane | Artifact | Bound |
    | --- | --- | --- |
    | A | `scripts/e2e_coverage_audit.py` | 400 rows |
    | B | journal window | 82 keys |

    No unresolved product or specification blocker remains in this register
    after the corrections recorded above.
    """

    var body: some View {
        Group {
            if let fileURL {
                QuickLookPresenter(fileURL: fileURL, displayTitle: "register.md")
            } else {
                ProgressView()
            }
        }
        .task {
            guard fileURL == nil else { return }
            if ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_IMAGE_HARNESS"] == "1" {
                fileURL = try? await MarkdownImagePreviewFixture.stage()
                return
            }
            // A real reported document, staged into the container by the
            // runner, beats any synthetic one: its inline emphasis, links,
            // and code spans are what make a block expensive to realise.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("markdown-harness-real.md")
            if FileManager.default.fileExists(atPath: staged.path) {
                fileURL = staged
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("markdown-harness-register.md")
            let blocks = Self.syntheticBlockCount
            let source = blocks > 0 ? Self.syntheticSource(blocks: blocks) : Self.sample
            try? source.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
        }
    }
}

struct UIKitContextMenuProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let label = ProbeLabel()
        label.text = "  uikit probe row"
        label.textColor = .white
        label.backgroundColor = .black
        label.isUserInteractionEnabled = true
        label.accessibilityIdentifier = "files.row.uikit-probe"
        label.isAccessibilityElement = true
        label.addInteraction(UIContextMenuInteraction(delegate: label))
        return label
    }

    func updateUIView(_ view: UIView, context: Context) {}

    final class ProbeLabel: UILabel, UIContextMenuInteractionDelegate {
        /// With `TESSERA_FILES_MENU_PROBE_PREVIEW=1` the configuration
        /// carries a `UIHostingController` preview — the same shape SwiftUI's
        /// `.contextMenu(preview:)` builds. Isolates whether hosting a
        /// preview is what stretches the platter's settle.
        private var usesHostedPreview: Bool {
            ProcessInfo.processInfo.environment["TESSERA_FILES_MENU_PROBE_PREVIEW"] == "1"
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let previewProvider: UIContextMenuContentPreviewProvider? = usesHostedPreview
                ? {
                    let controller = UIHostingController(
                        rootView: Text(verbatim: "uikit probe row")
                            .font(.system(size: 15, weight: .bold))
                            .padding(10)
                            .frame(width: 316, alignment: .leading)
                            .background(Color(white: 0.11))
                    )
                    controller.preferredContentSize = CGSize(width: 316, height: 44)
                    return controller
                }
                : nil
            return UIContextMenuConfiguration(identifier: nil, previewProvider: previewProvider) { _ in
                UIMenu(children: [
                    UIAction(title: "Quick Look") { _ in },
                    UIAction(title: "Download") { _ in },
                    UIAction(title: "Share…") { _ in },
                    UIAction(title: "Send Path to Terminal") { _ in },
                    UIAction(title: "Copy Path") { _ in },
                    UIAction(title: "Rename") { _ in },
                    UIAction(title: "Delete…", attributes: .destructive) { _ in },
                ])
            }
        }
    }
}

struct FilesPanelHarnessView: View {
    // Built empty and wired ONCE from `.task`. Doing the wiring in `init()`
    // ran it on every root body pass, and `terminalReportedDirectory` reads
    // `currentDirectory` — which registered the ROOT view as an observer of
    // a property the throwaway controller's own load then wrote, spinning
    // the app at 100% CPU. Harness-only, but it masks whatever it is
    // supposed to measure.
    @State private var controller = FilesPanelController()
    @State private var configured = false

    private var usesLightAppearance: Bool {
        ProcessInfo.processInfo.environment["TESSERA_FILES_HARNESS_LIGHT"] == "1"
    }

    private var harnessTokens: DesignTokens {
        DesignTokens.make(
            mode: usesLightAppearance ? .light : .dark,
            accent: .blue
        )
    }

    /// The residual-flicker controls are off unless asked for — the harness
    /// also serves glass and quick-open captures, which must keep their
    /// existing composition.
    private static var showsMenuBisectProbes: Bool {
        ProcessInfo.processInfo.environment["TESSERA_FILES_MENU_PROBES"] == "1"
    }

    /// Row count for the synthetic listing (`TESSERA_FILES_HARNESS_FILECOUNT`).
    /// 0 keeps the small canned tree; the context-menu churn case needs a
    /// realistically long directory (the reporter's was ~200 rows).
    private static var harnessFileCount: Int {
        Int(ProcessInfo.processInfo.environment["TESSERA_FILES_HARNESS_FILECOUNT"] ?? "") ?? 0
    }

    /// Milliseconds between synthetic listing refreshes
    /// (`TESSERA_FILES_HARNESS_CHURN`). Stands in for a live session's
    /// re-render pressure on the panel — the cwd poller reporting, a
    /// transfer finishing, the directory reloading — so the context-menu
    /// flicker reproduces without a host.
    private static var harnessChurnMilliseconds: Int {
        Int(ProcessInfo.processInfo.environment["TESSERA_FILES_HARNESS_CHURN"] ?? "") ?? 0
    }

    /// What the last context-menu action did, surfaced as text so a UI
    /// test can assert that a menu item actually fired.
    @State private var lastMenuAction = "none"

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let bridge = MockFileBridge()
        if Self.harnessFileCount > 0 {
            bridge.tree = Self.syntheticTree(fileCount: Self.harnessFileCount)
        }
        controller.attach(bridge: bridge)
        // Wire the real file actions over the mock bridge so row taps stage
        // and present for real — that's what makes Quick Look (and its size
        // toggle) verifiable here without an SSH host.
        controller.configureFileActions(
            transfers: TransferQueue(bridge: bridge),
            hostFolderName: "MockHost"
        )
        // Menu-tap oracle: the status label reports which item fired, so a
        // UI test can prove the platter is still hit-testable.
        controller.onSendPathToTerminal = { path in
            lastMenuAction = "send:\((path as NSString).lastPathComponent)"
        }
        controller.open()
        controller.terminalReportedDirectory(Self.harnessDirectory)
    }

    private static let harnessDirectory = "/home/mock/projects/dashboard"

    /// One directory holding `fileCount` files — enough rows that the
    /// panel body's per-pass row/menu construction is measurable.
    private static func syntheticTree(fileCount: Int) -> [String: [RemoteFileEntry]] {
        let home = "/home/mock"
        let proj = "\(home)/projects/dashboard"
        let files = (0..<fileCount).map { i in
            RemoteFileEntry(
                name: String(format: "report_%04d_analysis.md", i),
                path: String(format: "\(proj)/report_%04d_analysis.md", i),
                kind: .file, size: UInt64(1_024 + i * 37), modified: nil,
                permissions: 0o644
            )
        }
        return [
            home: [RemoteFileEntry(name: "projects", path: "\(home)/projects",
                                   kind: .directory, size: nil, modified: nil,
                                   permissions: 0o755)],
            "\(home)/projects": [
                RemoteFileEntry(name: "dashboard", path: proj, kind: .directory,
                                size: nil, modified: nil, permissions: 0o755)
            ],
            proj: files,
        ]
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            fakeTerminal
            FilesPanelView(
                controller: controller,
                T: harnessTokens,
                initiallyShowingQuickOpen: ProcessInfo.processInfo.environment[
                    "TESSERA_FILES_HARNESS_MODE"
                ] == "quick"
            )

            if Self.showsMenuBisectProbes {
            // UIKit-native control: its `UIMenu` is built once, at press
            // time, by `UIContextMenuInteraction` — no SwiftUI bridge, no
            // eager menu building, no deferred elements. If this platter
            // settles on the same schedule as the SwiftUI one, the settle
            // belongs to `UIContextMenuInteraction` and no amount of
            // owning the interaction removes it.
            UIKitContextMenuProbe()
                .frame(width: 220, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 80)

            // Control surface for the residual-flicker bisect: a bare
            // SwiftUI view with a context menu, sharing nothing with the
            // Files panel — no glass card, no drag, no custom preview, no
            // observable model. If its platter repaints on the same
            // schedule the panel's does, the repaint is the platform's.
            Text(verbatim: "plain probe row")
                .font(Typography.tesseraMonoFixed(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black)
                .accessibilityIdentifier("files.row.plain-probe")
                .contextMenu {
                    Button("Quick Look") {}
                    Button("Download") {}
                    Button("Share…") {}
                    Button("Send Path to Terminal") { lastMenuAction = "send:plain-probe" }
                    Button("Copy Path") {}
                    Divider()
                    Button("Rename") {}
                    Button("Delete…", role: .destructive) {}
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            // The harness renders the panel unconditionally (the glass
            // captures need it on screen), so `close()` is otherwise
            // invisible. Surface the state for hit-test probes.
            Text(verbatim: "isOpen: \(controller.isOpen ? "true" : "false") action: \(lastMenuAction)")
                .font(Typography.tesseraMonoFixed(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, usesLightAppearance ? .light : .dark)
        .preferredColorScheme(usesLightAppearance ? .light : .dark)
        .task { configureIfNeeded() }
        // Reloads the listing on a cadence — the same shape of update a
        // live panel takes (poller report, transfer completion, refresh).
        // The mock tree is stable, so every reload yields IDENTICAL rows:
        // nothing visible should move, and no row's context menu should be
        // rebuilt.
        .task {
            let ms = Self.harnessChurnMilliseconds
            guard ms > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard !Task.isCancelled else { return }
                controller.terminalReportedDirectory(Self.harnessDirectory)
                controller.refresh()
            }
        }
        .onAppear {
            guard UIDevice.current.userInterfaceIdiom != .phone else { return }
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                return
            }
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscapeLeft),
                errorHandler: { error in
                    NSLog("[Tessera][FilesHarness] landscape request failed: \(error)")
                }
            )
        }
    }

    private var fakeTerminal: some View {
        VStack(spacing: 0) {
            ForEach(0..<48, id: \.self) { i in
                stripeColor(i)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        // Overlay so the overflowing text can't widen the
                        // layout (it pushed the card off-screen as a bg).
                        Text(String(repeating: "HARNESS ROW \(i) ", count: 12))
                            .font(Typography.tesseraMonoFixed(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
    }

    private func stripeColor(_ i: Int) -> Color {
        let palette: [Color] = [.green, .purple, .orange, .blue, .red, .black]
        return palette[i % palette.count].opacity(0.85)
    }
}

/// Purchase/admission presentation harness — no App Store, no SSH, no mosh.
/// Launch with
/// `SIMCTL_CHILD_TESSERA_HOST_ACCESS_HARNESS=1 SIMCTL_CHILD_TESSERA_HOST_ACCESS_STATE=free1 xcrun simctl launch …`.
///
/// `TESSERA_HOST_ACCESS_STATE` scripts the fake client (default `free0`):
/// - `checking` — product and entitlement loads never return
/// - `free0` / `free1` — product loads, no entitlement, 0/1 seeded hosts
/// - `purchasing` — `purchase()` suspends forever (auto-fired at launch)
/// - `pending` — `purchase()` returns `.pending` (auto-fired at launch)
/// - `error` — product load throws
/// - `purchase-error` — `purchase()` throws with a loaded product, surfacing
///   the error note and the try-again purchase button
/// - `purchased` / `legacy` — IAP / original-paid-app entitlement
/// - `revoked-multi` — no entitlement with 3 seeded hosts
///
/// `TESSERA_HOST_ACCESS_SURFACE` picks the rendered surface: `sheet`
/// (default, UnlimitedHostsSheet over a hosts-landing backdrop), `notice`
/// (HostLimitNoticeSheet), or `settings` (UnlimitedHostsSettingsView).
/// The app runs on the in-memory model container for this harness (see
/// `init`), so seeded hosts never touch the on-disk store.
struct HostAccessHarnessView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @State private var store: HostAccessStore
    @State private var sheetPresented = true
    @State private var offerRequested = false

    private let scenario = HostAccessHarnessScenario.fromEnvironment()

    init() {
        let store = HostAccessStore(
            client: HostAccessHarnessClient(state: scenario.state)
        )
        _store = State(initialValue: store)
        store.start()
    }

    var body: some View {
        content
            .environment(store)
            .task {
                seedHostsIfNeeded()
                // `purchasing`/`pending` must manifest at launch, not only
                // after a manual tap on the purchase button; `purchase-error`
                // needs one failed attempt so the note + try-again label show.
                if scenario.state == .purchasing
                    || scenario.state == .pending
                    || scenario.state == .purchaseError {
                    // start() resolves access asynchronously, and purchase()
                    // correctly refuses to charge while ownership is unknown.
                    // Wait for the harness baseline so these scenarios test
                    // their intended in-flight/pending/error presentation.
                    await store.awaitReady()
                    await store.purchase()
                }
            }
            .onAppear {
                guard UIDevice.current.userInterfaceIdiom != .phone else { return }
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                    return
                }
                scene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: .landscapeLeft),
                    errorHandler: { error in
                        NSLog("[Tessera][HostAccessHarness] landscape request failed: \(error)")
                    }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch scenario.surface {
        case .settings:
            NavigationStack {
                UnlimitedHostsSettingsView()
            }
        case .sheet, .notice:
            hostsBackdrop
                .sheet(isPresented: $sheetPresented) {
                    if scenario.surface == .notice && !offerRequested {
                        HostLimitNoticeSheet(
                            onViewOffer: { offerRequested = true },
                            onCancel: { sheetPresented = false }
                        )
                    } else {
                        UnlimitedHostsSheet()
                    }
                }
        }
    }

    /// Minimal hosts-landing stand-in so the sheets present over the same
    /// kind of flat dark surface they cover in production.
    private var hostsBackdrop: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "hosts")
                .font(Typography.tesseraMonoFixed(size: 22, weight: .bold))
                .foregroundStyle(T.fg)
            ForEach(0..<max(scenario.seededHostCount, 1), id: \.self) { index in
                Text(verbatim: "harness host \(index + 1)  192.0.2.\(index + 1)")
                    .font(Typography.tesseraMonoFixed(size: 13, weight: .medium))
                    .foregroundStyle(T.fgMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
        .background(T.bg)
    }

    private func seedHostsIfNeeded() {
        let target = scenario.seededHostCount
        guard target > 0 else { return }
        let existing = (try? modelContext.fetchCount(FetchDescriptor<PersistedHost>())) ?? 0
        guard existing < target else { return }
        for index in existing..<target {
            let host = PersistedHost(
                name: "Harness host \(index + 1)",
                address: "192.0.2.\(index + 1)",
                port: 22,
                autoTmux: true,
                transport: .ssh,
                launchMode: .autoTmux,
                sortOrder: index + 1,
                identity: nil
            )
            host.user = "harness"
            modelContext.insert(host)
        }
        try? modelContext.save()
    }
}

private struct HostAccessHarnessScenario {
    enum State: String {
        case checking, free0, free1, purchasing, pending, error, purchased, legacy
        case purchaseError = "purchase-error"
        case revokedMulti = "revoked-multi"
    }

    enum Surface: String {
        case sheet, notice, settings
    }

    let state: State
    let surface: Surface

    var seededHostCount: Int {
        switch state {
        case .free1: return 1
        case .revokedMulti: return 3
        default: return 0
        }
    }

    static func fromEnvironment() -> HostAccessHarnessScenario {
        let environment = ProcessInfo.processInfo.environment
        return HostAccessHarnessScenario(
            state: environment["TESSERA_HOST_ACCESS_STATE"].flatMap(State.init(rawValue:)) ?? .free0,
            surface: environment["TESSERA_HOST_ACCESS_SURFACE"].flatMap(Surface.init(rawValue:)) ?? .sheet
        )
    }
}

private enum HostAccessHarnessError: Error {
    case productLoadFailed
    case purchaseFailed
}

/// Scripted StoreKit boundary for the harness. The `checking` state never
/// resumes any load so the store must hold `.checking` regardless of which
/// truth it awaits first; every other state resolves deterministically.
private final class HostAccessHarnessClient: StoreKitClient {
    private static let product = AccessProduct(
        id: "com.bambouville.TesseraApp.unlimited_hosts",
        displayName: "Unlimited Saved Hosts",
        productDescription: "Save and manage as many hosts as you need.",
        displayPrice: "$9.99"
    )

    private let state: HostAccessHarnessScenario.State

    init(state: HostAccessHarnessScenario.State) {
        self.state = state
    }

    func loadProduct() async throws -> AccessProduct {
        switch state {
        case .checking:
            return await neverResolved()
        case .error:
            throw HostAccessHarnessError.productLoadFailed
        default:
            return Self.product
        }
    }

    func isLegacyPaidCustomer() async throws -> Bool {
        if state == .checking { let _: Void = await neverResolved() }
        return state == .legacy
    }

    func hasUnlimitedHostsEntitlement() async -> Bool {
        if state == .checking { let _: Void = await neverResolved() }
        return state == .purchased
    }

    func entitlementUpdates() -> AsyncStream<EntitlementUpdate> {
        AsyncStream { _ in }
    }

    func purchase() async throws -> PurchaseOutcome {
        switch state {
        case .purchasing:
            return await neverResolved()
        case .pending:
            return .pending
        case .purchaseError:
            throw HostAccessHarnessError.purchaseFailed
        default:
            return .cancelled
        }
    }

    func sync() async throws {}

    private func neverResolved<T>() async -> T {
        await withCheckedContinuation { (_: CheckedContinuation<T, Never>) in }
    }
}

/// Production-session visual harness for the live four-transport scroll
/// matrix. Connections are created directly from an ephemeral, base64 JSON
/// configuration supplied by `scripts/integration/`; UI automation never
/// opens a host. The disposable fixture's unknown host key is accepted here so
/// the capture can exercise the terminal rather than the trust sheet.
struct LiveScrollVisualHarnessView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppearancePreferences.self) private var appearance
    @State private var sessionRegistry = SessionRegistry()
    @State private var commandPalette = CommandPalette()
    @State private var agentCenterV2 = AgentCenterV2Coordinator()
    @State private var programStatusCenter = ProgramStatusCenter()
    @State private var fileBridges = FileBridgeRegistry()
    @State private var liveSessionID = UUID()
    @State private var showAgentVerification = true
    /// `TESSERA_LIVE_SCROLL_SHOW_EDGES=1`: show the session as ContentView
    /// shows a selected one, so it takes part in grid authority (claim, own
    /// stamp, presented-window repair). Off by default: without show edges
    /// the controller stays hidden and never claims the grid.
    @State private var showEdges: SessionShowCoordinator? =
        ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_SHOW_EDGES"] == "1"
            ? SessionShowCoordinator(appForeground: false, locked: false)
            : nil

    private let configuration = LiveScrollVisualConfiguration.load()

    @ViewBuilder
    var body: some View {
        if let configuration {
            Group {
                switch configuration.mode.transport {
                case .ssh:
                    SSHLiveScrollVisualHarness(
                        configuration: configuration,
                        liveSessionID: liveSessionID,
                        sessionRegistry: sessionRegistry
                    )
                case .mosh:
                    MoshLiveScrollVisualHarness(
                        configuration: configuration,
                        liveSessionID: liveSessionID,
                        sessionRegistry: sessionRegistry
                    )
                }
            }
            .environment(sessionRegistry)
            .environment(commandPalette)
            .environment(agentCenterV2)
            .environment(programStatusCenter)
            .environment(fileBridges)
            .environment(\.sessionShowCoordinator, showEdges)
            .onChange(of: scenePhase, initial: true) { _, phase in
                showEdges?.setAppForeground(phase != .background)
            }
            .onAppear { showEdges?.setSelectedSlot(liveSessionID) }
            .overlay {
                if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_LIVE_VERIFY"] == "1",
                   showAgentVerification {
                    AgentCenterV2RootView(model: agentCenterV2.presentation) {
                        Button("terminal") { showAgentVerification = false }
                    }
                    .background(Color(uiColor: .systemBackground))
                }
            }
            // The app draws the shared palette from ContentView, which this
            // harness replaces. Mirrored here so a switcher pick hands the
            // keyboard back exactly as it does in the app.
            .overlay {
                if Self.paletteEnabled, commandPalette.isOpen {
                    CommandPaletteView(
                        palette: commandPalette,
                        onTmuxClose: sessionRegistry.requestTmuxClose,
                        onTmuxMutation: sessionRegistry.requestTmuxMutation,
                        onCommit: commitPalette
                    )
                    .environment(agentCenterV2)
                    .environment(programStatusCenter)
                    .transition(.opacity)
                    .zIndex(50)
                }
            }
            .task {
                if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_LIVE_VERIFY"] == "1" {
                    await agentCenterV2.setExperimentEnabled(true)
                    agentCenterV2.setSurfaceDemand(true)
                }
            }
            .onAppear {
                // Vim's blinking terminal cursor is a repeating UIView
                // animation. XCUITest otherwise waits two 60-second
                // quiescence timeouts around every real scroll gesture.
                UIView.setAnimationsEnabled(ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_PHYSICS"] == "1")
                appearance.cursorBlink = false
                appearance.smoothScrollingEnabled = ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_PHYSICS"] == "1"
            }
            .onDisappear {
                UIView.setAnimationsEnabled(true)
                #if DEBUG
                LiveScrollInitialRenderProbe.clear(sessionID: liveSessionID)
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                #if DEBUG
                switch phase {
                case .background:
                    LiveScrollForegroundProbe.arm()
                case .active:
                    LiveScrollForegroundProbe.sendAfterForegroundIfArmed()
                default:
                    break
                }
                #endif
            }
        } else {
            Text(verbatim: "LIVE SCROLL HARNESS CONFIGURATION ERROR")
                .font(Typography.tesseraMonoFixed(size: 18, weight: .bold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .accessibilityIdentifier("live-scroll-configuration-error")
        }
    }

    /// `TESSERA_LIVE_SCROLL_PALETTE=1`: draw the switcher and register the
    /// live session so a window pick routes like ContentView's. Off by
    /// default so the scroll lanes keep their single unregistered surface.
    static var paletteEnabled: Bool {
        ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_PALETTE"] == "1"
    }

    private func commitPalette(_ result: CommandPaletteCommit) {
        switch result {
        case .window(let sessionID, let windowID):
            sessionRegistry.requestTmuxFocus(sessionID: sessionID, windowID: windowID)
        case .pane(let sessionID, let windowID, let paneID):
            sessionRegistry.requestTmuxFocus(sessionID: sessionID, windowID: windowID, paneID: paneID)
        case .home, .session:
            break
        }
    }
}

@MainActor
private func registerLiveScrollPaletteSession(
    _ session: Session,
    id: UUID,
    configuration: LiveScrollVisualConfiguration,
    in registry: SessionRegistry
) {
    guard LiveScrollVisualHarnessView.paletteEnabled else { return }
    registry.syncActiveSessions([LiveSession(
        id: id,
        session: session,
        hostName: configuration.host.name,
        hostKey: "live-scroll:\(configuration.mode.rawValue)",
        launchMode: configuration.mode.usesTmux ? .pinnedTmux : .customCommand,
        pinnedSessionName: configuration.tmuxSessionName
    )])
}

private struct SSHLiveScrollVisualHarness: View {
    @StateObject private var session: SSHSession
    @State private var sharedState: SharedSessionState = .idle
    let configuration: LiveScrollVisualConfiguration
    let liveSessionID: UUID
    let sessionRegistry: SessionRegistry

    init(
        configuration: LiveScrollVisualConfiguration,
        liveSessionID: UUID,
        sessionRegistry: SessionRegistry
    ) {
        self.configuration = configuration
        self.liveSessionID = liveSessionID
        self.sessionRegistry = sessionRegistry
        _session = StateObject(wrappedValue: SSHSession(host: configuration.host))
    }

    var body: some View {
        SessionView(
            session: session,
            liveSessionID: liveSessionID,
            isActive: true,
            onToggleSidebar: {},
            sidebarVisible: false,
            onBack: {},
            onEditHost: {},
            onRetry: {},
            onSessionEnded: {},
            onSelectSession: { _ in },
            onOpenSettings: {},
            onOpenAgentCenter: {}
        )
        .overlay(alignment: .bottomLeading) { statusProbe }
        .onReceive(session.sessionCommands.statePublisher) { sharedState = $0 }
        .onReceive(session.sessionCommands.challengeRequests.compactMap { $0 }) { request in
            _ = session.sessionCommands.respondToHostKeyChallenge(
                request.id,
                decision: .approve
            )
        }
        .onAppear {
            registerLiveScrollPaletteSession(
                .ssh(session),
                id: liveSessionID,
                configuration: configuration,
                in: sessionRegistry
            )
        }
        .task { await refreshWhenReady() }
        .onDisappear { session.sessionCommands.disconnect() }
    }

    private var statusProbe: some View {
        LiveScrollStatusProbe(
            label: configuration.mode.label,
            isReady: sessionRegistry.isRenderReady(liveSessionID),
            state: legacySessionState(from: sharedState),
            liveSessionID: liveSessionID,
            requiresInitialTmuxRender: configuration.mode.requiresInitialTmuxRender
        )
    }

    private func refreshWhenReady() async {
        var didResignFirstResponder = false
        while !Task.isCancelled {
            if sessionRegistry.isRenderReady(liveSessionID) {
                LiveScrollTerminalExposure.refresh()
                if UIDevice.current.userInterfaceIdiom != .phone,
                   ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_KEEP_KEYBOARD"] != "1",
                   !didResignFirstResponder {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                    didResignFirstResponder = true
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private struct MoshLiveScrollVisualHarness: View {
    @StateObject private var session: MoshSession
    @State private var sharedState: SharedSessionState = .idle
    let configuration: LiveScrollVisualConfiguration
    let liveSessionID: UUID
    let sessionRegistry: SessionRegistry

    init(
        configuration: LiveScrollVisualConfiguration,
        liveSessionID: UUID,
        sessionRegistry: SessionRegistry
    ) {
        self.configuration = configuration
        self.liveSessionID = liveSessionID
        self.sessionRegistry = sessionRegistry
        _session = StateObject(wrappedValue: MoshSession(host: configuration.host))
    }

    var body: some View {
        MoshSessionView(
            session: session,
            liveSessionID: liveSessionID,
            isActive: true,
            onToggleSidebar: {},
            sidebarVisible: false,
            onBack: {},
            onEditHost: {},
            onRetry: {},
            onSessionEnded: {},
            onSelectSession: { _ in },
            onOpenSettings: {},
            onOpenAgentCenter: {}
        )
        .overlay(alignment: .bottomLeading) { statusProbe }
        .onReceive(session.sessionCommands.statePublisher) { sharedState = $0 }
        .onReceive(session.sessionCommands.challengeRequests.compactMap { $0 }) { request in
            _ = session.sessionCommands.respondToHostKeyChallenge(
                request.id,
                decision: .approve
            )
        }
        .onAppear {
            registerLiveScrollPaletteSession(
                .mosh(session),
                id: liveSessionID,
                configuration: configuration,
                in: sessionRegistry
            )
        }
        .task { await refreshWhenReady() }
        .onDisappear { session.sessionCommands.disconnect() }
    }

    private var statusProbe: some View {
        LiveScrollStatusProbe(
            label: configuration.mode.label,
            isReady: sessionRegistry.isRenderReady(liveSessionID),
            state: legacySessionState(from: sharedState),
            liveSessionID: liveSessionID,
            requiresInitialTmuxRender: configuration.mode.requiresInitialTmuxRender
        )
    }

    private func refreshWhenReady() async {
        var didResignFirstResponder = false
        while !Task.isCancelled {
            if sessionRegistry.isRenderReady(liveSessionID) {
                LiveScrollTerminalExposure.refresh()
                if UIDevice.current.userInterfaceIdiom != .phone,
                   ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_KEEP_KEYBOARD"] != "1",
                   !didResignFirstResponder {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                    didResignFirstResponder = true
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
private enum LiveScrollTerminalExposure {
    static func refresh() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let terminals = windows.flatMap { terminalViews(in: $0) }
        guard !terminals.isEmpty else { return }
        // Only what is on screen: a dormant overlay stays mounted at zero
        // opacity, and another scene's terminals are not in front.
        let shown = terminals.filter(isShown)
        var candidates = shown.isEmpty ? terminals : shown
        // A split lane aims its fingers at one pane, at this fraction of the
        // window's width: only terminals under that point are the target.
        // An SSH+tmux grid gives every pane its own terminal, and the one
        // aimed at need not be the largest.
        if let aimX = ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_AIM_X"]
            .flatMap(Double.init).map({ CGFloat($0) }) {
            let aimed = candidates.filter { terminal in
                guard let window = terminal.window else { return false }
                let point = CGPoint(x: window.bounds.width * aimX, y: window.bounds.midY)
                return terminal.convert(terminal.bounds, to: window).contains(point)
            }
            if !aimed.isEmpty { candidates = aimed }
        }

        // UIKit subviews are back-to-front. On equal-size mosh surfaces the
        // later terminal is the revealed capture-pane overlay and therefore
        // the gesture target; otherwise choose the largest production surface.
        var chosen = candidates[0]
        for terminal in candidates.dropFirst() {
            let candidateArea = terminal.bounds.width * terminal.bounds.height
            let chosenArea = chosen.bounds.width * chosen.bounds.height
            if candidateArea >= chosenArea { chosen = terminal }
        }
        let exposesRows = ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_EXPOSE_ROWS"] == "1"
        let rowSource = exposesRows ? frontmost(within: chosen, among: candidates) : chosen
        for terminal in terminals {
            terminal.isAccessibilityElement = terminal === chosen
            terminal.accessibilityIdentifier = terminal === chosen
                ? "live-scroll-terminal"
                : nil
            if exposesRows {
                terminal.accessibilityValue = terminal === chosen ? visibleRows(of: rowSource) : nil
            }
        }
    }

    /// The terminal whose rows are on screen over `chosen`: a revealed
    /// history overlay covering the focused pane of an iPad split, else
    /// `chosen` itself.
    private static func frontmost(within chosen: TerminalView, among terminals: [TerminalView]) -> TerminalView {
        guard let window = chosen.window else { return chosen }
        let chosenFrame = chosen.convert(chosen.bounds, to: window).insetBy(dx: -1, dy: -1)
        return terminals.last {
            $0.window === window && chosenFrame.contains($0.convert($0.bounds, to: window))
        } ?? chosen
    }

    private static func isShown(_ terminal: TerminalView) -> Bool {
        guard terminal.window?.windowScene?.activationState == .foregroundActive else { return false }
        var view: UIView? = terminal
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 || current.layer.opacity <= 0.01 { return false }
            view = current.superview
        }
        return true
    }

    /// The fixture rows on screen, for gestures graded by content: the Metal
    /// surface is black to XCUITest. "rows=00412-00447 n=36 order=1 top=0
    /// tail=1 tick=00031 screen=36 lines=1540 cols=82": the lowest and
    /// highest numbered fixture rows visible, how many there are and whether
    /// each follows the one above, whether the view sits at its oldest loaded
    /// row or at its live tail, the latest fixture heartbeat on screen, how
    /// many rows the screen shows, how many the terminal holds (output that
    /// scrolled has reached it), and its width, which a fixture row wider
    /// than the terminal wraps at.
    private static func visibleRows(of view: TerminalView) -> String {
        let cell = TerminalCellMetrics.cellSize(for: view)
        guard cell.height > 0 else { return "rows=- n=0 order=1 top=0 tail=0 tick=- screen=0 lines=0 cols=0" }
        let lines = String(decoding: view.getTerminal().getBufferAsData(kind: .active), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        // Rows whose centre is on screen. The viewport is rarely a whole
        // number of rows, so a partial top row must not push the bottom row
        // (the live tail's cursor line) out of the readout.
        let first = max(0, Int((view.contentOffset.y / cell.height - 0.5).rounded(.up)))
        let last = Int(((view.contentOffset.y + view.bounds.height) / cell.height - 0.5).rounded(.down))
        let visible = lines.dropFirst(first).prefix(max(1, last - first + 1))
        var numbers: [Int] = []
        var tick = "-"
        for line in visible {
            if let match = line.firstMatch(of: /TESSERA_SCROLL_[A-Z_]+?_(\d{5}) \|/) {
                numbers.append(Int(match.1) ?? 0)
            }
            // A resize can leave an older tick behind: keep the newest.
            for match in line.matches(of: /TESSERA_TICK_(\d{5})/) where tick == "-" || String(match.1) > tick {
                tick = String(match.1)
            }
        }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        let rows = numbers.isEmpty
            ? "-"
            : String(format: "%05d-%05d", numbers.min() ?? 0, numbers.max() ?? 0)
        // With `n` equal to the span, the rows run in order without a
        // missing, repeated or stale row between the bounds.
        let ordered = zip(numbers, numbers.dropFirst()).allSatisfy { $0 + 1 == $1 }
        return "rows=\(rows) n=\(numbers.count) order=\(ordered ? 1 : 0)"
            + " top=\(view.contentOffset.y <= 0.5 ? 1 : 0)"
            + " tail=\(maxOffsetY - view.contentOffset.y <= 1 ? 1 : 0) tick=\(tick)"
            + " screen=\(max(0, last - first + 1)) lines=\(Int((view.contentSize.height / cell.height).rounded()))"
            + " cols=\(view.getTerminal().cols)"
    }

    private static func terminalViews(in view: UIView) -> [TerminalView] {
        var result: [TerminalView] = []
        if let terminal = view as? TerminalView { result.append(terminal) }
        for subview in view.subviews {
            result.append(contentsOf: terminalViews(in: subview))
        }
        return result
    }
}

private struct LiveScrollStatusProbe: View {
    let label: String
    let isReady: Bool
    let state: SessionState
    let liveSessionID: UUID
    let requiresInitialTmuxRender: Bool
    @State private var foregroundProbeValue: String?
    @State private var initialTmuxRenderReady = false

    var body: some View {
        ZStack {
            Text(verbatim: "scroll")
                .font(.system(size: 1))
                .foregroundStyle(Color.white.opacity(0.01))
                .frame(width: 2, height: 2)
                .accessibilityIdentifier("live-scroll-status")
                .accessibilityLabel(label)
                .accessibilityValue(foregroundProbeValue ?? (isReady ? "ready" : stateDescription))

            // This must stay separate from broader registry readiness: the
            // launch watchdog can deliberately reveal a stalled session, but
            // screenshot capture needs a real initial tmux render.
            Text(verbatim: "tmux-render")
                .font(.system(size: 1))
                .foregroundStyle(Color.white.opacity(0.01))
                .frame(width: 2, height: 2)
                .accessibilityIdentifier("live-scroll-initial-render")
                .accessibilityValue(initialTmuxRenderStatus)
        }
        .accessibilityElement(children: .contain)
        .allowsHitTesting(false)
        .task(id: liveSessionID) {
            while !Task.isCancelled {
                #if DEBUG
                initialTmuxRenderReady = LiveScrollInitialRenderProbe.isReady(
                    for: liveSessionID
                )
                foregroundProbeValue = LiveScrollForegroundProbe.statusValue
                #endif
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var initialTmuxRenderStatus: String {
        requiresInitialTmuxRender
            ? (initialTmuxRenderReady ? "ready" : "waiting")
            : "not-required"
    }

    private var stateDescription: String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        }
    }
}

private struct LiveScrollVisualConfiguration: Decodable {
    enum Mode: String, Decodable {
        case ssh
        case sshTmux = "ssh-tmux"
        case mosh
        case moshTmux = "mosh-tmux"

        var requiresInitialTmuxRender: Bool {
            switch self {
            case .sshTmux, .moshTmux:
                true
            case .ssh, .mosh:
                false
            }
        }

        var transport: HostTransport {
            switch self {
            case .ssh, .sshTmux: return .ssh
            case .mosh, .moshTmux: return .mosh
            }
        }

        var usesTmux: Bool {
            self == .sshTmux || self == .moshTmux
        }

        var label: String { rawValue.uppercased() }
    }

    let mode: Mode
    let address: String
    let port: Int
    let user: String
    let password: String
    let launchCommand: String
    let tmuxSessionName: String?
    let privateKeyFilename: String?

    var host: Host {
        Host(
            name: "SCROLL \(mode.label)",
            address: address,
            port: port,
            user: user,
            password: password,
            transport: mode.transport,
            privateKeyFilename: privateKeyFilename,
            autoTmux: mode.usesTmux,
            launchMode: mode.usesTmux ? .pinnedTmux : .customCommand,
            tmuxSessionName: mode.usesTmux ? tmuxSessionName : nil,
            launchCommand: mode.usesTmux ? nil : launchCommand
        )
    }

    static func load() -> Self? {
        guard let encoded = ProcessInfo.processInfo.environment[
            "TESSERA_LIVE_SCROLL_CONFIG_B64"
        ], let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Fast, host-free scroll wiring harness. It mounts Tessera's real
/// `TerminalSurfaceBound`, feeds enough deterministic rows for primary-screen
/// history, and exposes a tiny accessibility state oracle. XCUITest supplies
/// an actual indirect-pointer scroll; assertions use contentOffset state rather
/// than Metal screenshots or timing-sensitive pixel diffs.
struct TerminalScrollHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @State private var oracle = TerminalScrollHarnessOracle()
    @State private var previewRequest: FilesPanelController.PreviewRequest?
    @State private var previewResizePulse = false
    private var previewResizeMode: Bool { ProcessInfo.processInfo.environment["TESSERA_IDLE_REDRAW_HARNESS"] == "preview" }
    // XCUITest's synthesized pointer event waits several seconds for the app
    // to idle before returning. Keep the DEBUG-only notice around long enough
    // for accessibility to inspect it; production retains the two-second TTL.
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController(
        dismissDelay: .seconds(10)
    )

    private var blocksAgentScrolling: Bool {
        ProcessInfo.processInfo.environment[
            "TESSERA_AGENT_SCROLL_BLOCK_HARNESS"
        ] == "1"
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurfaceBound(
                initialData: previewResizeMode ? [] : Self.fixtureBytes,
                onMade: { view in
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "terminal-scroll-harness"
                    view.accessibilityLabel = "terminal scroll harness"
                    oracle.terminalView = view
                    if ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK"] == "1",
                       let view = view as? TesseraResponderAwareTerminalView {
                        oracle.benchmark = TerminalScrollBenchmark(view: view)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        oracle.update()
                    }
                },
                onReady: {},
                onSend: { _ in },
                onResize: { cols, rows in
                    guard previewResizeMode else { return }
                    oracle.previewColumns = cols
                    oracle.previewRows = rows
                    oracle.previewNeedsFullPaint = true
                    NSLog("[Tessera][PreviewResize] remote-size=%dx%d", cols, rows)
                },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                agentScrollBlockingActive: blocksAgentScrolling,
                onAgentScrollBlocked: {
                    oracle.noteAgentScrollBlocked()
                    agentScrollNotice.show(Self.agentPrevention)
                },
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: ProcessInfo.processInfo.environment["TESSERA_IDLE_REDRAW_HARNESS"] != nil,
                onHardwareKey: nil,
                onTerminalScrolled: { _ in oracle.update() },
                scrollRetentionID: "integration-scroll-harness",
                onScrollDiagnostic: { message in
                    NSLog("[Tessera][ScrollHarness] \(message)")
                    // Direct contentOffset writes are deliberate in the real
                    // scroll path and don't call SwiftTerm's delegate. Sample
                    // the real UIScrollView after each diagnostic commit.
                    oracle.update()
                }
            )

            if previewResizeMode {
                Button("Open Markdown") {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-preview.md")
                    try? "# Terminal preview\n\nDismiss this document to check the prompt.".write(to: url, atomically: true, encoding: .utf8)
                    previewRequest = .init(localURL: url, title: "Terminal preview.md")
                }
                .accessibilityIdentifier("preview-resize-open")
                .padding(40)
            }

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: TerminalTheme.find(id: appearance.terminalThemeID)
                        .chromeTokens(applying: appearance)
                )
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
            }
        }
        .padding(ProcessInfo.processInfo.environment["TESSERA_IDLE_REDRAW_HARNESS"] != nil ? 32 : 0)
        .ignoresSafeArea(.all, edges: ProcessInfo.processInfo.environment["TESSERA_IDLE_REDRAW_HARNESS"] == nil ? .all : [])
        .background(Color.black)
        .padding(.bottom, previewResizePulse ? 32 : 0)
        .quickLookPreview(item: $previewRequest)
        .statusBarHidden(previewResizeMode)
        .preferredColorScheme(.dark)
        .task {
            guard let mode = ProcessInfo.processInfo.environment["TESSERA_IDLE_REDRAW_HARNESS"] else { return }
            guard mode != "benchmark" else { return }
            // Host-free visual reproduction through the production renderer.
            // Deliberate holds let simctl capture the Metal layer at each stage.
            try? await Task.sleep(for: .seconds(3))
            guard let view = oracle.terminalView as? TerminalView else { return }
            if mode == "preview" {
                for frame in 0..<650 {
                    guard !Task.isCancelled else { return }
                    let cols = oracle.previewColumns, rows = oracle.previewRows
                    if cols > 0 && rows > 0 {
                        if oracle.previewNeedsFullPaint {
                            view.feed(text: TerminalPreviewResizeFixture.screen(cols: cols, rows: rows))
                            oracle.previewNeedsFullPaint = false
                        }
                        view.feed(text: TerminalPreviewResizeFixture.tick(frame: frame, cols: cols, rows: rows))
                        if frame % 100 == 0 {
                            NSLog("[Tessera][PreviewResize] tick=%d local=%dx%d remote=%dx%d", frame, view.getTerminal().cols, view.getTerminal().rows, cols, rows)
                        }
                    }
                    if frame == 100 {
                        NSLog("[Tessera][PreviewResize] stage=before")
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-preview.md")
                        try? "# Terminal preview\n\nDismiss this document to check the prompt.".write(to: url, atomically: true, encoding: .utf8)
                        previewRequest = .init(localURL: url, title: "Terminal preview.md")
                    }
                    if frame == 300 {
                        NSLog("[Tessera][PreviewResize] stage=dismiss")
                        previewRequest = nil
                        if ProcessInfo.processInfo.environment["TESSERA_PREVIEW_RESIZE_PULSE"] == "1" {
                            previewResizePulse = true
                        }
                    }
                    if frame == 302 { previewResizePulse = false }
                    if frame == 600 {
                        let defects = TerminalPreviewResizeFixture.backgroundDefects(in: view.getTerminal())
                        let clean = defects == 0 && view.getTerminal().rows == rows && view.getTerminal().cols == cols
                        view.accessibilityValue = clean ? "preview-clean" : "preview-corrupt"
                        NSLog("[Tessera][PreviewResize] stage=after clean=%d defects=%d", clean, defects)
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return
            }
            if mode == "color" || mode == "color-baseline" {
                var framer = TmuxLiveOutputFramer()
                var filter = TerminalOutputContrastFilter()
                for (index, part) in ["\u{1B}[38;2;58;58;", "\u{1B}[0m\u{1B}[H\u{1B}[2Jprompt", "58;48;2;0;0;30mX"].enumerated() {
                    let bytes = index == 1 || mode == "color-baseline" ? Array(part.utf8) : framer.process(Array(part.utf8))
                    view.feed(byteArray: filter.process(bytes[...], defaultBackgroundRGB: 0,
                        defaultForegroundRGB: 0xD4D4D4, minimumContrast: 0.3))
                }
                let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
                let clean = text.contains("promptX") && !text.contains("58;48;2;0;0;30m")
                view.accessibilityValue = clean ? "repaint-clean" : "repaint-leaked"
                NSLog("[Tessera][IdleRedrawHarness] stage=color clean=%d", clean)
                return
            }
            view.contentOffset.y -= 600
            let readingPosition = view.contentOffset.y
            oracle.update()
            NSLog("[Tessera][IdleRedrawHarness] stage=history offset=%.1f", view.contentOffset.y)
            try? await Task.sleep(for: .seconds(4))
            for frame in 0..<30 {
                guard !Task.isCancelled else { return }
                view.feed(text: "\u{1B}[?2026h\u{1B}[s\u{1B}[1;1Hidle redraw \(frame)\u{1B}[u\u{1B}[?2026l")
                oracle.update()
                try? await Task.sleep(for: .milliseconds(150))
            }
            NSLog("[Tessera][IdleRedrawHarness] stage=redrawn offset=%.1f", view.contentOffset.y)
            view.accessibilityValue = abs(view.contentOffset.y - readingPosition) < 0.5 ? "redraw-stable" : "redraw-jumped"
        }
        .onAppear {
            // The harness has no visual-animation assertion. Cursor blinking
            // and inertial glide only keep XCUITest's quiescence detector
            // occupied, so turn them off inside this DEBUG/env-only surface.
            UIView.setAnimationsEnabled(previewResizeMode || ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK"] == "1")
            if previewResizeMode {
                UserDefaults.standard.set(ProcessInfo.processInfo.environment["TESSERA_PREVIEW_MODE"] ?? "popup", forKey: QuickLookPresentationMode.storageKey)
            }
            appearance.cursorBlink = false
            appearance.smoothScrollingEnabled = ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK"] == "1"
        }
        .onDisappear {
            UIView.setAnimationsEnabled(true)
        }
    }

    private static let fixtureBytes: [UInt8] = {
        var text = ""
        for row in 1...500 {
            if ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK"] == "1" {
                text += row % 12 < 6 ? "\u{1B}[48;5;22m" : "\u{1B}[48;5;52m"
            }
            text += String(format: "TESSERA_SCROLL_ROW_%04d ", row)
            text += String(repeating: "0123456789abcdef", count: 8)
            text += "\r\n"
        }
        return Array(text.utf8)
    }()

    private static let agentPrevention = AgentScrollPrevention(
        agentID: AgentInstanceID(
            sessionID: UUID(uuidString: "A6E70000-0000-0000-0000-000000000001")!,
            paneID: nil
        ),
        agentName: "Codex"
    )
}

/// Host-free touchscreen-scroll regression harness. The terminal starts in
/// alternate-screen + SGR mouse-reporting mode, matching Claude Code in the
/// supplied device diagnostics. Its accessibility value changes only after a
/// real finger pan produces an encoded terminal wheel event through `onSend`.
struct TerminalTouchScrollHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @State private var oracle = TerminalTouchScrollHarnessOracle()
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController(
        dismissDelay: .seconds(10)
    )

    private var blocksAgentScrolling: Bool {
        ProcessInfo.processInfo.environment[
            "TESSERA_AGENT_SCROLL_BLOCK_HARNESS"
        ] == "1"
    }

    /// A mosh+tmux primary screen: finger pans take the pointer's route to
    /// the host's history hook, which the oracle records.
    private var moshPrimary: Bool {
        ProcessInfo.processInfo.environment[
            "TESSERA_TOUCH_SCROLL_HARNESS_MOSH_PRIMARY"
        ] == "1"
    }

    /// An SSH+tmux primary screen: finger pans stay on UIScrollView's own
    /// pan, and its frames must reach the host (the inline history gate)
    /// through `onNativeScrollFrame`, which the oracle records.
    private var inlinePrimary: Bool {
        ProcessInfo.processInfo.environment[
            "TESSERA_TOUCH_SCROLL_HARNESS_INLINE_PRIMARY"
        ] == "1"
    }

    private var initialFixtureBytes: [UInt8] {
        if moshPrimary { return Self.primaryFixtureBytes }
        if inlinePrimary { return Self.inlinePrimaryFixtureBytes }
        return Self.fixtureBytes
    }

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurfaceBound(
                initialData: initialFixtureBytes,
                onMade: { view in
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "terminal-touch-scroll-harness"
                    view.accessibilityLabel = "terminal touch scroll harness"
                    oracle.terminalView = view
                    oracle.markReady()
                },
                onReady: {},
                onSend: { bytes in oracle.noteSent(bytes) },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                onPrimaryScrollbackDelta: moshPrimary ? { _, pointsY, _, _, _, _ in
                    oracle.notePrimaryHistoryRequest(pointsY: pointsY)
                    return .consumedCancelInertia
                } : nil,
                primaryTouchScrollIsLocal: moshPrimary ? { true } : nil,
                touchPansTakePointerRoute: moshPrimary ? { true } : nil,
                agentScrollBlockingActive: blocksAgentScrolling,
                onAgentScrollBlocked: {
                    oracle.noteAgentScrollBlocked()
                    agentScrollNotice.show(Self.agentPrevention)
                },
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: false,
                onHardwareKey: nil,
                onNativeScrollFrame: inlinePrimary ? { view, previousOffsetY in
                    oracle.noteNativeScrollFrame(view, previousOffsetY: previousOffsetY)
                } : nil,
                scrollRetentionID: "integration-touch-scroll-harness",
                onScrollDiagnostic: { message in
                    NSLog("[Tessera][TouchScrollHarness] \(message)")
                }
            )

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: TerminalTheme.find(id: appearance.terminalThemeID)
                        .chromeTokens(applying: appearance)
                )
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            UIView.setAnimationsEnabled(false)
            appearance.cursorBlink = false
            appearance.smoothScrollingEnabled = false
        }
        .onDisappear {
            UIView.setAnimationsEnabled(true)
        }
    }

    private static let fixtureBytes = Array(
        ("\u{1B}[?1049h" +  // alternate screen
         "\u{1B}[?1003h" +  // any-event mouse reporting
         "\u{1B}[?1006h" +  // SGR mouse encoding
         "CLAUDE_TOUCH_SCROLL_FIXTURE\r\n").utf8
    )

    private static let primaryFixtureBytes = Array(
        (1...80).map { "MOSH_PRIMARY_TOUCH_FIXTURE \($0)\r\n" }.joined().utf8
    )

    /// A few screens of local scrollback, so one fling can reach the top.
    private static let inlinePrimaryFixtureBytes = Array(
        (1...160).map { "INLINE_PRIMARY_TOUCH_FIXTURE \($0)\r\n" }.joined().utf8
    )

    private static let agentPrevention = AgentScrollPrevention(
        agentID: AgentInstanceID(
            sessionID: UUID(uuidString: "A6E70000-0000-0000-0000-000000000002")!,
            paneID: nil
        ),
        agentName: "Claude Code"
    )
}

private final class TerminalTouchScrollHarnessOracle {
    weak var terminalView: TerminalView?
    private var sawMouseDrag = false
    private var sawPrimaryHistoryRequest = false
    private var sawNativeDragUp = false
    private var sawNativeGlideUp = false
    private var sawNativeCrossing = false

    func markReady() {
        terminalView?.accessibilityValue = "ready"
    }

    /// A gesture that was blocked yet also reached the history hook (or moved
    /// primary history natively) reads differently, whichever came first.
    func noteAgentScrollBlocked() {
        terminalView?.accessibilityValue = sawPrimaryHistoryRequest || sawNativeDragUp || sawNativeGlideUp
            ? "agent-scroll-blocked-after-history" : "agent-scroll-blocked"
    }

    func notePrimaryHistoryRequest(pointsY: Double) {
        guard pointsY != 0 else { return }
        sawPrimaryHistoryRequest = true
        terminalView?.accessibilityValue = "primary-history-requested"
    }

    /// Upward finger frames while dragging, then a glide that carries past
    /// the oldest row (bounces make its offset negative): what the inline
    /// history gate needs to see from a finger's fling.
    func noteNativeScrollFrame(_ view: TerminalView, previousOffsetY: CGFloat) {
        let offsetY = view.contentOffset.y
        guard offsetY < previousOffsetY else { return }
        if view.isDecelerating {
            sawNativeGlideUp = true
            if sawNativeDragUp && offsetY < 0 { sawNativeCrossing = true }
        } else if view.isTracking || view.isDragging {
            sawNativeDragUp = true
        }
        let state: String
        if sawNativeCrossing {
            state = "native-frames-crossed-oldest"
        } else if sawNativeGlideUp {
            state = "native-frames-gliding"
        } else {
            state = "native-frames-dragging"
        }
        terminalView?.accessibilityValue = state
    }

    func noteSent(_ bytes: ArraySlice<UInt8>) {
        let payload = Array(bytes)
        let buttonPress = Array("\u{1B}[<0;".utf8)
        let buttonMotion = Array("\u{1B}[<32;".utf8)
        if payload.starts(with: buttonPress) || payload.starts(with: buttonMotion) {
            sawMouseDrag = true
            terminalView?.accessibilityValue = "mouse-drag-forwarded"
            return
        }

        let wheelUp = Array("\u{1B}[<64;".utf8)
        let wheelDown = Array("\u{1B}[<65;".utf8)
        guard !sawMouseDrag,
              payload.starts(with: wheelUp) || payload.starts(with: wheelDown)
        else {
            return
        }
        terminalView?.accessibilityValue = "mouse-wheel-forwarded"
    }
}

enum TerminalPreviewResizeFixture {
    static func backgroundDefects(in terminal: Terminal) -> Int {
        var defects = 0
        for row in max(0, terminal.rows - 3)..<terminal.rows {
            for col in 0..<terminal.cols {
                if terminal.getCharData(col: col, row: row)?.attribute.bg != .trueColor(red: 30, green: 30, blue: 30) { defects += 1 }
            }
        }
        return defects
    }
    static func screen(cols: Int, rows: Int) -> String {
        var text = "\u{1B}[0m\u{1B}[H\u{1B}[2J"
        for row in 1...max(1, rows - 4) {
            text += "\u{1B}[\(row);1HHistory row \(row) " + String(repeating: ".", count: max(0, cols - 20))
        }
        text += "\u{1B}[\(rows - 3);1HWorked for 6m 45s"
        for row in (rows - 2)...rows {
            text += "\u{1B}[\(row);1H\u{1B}[48;2;30;30;30m" + String(repeating: " ", count: cols) + "\u{1B}[0m"
        }
        return text + "\u{1B}[\(rows - 1);1H\u{1B}[48;2;30;30;30mAsk Codex to do anything\u{1B}[0m"
    }
    static func tick(frame: Int, cols: Int, rows: Int) -> String {
        var text = "\u{1B}[?2026h\u{1B}[48;2;30;30;30m\u{1B}[38;2;100;100;100m"
        for index in 0..<16 {
            let row = rows - 2 + index % 3
            let col = 28 + (index * 7 + frame % 13) % max(1, cols - 29)
            text += "\u{1B}[\(row);\(col)H" + (frame % 2 == 0 ? "⠂" : " ")
        }
        return text + "\u{1B}[0m\u{1B}[?2026l"
    }
}

/// Repeatable, host-free renderer workload. It changes only the viewport, using
/// continuous point offsets; actual gesture routing is covered by the UI lane.
private final class TerminalScrollBenchmark: NSObject {
    weak var view: TesseraResponderAwareTerminalView?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var origin: CGFloat = 0
    private var samples: [[Double]] = []

    init(view: TesseraResponderAwareTerminalView) {
        self.view = view
        super.init()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.begin() }
    }

    private func begin() {
        guard let view else { return }
        view.cachesCoreGraphicsRows = ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK_UNCACHED"] != "1"
        if let raw = ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK_FONT"], let size = Double(raw) {
            view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if ProcessInfo.processInfo.environment["TESSERA_SCROLL_BENCHMARK_METAL"] == "1" {
            try? view.setUseMetal(true)
        }
        _ = view.resignFirstResponder()
        var text = "\u{1B}[0m\u{1B}[2J\u{1B}[3J\u{1B}[H\u{1B}[?25l"
        for row in 0..<1500 {
            text += row % 12 < 6 ? "\u{1B}[48;5;22m" : "\u{1B}[48;5;52m"
            text += String(format: "%04d | ", row) + String(repeating: "0123456789abcdef", count: 9) + "\u{1B}[K\r\n"
        }
        view.feed(text: text)
        origin = max(0, view.contentSize.height - view.bounds.height - 4000)
        view.contentOffset.y = origin
        view.scrollBenchmarkRecording = true
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        NSLog("[Tessera][ScrollBenchmark] stage=ready metal=%@", String(view.isUsingMetalRenderer))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); self.link = nil; return }
        if start == 0 { start = link.timestamp }
        let elapsed = link.timestamp - start
        if elapsed >= 12 {
            link.invalidate()
            self.link = nil
            view.scrollBenchmarkRecording = false
            let result: [String: Any] = ["samples": samples, "drawMilliseconds": view.scrollBenchmarkDrawMilliseconds,
                                       "metal": view.isUsingMetalRenderer, "width": view.bounds.width, "height": view.bounds.height]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("scroll-benchmark.json")
                try? data.write(to: url)
            }
            NSLog("[Tessera][ScrollBenchmark] stage=done")
            return
        }
        // Idle, slow drag, fast glide, reversal, settle. Absolute time makes
        // before/after recordings comparable even when a display frame stalls.
        let movement: Double
        switch elapsed {
        case ..<2: movement = 0
        case ..<5: movement = (elapsed - 2) * 180
        case ..<8: movement = 540 + 1500 * (1 - exp(-(elapsed - 5) * 2))
        case ..<10: movement = 2036.28 - (elapsed - 8) * 650
        default: movement = 736.28
        }
        view.contentOffset.y = origin - movement
        samples.append([elapsed, Double(view.contentOffset.y)])
    }
}

/// Mutates only the existing UIKit accessibility value, so scroll assertions
/// do not trigger a SwiftUI render pass (or XCTest's quiescence heuristics).
private final class TerminalScrollHarnessOracle {
    var benchmark: TerminalScrollBenchmark?
    weak var terminalView: UIScrollView?
    var previewColumns = 0
    var previewRows = 0
    var previewNeedsFullPaint = true
    private var agentScrollWasBlocked = false

    func noteAgentScrollBlocked() {
        agentScrollWasBlocked = true
        update()
    }

    func update() {
        guard let view = terminalView else { return }
        let maxOffset = max(0, view.contentSize.height - view.bounds.height)
        let state: String
        if maxOffset <= 1 {
            state = "no-history"
        } else {
            state = view.contentOffset.y < maxOffset - 2 ? "history" : "bottom"
        }
        let projectedState = agentScrollWasBlocked ? "agent-blocked-\(state)" : state
        guard view.accessibilityValue != projectedState else { return }
        view.accessibilityValue = projectedState
    }
}

/// Idempotent dev-state seeder: ensures a `StoredKey` for the
/// `tessera-dev-key.raw` seed file exists, an `Identity` wraps it,
/// and the three demo hosts (Local Mac, Remote test 1, Remote test 2)
/// are present. Safe to run on every launch — only adds missing rows.
///
/// Seeds into the shared production container so the dev state lands in the same
/// migration-planned store the live app reads from.
private func seedDevStateIfNeeded(into container: ModelContainer) {
    let docsURL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    ).first!
    let seedURL = docsURL.appendingPathComponent("tessera-dev-key.raw")

    protectLegacyDevSeedWhileMigrating(at: seedURL)

    guard var seedData = try? Data(contentsOf: seedURL), seedData.count == 32 else {
        DiagnosticLogStore.appendApp("dev-seed skipped reason=missing-or-invalid")
        return
    }
    defer {
        seedData.resetBytes(in: seedData.startIndex..<seedData.endIndex)
        seedData.removeAll(keepingCapacity: false)
    }

    let pubLine: String
    do {
        let seedKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
        pubLine = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: seedKey.publicKey,
            comment: "tessera-simulator-dev@example.local"
        )
    } catch {
        DiagnosticLogStore.appendApp("dev-seed skipped reason=missing-or-invalid")
        return
    }

    do {
        let context = ModelContext(container)

        // 1. StoredKey row for the dev key.
        let existingKeys = try context.fetch(FetchDescriptor<StoredKey>())
        let storedKey: StoredKey
        if let existing = existingKeys.first(where: { $0.authorizedKeysLine == pubLine }) {
            storedKey = existing
        } else {
            let newKey = StoredKey(
                name: "Dev Key",
                algorithm: .ed25519,
                authorizedKeysLine: pubLine,
                createdAt: Date()
            )
            context.insert(newKey)
            storedKey = newKey
        }

        // Store (or update) and read back the seed before committing metadata.
        // The source file remains in place on every failure path.
        guard mirrorSeedToKeychainAndVerify(seed: seedData, keyID: storedKey.id) else {
            context.rollback()
            DiagnosticLogStore.appendApp("dev-seed failed step=keychain-verify")
            return
        }

        // 2. Identity wrapping that StoredKey.
        let identities = try context.fetch(FetchDescriptor<Identity>())
        let identity: Identity
        if let existing = identities.first(where: { id in
            if case .key(let k) = id.credentialMode, k == storedKey.id { return true }
            return false
        }) {
            identity = existing
            if identity.user.isEmpty { identity.user = "user" }
            if identity.name.isEmpty { identity.name = "Dev Key" }
        } else {
            let newID = Identity(
                name: "Dev Key",
                user: "user",
                credentialMode: .key(storedKey.id)
            )
            context.insert(newID)
            identity = newID
        }

        // 3. Migrate any legacy `.legacyDevKey` identities forward — repoint
        //    their hosts at the new StoredKey-backed identity, then delete.
        let legacyIdentities = identities.filter {
            if case .legacyDevKey = $0.credentialMode { return true }
            return false
        }
        for legacy in legacyIdentities {
            for host in legacy.hosts {
                host.identity = identity
            }
            context.delete(legacy)
        }

        // 4. Demo hosts.
        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())

        if !hosts.contains(where: { $0.name == "Local Mac" }) {
            let h = PersistedHost(
                name: "Local Mac",
                address: "127.0.0.1",
                port: 22,
                autoTmux: true,
                transport: .ssh,
                launchMode: .autoTmux,
                sortOrder: 1,
                identity: identity
            )
            h.user = "user"
            context.insert(h)
        }

        if !hosts.contains(where: { $0.name == "Remote test 1" }) {
            let h = PersistedHost(
                name: "Remote test 1",
                address: "192.0.2.10",
                port: 22,
                autoTmux: true,
                transport: .ssh,
                launchMode: .autoTmux,
                sortOrder: 2,
                identity: nil
            )
            h.user = "testuser"
            context.insert(h)
        }

        if !hosts.contains(where: { $0.name == "Remote test 2" }) {
            let h = PersistedHost(
                name: "Remote test 2",
                address: "192.0.2.20",
                port: 22,
                autoTmux: true,
                transport: .mosh,
                launchMode: .autoTmux,
                sortOrder: 3,
                identity: identity
            )
            h.user = "user"
            context.insert(h)
        }

        try context.save()

        guard DevRawKeyMigrationVerification.mayRemoveSource(
            keychainVerified: true,
            modelSaveSucceeded: true
        ) else { return }
        do {
            try FileManager.default.removeItem(at: seedURL)
            DiagnosticLogStore.appendApp("dev-seed migration completed sourceRemoved=true")
        } catch {
            DiagnosticLogStore.appendApp("dev-seed migration source-remove failed")
        }
    } catch {
        DiagnosticLogStore.appendApp("dev-seed failed error='\(error)'")
    }
}

enum DevRawKeyMigrationVerification {
    static func storedSeedMatches(_ storedSeed: Data?, expectedSeed: Data) -> Bool {
        guard let storedSeed, storedSeed.count == expectedSeed.count else { return false }
        var difference: UInt8 = 0
        for index in storedSeed.indices {
            difference |= storedSeed[index] ^ expectedSeed[index]
        }
        return difference == 0
    }

    static func mayRemoveSource(
        keychainVerified: Bool,
        modelSaveSucceeded: Bool
    ) -> Bool {
        keychainVerified && modelSaveSucceeded
    }
}

/// Stores the dev seed in the same Keychain slot used by `KeyStore`, then
/// verifies the exact bytes through a fresh Security-framework read. Unlike the
/// old seeder, this never deletes a working Keychain item before its replacement
/// has been accepted.
private func mirrorSeedToKeychainAndVerify(seed: Data, keyID: UUID) -> Bool {
    let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.bambouville.Tessera.sshkey",
        kSecAttrAccount as String: keyID.uuidString,
    ]

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = seed
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    var writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if writeStatus == errSecDuplicateItem {
        // DEBUG seeding owns this fixed account. Replace it without reading a
        // possibly protected legacy row so a simulator launch cannot summon a
        // raw authentication sheet.
        writeStatus = SecItemDelete(baseQuery as CFDictionary)
        if writeStatus == errSecSuccess {
            writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
    guard writeStatus == errSecSuccess else {
        DiagnosticLogStore.appendApp("dev-seed keychain-write failed status=\(writeStatus)")
        return false
    }

    var readQuery = baseQuery
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    let readContext = LAContext()
    readContext.interactionNotAllowed = true
    readQuery[kSecUseAuthenticationContext as String] = readContext
    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
    guard readStatus == errSecSuccess,
          DevRawKeyMigrationVerification.storedSeedMatches(
            result as? Data,
            expectedSeed: seed
          )
    else {
        DiagnosticLogStore.appendApp("dev-seed keychain-readback failed status=\(readStatus)")
        return false
    }
    return true
}

/// Minimize exposure while an old DEBUG seed is waiting for migration. These
/// attributes are defense in depth; migration still removes the source only
/// after Keychain verification and a successful model save.
private func protectLegacyDevSeedWhileMigrating(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedURL.setResourceValues(resourceValues)
    } catch {
        DiagnosticLogStore.appendApp("dev-seed source-protection failed")
    }
}
#endif
#if DEBUG
@MainActor
enum LiveScrollForegroundProbe {
    static let marker = "TESSERA_FOREGROUND_LIVE_PROBE"

    private static var isArmed = false
    private static var didObserveMarker = false
    private static var maxFeedBytes = 0
    private static var feedCount = 0
    private static var totalFeedBytes = 0
    private static var feedRecords: [String] = []
    private static var tail: [UInt8] = []
    private static var sendAction: (() -> Void)?
    private static var didSendAfterForeground = false

    static func arm() {
        isArmed = true
        didObserveMarker = false
        maxFeedBytes = 0
        feedCount = 0
        totalFeedBytes = 0
        feedRecords.removeAll(keepingCapacity: true)
        tail.removeAll(keepingCapacity: true)
        didSendAfterForeground = false
    }

    static func observeRenderedFeed(
        _ bytes: ArraySlice<UInt8>,
        source: TmuxController.TerminalFeedSource,
        reason: String?
    ) {
        guard isArmed else { return }
        feedCount += 1
        totalFeedBytes += bytes.count
        maxFeedBytes = max(maxFeedBytes, bytes.count)
        feedRecords.append("\(source.rawValue):\(reason ?? "none"):\(bytes.count)")
        tail.append(contentsOf: bytes)
        if tail.count > 512 {
            tail.removeFirst(tail.count - 512)
        }
        if String(decoding: tail, as: UTF8.self).contains(marker) {
            didObserveMarker = true
        }
    }

    static func registerSendAction(_ action: @escaping () -> Void) {
        sendAction = action
    }

    static func unregisterSendAction() {
        sendAction = nil
    }

    static func sendAfterForegroundIfArmed() {
        guard isArmed, !didSendAfterForeground else { return }
        didSendAfterForeground = true
        sendAction?()
    }

    static var statusValue: String? {
        guard isArmed else { return nil }
        let state = didObserveMarker ? "foreground-live" : "foreground-probe-armed"
        return "\(state)|feed-count=\(feedCount)|total-feed=\(totalFeedBytes)|feeds=\(feedRecords.joined(separator: ","))|max-feed=\(maxFeedBytes)"
    }
}
#endif

#if DEBUG
/// DEBUG-only fence for production live-scroll capture. `SessionRegistry`
/// deliberately treats a watchdog-revealed launch as presentable; visual
/// automation additionally needs the controller's actual initial render bit.
@MainActor
enum LiveScrollInitialRenderProbe {
    private static var readySessionIDs: Set<UUID> = []

    static func observe(sessionID: UUID, isReady: Bool) {
        guard ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1"
        else { return }
        set(sessionID: sessionID, isReady: isReady)
    }

    static func isReady(for sessionID: UUID) -> Bool {
        readySessionIDs.contains(sessionID)
    }

    static func clear(sessionID: UUID) {
        readySessionIDs.remove(sessionID)
    }

    private static func set(sessionID: UUID, isReady: Bool) {
        if isReady {
            readySessionIDs.insert(sessionID)
        } else {
            readySessionIDs.remove(sessionID)
        }
    }

    static func _testReset() {
        readySessionIDs.removeAll()
    }

    static func _testObserve(sessionID: UUID, isReady: Bool) {
        set(sessionID: sessionID, isReady: isReady)
    }
}
#endif

#if DEBUG
/// Host-free visual harness for the hook-proven Swipe Pad states. The state
/// is selected with `TESSERA_SWIPEPAD_STATUS_HARNESS_STATE`; no terminal or
/// provider connection is created.
struct SwipePadStatusHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(SpeechDictationController.self) private var dictation
    @Environment(SwipePadProfileStore.self) private var profileStore

    @State private var tmux = TmuxController()
    @State private var agentContext = SwipePadAgentContext()

    private static let sessionID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000006"
    )!
    private static let profileID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000007"
    )!
    private static let puckCenter = CGPoint(x: 640, y: 420)

    private var requestedStatus: AgentStatus {
        switch ProcessInfo.processInfo.environment[
            "TESSERA_SWIPEPAD_STATUS_HARNESS_STATE"
        ] {
        case "waiting": .waitingForInput
        case "working": .working
        case "idle": .idle
        default: .justFinished
        }
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "SWIPEPAD STATUS")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text(String(describing: requestedStatus))
                    .font(Typography.tesseraMono(size: 14))
                    .accessibilityIdentifier("swipepad-status-harness-state")
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            SwipePadOverlay(
                onSend: { _ in },
                tmux: tmux,
                agentContext: agentContext,
                profileStore: profileStore,
                dictationController: dictation
            )
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: configure)
    }

    private func configure() {
        appearance.swipePadEnabled = true
        appearance.swipePadLastX = Double(Self.puckCenter.x)
        appearance.swipePadLastY = Double(Self.puckCenter.y)
        let now = Date.now
        agentContext.publish(
            SwipePadAgentSnapshot(
                agentID: AgentInstanceID(
                    sessionID: Self.sessionID,
                    paneID: nil
                ),
                profileID: Self.profileID,
                profileName: "codex cli",
                status: requestedStatus,
                prompt: nil,
                statusChangedAt: now,
                detectedAt: now,
                providerSessionID: "status-harness",
                agentPID: 4242
            )
        )
    }
}
#endif

#if DEBUG
/// Host-free visual harness for the corner-fan radial. The puck home is
/// selected with `TESSERA_SWIPEPAD_FAN_CORNER` (topLeft / topRight /
/// bottomLeft / bottomRight, or `center` to confirm the cross still renders
/// mid-canvas); `TESSERA_SWIPEPAD_FAN_OPTIONS` picks the prompt size
/// (3 / 4 / 5 — 5 exercises the more petal), `working` for the
/// interrupt-only state, or `idle` for the mode-switch target. Combine with
/// TESSERA_SWIPEPAD_FORCE_RADIAL_OPEN=1
/// (and optionally TESSERA_SWIPEPAD_FORCE_ACTIVE_DIRECTION) to freeze the
/// open radial for screenshots. No terminal or provider connection is
/// created.
/// The Appearance settings page on its own, so the terminal-font picker can be
/// captured at both idioms without navigating a live app. Fonts are the reason
/// this exists: every row renders in the face it names, so a family that failed
/// to bundle, or a row whose sample overflows a compact width, is visible here
/// and nowhere else. Never reaches a release build (`#if DEBUG` at the call
/// site) and opens no connection.
struct AppearanceSettingsHarnessView: View {
    @Environment(\.designTokens) private var T

    var body: some View {
        ScrollView {
            AppearanceSettingsView()
                .padding(20)
        }
        .background(T.bg.ignoresSafeArea())
    }
}

struct SwipePadFanHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(SpeechDictationController.self) private var dictation
    @Environment(SwipePadProfileStore.self) private var profileStore

    @State private var tmux = TmuxController()
    @State private var agentContext = SwipePadAgentContext()
    @State private var lastSentBytes = "none"

    private static let sessionID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000008"
    )!
    private static let profileID = UUID(
        uuidString: "F17E0000-0000-0000-0000-000000000009"
    )!

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "SWIPEPAD FAN")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text(verbatim: "sent \(lastSentBytes)")
                    .font(Typography.tesseraMono(size: 14))
                    .accessibilityIdentifier("swipepad-fan-outcome")
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            SwipePadOverlay(
                onSend: { bytes in
                    lastSentBytes = bytes
                        .map { String(format: "%02x", $0) }
                        .joined(separator: " ")
                },
                tmux: tmux,
                agentContext: agentContext,
                onShowMore: {},
                profileStore: profileStore,
                dictationController: dictation
            )
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: configure)
    }

    private func configure() {
        appearance.swipePadEnabled = true
        let env = ProcessInfo.processInfo.environment

        let corner = env["TESSERA_SWIPEPAD_FAN_CORNER"] ?? "bottomRight"
        if corner == "center" {
            let bounds = UIScreen.main.bounds
            appearance.swipePadLastX = Double(bounds.width / 2)
            appearance.swipePadLastY = Double(bounds.height / 2)
        } else {
            appearance.swipePadCorner = corner
            appearance.swipePadLastX = -1
            appearance.swipePadLastY = -1
        }

        let now = Date.now
        if env["TESSERA_SWIPEPAD_FAN_OPTIONS"] == "working" {
            publish(status: .working, prompt: nil, at: now)
            return
        }
        if env["TESSERA_SWIPEPAD_FAN_OPTIONS"] == "idle" {
            publish(status: .idle, prompt: nil, at: now)
            return
        }
        let count = min(5, max(3, Int(env["TESSERA_SWIPEPAD_FAN_OPTIONS"] ?? "4") ?? 4))
        let labels = [
            "Yes",
            "Yes, don't ask again",
            "No, tell Claude",
            "Allow once",
            "Open editor",
        ]
        let prompt = AgentPrompt(
            signature: "fan-harness-prompt",
            summary: "Allow Bash command?",
            options: (1...count).map {
                AgentPromptOption(
                    id: $0,
                    label: labels[$0 - 1],
                    responseMacro: $0 == 3 ? "esc" : "\($0)↵",
                    isDefault: $0 == 1
                )
            }
        )
        publish(status: .waitingForInput, prompt: prompt, at: now)
    }

    private func publish(status: AgentStatus, prompt: AgentPrompt?, at now: Date) {
        agentContext.publish(
            SwipePadAgentSnapshot(
                agentID: AgentInstanceID(sessionID: Self.sessionID, paneID: nil),
                profileID: Self.profileID,
                profileName: "claude code",
                status: status,
                prompt: prompt,
                statusChangedAt: now,
                detectedAt: now,
                providerSessionID: "fan-harness",
                agentPID: 4242
            )
        )
    }
}
#endif

#if DEBUG
/// Hit-test harness for the swipe pad's expanded dictation pill — launch with
/// `SIMCTL_CHILD_TESSERA_SWIPEPAD_DICTATION_HARNESS=1 xcrun simctl launch …`.
///
/// Forces `SpeechDictationController` into `.listening` without touching the
/// microphone or speech recognizer, so the pill (waveform + timer + cancel X)
/// renders exactly as it does mid-dictation and automation can tap it. Every
/// outcome is logged so a tap's routing is unambiguous:
///   - `outcome=cancel` — the X button ran `stop(commit: false)`
///   - `outcome=commit` — the pill's tap-to-commit surface won the tap
///   - no line at all   — the tap reached neither (hit-testing hole)
struct SwipePadDictationHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(SpeechDictationController.self) private var dictation
    @Environment(SwipePadProfileStore.self) private var profileStore

    @State private var tmux = TmuxController()
    @State private var lastOutcome = "—"
    @State private var tapCount = 0
    @State private var didCommit = false

    /// Puck center, in the overlay's canvas points. Fixed so automation can
    /// compute the pill's geometry without hunting for it in a screenshot.
    private static let puckCenter = CGPoint(x: 640, y: 420)

    var body: some View {
        ZStack {
            stripes

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "SWIPEPAD DICTATION HIT TEST")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text(verbatim: "outcome: \(lastOutcome)  ·  taps: \(tapCount)")
                    .font(Typography.tesseraMono(size: 14))
                    .accessibilityIdentifier("swipepad-harness-outcome")
                Button("RESTART DICTATION") { startFakeDictation() }
                    .font(Typography.tesseraMono(size: 14, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("swipepad-harness-restart")
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            SwipePadOverlay(
                onSend: { bytes in
                    // The overlay wires `onCommit` to this, so any byte here
                    // means the pill's commit surface handled the tap.
                    didCommit = true
                    record("commit bytes=\(bytes.count)")
                },
                tmux: tmux,
                profileStore: profileStore,
                dictationController: dictation
            )
        }
        .preferredColorScheme(.dark)
        .onAppear {
            appearance.swipePadEnabled = true
            appearance.voiceDictationEnabled = true
            appearance.voiceWaveformOnPuck = true
            appearance.voiceCommitOnSilence = false
            appearance.swipePadLastX = Double(Self.puckCenter.x)
            appearance.swipePadLastY = Double(Self.puckCenter.y)
            startFakeDictation()
        }
        .onChange(of: dictation.activeState) { previous, next in
            guard previous == .listening, next == .idle else { return }
            // `stop(commit:)` reaches .idle either way, so only the absence of
            // a commit (which fires onSend first) means this was a cancel.
            guard !didCommit else { return }
            record("cancel")
        }
    }

    private func startFakeDictation() {
        dictation.activeState = .listening
        dictation.startedAt = .now
        dictation.transcript = "harness transcript"
        dictation.amplitude = 0.6
        didCommit = false
        lastOutcome = "—"
        NSLog("[Tessera][SwipePadHarness] armed state=listening")
    }

    private func record(_ outcome: String) {
        tapCount += 1
        lastOutcome = outcome
        NSLog("[Tessera][SwipePadHarness] outcome=\(outcome) tap#\(tapCount)")
    }

    private var stripes: some View {
        VStack(spacing: 0) {
            ForEach(0..<40, id: \.self) { row in
                (row.isMultiple(of: 2) ? Color(white: 0.08) : Color(white: 0.16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
    }
}
#endif

#if DEBUG
/// Host-free hardware-keyboard harness. Launch with
/// `SIMCTL_CHILD_TESSERA_HARDWARE_KEY_HARNESS=1 xcrun simctl launch ...` on a
/// simulator with "Connect Hardware Keyboard" on, then press the chord under
/// test: every byte sequence the terminal surface would put on the wire is
/// logged with `[Tessera][HWKey]` and listed on screen.
///
/// It exists because the modifier a hardware key holds is not observable from
/// a unit test — `UIKey` has no public initializer — and reproducing a
/// dropped ⇧ needs the real UIKit dispatch order, not a mock of it.
@MainActor
@Observable
final class HardwareKeyHarnessLog {
    private(set) var lines: [String] = []

    func note(_ bytes: ArraySlice<UInt8>) {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let readable = bytes.map { byte -> String in
            switch byte {
            case 0x1B: return "ESC"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return "<\(byte)>"
            }
        }.joined()
        let line = "\(hex)   \(readable)"
        NSLog("[Tessera][HWKey] \(line)")
        lines.insert(line, at: 0)
        if lines.count > 14 { lines.removeLast() }
    }
}

struct HardwareKeyHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppPhase.self) private var appPhase
    @State private var log = HardwareKeyHarnessLog()
    @State private var surfaceVisible = true
    @State private var localText = ""
    @FocusState private var localTextFocused: Bool
    @State private var terminal = HardwareKeyHarnessTerminal()
    @State private var modifierState = ModifierState()
    @State private var refreshCount = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["TESSERA_SOFTWARE_KEYBOARD_REFERENCE"] != "1" {
            TerminalSurfaceBound(
                initialData: Array(("Tessera hardware-key harness — press a chord\r\n"
                    + (ProcessInfo.processInfo.environment["TESSERA_SOFTWARE_KEYBOARD_HARNESS"] == "1"
                        ? "\u{1b}[?25l" : "")
                    + (ProcessInfo.processInfo.environment["TESSERA_HARDWARE_KEY_MOUSE"] == "1"
                        ? "\u{1b}[?1000h\u{1b}[?1006h" : "")).utf8),
                onMade: { view in
                    terminal.attach(view)
                    // Synthetic hardware keys do not attach a GCKeyboard in
                    // Simulator. Model its absent software input view explicitly.
                    if ProcessInfo.processInfo.environment["TESSERA_SOFTWARE_KEYBOARD_HARNESS"] != "1" {
                        view.inputAccessoryView = nil
                        view.inputView = UIView(frame: .zero)
                    }
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "hardware-key-harness"
                    view.accessibilityLabel = "hardware key harness"
                    DispatchQueue.main.async { _ = view.becomeFirstResponder() }
                },
                onReady: {},
                onSend: { bytes in log.note(bytes) },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                agentScrollBlockingActive: false,
                onAgentScrollBlocked: nil,
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                softwareModifierState: modifierState,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: !surfaceVisible || localTextFocused,
                onHardwareKey: nil,
                onTerminalScrolled: nil,
                scrollRetentionID: nil,
                onScrollDiagnostic: nil
            )
            .environment(\.terminalDrawingEnabled, surfaceVisible)
            .environment(\.terminalInputAllowed, { terminal.inputAllowed })
            }

            VStack {
                HStack {
                    Spacer()
                    Button(surfaceVisible ? "Hide terminal" : "Show terminal") {
                        surfaceVisible.toggle()
                    }
                    .accessibilityIdentifier("hardware-key-toggle")
                    TextField("Local input", text: $localText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($localTextFocused)
                        .accessibilityIdentifier("hardware-key-local-input")
                        .frame(width: 200)
                    Button("Focus terminal") { localTextFocused = false }
                        .accessibilityIdentifier("hardware-key-focus")
                    Button("Release focus") { terminal.releaseFocus() }
                        .accessibilityIdentifier("hardware-key-release")
                    Button("Background cleanup") { terminal.inactive.dismissTransientInteractions() }
                        .accessibilityIdentifier("hardware-key-background-cleanup")
                }
                .padding(20)
                .background(Color.gray)
                Spacer()
            }
            .padding(.top, 80)

            HardwareKeyHarnessLogView(log: log)
            if ProcessInfo.processInfo.environment["TESSERA_SOFTWARE_KEYBOARD_HARNESS"] == "1" {
                VStack {
                    HStack {
                        Button("Refresh \(refreshCount)") {
                            refreshCount += 1
                            terminal.view?.feed(text: "output \(refreshCount)\r\n$ ")
                        }
                            .accessibilityIdentifier("keyboard-refresh")
                        Button("Dismiss") { modifierState.dismissSoftwareKeyboard() }
                            .accessibilityIdentifier("keyboard-dismiss")
                        Button("Show") { modifierState.showSoftwareKeyboard() }
                            .accessibilityIdentifier("keyboard-show")
                    }
                    Text(modifierState.suppressesSoftwareKeyboardReclaim ? "dismissed" : "automatic")
                        .accessibilityIdentifier("keyboard-intent")
                }
                .padding(.top, 150)
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: appPhase.isActive) { _, isActive in
            // Mirror SessionView/MoshSessionView's production inactive edge.
            if !isActive {
                if ProcessInfo.processInfo.environment["TESSERA_HARDWARE_KEY_BLOCK_ON_WAKE"] == "1" {
                    terminal.inputAllowed = false
                }
                terminal.active.dismissTransientInteractions()
            }
        }
        .onAppear {
            // XCUITest waits for the app to go idle before returning from each
            // synthesized key press. A blinking cursor never goes idle, so
            // every `typeKey` would burn the full 60s animation timeout.
            UIView.setAnimationsEnabled(false)
            appearance.cursorBlink = false
            UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        }
        .onDisappear {
            UIView.setAnimationsEnabled(true)
        }
    }
}

@MainActor
private final class HardwareKeyHarnessTerminal {
    var inputAllowed = true
    weak var view: TerminalView?
    let active = TerminalBox(traceLabel: "keyboard-active")
    let inactive = TerminalBox(traceLabel: "keyboard-inactive")

    func releaseFocus() {
        guard let view else { return }
        _ = view.resignFirstResponder()
        // Expose the actual result without an observable-state change that
        // would make updateUIView reclaim focus and invalidate the experiment.
        view.accessibilityValue = view.isFirstResponder ? "focused" : "unfocused"
    }

    func attach(_ view: TerminalView) {
        self.view = view
        active.attach(view)
        // A real mounted background terminal in the same window, as in
        // ContentView's session stack. No host or transport is involved.
        let background = TesseraResponderAwareTerminalView(frame: .zero)
        background.setSessionDrawingEnabled(false)
        view.superview?.addSubview(background)
        inactive.attach(background)
    }
}

/// Keep diagnostic output observation outside the terminal's parent. Logging
/// a click must not trigger updateUIView and accidentally repair lost focus.
private struct HardwareKeyHarnessLogView: View {
    let log: HardwareKeyHarnessLog

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SENT BYTES (newest first)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(16)
        .allowsHitTesting(false)
        .accessibilityIdentifier("hardware-key-harness-log")
    }
}
#endif
