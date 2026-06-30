import XCTest
import TmuxControl
@testable import Tessera

final class SwipePadProfileTests: XCTestCase {
    func test_allBuiltInsCount() {
        // Claude Code + Codex CLI + fallback. Aider was retired 2026-05-16.
        XCTAssertEqual(SwipePadProfile.allBuiltIns.count, 3)
    }

    func test_claudeCodeBuiltInBindings() {
        let profile = SwipePadProfile.builtInClaudeCode

        XCTAssertEqual(profile.binding(for: .right).macro, "1↵")
        XCTAssertEqual(profile.binding(for: .left).macro, "2↵")
        XCTAssertEqual(profile.binding(for: .up).macro, "3↵")
        XCTAssertEqual(profile.binding(for: .down).isBound, false)
    }

    func test_claudeCodeMatchesSemverProcessTitle() {
        // Claude Code sets process.title = packageJson.version at runtime.
        // The smart default uses a regex to catch that pattern.
        let profile = SwipePadProfile.builtInClaudeCode
        XCTAssertTrue(profile.matchProcess.hasPrefix("regex:"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "2.1.143"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "0.1.0"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "12.34.56"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "claude"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "claude-code"))
        XCTAssertFalse(SwipePadActiveProfileResolver.matches(profile: profile, processName: "node"))
        XCTAssertFalse(SwipePadActiveProfileResolver.matches(profile: profile, processName: "2.1"))
    }

    func test_codexCLIMatchesPlatformVariants() {
        // Codex ships as a Rust binary with platform suffix; macOS truncates
        // the process name to 16 chars. The prefix regex catches all variants.
        let profile = SwipePadProfile.builtInCodexCLI
        XCTAssertTrue(profile.matchProcess.hasPrefix("regex:"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "codex"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "codex-aarch64-a"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "codex-x86_64-a"))
        XCTAssertTrue(SwipePadActiveProfileResolver.matches(profile: profile, processName: "codex-cli"))
        XCTAssertFalse(SwipePadActiveProfileResolver.matches(profile: profile, processName: "node"))
        XCTAssertFalse(SwipePadActiveProfileResolver.matches(profile: profile, processName: "bash"))
    }

    func test_codexCLIBuiltInBindings() {
        let profile = SwipePadProfile.builtInCodexCLI

        XCTAssertEqual(profile.binding(for: .right).macro, "y")
        XCTAssertEqual(profile.binding(for: .left).macro, "esc")
        XCTAssertEqual(profile.binding(for: .up).macro, "p")
        XCTAssertEqual(profile.binding(for: .down).isBound, false)
    }

    func test_fallbackIsEmptyCatchAll() {
        let profile = SwipePadProfile.fallback

        XCTAssertEqual(profile.name, "fallback")
        XCTAssertEqual(profile.matchProcess, "")
        XCTAssertEqual(profile.bindings.isEmpty, true)
        XCTAssertEqual(profile.visibleDirections.isEmpty, true)
    }

    func test_fallbackIsLastInBuiltIns() {
        XCTAssertEqual(SwipePadProfile.allBuiltIns.last?.id, SwipePadProfile.fallbackID)
    }

    func test_jsonRoundTripPreservesProfileEquality() throws {
        let profile = SwipePadProfile(
            id: UUID(),
            name: "custom",
            matchProcess: "zsh",
            bindings: [
                .left: SwipePadBinding(macro: "esc"),
                .right: SwipePadBinding(macro: "y↵")
            ],
            isBuiltIn: false
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SwipePadProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }

    func test_visibleDirectionsReturnsOnlyBoundDirections() {
        let profile = SwipePadProfile(
            id: UUID(),
            name: "custom",
            matchProcess: "zsh",
            bindings: [
                .left: SwipePadBinding(macro: "esc"),
                .right: SwipePadBinding(macro: ""),
                .up: SwipePadBinding(macro: "p")
            ],
            isBuiltIn: false
        )

        XCTAssertEqual(profile.visibleDirections, [.left, .up])
    }

    func test_plainSSHProcessProbeExtractsForegroundCodexNames() {
        let output = """
          100   1 Ss   pts/0  zsh              -zsh
          245 100 Sl+  pts/0  node             /usr/bin/node /Users/me/.codex/bin/codex-aarch64-apple-darwin
          300   1 S    pts/1  bash             bash
        """

        let names = SwipePadPlainSSHProcessProbe.processNames(from: output)

        XCTAssertEqual(names.first, "node")
        XCTAssertTrue(names.contains("codex-aarch64-apple-darwin"))
        XCTAssertFalse(names.contains("bash"))
    }

    func test_plainSSHProcessProbeExtractsForegroundClaudeWrapperName() {
        let output = """
          100   1 Ss   pts/0  zsh   -zsh
          245 100 Sl+  pts/0  node  /usr/local/bin/node /usr/local/bin/claude
        """

        let names = SwipePadPlainSSHProcessProbe.processNames(from: output)

        XCTAssertTrue(names.contains("claude"))
    }

    func test_plainSSHProcessProbeExtractsForegroundClaudeSemverTitle() {
        let output = """
          100   1 Ss   pts/0  zsh      -zsh
          245 100 Sl+  pts/0  2.1.143  2.1.143
        """

        let names = SwipePadPlainSSHProcessProbe.processNames(from: output)

        XCTAssertEqual(names, ["2.1.143"])
    }

    func test_plainSSHProcessProbeCommandCapsRemoteOutput() {
        XCTAssertLessThan(
            SwipePadPlainSSHProcessProbe.maximumExpectedOutputBytes,
            128 * 1024
        )
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("awk"))
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("tail -n 64"))
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("cut -c 1-1000"))
    }

    func test_plainSSHProcessProbeCommandScopesToCurrentSSHConnection() {
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("ps -o ppid= -p $$"))
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("awk -v root=\"$r\""))
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("pid == root"))
        XCTAssertTrue(SwipePadPlainSSHProcessProbe.command.contains("inside(pid)"))
    }

    func test_plainSSHProcessProbeCanScopeToKnownPanePID() {
        let command = SwipePadPlainSSHProcessProbe.makeCommand(rootPID: 4242)

        XCTAssertTrue(command.hasPrefix("r=4242;"))
        XCTAssertTrue(command.contains("awk -v root=\"$r\""))
        XCTAssertTrue(command.contains("inside(pid)"))
    }

    func test_tmuxProcessQueryAsksForActivePaneCommandAndPID() {
        let command = SwipePadActiveProfileResolver.tmuxProcessQuery(activePaneId: PaneId(42))

        XCTAssertEqual(command, "display-message -p -t %42 'cmd=#{pane_current_command}|pid=#{pane_pid}'")
        XCTAssertFalse(command.contains("pane_current_path"))
        XCTAssertFalse(command.contains("version"))
    }

    func test_tmuxProcessQueryFallsBackWhenPaneIsUnknown() {
        let command = SwipePadActiveProfileResolver.tmuxProcessQuery(activePaneId: nil)

        XCTAssertEqual(command, "display-message -p 'cmd=#{pane_current_command}|pid=#{pane_pid}'")
    }

    func test_tmuxProcessPayloadParsesCommandAndPanePID() {
        let parsed = SwipePadActiveProfileResolver.parseTmuxProcessPayload("cmd=node|pid=2977123")

        XCTAssertEqual(parsed.commandName, "node")
        XCTAssertEqual(parsed.panePID, 2_977_123)
    }

    func test_resolverMatchesPlainSSHProcessCandidates() {
        let resolved = SwipePadActiveProfileResolver.resolve(
            candidates: SwipePadProfile.allBuiltIns,
            fallback: .fallback,
            processNames: ["node", "codex-aarch64-a"]
        )

        XCTAssertEqual(resolved.id, SwipePadProfile.builtInCodexCLIID)
    }

    func test_resolverMatchesPlainSSHClaudeWrapperCandidate() {
        let resolved = SwipePadActiveProfileResolver.resolve(
            candidates: SwipePadProfile.allBuiltIns,
            fallback: .fallback,
            processNames: ["node", "claude"]
        )

        XCTAssertEqual(resolved.id, SwipePadProfile.builtInClaudeCodeID)
    }

    @MainActor
    func test_shellIntegrationTrackerReadsVSCodeCommandLine() {
        let tracker = SwipePadShellIntegrationTracker()
        let osc = "\u{1B}]633;E;node /Users/me/.codex/bin/codex-aarch64-apple-darwin\u{7}"

        tracker.feed(ArraySlice(Array(osc.utf8)))

        XCTAssertTrue(tracker.processNames.contains("codex-aarch64-apple-darwin"))

        tracker.feed(ArraySlice(Array("\u{1B}]633;D;0\u{7}".utf8)))

        XCTAssertEqual(tracker.processNames, [])
    }

    @MainActor
    func test_shellIntegrationTrackerReadsFinalTermCommandLineURL() {
        let tracker = SwipePadShellIntegrationTracker()
        let osc = "\u{1B}]133;C;cmdline_url=npx%20%40anthropic-ai/claude-code\u{1B}\\"

        tracker.feed(ArraySlice(Array(osc.utf8)))

        XCTAssertTrue(tracker.processNames.contains("claude-code"))
    }

    @MainActor
    func test_shellIntegrationTrackerReadsProgramUserVar() {
        let tracker = SwipePadShellIntegrationTracker()
        let command = Data("bunx @openai/codex".utf8).base64EncodedString()
        let osc = "\u{1B}]1337;SetUserVar=WEZTERM_PROG=\(command)\u{7}"

        tracker.feed(ArraySlice(Array(osc.utf8)))

        XCTAssertTrue(tracker.processNames.contains("codex"))
    }

    @MainActor
    func test_shellIntegrationTrackerHandlesSplitOSC() {
        let tracker = SwipePadShellIntegrationTracker()
        let first = Array("\u{1B}]633;E;".utf8)
        let second = Array("claude\u{7}".utf8)

        tracker.feed(ArraySlice(first))
        XCTAssertEqual(tracker.processNames, [])

        tracker.feed(ArraySlice(second))
        XCTAssertEqual(tracker.processNames, ["claude"])
    }
}
