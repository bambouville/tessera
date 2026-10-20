import XCTest
@testable import TesseraAgentCore

final class AgentIntegrationDecisionTests: XCTestCase {
    private func resolve(
        _ installation: AgentIntegrationInstallationKind,
        _ foreground: AgentIntegrationForegroundKind,
        shellActive: Bool? = false,
        agentActive: Bool = false
    ) -> AgentIntegrationDecision {
        AgentIntegrationDecisionReducer.resolve(
            .init(
                installation: installation,
                foreground: foreground,
                shellIntegrationActive: shellActive,
                agentIntegrationActive: agentActive
            )
        )
    }

    func testInstallAndUpdateActionsFollowFreshForeground() {
        XCTAssertEqual(resolve(.missing, .shell), .init(kind: .notInstalled, primaryAction: .installAndApply))
        XCTAssertEqual(resolve(.missing, .agent), .init(kind: .notInstalled, primaryAction: .installOnly))
        XCTAssertEqual(resolve(.outdated, .other), .init(kind: .outdated, primaryAction: .installOnly))
    }

    /// A newer app's installation this build cannot operate offers nothing to
    /// run, from any foreground: every action would downgrade the host.
    func testInstallationTooNewForThisAppOnlyAsksForAnAppUpdate() {
        for foreground in AgentIntegrationForegroundKind.allCases {
            for requiresHook in [nil, true, false] as [Bool?] {
                let decision = AgentIntegrationDecisionReducer.resolve(.init(
                    installation: .requiresAppUpdate,
                    foreground: foreground,
                    shellIntegrationActive: true,
                    agentIntegrationActive: true,
                    agentRequiresLifecycleHook: requiresHook
                ))
                XCTAssertEqual(decision, .init(kind: .appUpdateRequired), "\(foreground)")
                XCTAssertTrue(decision.showsWarning)
            }
        }
    }

    func testCurrentInstallationUsesExactShellAndAgentEvidence() {
        XCTAssertEqual(resolve(.current, .shell, shellActive: true).kind, .ready)
        XCTAssertEqual(resolve(.current, .shell, shellActive: false), .init(kind: .inactiveShell, primaryAction: .apply, secondaryAction: .persistAndApply))
        XCTAssertEqual(resolve(.current, .shell, shellActive: nil), .init(kind: .unavailable, primaryAction: .retry))
        XCTAssertEqual(resolve(.current, .agent, agentActive: true).kind, .ready)
        XCTAssertEqual(resolve(.current, .agent, agentActive: false).kind, .insideAgent)
        XCTAssertEqual(resolve(.current, .unsupportedShell).kind, .unsupportedShell)
        XCTAssertEqual(resolve(.current, .other).kind, .busyProgram)
    }

    func testFreshDecisionSafelyNarrowsOrWidensCapturedInstallAction() {
        let shell = resolve(.missing, .shell)
        let agent = resolve(.missing, .agent)
        let inactive = resolve(.current, .shell, shellActive: false)
        XCTAssertEqual(shell.effectiveAction(for: .installOnly), .installAndApply)
        XCTAssertEqual(agent.effectiveAction(for: .installAndApply), .installOnly)
        XCTAssertEqual(inactive.effectiveAction(for: .installAndApply), .apply)
        XCTAssertNil(resolve(.current, .other).effectiveAction(for: .installAndApply))
    }

    func testTierCForegroundAgentNeverRequestsLifecycleHookRepair() {
        let decision = AgentIntegrationDecisionReducer.resolve(.init(
            installation: .current,
            foreground: .agent,
            shellIntegrationActive: nil,
            agentIntegrationActive: false,
            agentRequiresLifecycleHook: false
        ))
        XCTAssertEqual(decision.kind, .ready)
        XCTAssertFalse(decision.showsWarning)
    }

    func testCoreDiscoveryClassifiesUnsupportedShellsAndTierCProviders() throws {
        let scope = try XCTUnwrap(AgentIntegrationProcessDiscoveryScope(rootProcessID: 42))
        func frame(_ executable: String) -> String {
            "TESSERA_AGENT_PROCESS_DISCOVERY {\"v\":1,\"kind\":\"processDiscovery\",\"processes\":[{\"pid\":42,\"ppid\":1,\"executable\":\"\(executable)\",\"foreground\":true}]}\n"
        }
        for shell in ["ash", "mksh", "pwsh"] {
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(frame(shell), scope: scope)?.foreground,
                .unsupportedShell,
                shell
            )
        }
        let opencode = try XCTUnwrap(RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(frame("opencode"), scope: scope))
        XCTAssertEqual(opencode.foreground, .agent)
        XCTAssertFalse(opencode.foregroundRequiresLifecycleHook)
        XCTAssertTrue(opencode.foregroundProviderProcessIDs.contains(42))
        XCTAssertTrue(opencode.foregroundLifecycleProviderProcessIDs.isEmpty)

        let loginShell = try XCTUnwrap(RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(frame("-zsh"), scope: scope))
        XCTAssertEqual(loginShell.foreground, .shell)
        XCTAssertEqual(loginShell.foregroundShellProcessIDs, [42])

        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(
            "TESSERA_AGENT_PROCESS_DISCOVERY {\"v\":1,\"kind\":\"processDiscovery\",\"processes\":[{\"pid\":42,\"ppid\":1,\"executable\":\"bash\",\"foreground\":false},{\"pid\":99,\"ppid\":1,\"executable\":\"codex\",\"foreground\":true}]}\n",
            scope: scope
        ))
    }

    /// Tessera's shims run the provider as a child of `/bin/sh` without job
    /// control, so a shimmed Codex pane's foreground process group is
    /// {sh, codex}. The provider must win over the wrapper shell, or every
    /// shimmed pane reads as "open bash or zsh".
    func testCoreDiscoveryRanksAProviderAboveItsWrapperShell() throws {
        let scope = try XCTUnwrap(AgentIntegrationProcessDiscoveryScope(rootProcessID: 42))
        let shimmed = try XCTUnwrap(RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(
            "TESSERA_AGENT_PROCESS_DISCOVERY {\"v\":1,\"kind\":\"processDiscovery\",\"processes\":[{\"pid\":42,\"ppid\":1,\"executable\":\"-zsh\",\"foreground\":false},{\"pid\":50,\"ppid\":42,\"executable\":\"/bin/sh\",\"foreground\":true},{\"pid\":51,\"ppid\":50,\"executable\":\"codex\",\"foreground\":true},{\"pid\":52,\"ppid\":51,\"executable\":\"node\",\"foreground\":false}]}\n",
            scope: scope
        ))
        XCTAssertEqual(shimmed.foreground, .agent)
        XCTAssertTrue(shimmed.foregroundRequiresLifecycleHook)
        XCTAssertEqual(shimmed.foregroundProviderProcessIDs, [51])
        XCTAssertEqual(shimmed.foregroundLifecycleProviderProcessIDs, [51])
        XCTAssertTrue(shimmed.foregroundShellProcessIDs.isEmpty)

        let bashWrapper = AgentIntegrationForegroundClassifier.classify(executables: ["bash", "claude"])
        XCTAssertEqual(bashWrapper.foreground, .agent)
        XCTAssertEqual(AgentIntegrationForegroundClassifier.classify(executables: ["sh"]).foreground, .unsupportedShell)
        XCTAssertEqual(AgentIntegrationForegroundClassifier.classify(executables: ["sh", "vim"]).foreground, .unsupportedShell)
    }

    func testCoreConfigParserPreservesMissingEmptyAndRejectsMalformedOrOversize() throws {
        let valid = """
        TESSERA_AGENT_CODEX_HOOKS missing
        TESSERA_AGENT_CLAUDE_SETTINGS present:e30=
        TESSERA_AGENT_KIMI_CONFIG present:
        """
        let snapshots = try XCTUnwrap(RemoteAgentLifecycleIntegrationInstaller.parseProviderConfigSnapshots(valid))
        XCTAssertEqual(snapshots.codex, .missing)
        XCTAssertEqual(snapshots.claude, .present("{}"))
        XCTAssertEqual(snapshots.kimi, .present(""))

        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseProviderConfigSnapshots("""
        TESSERA_AGENT_CODEX_HOOKS present:not-base64!
        TESSERA_AGENT_CLAUDE_SETTINGS missing
        TESSERA_AGENT_KIMI_CONFIG missing
        """))
        let oversizedPayload = String(repeating: "A", count: 1_398_104)
        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseProviderConfigSnapshots("""
        TESSERA_AGENT_CODEX_HOOKS present:\(oversizedPayload)
        TESSERA_AGENT_CLAUDE_SETTINGS missing
        TESSERA_AGENT_KIMI_CONFIG missing
        """))
    }

    func testCoreLifecycleParserOwnsKimiSchemaAndRejectsInvalidState() throws {
        func payload(state: String) -> Data {
            Data("""
            {"version":9,"provider":"kimi","event":"PermissionRequest","state":"\(state)","reason":"permission","timestampNs":"184467440","sessionId":"session-1","agentPid":42,"transcriptRef":"session_abc"}
            """.utf8)
        }
        let event = try XCTUnwrap(AgentLifecycleHookEvent.decode(payload(state: "waitingForInput")))
        XCTAssertEqual(event.providerID, .kimi)
        XCTAssertEqual(event.event, .permissionRequest)
        XCTAssertEqual(event.status, .waitingForInput)
        XCTAssertEqual(event.agentPID, 42)
        XCTAssertNil(AgentLifecycleHookEvent.decode(payload(state: "idle")))
    }

    func testRouteMarkerDiscoveryRejectsAnEmptyUnprovenFrame() throws {
        let scope = try XCTUnwrap(AgentIntegrationProcessDiscoveryScope(
            routeMarker: "01234567-89ab-cdef-0123-456789abcdef"
        ))
        XCTAssertNil(RemoteAgentLifecycleIntegrationInstaller.parseProcessDiscovery(
            "TESSERA_AGENT_PROCESS_DISCOVERY {\"v\":1,\"kind\":\"processDiscovery\",\"processes\":[]}\n",
            scope: scope
        ))
    }
}
