import SwiftUI
import SwiftData
import Crypto
import Security
import LocalAuthentication
import MoshBridge
import PortForwarding
import TmuxControl
#if DEBUG
import class SwiftTerm.TerminalView
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
/// password credential) and injects a matching descriptor so the exact
/// production fast path — resolve, connect, launch, render-ready, overlay
/// dismissal — runs against a disposable integration fixture.
struct ContinuityLiveHarnessConfiguration: Codable {
    static let hostID = UUID(uuidString: "7C5DE2BE-2F62-4ED7-8C41-8A66498A9FEE")!

    var name: String
    var user: String
    var address: String
    var port: Int
    var password: String
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
    @State private var dictationController: SpeechDictationController
    @State private var hostBackgrounds: HostTerminalBackgroundStore
    @State private var activityBroadcaster: ActivityBroadcaster
    @State private var continuationCoordinator: ContinuationCoordinator
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
            if let bootstrapNetworkHarness {
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
                dictationController: dictationController,
                hostBackgrounds: hostBackgrounds,
                activityBroadcaster: activityBroadcaster,
                continuationCoordinator: continuationCoordinator,
                bootstrapCoordinator: bootstrapCoordinator,
                enrollmentCoordinator: enrollmentCoordinator,
                hostAccessStore: hostAccessStore,
                isInitialColdLaunch: $isInitialColdLaunch
            )
            .onChange(of: scenePhase) { _, newPhase in
                appLockController.handleScenePhaseChange(newPhase)
                let isActive = (newPhase == .active)
                appPhase.update(newPhase)
                if newPhase == .active {
                    hostAccessStore.applicationDidBecomeActive()
                }
                if newPhase == .background {
                    bootstrapCoordinator.stopForBackground()
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
        _dictationController = State(initialValue: SpeechDictationController(appearance: appearance))
        _hostBackgrounds = State(initialValue: HostTerminalBackgroundStore())
        _activityBroadcaster = State(initialValue: ActivityBroadcaster())
        _continuationCoordinator = State(initialValue: ContinuationCoordinator())
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
    @Bindable var dictationController: SpeechDictationController
    @Bindable var hostBackgrounds: HostTerminalBackgroundStore
    @Bindable var activityBroadcaster: ActivityBroadcaster
    @Bindable var continuationCoordinator: ContinuationCoordinator
    @Bindable var bootstrapCoordinator: BootstrapCoordinator
    @Bindable var enrollmentCoordinator: EnrollmentCoordinator
    @Bindable var hostAccessStore: HostAccessStore
    @Binding var isInitialColdLaunch: Bool
    @State private var didInjectContinuityHarness = false

    var body: some View {
        ZStack {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_COMPACT_NAVIGATION_HARNESS"] == "1" {
                CompactNavigationTransitionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_IPHONE_KEYBOARD_HARNESS"] == "1" {
                IPhoneKeyboardHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_ACCESSORY_EDITOR_HARNESS"] == "1" {
                AccessoryEditorHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_IPHONE_SESSION_HARNESS"] == "1" {
                IPhoneCompanionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_EMPTY_CAPTURE_HARNESS"] == "1" {
                TmuxEmptyCaptureHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_NETWORK_PATH_WARNING_HARNESS"] == "1" {
                NetworkPathWarningHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TERMINAL_CANVAS_HARNESS"] == "1" {
                TerminalCanvasHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_HARNESS"] == "1" {
                AgentCenterHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_HOOK_HELP_HARNESS"] == "1" {
                AgentLifecycleIntegrationHelpView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_HOOK_SOURCE_HARNESS"] == "1" {
                AgentLifecycleIntegrationHelpView(initiallyShowsSource: true)
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_INTEGRATION_WARNING_HARNESS"] == "1" {
                AgentIntegrationWarningHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] == "1" {
                TmuxWindowCloseHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] == "1" {
                TmuxWindowListHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_HARNESS"] == "1" {
                AgentAttentionHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_NOTIFICATION_HARNESS"] == "1" {
                AgentNotificationDeliveryHarnessView()
            } else if ProcessInfo.processInfo.environment["TESSERA_AGENT_PALETTE_HARNESS"] == "1" {
                AgentPaletteHarnessView()
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
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .environment(appearance)
        .environment(appLockController)
        .environment(onboardingController)
        .environment(appPhase)
        .environment(bellController)
        .environment(tunnelsRegistry)
        .environment(swipePadStore)
        .environment(dictationController)
        .environment(hostBackgrounds)
        .environment(activityBroadcaster)
        .environment(continuationCoordinator)
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
            Task { @MainActor in
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
        ContentView()
            .allowsHitTesting(!appLockController.isLocked)

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
                Text("SWIPEPAD OVERFLOW HIT TEST")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text("more \(moreOpenCount) · sent \(lastSentBytes)")
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
        controller.sendBytes = { _ in }

        // Enter -CC and drain the normal inline attach-init FIFO.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Self.responseFrame(1, flags: 0))
        for number in 2...8 {
            controller.ingest(Self.responseFrame(number))
        }
        controller.updateClientSize(cols: cols, rows: rows)
        controller.ingest(Self.responseFrame(9))

        // Latch a complete, already-rendered first window without a network.
        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(Self.responseFrame(50, body: ["one"]))
        controller.ingest(Array("%output %31 \(Self.seedRefreshText)\r\n".utf8))

        // Switch to @2, resolve valid metadata, then reproduce the diagnostic
        // log's impossible successful capture with zero body rows.
        controller.ingest(Array("%window-add @2\r\n".utf8))
        controller.ingest(Self.responseFrame(51, body: ["two"]))
        controller.ingest(Array("%window-pane-changed @2 %32\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        controller.ingest(Self.responseFrame(52, body: [
            "%32\t2\t10\tsecond pane\ttwo\thost\t0",
        ]))
        controller.ingest(Self.responseFrame(53))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            probe.preserved = controller.renderedWindowId == nil
                && controller.renderedPaneId == nil
                && probe.feedCount == 1
                && probe.swapCount == 0
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
            controller.ingest(Self.responseFrame(54, body: [
                "%32\t2\t10\tsecond pane\ttwo\thost\t0",
            ]))
            controller.ingest(Self.responseFrame(
                55,
                body: Self.recoveredLines(cols: cols, rows: rows)
            ))
            let recovered = controller.renderedWindowId == WindowId(2)
                && controller.renderedPaneId == PaneId(32)
                && probe.feedCount == 2
                && probe.swapCount == 1
            NSLog(
                "%@",
                "[Tessera][TmuxEmptyCaptureHarness] verdict=\(recovered ? "recovered" : "failed") token=\(runToken) window=\(controller.renderedWindowId?.description ?? "nil") pane=\(controller.renderedPaneId?.description ?? "nil") feedCount=\(probe.feedCount) swapCount=\(probe.swapCount) cols=\(cols) rows=\(rows)"
            )
        }
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

/// Visual regression harness for the terminal canvas bleed. Launch with
/// `SIMCTL_CHILD_TESSERA_TERMINAL_CANVAS_HARNESS=1 xcrun simctl launch ...`.
/// It mirrors the production canvas inset without opening a transport.
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

/// Presentation harness for the floating Files card — launch with
/// `SIMCTL_CHILD_TESSERA_FILES_HARNESS=1 xcrun simctl launch …`. Renders a
/// high-contrast striped fake "terminal" behind the card so backdrop-loss
/// bugs (context menu turning the glass transparent) are unmistakable in
/// simctl screenshots. No SSH — the panel runs on `MockFileBridge`.
struct FilesPanelHarnessView: View {
    @State private var controller: FilesPanelController

    private var usesLightAppearance: Bool {
        ProcessInfo.processInfo.environment["TESSERA_FILES_HARNESS_LIGHT"] == "1"
    }

    private var harnessTokens: DesignTokens {
        DesignTokens.make(
            mode: usesLightAppearance ? .light : .dark,
            accent: .blue
        )
    }

    init() {
        let controller = FilesPanelController()
        controller.attach(bridge: MockFileBridge())
        controller.open()
        controller.terminalReportedDirectory("/home/mock/projects/dashboard")
        _controller = State(initialValue: controller)
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

            // The harness renders the panel unconditionally (the glass
            // captures need it on screen), so `close()` is otherwise
            // invisible. Surface the state for hit-test probes.
            Text("isOpen: \(controller.isOpen ? "true" : "false")")
                .font(Typography.tesseraMonoFixed(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, usesLightAppearance ? .light : .dark)
        .preferredColorScheme(usesLightAppearance ? .light : .dark)
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
            Text("hosts")
                .font(Typography.tesseraMonoFixed(size: 22, weight: .bold))
                .foregroundStyle(T.fg)
            ForEach(0..<max(scenario.seededHostCount, 1), id: \.self) { index in
                Text("harness host \(index + 1)  192.0.2.\(index + 1)")
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
    @State private var agentCenter = AgentCenter()
    @State private var fileBridges = FileBridgeRegistry()
    @State private var liveSessionID = UUID()

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
            .environment(agentCenter)
            .environment(fileBridges)
            .onAppear {
                // Vim's blinking terminal cursor is a repeating UIView
                // animation. XCUITest otherwise waits two 60-second
                // quiescence timeouts around every real scroll gesture.
                UIView.setAnimationsEnabled(false)
                appearance.cursorBlink = false
                appearance.smoothScrollingEnabled = false
            }
            .onDisappear {
                UIView.setAnimationsEnabled(true)
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
            Text("LIVE SCROLL HARNESS CONFIGURATION ERROR")
                .font(Typography.tesseraMonoFixed(size: 18, weight: .bold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .accessibilityIdentifier("live-scroll-configuration-error")
        }
    }

}

private struct SSHLiveScrollVisualHarness: View {
    @StateObject private var session: SSHSession
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
        .task { await acceptHostKeys() }
        .onDisappear { session.disconnect() }
    }

    private var statusProbe: some View {
        LiveScrollStatusProbe(
            label: configuration.mode.label,
            isReady: sessionRegistry.isRenderReady(liveSessionID),
            state: session.state
        )
    }

    private func acceptHostKeys() async {
        var didResignFirstResponder = false
        while !Task.isCancelled {
            session.pendingHostKeyVerification?.accept()
            if sessionRegistry.isRenderReady(liveSessionID) {
                LiveScrollTerminalExposure.refresh()
                if UIDevice.current.userInterfaceIdiom != .phone,
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
        .task { await acceptHostKeys() }
        .onDisappear { session.disconnect() }
    }

    private var statusProbe: some View {
        LiveScrollStatusProbe(
            label: configuration.mode.label,
            isReady: sessionRegistry.isRenderReady(liveSessionID),
            state: session.state
        )
    }

    private func acceptHostKeys() async {
        var didResignFirstResponder = false
        while !Task.isCancelled {
            session.pendingHostKeyVerification?.accept()
            if sessionRegistry.isRenderReady(liveSessionID) {
                LiveScrollTerminalExposure.refresh()
                if UIDevice.current.userInterfaceIdiom != .phone,
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

        // UIKit subviews are back-to-front. On equal-size mosh surfaces the
        // later terminal is the revealed capture-pane overlay and therefore
        // the gesture target; otherwise choose the largest production surface.
        var chosen = terminals[0]
        for terminal in terminals.dropFirst() {
            let candidateArea = terminal.bounds.width * terminal.bounds.height
            let chosenArea = chosen.bounds.width * chosen.bounds.height
            if candidateArea >= chosenArea { chosen = terminal }
        }
        for terminal in terminals {
            terminal.isAccessibilityElement = terminal === chosen
            terminal.accessibilityIdentifier = terminal === chosen
                ? "live-scroll-terminal"
                : nil
        }
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
    @State private var foregroundProbeValue: String?

    var body: some View {
        Text("scroll")
            .font(.system(size: 1))
            .foregroundStyle(Color.white.opacity(0.01))
            .frame(width: 2, height: 2)
            .accessibilityIdentifier("live-scroll-status")
            .accessibilityLabel(label)
            .accessibilityValue(foregroundProbeValue ?? (isReady ? "ready" : stateDescription))
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    #if DEBUG
                    foregroundProbeValue = LiveScrollForegroundProbe.statusValue
                    #endif
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
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

    var host: Host {
        Host(
            name: "SCROLL \(mode.label)",
            address: address,
            port: port,
            user: user,
            password: password,
            transport: mode.transport,
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
                initialData: Self.fixtureBytes,
                onMade: { view in
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "terminal-scroll-harness"
                    view.accessibilityLabel = "terminal scroll harness"
                    oracle.terminalView = view
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        oracle.update()
                    }
                },
                onReady: {},
                onSend: { _ in },
                onResize: { _, _ in },
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
                suppressFirstResponderReclaim: false,
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
            // The harness has no visual-animation assertion. Cursor blinking
            // and inertial glide only keep XCUITest's quiescence detector
            // occupied, so turn them off inside this DEBUG/env-only surface.
            UIView.setAnimationsEnabled(false)
            appearance.cursorBlink = false
            appearance.smoothScrollingEnabled = false
        }
        .onDisappear {
            UIView.setAnimationsEnabled(true)
        }
    }

    private static let fixtureBytes: [UInt8] = {
        var text = ""
        for row in 1...500 {
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

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurfaceBound(
                initialData: Self.fixtureBytes,
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

    func markReady() {
        terminalView?.accessibilityValue = "ready"
    }

    func noteAgentScrollBlocked() {
        terminalView?.accessibilityValue = "agent-scroll-blocked"
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

/// Mutates only the existing UIKit accessibility value, so scroll assertions
/// do not trigger a SwiftUI render pass (or XCTest's quiescence heuristics).
private final class TerminalScrollHarnessOracle {
    weak var terminalView: UIScrollView?
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
    private static var tail: [UInt8] = []
    private static var sendAction: (() -> Void)?
    private static var didSendAfterForeground = false

    static func arm() {
        isArmed = true
        didObserveMarker = false
        maxFeedBytes = 0
        feedCount = 0
        totalFeedBytes = 0
        tail.removeAll(keepingCapacity: true)
        didSendAfterForeground = false
    }

    static func observeRenderedFeed(_ bytes: ArraySlice<UInt8>) {
        guard isArmed else { return }
        feedCount += 1
        totalFeedBytes += bytes.count
        maxFeedBytes = max(maxFeedBytes, bytes.count)
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
        return "\(state)|feed-count=\(feedCount)|total-feed=\(totalFeedBytes)|max-feed=\(maxFeedBytes)"
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
                Text("SWIPEPAD STATUS")
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
                Text("SWIPEPAD FAN")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text("sent \(lastSentBytes)")
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
                Text("SWIPEPAD DICTATION HIT TEST")
                    .font(Typography.tesseraMono(size: 16, weight: .bold))
                Text("outcome: \(lastOutcome)  ·  taps: \(tapCount)")
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
