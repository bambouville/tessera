import SwiftUI
import SwiftData
import Crypto
import Security
import MoshBridge
import PortForwarding
import TmuxControl

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
    @State private var isInitialColdLaunch: Bool

    /// The single on-disk SwiftData container, wired to `TesseraMigrationPlan`.
    /// Built once in `init` so the DEBUG seeder and the live scene share one
    /// model list + migration plan (no second container over the same store).
    private let modelContainer: ModelContainer

    var body: some Scene {
        WindowGroup {
            RootView(
                appearance: appearance,
                appLockController: appLockController,
                onboardingController: onboardingController,
                appPhase: appPhase,
                bellController: bellController,
                tunnelsRegistry: tunnelsRegistry,
                swipePadStore: swipePadStore,
                dictationController: dictationController,
                isInitialColdLaunch: $isInitialColdLaunch
            )
            .onChange(of: scenePhase) { _, newPhase in
                appLockController.handleScenePhaseChange(newPhase)
                let isActive = (newPhase == .active)
                appPhase.isActive = isActive

                let phase = describe(newPhase)
                DiagnosticLogStore.appendApp("scene-phase phase=\(phase) forwardingRunning=\(tunnelsRegistry.globalRunningCount)")
                ForwardingBackgroundKeepAlive.shared.update(
                    isActive: isActive,
                    runningCount: tunnelsRegistry.globalRunningCount,
                    reason: "scenePhase=\(phase)"
                )
            }
        }
        .modelContainer(modelContainer)
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
        _isInitialColdLaunch = State(initialValue: appearance.requireFaceIDToUnlock)

        do {
            modelContainer = try TesseraModelContainer.make()
        } catch {
            // Crash loudly rather than silently falling back to an empty store:
            // a migration failure here means the schema/plan are wrong, and we
            // want to catch that in TestFlight before it ships and resets real
            // users' hosts. (The previous `.modelContainer(for:)` modifier also
            // fatal-errored on build failure.)
            fatalError("[Tessera] Failed to build SwiftData ModelContainer: \(error)")
        }

        registerEmbeddedFonts()
        #if DEBUG
        seedDevStateIfNeeded(into: modelContainer)
        DiagnosticLogStore.appendApp(
            "moshbridge-probe probe=\(MoshBridgeProbe.probe()) primitive=\(MoshBridgeProbe.primitiveProbe()) crypto=\(MoshBridgeProbe.cryptoProbe())"
        )
        #endif
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
    @Binding var isInitialColdLaunch: Bool

    var body: some View {
        ZStack {
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
        .environment(appearance)
        .environment(appLockController)
        .environment(onboardingController)
        .environment(appPhase)
        .environment(bellController)
        .environment(tunnelsRegistry)
        .environment(swipePadStore)
        .environment(dictationController)
        .environment(\.designTokens, appearance.tokens(systemColorScheme: systemScheme))
        .preferredColorScheme(swiftUIScheme(for: appearance.mode))
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

    guard let seedData = try? Data(contentsOf: seedURL),
          seedData.count == 32,
          let seedKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
    else {
        DiagnosticLogStore.appendApp("dev-seed skipped reason=missing-or-invalid")
        return
    }

    do {
        let context = ModelContext(container)

        let pubLine = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: seedKey.publicKey,
            comment: "tessera-simulator-dev@example.local"
        )

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
            mirrorSeedToKeychain(seed: seedData, keyID: newKey.id)
            storedKey = newKey
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
    } catch {
        DiagnosticLogStore.appendApp("dev-seed failed error='\(error)'")
    }
}

/// Mirrors the dev seed bytes into the same Keychain slot
/// `KeyStore.authMethod(forKeyID:algorithm:username:)` reads from.
private func mirrorSeedToKeychain(seed: Data, keyID: UUID) {
    let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.bambouville.Tessera.sshkey",
        kSecAttrAccount as String: keyID.uuidString,
    ]
    SecItemDelete(baseQuery as CFDictionary)

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = seed
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    SecItemAdd(addQuery as CFDictionary, nil)
}
#endif
