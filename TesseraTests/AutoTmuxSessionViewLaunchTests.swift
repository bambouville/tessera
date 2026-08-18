import XCTest
import SwiftUI
@testable import TmuxControl
@testable import Tessera

#if DEBUG
/// Mounts the **real** `SessionView` — SwiftUI wiring, agent-center probes,
/// launch overlay and all — against a live fixture host, so the auto-tmux
/// launch is exercised through the same code path the shipping app uses
/// rather than through a hand-rolled transport rig.
@MainActor
final class AutoTmuxSessionViewLaunchTests: XCTestCase {
    private struct Config: Decodable {
        let stableHost: String
        let chaosHost: String
        let port: Int
        let user: String
        let password: String

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_REAL_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip("real-host fixture is opt-in")
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    /// Freshly added host: nothing cached locally, no tmux server remotely.
    func test_liveSessionViewAutoTmuxOnFreshlyAddedHost() async throws {
        let config = try Config.load()
        try await runMountedLaunch(config: config, label: "sessionview-fresh")
    }

    /// Immediately afterwards, the same host again — the state the user
    /// reports as working ("solved for that host").
    func test_liveSessionViewAutoTmuxOnRepeatConnect() async throws {
        let config = try Config.load()
        try await runMountedLaunch(config: config, label: "sessionview-repeat-1")
        try await runMountedLaunch(config: config, label: "sessionview-repeat-2")
    }

    /// A host that can never hand us control mode: its login dotfiles
    /// `exec` a plain tmux client before the launch command can run. The
    /// launch must give the user their terminal back instead of spinning
    /// on "starting tmux" forever.
    func test_liveSessionViewDegradesWhenHostNeverEntersControlMode() async throws {
        let config = try Config.load()
        try await runMountedLaunch(
            config: config,
            label: "sessionview-hostile-dotfiles",
            user: "\(config.user)-dotfile-tmux",
            expectsControlMode: false
        )
    }

    /// The long-standing "tmux is not installed" path must still degrade
    /// through the same banner after the launch-script rework.
    func test_liveSessionViewDegradesWhenTmuxIsNotInstalled() async throws {
        let config = try Config.load()
        try await runMountedLaunch(
            config: config,
            label: "sessionview-no-tmux",
            user: "\(config.user)-notmux",
            expectsControlMode: false
        )
    }

    private func runMountedLaunch(
        config: Config,
        label: String,
        user: String? = nil,
        expectsControlMode: Bool = true
    ) async throws {
        let host = Host(
            name: "SessionView \(label)",
            address: config.stableHost,
            port: config.port,
            user: user ?? config.user,
            password: config.password,
            transport: .ssh,
            autoTmux: true,
            launchMode: .autoTmux
        )
        await KnownHostsStore.shared.remove(endpoint: "\(config.stableHost):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()

        let session = SSHSession(host: host)
        let liveSessionID = UUID()

        let appearance = AppearancePreferences()
        let appPhase = AppPhase()
        let sessionRegistry = SessionRegistry()
        let view = SessionView(
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
            onOpenSettings: {}
        )
        .environment(appearance)
        .environment(AppLockController(appearance: appearance))
        .environment(BellController(appearance: appearance, appPhase: appPhase))
        .environment(TunnelsRegistry())
        .environment(SwipePadProfileStore())
        .environment(SpeechDictationController(appearance: appearance))
        .environment(sessionRegistry)
        .environment(CommandPalette())
        .environment(AgentCenter())
        .environment(appPhase)
        .environment(FileBridgeRegistry())
        .environment(HostTerminalBackgroundStore())
        .environment(ShortcutStore())

        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }

        // Accept the first-connect host-key prompt the way ContentView does.
        let acceptor = Task { @MainActor in
            for _ in 0..<600 {
                if let pending = session.pendingHostKeyVerification, !pending.isResolved {
                    pending.accept()
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { acceptor.cancel() }

        // The overlay dropping is the user-visible contract: either tmux
        // took over, or the launch degraded to the plain shell. Both must
        // happen inside the watchdog window; neither may hang.
        let started = Date()
        let deadline = started.addingTimeInterval(expectsControlMode ? 30 : 45)
        while Date() < deadline {
            if sessionRegistry.isRenderReady(liveSessionID) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let ready = sessionRegistry.isRenderReady(liveSessionID)
        let elapsed = Date().timeIntervalSince(started)
        let report = "[\(label)] renderReady=\(ready) after=\(String(format: "%.1f", elapsed))s "
            + "state=\(session.state) launchMode=\(session.host.launchMode.rawValue)"
        print(report)
        XCTAssertTrue(ready, "launch overlay never cleared — \(report)")
        if !expectsControlMode {
            XCTAssertEqual(
                session.state,
                .connected,
                "degrading must keep the shell session alive — \(report)"
            )
        }
    }
}
#endif
