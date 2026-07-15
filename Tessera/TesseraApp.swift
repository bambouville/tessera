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
                hostBackgrounds: hostBackgrounds,
                isInitialColdLaunch: $isInitialColdLaunch
            )
            .onChange(of: scenePhase) { _, newPhase in
                appLockController.handleScenePhaseChange(newPhase)
                let isActive = (newPhase == .active)
                appPhase.update(newPhase)

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
        reconcileStoredKeySecurity(
            into: modelContainer,
            globalOwnerPresencePreference: appearance.requireBiometricForKeyUse
        )
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
                        // An old Secure Enclave scalar cannot acquire a stronger
                        // ACL after creation. Preserve the user's ON intent so
                        // Tessera's app gate still enforces it; the UI separately
                        // reports that hardware-bound enforcement needs rotation.
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
                        if reconciledPreference {
                            preferenceBoundaryMismatches += 1
                        }
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
    @Binding var isInitialColdLaunch: Bool

    var body: some View {
        ZStack {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_TERMINAL_CANVAS_HARNESS"] == "1" {
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
            } else if ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1" {
                LiveScrollVisualHarnessView()
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
        .environment(\.designTokens, appearance.tokens(systemColorScheme: systemScheme))
        .preferredColorScheme(swiftUIScheme(for: appearance.mode))
        .task { prewarmTerminalBackgrounds() }
        .onChange(of: appearance.requireFaceIDToUnlock) { _, _ in
            appLockController.reconcileRequirement(enforceNewlyEnabled: true)
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
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
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
                T: DesignTokens.make(mode: .dark, accent: .blue)
            )
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
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
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
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
                .font(.system(size: 18, weight: .bold, design: .monospaced))
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
                if !didResignFirstResponder {
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
                if !didResignFirstResponder {
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
    private let oracle = TerminalScrollHarnessOracle()

    var body: some View {
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
}

/// Mutates only the existing UIKit accessibility value, so scroll assertions
/// do not trigger a SwiftUI render pass (or XCTest's quiescence heuristics).
private final class TerminalScrollHarnessOracle {
    weak var terminalView: UIScrollView?

    func update() {
        guard let view = terminalView else { return }
        let maxOffset = max(0, view.contentSize.height - view.bounds.height)
        let state: String
        if maxOffset <= 1 {
            state = "no-history"
        } else {
            state = view.contentOffset.y < maxOffset - 2 ? "history" : "bottom"
        }
        guard view.accessibilityValue != state else { return }
        view.accessibilityValue = state
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
