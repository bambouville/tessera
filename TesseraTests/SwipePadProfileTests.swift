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

        // Menu is 1=Yes / 2=Yes-always / 3=No: deny sends 3, always sends 2.
        // (Corrected 2026-08 — the old left=2↵ made "deny" grant sticky
        // consent after Claude reordered its menu. The drift test in
        // SwipePadPetalLayoutTests pins these against the parser fixture.)
        XCTAssertEqual(profile.binding(for: .right).macro, "1↵")
        XCTAssertEqual(profile.binding(for: .left).macro, "3↵")
        XCTAssertEqual(profile.binding(for: .up).macro, "2↵")
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

    func test_agentRulesParseLiveClaudeApprovalMenu() {
        let viewport = """
        ⏺ Bash(touch created-by-probe)
          ⎿  Waiting…

        Bash command

           touch created-by-probe
           Create empty file created-by-probe

        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and always allow access to claude/ from this project
          3. No

        Esc to cancel · Tab to amend · ctrl+e to explain
        """

        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInClaudeCode
        )

        XCTAssertEqual(parsed.prompt?.summary, "Do you want to proceed?")
        XCTAssertEqual(parsed.prompt?.options.map(\.label), [
            "Yes",
            "Yes, and always allow access to claude/ from this project",
            "No",
        ])
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1↵", "2↵", "3↵"])
        XCTAssertEqual(parsed.prompt?.options.first?.isDefault, true)
    }

    func test_agentRulesParseLiveCodexApprovalShortcuts() {
        let viewport = """
        • Running touch created-by-probe

        Would you like to run the following command?

        Environment: local

        $ touch created-by-probe

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `touch created-by-probe` (p)
          3. No, and tell Codex what to do differently (esc)

        Press enter to confirm or esc to cancel
        """

        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI
        )

        XCTAssertEqual(parsed.prompt?.summary, "Would you like to run the following command?")
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["y", "p", "esc"])
        XCTAssertEqual(parsed.prompt?.options.map(\.label), [
            "Yes, proceed",
            "Yes, and don't ask again for commands that start with `touch created-by-probe`",
            "No, and tell Codex what to do differently",
        ])
    }

    func test_agentRulesParseCodexTrustMenuWithoutShortcuts() {
        let viewport = """
        You are in /tmp/probe

        Do you trust the contents of this directory? Working with untrusted contents comes with higher risk.

        › 1. Yes, continue
          2. No, quit

        Press enter to continue
        """

        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI
        )

        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1↵", "2↵"])
    }

    func test_agentRulesParseLiveCodexPlanApprovalMenu() {
        let viewport = """
        1. Yes, implement this plan          Switch to Default and start coding.
        2. Yes, clear context and implement  Fresh thread. Context: 61% used.
        3. No, stay in Plan mode              Continue planning with the model.

        Press enter to confirm or esc to go back
        """

        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI,
            currentInputLine: "Press enter to confirm or esc to go back"
        )

        XCTAssertTrue(parsed.blockingPromptDetected)
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1↵", "2↵", "3↵"])
        XCTAssertTrue(parsed.prompt?.options.first?.label.hasPrefix("Yes, implement this plan") == true)
    }

    func test_agentRulesParseLiveCodexRateLimitModelSwitchMenu() {
        let viewport = """
        Approaching rate limits
        Switch to gpt-5.4-mini for lower credit usage?

        › 1. Switch to gpt-5.4-mini  Small, fast, and cost-efficient.
          2. Keep current model
          3. Keep current model (never show again)  Hide future reminders.

        Press enter to confirm or esc to go back
        """

        let parsed = AgentPromptParser.parse(
            visibleText: viewport,
            profile: .builtInCodexCLI,
            currentInputLine: ""
        )

        XCTAssertTrue(parsed.blockingPromptDetected)
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1↵", "2↵", "3↵"])
        XCTAssertEqual(parsed.prompt?.summary, "Approaching rate limits")
    }

    func test_agentRulesRecognizeIdlePromptsButNotWorkingText() {
        let claude = AgentPromptParser.parse(
            visibleText: "Done. Tests pass.\n\n❯ ",
            profile: .builtInClaudeCode
        )
        let codex = AgentPromptParser.parse(
            visibleText: "Tip: use /fork.\n\n› Write tests for @filename",
            profile: .builtInCodexCLI
        )
        let working = AgentPromptParser.parse(
            visibleText: "✽ Gallivanting… (6s · 92 tokens)",
            profile: .builtInClaudeCode
        )

        XCTAssertTrue(claude.isIdlePrompt)
        XCTAssertTrue(codex.isIdlePrompt)
        XCTAssertFalse(working.isIdlePrompt)
        XCTAssertNil(working.prompt)
    }

    func test_agentRulesRecognizeCurrentFreeformComposerRows() {
        let claude = AgentPromptParser.parse(
            visibleText: """
            ─────────────────────────────────────────
            › open it in the browser
            ─────────────────────────────────────────
            ctx:46%  Fable 5  eff:xhigh
            """,
            profile: .builtInClaudeCode
        )
        let codex = AgentPromptParser.parse(
            visibleText: """
            › Implement {feature}

            gpt-5.6-terra high · ~/projects/learn · Context 3% used
            """,
            profile: .builtInCodexCLI
        )

        XCTAssertTrue(claude.isIdlePrompt)
        XCTAssertTrue(codex.isIdlePrompt)
        XCTAssertFalse(claude.blockingPromptDetected)
        XCTAssertFalse(codex.blockingPromptDetected)
    }

    func test_freeformComposerRuleDoesNotConsumeNumberedApprovalOption() {
        let claude = AgentPromptParser.parse(
            visibleText: """
            Do you want to proceed?
            › 1. Yes
              2. No
            """,
            profile: .builtInClaudeCode
        )

        XCTAssertNotNil(claude.prompt)
        XCTAssertTrue(claude.blockingPromptDetected)
        XCTAssertFalse(claude.isIdlePrompt)
    }

    func test_cursorRowPreventsOldComposerFromMaskingWorkingViewport() {
        let parsed = AgentPromptParser.parse(
            visibleText: """
            › Implement {feature}

            • Running the complete regression suite…
            ✽ Working…
            """,
            profile: .builtInCodexCLI,
            currentInputLine: "✽ Working…"
        )

        XCTAssertFalse(parsed.isIdlePrompt)
        XCTAssertFalse(parsed.blockingPromptDetected)
        XCTAssertNil(parsed.prompt)
    }

    func test_cursorRowPreventsStaleApprovalFromMaskingCodexAutoClassifier() {
        let parsed = AgentPromptParser.parse(
            visibleText: """
            Would you like to run the following command?
            › 1. Yes, proceed (y)
              2. No, and tell Codex what to do differently (esc)

            • Checking command policy…
            """,
            profile: .builtInCodexCLI,
            currentInputLine: "• Checking command policy…"
        )

        XCTAssertFalse(parsed.blockingPromptDetected)
        XCTAssertNil(parsed.prompt)
        XCTAssertFalse(parsed.isIdlePrompt)
    }

    func test_numberedCursorRowKeepsBlockingPromptActionable() {
        let parsed = AgentPromptParser.parse(
            visibleText: """
            Do you want to proceed?
            › 1. Yes
              2. No
            """,
            profile: .builtInClaudeCode,
            currentInputLine: "› 1. Yes"
        )

        XCTAssertNotNil(parsed.prompt)
        XCTAssertTrue(parsed.blockingPromptDetected)
        XCTAssertFalse(parsed.isIdlePrompt)
    }

    func test_newerIdlePromptSuppressesStaleApprovalInViewport() {
        let parsed = AgentPromptParser.parse(
            visibleText: """
            Do you want to proceed?
            ❯ 1. Yes
              2. No

            Request cancelled.
            ❯
            """,
            profile: .builtInClaudeCode
        )

        XCTAssertNil(parsed.prompt)
        XCTAssertFalse(parsed.blockingPromptDetected)
        XCTAssertTrue(parsed.isIdlePrompt)
    }

    func test_unparseableBlockingPromptIsDetectedButNeverActionable() {
        let parsed = AgentPromptParser.parse(
            visibleText: "Do you want to proceed?\nChoose using an unknown control",
            profile: .builtInClaudeCode
        )

        XCTAssertNil(parsed.prompt)
        XCTAssertTrue(parsed.blockingPromptDetected)
    }

    func test_approvalWordsInOrdinaryProseDoNotCreatePrompt() {
        let parsed = AgentPromptParser.parse(
            visibleText: "The test asks whether you want to proceed with migration.",
            profile: .builtInClaudeCode
        )

        XCTAssertNil(parsed.prompt)
        XCTAssertFalse(parsed.blockingPromptDetected)
    }

    func test_agentTerminalTextStripsANSIAndOSCWithoutLosingMenuText() {
        let raw = "\u{1B}]0;secret title\u{7}\u{1B}[38;5;6m› 1. Yes, proceed (y)\u{1B}[0m"

        XCTAssertEqual(
            AgentTerminalText.normalized(raw),
            "› 1. Yes, proceed (y)"
        )
    }

    func test_agentCardExcerptSkipsBlankComposerRows() {
        let viewport = """
        › Implement reliable Agent Center detection



        gpt-5.6 · ~/projects/tessera · Context 61% used


        """

        XCTAssertEqual(
            AgentTerminalText.cardExcerpt(viewport),
            "› Implement reliable Agent Center detection\ngpt-5.6 · ~/projects/tessera · Context 61% used"
        )
        XCTAssertEqual(
            AgentTerminalText.taskSummary(viewport),
            "Implement reliable Agent Center detection"
        )
        XCTAssertNil(AgentTerminalText.taskSummary("› 1. Yes\n  2. No"))
    }

    func test_profileWithoutAgentRulesDegradesToUnavailableGrammar() {
        let profile = SwipePadProfile(
            id: UUID(),
            name: "future harness",
            matchProcess: "opencode",
            bindings: [:],
            isBuiltIn: false
        )

        let parsed = AgentPromptParser.parse(
            visibleText: "1. definitely\n2. maybe",
            profile: profile
        )

        XCTAssertNil(parsed.prompt)
        XCTAssertFalse(parsed.isIdlePrompt)
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

    func test_legacyProfileJSONWithoutAgentRulesDecodesAsUnavailable() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000123","name":"legacy","matchProcess":"opencode","bindings":[],"isBuiltIn":false}
        """

        let decoded = try JSONDecoder().decode(
            SwipePadProfile.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(decoded.agentDetection)
        XCTAssertEqual(decoded.matchProcess, "opencode")
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

@MainActor
final class AgentCenterSafetyTests: XCTestCase {
    func test_swipePadDraggedPositionPersistsAcrossPreferenceRecreation() {
        let keys = [
            "tessera.pref.swipePadLastX",
            "tessera.pref.swipePadLastY",
        ]
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let preferences = AppearancePreferences()
        preferences.swipePadLastX = 321.25
        preferences.swipePadLastY = 654.5

        let restored = AppearancePreferences()
        XCTAssertEqual(restored.swipePadLastX, 321.25)
        XCTAssertEqual(restored.swipePadLastY, 654.5)
    }

    func test_experimentalPreferenceDefaultsOffAndPersistsExplicitFalse() {
        let key = "tessera.pref.agentCenterEnabled"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(AppearancePreferences().agentCenterEnabled)

        let enabled = AppearancePreferences()
        enabled.agentCenterEnabled = true
        XCTAssertTrue(AppearancePreferences().agentCenterEnabled)

        enabled.agentCenterEnabled = false
        XCTAssertNotNil(defaults.object(forKey: key))
        XCTAssertFalse(AppearancePreferences().agentCenterEnabled)
    }

    func test_agentNotificationsDisableBellOnceButPreserveLaterOverride() {
        let keys = [
            "tessera.pref.agentCenterEnabled",
            "tessera.pref.agentCenterNotificationsEnabled",
            "tessera.pref.agentCenterBellCoordinationPerformed",
            "tessera.pref.bellNotificationEnabled",
        ]
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))

        let preferences = AppearancePreferences()
        XCTAssertTrue(preferences.agentCenterNotificationsEnabled)
        XCTAssertTrue(preferences.bellNotificationEnabled)

        preferences.agentCenterEnabled = true
        XCTAssertFalse(preferences.bellNotificationEnabled)
        XCTAssertTrue(
            defaults.bool(forKey: "tessera.pref.agentCenterBellCoordinationPerformed")
        )

        preferences.bellNotificationEnabled = true
        preferences.agentCenterEnabled = false
        preferences.agentCenterEnabled = true
        XCTAssertTrue(
            preferences.bellNotificationEnabled,
            "a later explicit terminal-bell override must not be undone"
        )
    }

    func test_agentNotificationPreferenceDoesNotDisableBellWhileAgentCenterIsOff() {
        let keys = [
            "tessera.pref.agentCenterEnabled",
            "tessera.pref.agentCenterNotificationsEnabled",
            "tessera.pref.agentCenterBellCoordinationPerformed",
            "tessera.pref.bellNotificationEnabled",
        ]
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))
        defaults.set(false, forKey: "tessera.pref.agentCenterEnabled")
        defaults.set(true, forKey: "tessera.pref.agentCenterNotificationsEnabled")
        defaults.set(true, forKey: "tessera.pref.bellNotificationEnabled")

        let preferences = AppearancePreferences()

        XCTAssertFalse(preferences.agentCenterEnabled)
        XCTAssertTrue(preferences.agentCenterNotificationsEnabled)
        XCTAssertTrue(preferences.bellNotificationEnabled)
        XCTAssertFalse(
            defaults.bool(forKey: "tessera.pref.agentCenterBellCoordinationPerformed")
        )
    }

    func test_agentNotificationScenePolicyDistinguishesLeavingFromReturning() {
        let phase = AppPhase()

        XCTAssertEqual(phase.agentNotificationDecision, .suppressForeground)

        phase.update(.inactive)
        XCTAssertEqual(phase.inactiveDirection, .leavingForeground)
        XCTAssertEqual(phase.agentNotificationDecision, .awaitBackground)

        phase.update(.background)
        XCTAssertEqual(phase.agentNotificationDecision, .deliver)

        phase.update(.inactive)
        XCTAssertEqual(phase.inactiveDirection, .returningToForeground)
        XCTAssertEqual(
            phase.agentNotificationDecision,
            .suppressForegrounding,
            "a retained event recovered while returning must not become a late banner"
        )

        phase.update(.active)
        XCTAssertEqual(phase.agentNotificationDecision, .suppressForeground)
    }

    func test_agentBackgroundAssertionCoversTurnUntilBackgroundDelivery() {
        typealias KeepAlive = AgentAttentionBackgroundKeepAlive

        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: true,
                workingCount: 1,
                state: .active,
                inactiveDirection: .unknown,
                assertionActive: false
            ),
            .end,
            "a foreground turn must not hold an unnecessary background assertion"
        )
        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: true,
                workingCount: 1,
                state: .inactive,
                inactiveDirection: .leavingForeground,
                assertionActive: false
            ),
            .begin,
            "the assertion must start on the outbound inactive edge before background"
        )
        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: true,
                workingCount: 0,
                state: .background,
                inactiveDirection: .unknown,
                assertionActive: true
            ),
            .keep,
            "the Stop transition must not end execution before notification submission"
        )
        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: true,
                workingCount: 1,
                state: .inactive,
                inactiveDirection: .returningToForeground,
                assertionActive: false
            ),
            .end,
            "resuming to a stale working card must not hide an expired background window"
        )
        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: true,
                workingCount: 0,
                state: .active,
                inactiveDirection: .unknown,
                assertionActive: true
            ),
            .end
        )
        XCTAssertEqual(
            KeepAlive.assertionAction(
                enabled: false,
                workingCount: 1,
                state: .background,
                inactiveDirection: .unknown,
                assertionActive: true
            ),
            .end
        )
    }

    func test_agentSidebarBadgesKeepNeedsInputFinishedAndTotalSeparate() {
        let badges = AgentSidebarBadgeFactory.make(
            waitingCount: 1,
            justFinishedCount: 2,
            totalCount: 4
        )

        XCTAssertEqual(badges.map(\.id), ["needs-input", "just-finished", "total"])
        XCTAssertEqual(badges.map(\.count), [1, 2, 4])
        XCTAssertEqual(badges.map(\.tone), [.needsInput, .justFinished, .neutral])
        XCTAssertTrue(
            AgentSidebarBadgeFactory.make(
                waitingCount: 0,
                justFinishedCount: 0,
                totalCount: 0
            ).isEmpty
        )
    }

    func test_finishedIndicatorsCountOnlyUnreadOffScreenCompletions() {
        let sessionID = UUID()
        let now = Date.now
        func finishedAgent(paneID: Int, windowID: Int) -> AgentInstance {
            AgentCenterHarnessFixtures.make(
                sessionID: sessionID,
                paneID: paneID,
                profileID: SwipePadProfile.builtInCodexCLIID,
                name: "Codex",
                host: "test-host",
                transport: "ssh+tmux",
                tmuxSession: "work",
                windowID: windowID,
                windowName: "window-\(windowID)",
                status: .justFinished,
                tail: "Finished",
                prompt: nil,
                detectedAt: now.addingTimeInterval(-30),
                statusChangedAt: now.addingTimeInterval(-5),
                lastOutputAt: now.addingTimeInterval(-5)
            )
        }

        let first = finishedAgent(paneID: 10, windowID: 1)
        let second = finishedAgent(paneID: 20, windowID: 2)
        let center = AgentCenter(completionAttentionDelayNanoseconds: 0)
        center.installHarnessAgents([first, second])
        center.installHarnessAttention(.justFinished, for: first.id)
        center.installHarnessAttention(.justFinished, for: second.id)

        XCTAssertEqual(center.unreadJustFinishedCount, 2)
        XCTAssertTrue(center.hasUnreadJustFinished(sessionID: sessionID))
        XCTAssertTrue(center.hasUnreadJustFinished(sessionID: sessionID, windowID: 1))
        XCTAssertTrue(center.hasUnreadJustFinished(sessionID: sessionID, windowID: 2))

        center.setApplicationActive(true)
        center.setVisibleTarget(
            sessionID: sessionID,
            windowID: 1,
            paneID: 10,
            isVisible: true
        )

        XCTAssertEqual(center.unreadJustFinishedCount, 1)
        XCTAssertFalse(center.hasUnreadJustFinished(sessionID: sessionID, windowID: 1))
        XCTAssertTrue(center.hasUnreadJustFinished(sessionID: sessionID, windowID: 2))
        XCTAssertEqual(
            center.agents.count { $0.status == .justFinished },
            2,
            "checking a completion must not erase its five-minute semantic state"
        )

        center.setVisibleTarget(
            sessionID: sessionID,
            windowID: 2,
            paneID: 20,
            isVisible: true
        )

        XCTAssertEqual(center.unreadJustFinishedCount, 0)
        XCTAssertFalse(center.hasUnreadJustFinished(sessionID: sessionID))
        XCTAssertEqual(center.agents.count { $0.status == .justFinished }, 2)
    }

    @MainActor
    func test_tmuxPaneCaptureUsesSeparateControlFrames() async {
        var commands: [String] = []
        let capture = await AgentSessionSourceFactory.capturePane(
            paneID: PaneId(4)
        ) { command in
            commands.append(command)
            if command.hasPrefix("display-message") {
                return .success(["1"])
            }
            return .success(["old output", "› Implement {feature}", "status"])
        }

        XCTAssertEqual(commands, [
            "display-message -p -t %4 '#{cursor_y}'",
            "capture-pane -p -e -N -t %4",
        ])
        XCTAssertEqual(capture?.text, "old output\n› Implement {feature}\nstatus")
        XCTAssertEqual(capture?.currentInputLine, "› Implement {feature}")
    }

    func test_processWrappersTriggerDescendantProbeWithoutProbingShells() {
        for wrapper in ["node", "bunx", "npm", "npx", "pnpm", "yarn", "2.1.210"] {
            XCTAssertTrue(AgentSessionSourceFactory.shouldProbeDescendants(command: wrapper))
        }
        XCTAssertFalse(AgentSessionSourceFactory.shouldProbeDescendants(command: "zsh"))
        XCTAssertFalse(AgentSessionSourceFactory.shouldProbeDescendants(command: "fish"))
        XCTAssertFalse(AgentSessionSourceFactory.shouldProbeDescendants(command: "2.1"))
        XCTAssertFalse(AgentSessionSourceFactory.shouldProbeDescendants(command: "2.1.beta"))
    }

    func test_lifecycleWireAcceptsCompatibleRetainedProtocolAfterInstallerUpgrade() {
        let current = Self.lifecycleJSON(state: "idle", timestamp: 1)
        XCTAssertNotNil(AgentLifecycleEvent.decode(json: current))
        for version in AgentLifecycleEvent.compatibleVersions.sorted() {
            let payload = current.replacingOccurrences(
                of: #""version":8"#,
                with: #""version":\#(version)"#
            )
            XCTAssertEqual(AgentLifecycleEvent.decode(json: payload)?.version, version)
        }
        for version in [1, 5, AgentLifecycleEvent.supportedVersion + 1] {
            let payload = current.replacingOccurrences(
                of: #""version":8"#,
                with: #""version":\#(version)"#
            )
            XCTAssertNil(AgentLifecycleEvent.decode(json: payload))
            XCTAssertEqual(AgentLifecycleEvent.declaredVersion(json: payload), version)
        }
        XCTAssertNil(AgentLifecycleEvent.declaredVersion(json: "not-json"))
        XCTAssertNil(
            AgentLifecycleEvent.decode(
                json: current.replacingOccurrences(of: #""event":"Stop""#, with: #""event":"MadeUp""#)
            )
        )
        XCTAssertNil(
            AgentLifecycleEvent.decode(
                json: current.replacingOccurrences(of: #""state":"idle""#, with: #""state":"working""#)
            )
        )
        XCTAssertNil(
            AgentLifecycleEvent.decode(
                json: current.replacingOccurrences(of: #""reason":"test""#, with: #""reason":"unsafe/value""#)
            )
        )
    }

    func test_preexistingAgentRetainsAvailabilityAcrossCompatibleInstallerUpgrade() async {
        let box = AgentTestSourceBox(visibleText: "Finished.\n\n› ")
        box.processNames = ["codex"]
        box.processIDs = [100]
        let current = Self.lifecycleJSON(
            state: "idle",
            timestamp: 2,
            provider: "codex",
            event: "Stop",
            agentPID: 100
        )
        box.lifecycleEvent = AgentLifecycleEvent.decode(
            json: current.replacingOccurrences(
                of: #""version":8"#,
                with: #""version":2"#
            )
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)

        center.register(box.source())

        await waitUntil { center.agents.first?.status == .idle }
        XCTAssertEqual(center.agents.first?.providerSessionReference, "provider")
    }

    func test_sortedAgentsUsesStateThenNewestLifecycleEvent() async {
        let waiting = AgentTestSourceBox(
            hostName: "waiting",
            visibleText: Self.claudePrompt
        )
        waiting.currentInputLine = "❯ 1. Yes"
        waiting.processIDs = [100]
        waiting.lifecycleEvent = Self.lifecycleEvent(
            state: "waitingForInput",
            timestamp: 1_000_000_000,
            event: "PermissionRequest"
        )

        let olderIdle = AgentTestSourceBox(
            hostName: "older-idle",
            visibleText: "Finished.\n\n❯ "
        )
        olderIdle.currentInputLine = "❯ "
        olderIdle.processIDs = [100]
        olderIdle.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: 2_000_000_000,
            event: "Stop"
        )

        let newerIdle = AgentTestSourceBox(
            hostName: "newer-idle",
            visibleText: "Finished.\n\n❯ "
        )
        newerIdle.currentInputLine = "❯ "
        newerIdle.processIDs = [100]
        newerIdle.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: 3_000_000_000,
            event: "Stop"
        )

        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(olderIdle.source())
        center.register(waiting.source())
        center.register(newerIdle.source())

        await waitUntil { center.agents.count == 3 }
        XCTAssertEqual(
            center.sortedAgents.map(\.location.hostName),
            ["waiting", "newer-idle", "older-idle"]
        )

        center.noteLifecyclePayload(
            sessionID: olderIdle.sessionID,
            paneID: olderIdle.paneID,
            json: Self.lifecycleJSON(
                state: "idle",
                timestamp: 4_000_000_000,
                event: "Stop"
            )
        )

        await waitUntil {
            center.sortedAgents.map(\.location.hostName)
                == ["waiting", "older-idle", "newer-idle"]
        }
        XCTAssertEqual(center.agents.first {
            $0.id.sessionID == olderIdle.sessionID
        }?.status, .idle)
    }

    func test_preexistingAgentCompatibleEventClearsCurrentSessionWarningOnlyForLivePID() {
        let current = Self.lifecycleJSON(
            state: "idle",
            timestamp: 3,
            provider: "codex",
            event: "Stop",
            agentPID: 341_402
        )
        let legacy = AgentLifecycleEvent.decode(
            json: current.replacingOccurrences(
                of: #""version":8"#,
                with: #""version":2"#
            )
        )

        XCTAssertTrue(
            AgentSessionSourceFactory.lifecycleRuntimeActive(
                isAgent: true,
                lifecycleEvent: legacy,
                processIDs: [341_395, 341_402]
            )
        )
        XCTAssertFalse(
            AgentSessionSourceFactory.lifecycleRuntimeActive(
                isAgent: true,
                lifecycleEvent: legacy,
                processIDs: [200]
            )
        )
        XCTAssertFalse(
            AgentSessionSourceFactory.lifecycleRuntimeActive(
                isAgent: false,
                lifecycleEvent: legacy,
                processIDs: [341_402]
            )
        )
    }

    func test_currentIntegrationRecognizesOnlySupportedSourceCompatibleShells() {
        XCTAssertTrue(AgentSessionSourceFactory.matchesSupportedShell(["zsh"]))
        XCTAssertTrue(AgentSessionSourceFactory.matchesSupportedShell(["/bin/bash"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesSupportedShell(["-sh"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesSupportedShell(["dash"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesSupportedShell(["fish"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesSupportedShell(["vim"]))
    }

    func test_currentIntegrationRecognizesOnlyProvidersWithInstalledHookContracts() {
        XCTAssertTrue(AgentSessionSourceFactory.matchesLifecycleAgent(["claude"]))
        XCTAssertTrue(AgentSessionSourceFactory.matchesLifecycleAgent(["codex-linux-x64"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesLifecycleAgent(["vim"]))
        XCTAssertFalse(AgentSessionSourceFactory.matchesLifecycleAgent(["custom-agent"]))
    }

    func test_currentIntegrationNeverTreatsDormantShellAncestorAsForegroundShell() {
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "vim",
                processNames: ["vim", "bash"]
            ),
            .other
        )
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "node",
                processNames: ["node", "codex"]
            ),
            .agent
        )
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "zsh",
                processNames: ["zsh"]
            ),
            .shell
        )
    }

    @MainActor
    func test_currentIntegrationUsesExactShellProofButAllowsInheritedChildProof() async {
        var snapshot = SwipePadPlainSSHProcessProbe.Snapshot(
            processNames: ["bash"],
            processIDs: [42]
        )
        var probes: [(Set<Int>, Bool)] = []
        let source = AgentSessionSourceFactory.make(
            sessionID: UUID(),
            hostName: "fixture",
            baseTransportLabel: "ssh",
            tmux: TmuxController(),
            terminalBox: TerminalBox(traceLabel: "agent-center-test"),
            tmuxSessionName: { nil },
            profiles: { SwipePadProfile.allBuiltIns },
            rawProcessProvider: { snapshot },
            probeShellIntegration: { processIDs, allowInheritedEnvironment in
                probes.append((processIDs, allowInheritedEnvironment))
                return true
            },
            rawSend: { _ in }
        )

        _ = await source.inspectCurrentIntegration?()
        snapshot = .init(processNames: ["fish"], processIDs: [43])
        _ = await source.inspectCurrentIntegration?()
        snapshot = .init(processNames: ["vim"], processIDs: [44])
        _ = await source.inspectCurrentIntegration?()

        XCTAssertEqual(probes.map(\.0), [[42], [43], [44]])
        XCTAssertEqual(probes.map(\.1), [false, false, true])
    }

    func test_tmuxShellMarkerParsesExactVersionedShellPID() {
        XCTAssertEqual(AgentSessionSourceFactory.shellMarkerPID("8:412:8"), 412)
        XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID("8:412"))
        XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID("7:412:8"))
        XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID("8:1:8"))
        XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID("8:not-a-pid:8"))
        XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID("8:412:7"))
    }

    func test_disabledCenterKeepsSourcesInertUntilExplicitlyEnabled() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var discoveryCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: {
                discoveryCount += 1
                return await base.discover()
            },
            observe: base.observe,
            inspect: base.inspect,
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(
            isEnabled: false,
            sendVerificationDelayNanoseconds: 1_000_000
        )

        center.register(source)
        center.noteOutput(sessionID: box.sessionID, paneID: box.paneID)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(discoveryCount, 0)
        XCTAssertTrue(center.agents.isEmpty)
        XCTAssertFalse(center.shouldMaintainObservation(sessionID: box.sessionID))

        center.setEnabled(true)
        await waitUntil { center.agents.first?.name == "claude code" }
        XCTAssertEqual(discoveryCount, 1)
    }

    func test_disablingCenterCancelsWorkAndClearsDerivedAgentState() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        center.setSurfaceDemand(true)
        await waitUntil { center.agents.first?.name == "claude code" }

        center.setEnabled(false)

        XCTAssertFalse(center.isEnabled)
        XCTAssertFalse(center.surfaceDemand)
        XCTAssertTrue(center.agents.isEmpty)
        XCTAssertFalse(center.shouldMaintainObservation(sessionID: box.sessionID))

        center.requestRefresh(sessionID: box.sessionID)
        center.noteOutput(sessionID: box.sessionID, paneID: box.paneID)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(center.agents.isEmpty)
    }

    func test_observationBootstrapStaysLatchedUntilCarrierReadyDiscovery() async {
        let box = AgentTestSourceBox(visibleText: "shell")
        box.processNames = ["zsh"]
        let center = AgentCenter(
            isEnabled: false,
            sendVerificationDelayNanoseconds: 1_000_000
        )
        center.register(box.source())

        center.setEnabled(true)
        XCTAssertTrue(center.shouldMaintainObservation(sessionID: box.sessionID))

        center.observationCarrierBecameReady(sessionID: box.sessionID)
        await waitUntil {
            !center.shouldMaintainObservation(sessionID: box.sessionID)
        }
        XCTAssertTrue(center.agents.isEmpty)
    }

    func test_observationBootstrapRetriesTransientReadyCarrierFailure() async {
        let box = AgentTestSourceBox(visibleText: "shell")
        let base = box.source()
        var discoveryCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: {
                discoveryCount += 1
                return discoveryCount == 2 ? .unavailable : .success([])
            },
            observe: base.observe,
            inspect: base.inspect,
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(
            isEnabled: false,
            sendVerificationDelayNanoseconds: 1_000_000
        )
        center.register(source)
        center.setEnabled(true)
        await waitUntil { discoveryCount == 1 }

        center.observationCarrierBecameReady(sessionID: box.sessionID)
        await waitUntil { discoveryCount == 2 }
        XCTAssertTrue(center.shouldMaintainObservation(sessionID: box.sessionID))

        try? await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertGreaterThanOrEqual(discoveryCount, 3)
        XCTAssertFalse(center.shouldMaintainObservation(sessionID: box.sessionID))
    }

    func test_stalePromptGuardRefusesMovedPrompt() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        box.visibleText = "Done.\n\n❯ "
        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.actionMessage == "prompt changed" }
        XCTAssertTrue(box.sentBytes.isEmpty)
        XCTAssertFalse(center.agents[0].sendInFlight)
    }

    func test_stalePromptGuardRefusesPromptLeftBehindAfterAgentExit() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        box.processNames = ["zsh"]
        center.answer(agentID: id, optionID: 1)

        await waitUntil {
            center.agents.first?.actionMessage == "status unavailable — open the pane"
                || center.agents.isEmpty
        }
        XCTAssertTrue(box.sentBytes.isEmpty)
    }

    func test_oneInFlightSendSuppressesDoubleAnswer() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 30_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        center.answer(agentID: id, optionID: 1)
        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("1".utf8), [0x0D]])
        XCTAssertEqual(center.agents.first?.actionMessage, "didn't land — open the pane")
    }

    func test_echoVerificationAcceptsChangedTail() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        box.echoTextAfterSend = "Queued response\n\n❯ "
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("1".utf8), [0x0D]])
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_promptDisappearanceVerifiesEvenWhenLastFiveLinesStayIdentical() async {
        let footer = "footer one\nfooter two\nfooter three\nfooter four\nfooter five"
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt + "\n" + footer)
        box.currentInputLine = ""
        box.echoTextAfterSend = "Accepted\n" + footer
        box.currentInputLineAfterSend = "footer five"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 30_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("1".utf8), [0x0D]])
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_promptAcceleratorThatSubmitsImmediatelySkipsExtraReturn() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        box.currentInputLine = "❯ 1. Yes"
        box.onSend = { bytes in
            guard bytes == Array("1".utf8) else { return }
            box.visibleText = "Request accepted\n\n❯ "
            box.currentInputLine = "❯ "
        }
        let center = AgentCenter(sendVerificationDelayNanoseconds: 30_000_000)
        center.register(box.source(supportsSemanticKeys: true))
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("1".utf8)])
        XCTAssertTrue(box.sentKeys.isEmpty)
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_messageSubmissionVerifiesWhenOnlyViewportAboveStableFooterChanges() async {
        let footer = "footer one\nfooter two\nfooter three\nfooter four\nfooter five"
        let box = AgentTestSourceBox(visibleText: "Ready\n" + footer)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "› "
        box.echoTextAfterSend = "› retry me\n\nWorking\n" + footer
        box.currentInputLineAfterSend = "footer five"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 30_000_000)
        center.register(box.source(supportsSemanticKeys: true))
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "retry me"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("retry me".utf8)])
        XCTAssertEqual(box.sentKeys, [.enter])
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_messageDoesNotAcceptUnrelatedOutputAsEcho() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.echoTextAfterSend = "background task progressed\n\n❯ "
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "hello"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(
            center.agents.first?.actionMessage,
            "submission not verified — open the pane"
        )
    }

    func test_messageAlreadyInHistoryCannotVerifyUnrelatedTailChange() async {
        let box = AgentTestSourceBox(visibleText: "hello\nold answer\n› ")
        box.currentInputLine = "› "
        box.echoTextAfterSend = "hello\nold answer\nunrelated status\n› "
        box.currentInputLineAfterSend = "› "
        let center = AgentCenter(sendVerificationDelayNanoseconds: 20_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "hello"))
        await waitUntil { center.agents.first?.sendInFlight == false }

        XCTAssertEqual(
            center.agents.first?.actionMessage,
            "submission not verified — open the pane"
        )
    }

    func test_claudeComposerInsertionWithoutSubmissionIsNotReportedAsSent() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.currentInputLine = "❯ "
        box.echoTextAfterSend = "Done.\n\n❯ hello"
        box.currentInputLineAfterSend = "❯ hello"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "hello"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("hello".utf8), [0x0D]])
        XCTAssertEqual(
            center.agents.first?.actionMessage,
            "submission not verified — open the pane"
        )
    }

    func test_messageUsesSemanticEnterExactlyOnceWhenSubmissionLands() async {
        let box = AgentTestSourceBox(visibleText: "Ready\n\n› ")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "› "
        let center = AgentCenter(sendVerificationDelayNanoseconds: 90_000_000)
        box.onSend = { bytes in
            guard bytes != [0x0D] else { return }
            box.visibleText = "Ready\n\n› retry me"
            box.currentInputLine = "› retry me"
        }
        box.onSendKey = { key in
            guard key == .enter, box.sentKeys.count == 1 else { return }
            box.visibleText = "› retry me\n\nWorking"
            box.currentInputLine = "Working"
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 100,
                    event: "UserPromptSubmit",
                    provider: "codex"
                )[...]
            )
        }
        center.register(box.source(supportsSemanticKeys: true))
        await waitUntil { center.agents.first?.name == "codex cli" }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "retry me"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("retry me".utf8)])
        XCTAssertEqual(box.sentKeys, [.enter])
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_unverifiedSubmissionNeverRepeatsSemanticEnter() async {
        let box = AgentTestSourceBox(visibleText: "Ready\n\n› ")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "› "
        box.onSend = { bytes in
            guard bytes != [0x0D] else { return }
            box.visibleText = "Ready\n\n› one enter only"
            box.currentInputLine = "› one enter only"
        }
        let center = AgentCenter(sendVerificationDelayNanoseconds: 30_000_000)
        center.register(box.source(supportsSemanticKeys: true))
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "one enter only"))
        await waitUntil { center.agents.first?.sendInFlight == false }

        XCTAssertEqual(box.sentKeys, [.enter])
        XCTAssertEqual(
            center.agents.first?.actionMessage,
            "submission not verified — open the pane"
        )
    }

    func test_returnTransportFailureReportsComposerMayStillContainText() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.sendResults = [true, false]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        XCTAssertTrue(center.sendMessage(agentID: id, text: "hello"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("hello".utf8), [0x0D]])
        XCTAssertEqual(
            center.agents.first?.actionMessage,
            "submission failed — text may still be in the composer"
        )
    }

    func test_codexUserPromptSubmitIsAuthoritativeEvenWithoutScreenEcho() async {
        let box = AgentTestSourceBox(visibleText: "Ready\n\n› ")
        box.processNames = ["codex"]
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 50_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.name == "codex cli" }
        let id = try! XCTUnwrap(center.agents.first?.id)
        box.onSend = { bytes in
            guard bytes == [0x0D] else { return }
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 100,
                    event: "UserPromptSubmit",
                    provider: "codex"
                )[...]
            )
        }

        XCTAssertTrue(center.sendMessage(agentID: id, text: "land this"))

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(box.sentBytes, [Array("land this".utf8), [0x0D]])
        XCTAssertNil(center.agents.first?.actionMessage)
        XCTAssertEqual(center.agents.first?.status, .working)
    }

    func test_codexSubagentLifecycleDoesNotAcknowledgeRootSubmission() async {
        for event in ["SubagentStart", "SubagentStop"] {
            let box = AgentTestSourceBox(visibleText: "Ready\n\n› ")
            box.processNames = ["codex"]
            box.processIDs = [100]
            let center = AgentCenter(sendVerificationDelayNanoseconds: 20_000_000)
            center.register(box.source())
            await waitUntil { center.agents.first?.name == "codex cli" }
            let id = try! XCTUnwrap(center.agents.first?.id)
            box.onSend = { bytes in
                guard bytes == [0x0D] else { return }
                center.noteOutput(
                    sessionID: box.sessionID,
                    paneID: box.paneID,
                    data: Self.lifecycleOSC(
                        state: "working",
                        timestamp: 100,
                        event: event,
                        provider: "codex"
                    )[...]
                )
            }

            XCTAssertTrue(center.sendMessage(agentID: id, text: "root prompt"))
            await waitUntil { center.agents.first?.sendInFlight == false }
            XCTAssertEqual(
                center.agents.first?.actionMessage,
                "submission not verified — open the pane"
            )
        }
    }

    func test_freeFormRefusesStaleAgentCard() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        box.processNames = ["zsh"]
        XCTAssertTrue(center.sendMessage(agentID: id, text: "must not reach shell"))
        await waitUntil {
            center.agents.first?.actionMessage == "status unavailable — open the pane"
                || center.agents.isEmpty
        }
        XCTAssertTrue(box.sentBytes.isEmpty)
    }

    func test_interruptRefusesStaleAgentCard() async {
        let box = AgentTestSourceBox(visibleText: "Working…")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)

        box.processNames = ["zsh"]
        center.interrupt(agentID: id)
        await waitUntil {
            center.agents.first?.actionMessage == "status unavailable — open the pane"
                || center.agents.isEmpty
        }

        XCTAssertTrue(box.sentBytes.isEmpty)
    }

    func test_promptIdentityIgnoresMutableFooterText() throws {
        let first = AgentPromptParser.parse(
            visibleText: Self.claudePrompt + "\nEsc to cancel · 12s",
            profile: .builtInClaudeCode,
            currentInputLine: nil
        ).prompt
        let second = AgentPromptParser.parse(
            visibleText: Self.claudePrompt + "\nEsc to cancel · 11s",
            profile: .builtInClaudeCode,
            currentInputLine: nil
        ).prompt

        XCTAssertEqual(try XCTUnwrap(first).signature, try XCTUnwrap(second).signature)
    }

    func test_promptIdentityIncludesCommandContextForGenericClaudeMenu() throws {
        let first = AgentPromptParser.parse(
            visibleText: "Bash command\n\nrm -rf build-one\n\n" + Self.claudePrompt,
            profile: .builtInClaudeCode
        ).prompt
        let second = AgentPromptParser.parse(
            visibleText: "Bash command\n\nrm -rf build-two\n\n" + Self.claudePrompt,
            profile: .builtInClaudeCode
        ).prompt

        XCTAssertNotEqual(try XCTUnwrap(first).signature, try XCTUnwrap(second).signature)
    }

    func test_interruptDoesNotAcceptUnrelatedLifecycleProgressAsDelivery() async {
        let box = AgentTestSourceBox(visibleText: "Working…")
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 20_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)
        box.onSend = { _ in
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 100,
                    event: "PostToolUse"
                )[...]
            )
        }

        center.interrupt(agentID: id)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(center.agents.first?.actionMessage, "didn't land — open the pane")
    }

    func test_promptAnswerDoesNotAcceptAnotherWaitingEventAsDelivery() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 20_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.prompt != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)
        box.onSend = { bytes in
            guard bytes == [0x0D] else { return }
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "waitingForInput",
                    timestamp: 100,
                    event: "PermissionRequest"
                )[...]
            )
        }

        center.answer(agentID: id, optionID: 1)

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(center.agents.first?.actionMessage, "didn't land — open the pane")
    }

    func test_fullDiscoveryRemovesExitedAgent() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.name == "claude code" }

        box.processNames = []
        center.requestRefresh(sessionID: box.sessionID)

        await waitUntil { center.agents.isEmpty }
    }

    func test_fullDiscoveryCanChangeHarnessProfileInSamePane() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.name == "claude code" }

        box.processNames = ["codex"]
        box.visibleText = "› Write tests for @filename"
        center.requestRefresh(sessionID: box.sessionID)

        await waitUntil { center.agents.first?.name == "codex cli" }
        XCTAssertEqual(center.agents.first?.profileID, SwipePadProfile.builtInCodexCLI.id)
    }

    func test_unavailableDiscoveryRetainsLastAuthoritativeAgentSnapshot() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.lifecycleEvent = Self.lifecycleEvent(state: "idle", timestamp: 10)
        let base = box.source()
        var discoveryAvailable = true
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: {
                if discoveryAvailable {
                    return await base.discover()
                }
                return .unavailable
            },
            observe: base.observe,
            inspect: base.inspect,
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        await waitUntil { center.agents.first?.status == .idle }
        let original = center.agents.first

        discoveryAvailable = false
        center.requestRefresh(sessionID: box.sessionID)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(center.agents.first, original)
    }

    func test_unregisterCancelsPendingSendVerification() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.echoTextAfterSend = "hello\nWorking…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 50_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)
        XCTAssertTrue(center.sendMessage(agentID: id, text: "hello"))
        await waitUntil { !box.sentBytes.isEmpty }

        center.unregister(
            sessionID: box.sessionID,
            registrationID: source.registrationID
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(center.agents.isEmpty)
    }

    func test_sourceReplacementIgnoresLateUnregisterAndOldOutput() async {
        let sessionID = UUID()
        let oldBox = AgentTestSourceBox(
            sessionID: sessionID,
            hostName: "destination-via-old-bastion",
            visibleText: "Old carrier\n\n❯ "
        )
        let newBox = AgentTestSourceBox(
            sessionID: sessionID,
            hostName: "destination-via-new-bastion",
            visibleText: "Replacement carrier\n\n❯ "
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let oldSource = oldBox.source()
        let newSource = newBox.source()

        center.register(oldSource)
        await waitUntil {
            center.agents.first?.location.hostName == "destination-via-old-bastion"
        }
        center.register(newSource)
        await waitUntil {
            center.agents.first?.location.hostName == "destination-via-new-bastion"
        }

        center.unregister(
            sessionID: sessionID,
            registrationID: oldSource.registrationID
        )
        oldBox.visibleText = Self.claudePrompt
        center.noteOutput(
            sessionID: sessionID,
            paneID: oldBox.paneID,
            registrationID: oldSource.registrationID,
            data: Array(Self.claudePrompt.utf8)[...]
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(
            center.agents.first?.location.hostName,
            "destination-via-new-bastion"
        )
        XCTAssertEqual(center.agents.first?.outputTail, "Replacement carrier\n❯")
    }

    func test_sourceReplacementIgnoresOldDiscoveryThatResumesAfterCancellation() async {
        let sessionID = UUID()
        let oldBox = AgentTestSourceBox(
            sessionID: sessionID,
            hostName: "old-route",
            visibleText: "Old carrier\n\n❯ "
        )
        let newBox = AgentTestSourceBox(
            sessionID: sessionID,
            hostName: "new-route",
            visibleText: "Replacement carrier\n\n❯ "
        )
        let oldBase = oldBox.source()
        let oldLocation = AgentLocation(
            sessionID: sessionID,
            hostName: "old-route",
            transportLabel: "mosh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: oldBox.paneID
        )
        let oldProbe = AgentProbeTarget(
            location: oldLocation,
            processNames: ["claude"],
            visibleText: oldBox.visibleText,
            bracketedPasteEnabled: false
        )
        var oldDiscovery: CheckedContinuation<[AgentProbeTarget], Never>?
        let oldSource = AgentSessionSource(
            registrationID: oldBase.registrationID,
            sessionID: sessionID,
            discover: {
                let probes: [AgentProbeTarget] = await withCheckedContinuation { continuation in
                    oldDiscovery = continuation
                }
                return .success(probes)
            },
            observe: oldBase.observe,
            inspect: oldBase.inspect,
            send: oldBase.send,
            jump: oldBase.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)

        center.register(oldSource)
        await waitUntil { oldDiscovery != nil }
        center.register(newBox.source())
        await waitUntil {
            center.agents.first?.location.hostName == "new-route"
        }

        oldDiscovery?.resume(returning: [oldProbe])
        oldDiscovery = nil
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(center.agents.count, 1)
        XCTAssertEqual(center.agents.first?.location.hostName, "new-route")
        XCTAssertEqual(center.agents.first?.outputTail, "Replacement carrier\n❯")
    }

    func test_sameDestinationAcrossJumpRoutesSendsOnlyToSelectedSession() async {
        let firstBox = AgentTestSourceBox(
            hostName: "shared-destination",
            visibleText: Self.claudePrompt
        )
        let secondBox = AgentTestSourceBox(
            hostName: "shared-destination",
            visibleText: Self.claudePrompt
        )
        secondBox.echoTextAfterSend = "Accepted on second route\n\n❯ "
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(firstBox.source())
        center.register(secondBox.source())
        await waitUntil { center.agents.count == 2 }
        let secondID = AgentInstanceID(
            sessionID: secondBox.sessionID,
            paneID: secondBox.paneID
        )
        await waitUntil {
            center.agents.first(where: { $0.id == secondID })?.prompt != nil
        }

        center.answer(agentID: secondID, optionID: 1)
        await waitUntil { secondBox.sentBytes.count == 2 }
        await waitUntil {
            center.agents.first(where: { $0.id == secondID })?.sendInFlight == false
        }

        XCTAssertTrue(firstBox.sentBytes.isEmpty)
        XCTAssertEqual(secondBox.sentBytes, [Array("1".utf8), [0x0D]])
        XCTAssertEqual(
            center.agents.first(where: { $0.id == secondID })?.location.hostName,
            "shared-destination"
        )
    }

    func test_sourceReplacementCancelsOldInFlightVerification() async {
        let sessionID = UUID()
        let oldBox = AgentTestSourceBox(
            sessionID: sessionID,
            visibleText: "Old carrier\n\n❯ "
        )
        oldBox.echoTextAfterSend = "old carrier echoed\n\n❯ "
        let replacementBox = AgentTestSourceBox(
            sessionID: sessionID,
            visibleText: "Replacement carrier\n\n❯ "
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 50_000_000)
        center.register(oldBox.source())
        await waitUntil { center.agents.first != nil }
        let oldID = try! XCTUnwrap(center.agents.first?.id)
        XCTAssertTrue(center.sendMessage(agentID: oldID, text: "old carrier message"))
        await waitUntil { !oldBox.sentBytes.isEmpty }

        center.register(replacementBox.source())
        await waitUntil {
            center.agents.first?.outputTail == "Replacement carrier\n❯"
        }
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(center.agents.count, 1)
        XCTAssertEqual(center.agents.first?.outputTail, "Replacement carrier\n❯")
        XCTAssertFalse(center.agents.first?.sendInFlight ?? true)
        XCTAssertNil(center.agents.first?.actionMessage)
    }

    func test_messageUsesBracketedPasteWhenProbeReportsIt() async {
        let box = AgentTestSourceBox(
            visibleText: "Done.\n\n❯ ",
            bracketedPasteEnabled: false
        )
        box.echoTextAfterSend = "hello\nWorking…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Array("\u{1B}[?20".utf8)[...]
        )
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Array("04h".utf8)[...]
        )

        center.sendMessage(agentID: id, text: "hello")

        await waitUntil { center.agents.first?.sendInFlight == false }
        XCTAssertEqual(
            box.sentBytes,
            [Array("\u{1B}[200~hello\u{1B}[201~".utf8), [0x0D]]
        )
    }

    func test_workingToWaitingEmitsAttentionTransitionOnce() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        var transitions: [AgentInstance] = []
        var attentions: [AgentAttention] = []
        center.setApplicationActive(false)
        center.onWaitingForInput = { transitions.append($0) }
        center.onAttention = { attention, _ in attentions.append(attention) }
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 20)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.visibleText = Self.claudePrompt
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "waitingForInput", timestamp: 21)[...]
        )

        await waitUntil { center.agents.first?.status == .waitingForInput }
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(attentions.map(\.kind), [.needsInput])
        center.requestRefresh(sessionID: box.sessionID)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(attentions.count, 1)
    }

    func test_rootStopTransitionsThroughJustFinishedThenIdle() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            justFinishedDuration: 0.06,
            completionAttentionDelayNanoseconds: 0
        )
        var attentions: [AgentAttention] = []
        center.setApplicationActive(false)
        center.onAttention = { attention, _ in attentions.append(attention) }
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 200)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 201,
                event: "Stop"
            )[...]
        )

        await waitUntil { center.agents.first?.status == .justFinished }
        XCTAssertNotNil(center.agents.first?.finishedAt)
        XCTAssertEqual(center.sortedUnreadAttentions.map(\.kind), [.justFinished])
        XCTAssertEqual(center.unreadJustFinishedCount, 1)
        XCTAssertEqual(attentions.map(\.kind), [.justFinished])

        await waitUntil { center.agents.first?.status == .idle }
        XCTAssertNil(center.agents.first?.finishedAt)
        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(center.unreadJustFinishedCount, 0)
        XCTAssertNotNil(center.agents.first?.lastLifecycleEventAt)
    }

    func test_visibleSurfaceSuppressesAttentionAndVisitingOtherSurfaceAcknowledgesIt() async {
        let visible = AgentTestSourceBox(hostName: "visible", visibleText: "Thinking…")
        let hidden = AgentTestSourceBox(hostName: "hidden", visibleText: "Thinking…")
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            completionAttentionDelayNanoseconds: 0
        )
        var emittedAgentIDs: [AgentInstanceID] = []
        center.onAttention = { attention, _ in
            emittedAgentIDs.append(attention.agentID)
        }
        center.setApplicationActive(true)
        center.setVisibleTarget(
            sessionID: visible.sessionID,
            windowID: 3,
            paneID: visible.paneID,
            isVisible: true
        )
        for box in [visible, hidden] {
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(state: "working", timestamp: 210)[...]
            )
            center.register(box.source())
        }
        await waitUntil { center.agents.count == 2 }

        visible.visibleText = Self.claudePrompt
        hidden.visibleText = Self.claudePrompt
        for box in [visible, hidden] {
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "waitingForInput",
                    timestamp: 211
                )[...]
            )
        }

        await waitUntil {
            center.agents.allSatisfy { $0.status == .waitingForInput }
        }
        XCTAssertEqual(center.unreadAttentions.map(\.agentID), [
            AgentInstanceID(sessionID: hidden.sessionID, paneID: hidden.paneID),
        ])
        XCTAssertEqual(emittedAgentIDs, [
            AgentInstanceID(sessionID: hidden.sessionID, paneID: hidden.paneID),
        ])

        center.setVisibleTarget(
            sessionID: hidden.sessionID,
            windowID: 3,
            paneID: hidden.paneID,
            isVisible: true
        )
        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(center.waitingCount, 2, "acknowledgement must not alter live state")
    }

    func test_visitingTmuxWindowAcknowledgesEveryVisibleSplitPane() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            completionAttentionDelayNanoseconds: 0
        )
        var attentions: [AgentAttention] = []
        center.setApplicationActive(false)
        center.onAttention = { attention, _ in attentions.append(attention) }
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 220)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.visibleText = Self.claudePrompt
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "waitingForInput", timestamp: 221)[...]
        )
        await waitUntil { center.unreadAttentions.count == 1 }

        center.setApplicationActive(true)
        center.setVisibleTarget(
            sessionID: box.sessionID,
            windowID: 3,
            paneID: 99,
            isVisible: true
        )

        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(attentions.count, 1)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 222)[...]
        )
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 223,
                event: "Stop"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .justFinished }
        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(center.unreadJustFinishedCount, 0)
        XCTAssertEqual(attentions.count, 1, "a visible split pane must stay suppressed")
    }

    func test_selectedWindowStillEmitsInBackgroundAndAcknowledgesOnForeground() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            completionAttentionDelayNanoseconds: 0
        )
        var attentions: [AgentAttention] = []
        center.onAttention = { attention, _ in attentions.append(attention) }
        center.setApplicationActive(true)
        center.setVisibleTarget(
            sessionID: box.sessionID,
            windowID: 3,
            paneID: box.paneID,
            isVisible: true
        )
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 224)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        center.setApplicationActive(false)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 225,
                event: "Stop"
            )[...]
        )
        await waitUntil { center.unreadAttentions.count == 1 }
        XCTAssertEqual(attentions.map(\.kind), [.justFinished])
        XCTAssertEqual(center.unreadJustFinishedCount, 1)

        center.setApplicationActive(true)

        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(center.unreadJustFinishedCount, 0)
        XCTAssertEqual(center.agents.first?.status, .justFinished)
    }

    func test_jumpAcknowledgesAttentionAndRoutesExactAgentLocation() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.setApplicationActive(false)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 226)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }
        let agent = try! XCTUnwrap(center.agents.first)

        box.visibleText = Self.claudePrompt
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "waitingForInput", timestamp: 227)[...]
        )
        await waitUntil { center.unreadAttentions.count == 1 }

        center.jump(agentID: agent.id)

        XCTAssertTrue(center.unreadAttentions.isEmpty)
        XCTAssertEqual(box.jumpedLocations, [agent.location])
        XCTAssertEqual(center.agents.first?.status, .waitingForInput)
    }

    func test_recentRetainedStopRecoversFinishedWindowButOldStopIsIdle() async {
        let nowNanoseconds = UInt64(Date.now.timeIntervalSince1970 * 1_000_000_000)
        let recent = AgentTestSourceBox(hostName: "recent", visibleText: "Done.\n\n❯ ")
        recent.processIDs = [100]
        recent.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: nowNanoseconds - 30_000_000_000,
            event: "Stop"
        )
        let old = AgentTestSourceBox(hostName: "old", visibleText: "Done.\n\n❯ ")
        old.processIDs = [100]
        old.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: nowNanoseconds - 600_000_000_000,
            event: "Stop"
        )
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            completionAttentionDelayNanoseconds: 0
        )

        center.register(recent.source())
        center.register(old.source())

        await waitUntil { center.agents.count == 2 }
        XCTAssertEqual(
            center.agents.first { $0.location.hostName == "recent" }?.status,
            .justFinished
        )
        XCTAssertEqual(
            center.agents.first { $0.location.hostName == "old" }?.status,
            .idle
        )
    }

    func test_knownWorkingAgentOutputBurstDoesNotPublishEveryChunk() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 30)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }
        let initialRevision = center.activityRevision

        for _ in 0..<500 {
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Array("streaming output\n".utf8)[...]
            )
        }

        XCTAssertEqual(center.activityRevision, initialRevision)
        XCTAssertEqual(center.agents.first?.status, .working)
    }

    func test_scrollPreventionRequiresExactHookProvenWorkingPane() async throws {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 301)[...]
        )
        center.register(box.source())

        await waitUntil {
            center.agents.first?.status == .working
                && center.lifecycleIntegrationState(
                    agentID: AgentInstanceID(
                        sessionID: box.sessionID,
                        paneID: box.paneID
                    )
                ) == .active
        }

        let prevention = try XCTUnwrap(
            center.scrollPrevention(sessionID: box.sessionID, paneID: box.paneID)
        )
        XCTAssertEqual(prevention.agentID.sessionID, box.sessionID)
        XCTAssertEqual(prevention.agentID.paneID, box.paneID)
        XCTAssertEqual(prevention.agentName, center.agents.first?.name)
        XCTAssertNil(
            center.scrollPrevention(sessionID: box.sessionID, paneID: box.paneID + 1),
            "a working hook in one tmux pane must not block another pane"
        )
        XCTAssertNil(
            center.scrollPrevention(sessionID: UUID(), paneID: box.paneID),
            "a working hook in one session must not block another session"
        )

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "idle", timestamp: 302)[...]
        )
        await waitUntil { center.agents.first?.status == .justFinished }
        XCTAssertNil(
            center.scrollPrevention(sessionID: box.sessionID, paneID: box.paneID)
        )
    }

    func test_scrollPreventionRejectsUnprovenWorkingCard() {
        let sessionID = UUID()
        let agent = AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: 17,
            profileID: SwipePadProfile.builtInCodexCLIID,
            name: "Codex",
            host: "test-host",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 1,
            windowName: "agent",
            status: .working,
            tail: "Working",
            prompt: nil,
            detectedAt: .now,
            statusChangedAt: .now,
            lastOutputAt: .now
        )
        let center = AgentCenter()
        center.installHarnessAgents([agent])

        XCTAssertNotEqual(center.lifecycleIntegrationState(agentID: agent.id), .active)
        XCTAssertNil(
            center.scrollPrevention(sessionID: sessionID, paneID: 17),
            "process or harness status without a trusted lifecycle event must never block scrolling"
        )
    }

    func test_visibleAgentCenterBoundsViewportCapturesDuringSustainedOutput() async {
        let box = AgentTestSourceBox(visibleText: "Thinking…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 31,
            provider: "codex"
        )
        let base = box.source()
        var observationCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: { location in
                observationCount += 1
                return await base.observe(location)
            },
            inspect: base.inspect,
            send: base.send,
            sendKey: base.sendKey,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        await waitUntil { center.agents.first?.status == .working }
        center.setSurfaceDemand(true)
        await waitUntil { observationCount >= 1 }
        observationCount = 0

        for _ in 0..<50 {
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Array("streaming output\n".utf8)[...]
            )
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertGreaterThanOrEqual(observationCount, 1)
        XCTAssertLessThanOrEqual(
            observationCount,
            2,
            "visible cards should capture at a bounded display cadence, not per chunk"
        )
    }

    func test_cursorOwnedComposerWithoutLifecycleIsUnavailable() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n› open it in the browser")
        let base = box.source()
        let composerProbe: @MainActor () -> AgentProbeTarget = {
            AgentProbeTarget(
                location: AgentLocation(
                    sessionID: box.sessionID,
                    hostName: box.hostName,
                    transportLabel: "ssh+tmux",
                    tmuxSessionName: "work",
                    windowID: 3,
                    windowName: "agent",
                    paneID: box.paneID
                ),
                processNames: box.processNames,
                visibleText: box.visibleText,
                currentInputLine: "› open it in the browser",
                bracketedPasteEnabled: false
            )
        }
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: { .success([composerProbe()]) },
            observe: { _ in composerProbe() },
            inspect: { _ in composerProbe() },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.noteOutput(sessionID: box.sessionID, paneID: box.paneID)
        center.register(source)

        await waitUntil { center.agents.first?.status == .unavailable }
    }

    func test_lifecycleOSCScannerHandlesSplitFrame() throws {
        let bytes = Self.lifecycleOSC(state: "working", timestamp: 40)
        var scanner = AgentLifecycleOSCScanner()

        XCTAssertTrue(scanner.feed(bytes.prefix(17)).isEmpty)
        let events = scanner.feed(bytes.dropFirst(17))

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.provider, "claude")
        XCTAssertEqual(event.state, .working)
        XCTAssertEqual(event.timestampNanoseconds, 40)
    }

    func test_lifecycleOSCScannerSkipsANSIHeavyChunksWithoutLosingNextFrame() throws {
        var scanner = AgentLifecycleOSCScanner()
        let ansi = Array(repeating: Array("\u{1B}[38;5;244mspinner\u{1B}[0m\r".utf8), count: 10_000)
            .flatMap { $0 }

        XCTAssertTrue(scanner.feed(ansi[...]).isEmpty)
        XCTAssertEqual(scanner.candidateChunkCount, 0)
        let event = try XCTUnwrap(
            scanner.feed(Self.lifecycleOSC(state: "working", timestamp: 41)[...]).first
        )
        XCTAssertEqual(scanner.candidateChunkCount, 1)
        XCTAssertEqual(event.state, .working)
    }

    /// Regression: curly quotes are E2 80 9C / E2 80 9D — their trailing
    /// bytes are also the C1 OSC/ST codes. Treating 0x9D as an OSC opener
    /// parked the scanner in skip mode after ordinary prose, and the next
    /// genuine agent-state OSC was consumed as skip filler.
    func test_lifecycleOSCScannerIgnoresCurlyQuoteProse() throws {
        var scanner = AgentLifecycleOSCScanner()
        let prose = Array("agent said \u{201C}done\u{201D} just now".utf8)

        XCTAssertTrue(scanner.feed(prose[...]).isEmpty)
        let event = try XCTUnwrap(
            scanner.feed(Self.lifecycleOSC(state: "working", timestamp: 42)[...]).first
        )
        XCTAssertEqual(event.state, .working)
    }

    /// Regression: skip mode is byte-capped. An unterminated foreign OSC
    /// opener (e.g. cat-ing a binary) must not park the scanner in skip for
    /// the rest of the session — after the cap it recovers and the next
    /// agent-state OSC parses.
    func test_lifecycleOSCScannerRecoversFromUnterminatedForeignOSC() throws {
        var scanner = AgentLifecycleOSCScanner()
        var opener = Array("\u{1B}]0;stuck".utf8)
        opener.append(contentsOf: Array(repeating: UInt8(ascii: "a"), count: 17 * 1024))
        let filler = Array(repeating: UInt8(ascii: "b"), count: 17 * 1024)

        XCTAssertTrue(scanner.feed(opener[...]).isEmpty)
        XCTAssertTrue(scanner.feed(filler[...]).isEmpty)
        let event = try XCTUnwrap(
            scanner.feed(Self.lifecycleOSC(state: "working", timestamp: 43)[...]).first
        )
        XCTAssertEqual(event.state, .working)
    }

    func test_lifecycleEventsOverrideComposerAndIgnoreOlderDelivery() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 50)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "idle", timestamp: 49)[...]
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(center.agents.first?.status, .working)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "idle", timestamp: 51)[...]
        )
        await waitUntil { center.agents.first?.status == .justFinished }
    }

    func test_escapeSuppressesSameTurnWorkingHooksForClaudeAndCodex() async {
        for provider in ["claude", "codex"] {
            let box = AgentTestSourceBox(visibleText: "Working")
            box.processNames = [provider]
            box.processIDs = [100]
            let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
            center.register(box.source())
            await waitUntil { center.agents.first != nil }

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 100,
                    event: "UserPromptSubmit",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .working }

            center.noteInput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                bytes: [0x1B, 0x5B, 0x41]
            )
            XCTAssertEqual(
                center.agents.first?.status,
                .working,
                "\(provider) arrow-key escape sequences must not interrupt"
            )

            center.noteInput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                bytes: [0x1B]
            )
            XCTAssertEqual(
                center.agents.first?.status,
                .idle,
                "\(provider) should hide interrupt as soon as Escape is sent"
            )

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "idle",
                    timestamp: 101,
                    event: "Stop",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .justFinished }

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 100,
                    event: "UserPromptSubmit",
                    provider: provider
                )[...]
            )
            center.noteLifecyclePayload(
                sessionID: box.sessionID,
                paneID: box.paneID,
                json: Self.lifecycleJSON(
                    state: "working",
                    timestamp: 102,
                    provider: provider,
                    event: "PreToolUse"
                )
            )
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 103,
                    event: "PostToolUse",
                    provider: provider
                )[...]
            )
            try? await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(
                center.agents.first?.status,
                .justFinished,
                "\(provider) same-turn tool cleanup must not restore interrupt"
            )

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 104,
                    event: "UserPromptSubmit",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .working }
        }
    }

    func test_lateSubagentStopDoesNotOverwriteRootJustFinishedState() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.currentInputLine = "❯ "
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 60,
                event: "UserPromptSubmit"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "idle", timestamp: 61, event: "Stop")[...]
        )
        await waitUntil { center.agents.first?.status == .justFinished }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 62,
                event: "SubagentStop"
            )[...]
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(center.agents.first?.status, .justFinished)
    }

    func test_legacyRetainedSubagentStopUsesLiveComposerInsteadOfStickingWorking() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.currentInputLine = "❯ "
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 63,
            event: "SubagentStop"
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)

        center.register(box.source())

        await waitUntil { center.agents.first?.status == .idle }
    }

    func test_distinctLifecycleTransitionsWithEqualFallbackTimestampAreAccepted() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 52)[...]
        )
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "idle", timestamp: 52)[...]
        )

        await waitUntil { center.agents.first?.status == .justFinished }
    }

    func test_unhookedPromptAnswerReturnsToUnavailableInsteadOfGuessing() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.status == .waitingForInput }

        center.noteInput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            bytes: Array("1\r".utf8)
        )

        XCTAssertEqual(center.agents.first?.status, .unavailable)
    }

    func test_stopFailureStillProvesHookActiveButWrapperExitDoesNot() async {
        let box = AgentTestSourceBox(visibleText: "failure\n❯ ")
        let base = box.source()
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-stop-failure",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        await waitUntil { !center.agents.isEmpty }
        let id = try! XCTUnwrap(center.agents.first?.id)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "unavailable",
                timestamp: 56,
                event: "StopFailure"
            )[...]
        )
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .active }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "unavailable",
                timestamp: 57,
                event: "WrapperExit"
            )[...]
        )
        center.setSurfaceDemand(true)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .installedInactive }
    }

    func test_openingSurfacePromotesLongBackgroundDiscoveryDelay() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var agentStarted = false
        var discoveryCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: {
                discoveryCount += 1
                if agentStarted { return await base.discover() }
                return .success([])
            },
            observe: base.observe,
            inspect: base.inspect,
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        await waitUntil { discoveryCount == 1 && center.agents.isEmpty }

        agentStarted = true
        center.noteOutput(sessionID: box.sessionID, paneID: box.paneID)
        center.setSurfaceDemand(true)

        await waitUntil { center.agents.first?.name == "claude code" }
        XCTAssertGreaterThanOrEqual(discoveryCount, 2)
    }

    func test_retainedLifecycleStateIsRejectedAfterPaneProcessReplacement() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.lifecycleEvent = Self.lifecycleEvent(state: "working", timestamp: 54)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.processNames = []
        center.requestRefresh(sessionID: box.sessionID)
        await waitUntil { center.agents.isEmpty }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 54)[...]
        )

        box.processNames = ["claude"]
        center.requestRefresh(sessionID: box.sessionID)
        await waitUntil { center.agents.first?.status == .unavailable }

        box.processNames = ["codex"]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 55,
            provider: "claude"
        )
        center.requestRefresh(sessionID: box.sessionID)
        await waitUntil { center.agents.first?.name == "codex cli" }
        XCTAssertEqual(center.agents.first?.status, .unavailable)
    }

    func test_sameProviderLifecycleStateIsBoundToProcessPID() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 58,
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.processIDs = [200]
        center.requestRefresh(sessionID: box.sessionID)

        await waitUntil { center.agents.first?.status == .unavailable }
        XCTAssertEqual(center.lifecycleIntegrationState(agentID: center.agents[0].id), .checking)
    }

    func test_newProcessLifecycleEventCanLeadProcessDiscovery() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 59,
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.processIDs = [200]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: 59,
            agentPID: 200
        )
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 59,
                agentPID: 200
            )[...]
        )

        await waitUntil { center.agents.first?.status == .justFinished }
        center.requestRefresh(sessionID: box.sessionID)
        await waitUntil { center.agents.first?.status == .justFinished }
    }

    func test_equalTimestampNewPIDCanReplaceRemovedProcessTombstone() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 62,
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .working }

        box.processNames = []
        box.processIDs = []
        center.requestRefresh(sessionID: box.sessionID)
        await waitUntil { center.agents.isEmpty }

        box.processNames = ["claude"]
        box.processIDs = [200]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "idle",
            timestamp: 62,
            agentPID: 200
        )
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 62,
                agentPID: 200
            )[...]
        )

        await waitUntil { center.agents.first?.status == .justFinished }
    }

    func test_pidlessWorkingEventIsNotAuthoritative() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .unavailable }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            data: Self.lifecycleOSC(state: "working", timestamp: 61, agentPID: nil)[...]
        )

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(center.agents.first?.status, .unavailable)
    }

    func test_realProviderLifecycleSequenceCoversIdleWorkingPermissionResumeAndIdle() async {
        for provider in ["claude", "codex"] {
            let box = AgentTestSourceBox(visibleText: "Ready")
            box.processNames = [provider]
            box.processIDs = [100]
            let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
            let source = box.source()
            center.register(source)
            await waitUntil { center.agents.first != nil }

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "idle",
                    timestamp: 70,
                    event: "SessionStart",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .idle }

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 71,
                    event: "UserPromptSubmit",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .working }

            box.visibleText = provider == "claude" ? Self.claudePrompt : """
            Would you like to run the following command?
            › 1. Yes, proceed (y)
              2. Yes, and don't ask again (p)
              3. No, and tell Codex what to do differently (esc)
            Press enter to confirm or esc to cancel
            """
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "waitingForInput",
                    timestamp: 72,
                    event: "PermissionRequest",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .waitingForInput }

            center.noteInput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                bytes: [0x0D]
            )
            XCTAssertEqual(center.agents.first?.status, .working, provider)

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: 73,
                    event: "PostToolUse",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .working }

            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "idle",
                    timestamp: 74,
                    event: "Stop",
                    provider: provider
                )[...]
            )
            await waitUntil { center.agents.first?.status == .justFinished }
        }
    }

    func test_codexAutoClassifierPermissionHookNeverBecomesWaitingWithoutVisiblePrompt() async {
        let box = AgentTestSourceBox(visibleText: "• Checking command policy…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 80,
                event: "PreToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "waitingForInput",
                timestamp: 81,
                event: "PermissionRequest",
                provider: "codex"
            )[...]
        )

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(center.agents.first?.status, .working)
        XCTAssertNil(center.agents.first?.prompt)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 82,
                event: "PostToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }
    }

    func test_codexAutoClassifierCannotReusePreviouslyParsedPermissionMenu() async {
        let staleMenu = """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """
        let box = AgentTestSourceBox(visibleText: staleMenu)
        box.processNames = ["codex"]
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.prompt != nil }

        box.visibleText += "\n\n• Checking command policy…"
        box.currentInputLine = "• Checking command policy…"
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 83,
                event: "PreToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "waitingForInput",
                timestamp: 84,
                event: "PermissionRequest",
                provider: "codex"
            )[...]
        )

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(center.agents.first?.status, .working)
        XCTAssertNil(center.agents.first?.prompt)
    }

    func test_codexAutoClassifierRejectsStaleMenuWithBlankCursor() async {
        let staleMenu = """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """
        let box = AgentTestSourceBox(visibleText: staleMenu)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = ""
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.prompt != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 85,
                event: "PreToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "waitingForInput",
                timestamp: 86,
                event: "PermissionRequest",
                provider: "codex"
            )[...]
        )
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(center.agents.first?.status, .working)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 87,
                event: "PostToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }
        XCTAssertNil(center.agents.first?.prompt)
    }

    func test_codexSingleKeyApprovalClearsWaitingImmediately() async {
        let box = AgentTestSourceBox(visibleText: """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again (p)
          3. No, and tell Codex what to do differently (esc)
        """)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = ""
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "waitingForInput",
            timestamp: 88,
            provider: "codex",
            event: "PermissionRequest"
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.status == .waitingForInput }

        center.noteInput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            bytes: Array("y".utf8)
        )

        XCTAssertEqual(center.agents.first?.status, .working)
        XCTAssertNil(center.agents.first?.prompt)
    }

    func test_permissionPromptPaintedAfterClassifierDelayIsStillObserved() async {
        let box = AgentTestSourceBox(visibleText: "• Checking command policy…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "• Checking command policy…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "waitingForInput",
                timestamp: 91,
                event: "PermissionRequest",
                provider: "codex"
            )[...]
        )
        try? await Task.sleep(nanoseconds: 2_050_000_000)

        box.visibleText = """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """
        box.currentInputLine = ""
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Array("permission-ui-painted".utf8)[...]
        )

        try? await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(center.agents.first?.status, .waitingForInput)
    }

    func test_activeLifecycleProviderHintAvoidsRediscoveryAndClearsOnExit() async {
        let box = AgentTestSourceBox(visibleText: "• Working…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 86,
            provider: "codex"
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)

        await waitUntil {
            center.activeLifecycleProcessName(
                sessionID: box.sessionID,
                paneID: box.paneID
            ) == "codex"
        }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "unavailable",
                timestamp: 87,
                event: "WrapperExit",
                provider: "codex"
            )[...]
        )

        XCTAssertNil(center.activeLifecycleProcessName(
            sessionID: box.sessionID,
            paneID: box.paneID
        ))
    }

    func test_agentCardRetainsTaskAndLastMeaningfulExcerptAcrossBlankRedraw() async {
        let box = AgentTestSourceBox(visibleText: """
        › Fix activation detection

        gpt-5.6 · ~/projects/tessera
        """)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 85,
            provider: "codex"
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.taskSummary == "Fix activation detection" }
        let originalTail = center.agents.first?.outputTail

        box.visibleText = "\n\n\n"
        center.setSurfaceDemand(true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(center.agents.first?.taskSummary, "Fix activation detection")
        XCTAssertEqual(center.agents.first?.outputTail, originalTail)
    }

    func test_agentCardDoesNotTreatModelBlockquoteAsTask() async {
        let box = AgentTestSourceBox(visibleText: """
        › Fix activation detection
        I found the cause.
        > this is quoted model output
        """)
        box.processNames = ["codex"]
        box.processIDs = [100]
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())

        await waitUntil { center.agents.first != nil }
        XCTAssertEqual(center.agents.first?.taskSummary, "Fix activation detection")
    }

    func test_workingAgentTaskNeverUsesLiveComposerSuggestion() async {
        let box = AgentTestSourceBox(visibleText: """
        › Investigate Agent Center startup detection
        • Explored
          └ AgentCenter.swift
        • Working (35s • esc to interrupt)
        › Improve documentation in @filename
        """)
        box.currentInputLine = "› Improve documentation in @filename"
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 88,
            provider: "codex",
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())

        await waitUntil { center.agents.first?.status == .working }

        XCTAssertEqual(
            center.agents.first?.taskSummary,
            "Investigate Agent Center startup detection"
        )
    }

    func test_workingAgentWithOnlyComposerSuggestionHasNoTaskSummary() async {
        let box = AgentTestSourceBox(
            visibleText: "• Working (3s • esc to interrupt)\n› Improve documentation in @filename"
        )
        box.currentInputLine = "› Improve documentation in @filename"
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 89,
            provider: "codex",
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())

        await waitUntil { center.agents.first?.status == .working }

        XCTAssertNil(center.agents.first?.taskSummary)
    }

    func test_agentCardDropsOldContextWhenProviderProcessIsReplaced() async {
        let box = AgentTestSourceBox(visibleText: "› Old task\nold output")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 89,
            provider: "codex",
            agentPID: 100
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())
        await waitUntil { center.agents.first?.taskSummary == "Old task" }

        box.processIDs = [200]
        box.visibleText = "\n\n"
        box.currentInputLine = ""
        let replacementJSON = Self.lifecycleJSON(
            state: "idle",
            timestamp: 90,
            provider: "codex",
            event: "SessionStart",
            agentPID: 200
        ).replacingOccurrences(
            of: #""sessionId":"provider-session""#,
            with: #""sessionId":"replacement-session""#
        )
        box.lifecycleEvent = AgentLifecycleEvent.decode(json: replacementJSON)
        center.requestRefresh(sessionID: box.sessionID)

        await waitUntil {
            center.agents.first?.providerSessionReference == "replacem"
        }
        XCTAssertNil(center.agents.first?.taskSummary)
        XCTAssertNil(center.agents.first?.outputTail)
    }

    func test_retainedCodexPlanApprovalRequiresVisibleMenuAndExposesProviderSession() async {
        let box = AgentTestSourceBox(visibleText: """
        1. Yes, implement this plan          Switch to Default and start coding.
        2. Yes, clear context and implement  Fresh thread.
        3. No, stay in Plan mode              Continue planning.
        Press enter to confirm or esc to go back
        """)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.lifecycleEvent = AgentLifecycleEvent.decode(json: Self.lifecycleJSON(
            state: "waitingForInput",
            timestamp: 90,
            provider: "codex",
            event: "PermissionRequest",
            agentPID: 100
        ))
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(box.source())

        await waitUntil { center.agents.first?.status == .waitingForInput }
        XCTAssertEqual(center.agents.first?.prompt?.options.count, 3)
        XCTAssertEqual(center.agents.first?.providerSessionReference, "provider")
    }

    func test_codexPlanApprovalPaintedAtStopOverridesIdleLifecycleState() async {
        let box = AgentTestSourceBox(visibleText: "• Planning…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "• Planning…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.setSurfaceDemand(true)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 92,
                event: "UserPromptSubmit",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        box.visibleText = """
        1. Yes, implement this plan          Switch to Default and start coding.
        2. Yes, clear context and implement  Fresh thread.
        3. No, stay in Plan mode             Continue planning.
        Press enter to confirm or esc to go back
        """
        box.currentInputLine = "Press enter to confirm or esc to go back"
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 93,
                event: "Stop",
                provider: "codex"
            )[...]
        )

        await waitUntil { center.agents.first?.status == .waitingForInput }
        XCTAssertEqual(center.agents.first?.prompt?.options.count, 3)
    }

    func test_codexRateLimitModalPaintedAtStopOverridesIdleLifecycleState() async {
        let box = AgentTestSourceBox(visibleText: "• Finishing…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "• Finishing…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.setSurfaceDemand(true)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 94,
                event: "UserPromptSubmit",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        box.visibleText = """
        Approaching rate limits
        Switch to gpt-5.4-mini for lower credit usage?
        › 1. Switch to gpt-5.4-mini
          2. Keep current model
          3. Keep current model (never show again)
        Press enter to confirm or esc to go back
        """
        box.currentInputLine = ""
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 95,
                event: "Stop",
                provider: "codex"
            )[...]
        )

        await waitUntil { center.agents.first?.status == .waitingForInput }
        XCTAssertEqual(center.agents.first?.prompt?.options.count, 3)
    }

    func test_codexPlanApprovalPaintedAfterInitialStopCaptureIsObservedOffSurface() async {
        let box = AgentTestSourceBox(visibleText: "• Finishing plan…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = "• Finishing plan…"
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 96,
                event: "Stop",
                provider: "codex"
            )[...]
        )
        try? await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(center.agents.first?.status, .justFinished)

        box.visibleText = """
        1. Yes, implement this plan          Switch to Default and start coding.
        2. Yes, clear context and implement  Fresh thread.
        3. No, stay in Plan mode             Continue planning.
        Press enter to confirm or esc to go back
        """
        box.currentInputLine = "Press enter to confirm or esc to go back"
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Array("plan-ui-painted".utf8)[...]
        )

        await waitUntil { center.agents.first?.status == .waitingForInput }
        XCTAssertEqual(center.agents.first?.prompt?.options.count, 3)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(center.sortedUnreadAttentions.map(\.kind), [.needsInput])
    }

    func test_staleCodexMenuCannotOverrideNewerStopCompletionBoundary() async {
        let staleMenu = """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """
        let box = AgentTestSourceBox(visibleText: staleMenu)
        box.processNames = ["codex"]
        box.processIDs = [100]
        box.currentInputLine = ""
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.setSurfaceDemand(true)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.prompt != nil }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "working",
                timestamp: 94,
                event: "PostToolUse",
                provider: "codex"
            )[...]
        )
        await waitUntil { center.agents.first?.status == .working }

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 95,
                event: "Stop",
                provider: "codex"
            )[...]
        )

        await waitUntil { center.agents.first?.status == .justFinished }
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(center.agents.first?.status, .justFinished)
        XCTAssertNil(center.agents.first?.prompt)
    }

    func test_negativePromptAnswerTransitionsIdleUntilNextLifecycleEvent() async {
        let box = AgentTestSourceBox(visibleText: Self.claudePrompt)
        box.lifecycleEvent = Self.lifecycleEvent(state: "waitingForInput", timestamp: 60)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.status == .waitingForInput }

        center.noteInput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            bytes: Array("3\r".utf8)
        )

        XCTAssertEqual(center.agents.first?.status, .idle)
        XCTAssertNil(center.agents.first?.prompt)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(state: "working", timestamp: 61)[...]
        )
        await waitUntil { center.agents.first?.status == .working }
    }

    func test_bareReturnOnHighlightedNegativePromptTransitionsIdle() async {
        let deniedPrompt = """
        Do you want to proceed?
          1. Yes
          2. Yes, and always allow
        ❯ 3. No
        """
        let box = AgentTestSourceBox(visibleText: deniedPrompt)
        box.lifecycleEvent = Self.lifecycleEvent(state: "waitingForInput", timestamp: 70)
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        let source = box.source()
        center.register(source)
        await waitUntil { center.agents.first?.status == .waitingForInput }

        center.noteInput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            bytes: [0x0D]
        )

        XCTAssertEqual(center.agents.first?.status, .idle)
        XCTAssertNil(center.agents.first?.prompt)
    }

    func test_lifecycleIntegrationDistinguishesInstalledInactiveFromActiveAndCachesProbe() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-a",
            probeLifecycleIntegration: {
                probeCount += 1
                return .current
            },
            installLifecycleIntegration: {},
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.setSurfaceDemand(true)
        await waitUntil { center.agents.first?.status == .unavailable }
        let id = try! XCTUnwrap(center.agents.first?.id)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .installedInactive }

        XCTAssertEqual(probeCount, 1)
        center.requestRefresh(sessionID: box.sessionID)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(probeCount, 1)

        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(state: "working", timestamp: 80)[...]
        )
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .active }
    }

    func test_currentTerminalIntegrationPolicyCoversShellAgentAndOtherProgram() {
        let location = AgentLocation(
            sessionID: UUID(),
            hostName: "test-host",
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "shell",
            paneID: 7
        )
        func target(
            _ foreground: AgentIntegrationForeground,
            shellActive: Bool? = false,
            agentActive: Bool = false
        ) -> AgentCurrentIntegrationTarget {
            AgentCurrentIntegrationTarget(
                location: location,
                foreground: foreground,
                processIDs: [],
                shellIntegrationActive: shellActive,
                agentIntegrationActive: agentActive
            )
        }

        let missingAtShell = AgentIntegrationWarningState.resolved(
            installation: .missing,
            target: target(.shell)
        )
        XCTAssertEqual(missingAtShell.kind, .notInstalled)
        XCTAssertEqual(missingAtShell.action, .installAndApply)
        XCTAssertEqual(
            missingAtShell.effectiveAction(for: .installOnly),
            .installAndApply
        )

        let installedAtInactiveShell = AgentIntegrationWarningState.resolved(
            installation: .current,
            target: target(.shell)
        )
        XCTAssertEqual(installedAtInactiveShell.kind, .inactiveShell)
        XCTAssertEqual(installedAtInactiveShell.action, .apply)
        XCTAssertEqual(
            installedAtInactiveShell.effectiveAction(for: .installOnly),
            .apply
        )
        XCTAssertEqual(installedAtInactiveShell.secondaryAction, .persistAndApply)
        XCTAssertEqual(
            installedAtInactiveShell.secondaryActionLabel,
            "Enable automatically"
        )

        XCTAssertEqual(
            AgentIntegrationWarningState.resolved(
                installation: .current,
                target: target(.shell, shellActive: true)
            ),
            .ready
        )

        let unhookedAgent = AgentIntegrationWarningState.resolved(
            installation: .current,
            target: target(.agent)
        )
        XCTAssertEqual(unhookedAgent.kind, .insideAgent)
        XCTAssertEqual(unhookedAgent.title, "Agent lifecycle hook inactive")
        XCTAssertNil(unhookedAgent.action)
        XCTAssertEqual(
            AgentIntegrationWarningState.resolved(
                installation: .current,
                target: target(.agent, agentActive: true)
            ),
            .ready
        )

        let missingInsideAgent = AgentIntegrationWarningState.resolved(
            installation: .missing,
            target: target(.agent)
        )
        XCTAssertEqual(missingInsideAgent.kind, .notInstalled)
        XCTAssertEqual(missingInsideAgent.action, .installOnly)
        XCTAssertEqual(
            missingInsideAgent.effectiveAction(for: .installAndApply),
            .installOnly
        )

        let outdatedInsideAgent = AgentIntegrationWarningState.resolved(
            installation: .outdated(version: 5),
            target: target(.agent)
        )
        XCTAssertEqual(outdatedInsideAgent.kind, .outdated)
        XCTAssertEqual(outdatedInsideAgent.action, .installOnly)

        let otherProgram = AgentIntegrationWarningState.resolved(
            installation: .current,
            target: target(.other)
        )
        XCTAssertEqual(otherProgram.kind, .busyProgram)
        XCTAssertFalse(otherProgram.showsWarning)
        XCTAssertNil(otherProgram.action)

        let failedShellProbe = AgentIntegrationWarningState.resolved(
            installation: .current,
            target: target(.shell, shellActive: nil)
        )
        XCTAssertEqual(failedShellProbe.kind, .unavailable)
        XCTAssertEqual(failedShellProbe.action, .retry)

        let unsupportedShell = AgentIntegrationWarningState.resolved(
            installation: .current,
            target: target(.unsupportedShell)
        )
        XCTAssertEqual(unsupportedShell.kind, .unsupportedShell)
        XCTAssertTrue(unsupportedShell.showsWarning)
        XCTAssertNil(unsupportedShell.action)
    }

    func test_currentShellRepairInstallsThenAppliesAndClearsWarning() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var installation = AgentLifecycleHostInstallation.missing
        var shellActive = false
        var installCount = 0
        var applyCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "repair-host",
            probeLifecycleIntegration: { installation },
            installLifecycleIntegration: {
                installCount += 1
                installation = .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [],
                    shellIntegrationActive: shellActive,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                applyCount += 1
                shellActive = true
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .notInstalled
        }

        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }

        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(applyCount, 1)
    }

    func test_installConfirmationFollowsAgentExitAndCompletesOneRepair() async {
        func exercise(
            initialInstallation: AgentLifecycleHostInstallation,
            cacheKey: String
        ) async {
            let box = AgentTestSourceBox(visibleText: "agent")
            let base = box.source()
            let location = AgentLocation(
                sessionID: box.sessionID,
                hostName: box.hostName,
                transportLabel: "ssh+tmux",
                tmuxSessionName: "work",
                windowID: 3,
                windowName: "agent",
                paneID: box.paneID
            )
            var installation = initialInstallation
            var foreground = AgentIntegrationForeground.agent
            var shellActive = false
            var installCount = 0
            var applyCount = 0
            let source = AgentSessionSource(
                registrationID: base.registrationID,
                sessionID: base.sessionID,
                discover: base.discover,
                observe: base.observe,
                inspect: base.inspect,
                lifecycleIntegrationCacheKey: cacheKey,
                probeLifecycleIntegration: { installation },
                installLifecycleIntegration: {
                    installCount += 1
                    installation = .current
                },
                inspectCurrentIntegration: {
                    AgentCurrentIntegrationTarget(
                        location: location,
                        foreground: foreground,
                        processIDs: foreground == .shell ? [93416] : [200],
                        shellIntegrationActive: foreground == .shell ? shellActive : false,
                        agentIntegrationActive: false
                    )
                },
                applyLifecycleIntegrationToCurrentShell: { target in
                    XCTAssertEqual(target.processIDs, [93416])
                    applyCount += 1
                    shellActive = true
                    return true
                },
                send: base.send,
                jump: base.jump
            )
            let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
            center.register(source)
            center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
            await waitUntil {
                center.currentIntegrationState(sessionID: box.sessionID).action == .installOnly
            }

            // Reproduces the real log: the warning was opened inside an agent,
            // but that agent had exited to a shell before confirmation.
            foreground = .shell
            center.fixCurrentIntegration(
                sessionID: box.sessionID,
                action: .installOnly
            )
            await waitUntil {
                center.currentIntegrationState(sessionID: box.sessionID) == .ready
            }

            XCTAssertEqual(installCount, 1)
            XCTAssertEqual(applyCount, 1)
        }

        await exercise(
            initialInstallation: .missing,
            cacheKey: "missing-agent-to-shell-repair"
        )
        await exercise(
            initialInstallation: .outdated(version: 6),
            cacheKey: "outdated-agent-to-shell-repair"
        )
    }

    func test_installOnlyConfirmationActivatesIfAgentExitsDuringInstall() async {
        let box = AgentTestSourceBox(visibleText: "agent")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: box.paneID
        )
        var installation = AgentLifecycleHostInstallation.missing
        var foreground = AgentIntegrationForeground.agent
        var shellActive = false
        var installCount = 0
        var installContinuation: CheckedContinuation<Void, Never>?
        var applyCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "agent-exits-during-install",
            probeLifecycleIntegration: { installation },
            installLifecycleIntegration: {
                installCount += 1
                await withCheckedContinuation { continuation in
                    installContinuation = continuation
                }
                installation = .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: foreground == .shell ? [93416] : [200],
                    shellIntegrationActive: foreground == .shell ? shellActive : false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { target in
                XCTAssertEqual(target.foreground, .shell)
                XCTAssertEqual(target.processIDs, [93416])
                applyCount += 1
                shellActive = true
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).action == .installOnly
        }

        center.fixCurrentIntegration(
            sessionID: box.sessionID,
            action: .installOnly
        )
        await waitUntil { installCount == 1 && installContinuation != nil }
        foreground = .shell
        installContinuation?.resume()
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }

        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(applyCount, 1)
    }

    func test_installAndApplyConfirmationDowngradesIfAgentStarts() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var installation = AgentLifecycleHostInstallation.missing
        var foreground = AgentIntegrationForeground.shell
        var installCount = 0
        var installContinuation: CheckedContinuation<Void, Never>?
        var applyCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "shell-to-agent-install-repair",
            probeLifecycleIntegration: { installation },
            installLifecycleIntegration: {
                installCount += 1
                await withCheckedContinuation { continuation in
                    installContinuation = continuation
                }
                installation = .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: foreground == .agent ? [200] : [93416],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                applyCount += 1
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).action == .installAndApply
        }

        center.fixCurrentIntegration(
            sessionID: box.sessionID,
            action: .installAndApply
        )
        await waitUntil { installCount == 1 && installContinuation != nil }
        foreground = .agent
        installContinuation?.resume()
        await waitUntil {
            installCount == 1
                && center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        XCTAssertEqual(applyCount, 0)
    }

    func test_currentShellPersistentActivationUsesDedicatedVerifiedAction() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 4,
            windowName: "zsh",
            paneID: 25
        )
        var shellActive = false
        var applyCount = 0
        var persistCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "persistent-shell-host",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [93416],
                    shellIntegrationActive: shellActive,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                applyCount += 1
                return false
            },
            persistLifecycleIntegrationInCurrentShell: { _ in
                persistCount += 1
                shellActive = true
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .inactiveShell
        }

        center.fixCurrentIntegration(
            sessionID: box.sessionID,
            action: .persistAndApply
        )
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }

        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(applyCount, 0)
    }

    func test_newTmuxShellConvergesAfterItsStartupFileFinishes() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 4,
            windowName: "zsh",
            paneID: 25
        )
        var inspectionCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "new-shell-startup-race",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [93416],
                    shellIntegrationActive: inspectionCount >= 2,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            reason: "surface-change"
        )

        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }
        XCTAssertEqual(inspectionCount, 2)
    }

    func test_currentShellRepairsShareOneInstallForTheSameHostRoute() async {
        let firstBox = AgentTestSourceBox(visibleText: "$ ")
        let secondBox = AgentTestSourceBox(visibleText: "$ ")
        var installation = AgentLifecycleHostInstallation.missing
        var firstShellActive = false
        var secondShellActive = false
        var installCount = 0
        var installContinuation: CheckedContinuation<Void, Never>?

        func source(
            for box: AgentTestSourceBox,
            shellActive: @escaping () -> Bool,
            markShellActive: @escaping () -> Void
        ) -> AgentSessionSource {
            let base = box.source()
            let location = AgentLocation(
                sessionID: box.sessionID,
                hostName: box.hostName,
                transportLabel: "ssh",
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            )
            return AgentSessionSource(
                registrationID: base.registrationID,
                sessionID: base.sessionID,
                discover: base.discover,
                observe: base.observe,
                inspect: base.inspect,
                lifecycleIntegrationCacheKey: "shared-repair-host",
                probeLifecycleIntegration: { installation },
                installLifecycleIntegration: {
                    installCount += 1
                    await withCheckedContinuation { continuation in
                        installContinuation = continuation
                    }
                    installation = .current
                },
                inspectCurrentIntegration: {
                    AgentCurrentIntegrationTarget(
                        location: location,
                        foreground: .shell,
                        processIDs: [100],
                        shellIntegrationActive: shellActive(),
                        agentIntegrationActive: false
                    )
                },
                applyLifecycleIntegrationToCurrentShell: { _ in
                    markShellActive()
                    return true
                },
                send: base.send,
                jump: base.jump
            )
        }

        let firstSource = source(
            for: firstBox,
            shellActive: { firstShellActive },
            markShellActive: { firstShellActive = true }
        )
        let secondSource = source(
            for: secondBox,
            shellActive: { secondShellActive },
            markShellActive: { secondShellActive = true }
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(firstSource)
        center.register(secondSource)
        center.requestCurrentIntegrationRefresh(sessionID: firstBox.sessionID)
        center.requestCurrentIntegrationRefresh(sessionID: secondBox.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: firstBox.sessionID).kind == .notInstalled
                && center.currentIntegrationState(sessionID: secondBox.sessionID).kind == .notInstalled
        }

        center.fixCurrentIntegration(sessionID: firstBox.sessionID)
        center.fixCurrentIntegration(sessionID: secondBox.sessionID)
        await waitUntil { installCount == 1 && installContinuation != nil }
        installContinuation?.resume()
        await waitUntil {
            center.currentIntegrationState(sessionID: firstBox.sessionID) == .ready
                && center.currentIntegrationState(sessionID: secondBox.sessionID) == .ready
        }

        XCTAssertEqual(installCount, 1)
        XCTAssertTrue(firstShellActive)
        XCTAssertTrue(secondShellActive)
    }

    func test_currentRepairRechecksAndNeverMutatesAfterAgentStarts() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var foreground = AgentIntegrationForeground.shell
        var installCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "agent-race-host",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: { installCount += 1 },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: [],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in XCTFail("must not apply inside agent"); return false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .inactiveShell
        }

        foreground = .agent
        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        XCTAssertEqual(installCount, 0)
    }

    func test_currentAgentWarningRejectsLifecycleEventFromPriorPID() async {
        let box = AgentTestSourceBox(visibleText: "working")
        box.processIDs = [100]
        box.lifecycleEvent = Self.lifecycleEvent(
            state: "working",
            timestamp: 81,
            agentPID: 100
        )
        let base = box.source()
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "stale-current-agent-pid",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh+tmux",
                        tmuxSessionName: "work",
                        windowID: 3,
                        windowName: "agent",
                        paneID: box.paneID
                    ),
                    foreground: .agent,
                    processIDs: [200],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                XCTFail("must not apply inside an agent")
                return false
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        await waitUntil { center.agents.first?.status == .working }

        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        XCTAssertEqual(
            center.currentIntegrationState(sessionID: box.sessionID).title,
            "Agent lifecycle hook inactive"
        )
    }

    func test_currentAgentInstallWritesHostFilesWithoutInjectingInput() async {
        let box = AgentTestSourceBox(visibleText: "agent")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: box.paneID
        )
        var installation = AgentLifecycleHostInstallation.missing
        var installCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "install-inside-agent-host",
            probeLifecycleIntegration: { installation },
            installLifecycleIntegration: {
                installCount += 1
                installation = .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .agent,
                    processIDs: [200],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                XCTFail("install-only must not write into the running agent")
                return false
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).action == .installOnly
        }

        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil {
            installCount == 1
                && center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        XCTAssertEqual(
            center.currentIntegrationState(sessionID: box.sessionID).title,
            "Agent lifecycle hook inactive"
        )
    }

    func test_inactiveAgentDiagnosticsProbeOncePerProcessIncarnation() async {
        let box = AgentTestSourceBox(visibleText: "agent")
        let base = box.source()
        var processIDs: Set<Int> = [200]
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "inactive-agent-diagnostic-host",
            probeLifecycleIntegration: {
                probeCount += 1
                return .current
            },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh+tmux",
                        tmuxSessionName: "work",
                        windowID: 3,
                        windowName: "agent",
                        paneID: box.paneID
                    ),
                    foreground: .agent,
                    processIDs: processIDs,
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: nil,
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            probeCount == 1
                && center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true,
            reason: "same-process"
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(probeCount, 1)

        processIDs = [201]
        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true,
            reason: "new-process"
        )
        await waitUntil { probeCount == 2 }
    }

    func test_currentPaneChangeSupersedesDelayedReadinessProbe() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "shell",
            paneID: box.paneID
        )
        var inspectionCount = 0
        var firstInspection: CheckedContinuation<AgentCurrentIntegrationTarget?, Never>?
        let activeTarget = AgentCurrentIntegrationTarget(
            location: location,
            foreground: .shell,
            processIDs: [200],
            shellIntegrationActive: true,
            agentIntegrationActive: false
        )
        let inactiveTarget = AgentCurrentIntegrationTarget(
            location: location,
            foreground: .shell,
            processIDs: [100],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "current-pane-supersede",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                if inspectionCount == 1 {
                    return await withCheckedContinuation { continuation in
                        firstInspection = continuation
                    }
                }
                return activeTarget
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { firstInspection != nil }

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }

        firstInspection?.resume(returning: inactiveTarget)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .ready)
    }

    func test_hiddenCurrentInspectionDoesNotStartLaterHostProbe() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionContinuation: CheckedContinuation<AgentCurrentIntegrationTarget?, Never>?
        var probeCount = 0
        let target = AgentCurrentIntegrationTarget(
            location: AgentLocation(
                sessionID: box.sessionID,
                hostName: box.hostName,
                transportLabel: "mosh",
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            ),
            foreground: .shell,
            processIDs: [100],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "hidden-current-probe",
            probeLifecycleIntegration: {
                probeCount += 1
                return .current
            },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                await withCheckedContinuation { continuation in
                    inspectionContinuation = continuation
                }
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { inspectionContinuation != nil }

        center.cancelCurrentIntegrationRequest(sessionID: box.sessionID)
        inspectionContinuation?.resume(returning: target)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(probeCount, 0)
    }

    func test_plainMoshCurrentIntegrationRequiresExplicitSideChannelCheck() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        let target = AgentCurrentIntegrationTarget(
            location: AgentLocation(
                sessionID: box.sessionID,
                hostName: box.hostName,
                transportLabel: "mosh",
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            ),
            foreground: .shell,
            processIDs: [100],
            shellIntegrationActive: true,
            agentIntegrationActive: false
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "plain-mosh-explicit-check",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            automaticallyInspectCurrentIntegration: { false },
            inspectCurrentIntegration: {
                inspectionCount += 1
                return target
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .manualCheckRequired)
        XCTAssertEqual(inspectionCount, 0)

        center.fixCurrentIntegration(sessionID: box.sessionID)
        XCTAssertEqual(
            center.currentIntegrationState(sessionID: box.sessionID),
            .checkingOnDemand
        )
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }
        XCTAssertEqual(inspectionCount, 1)

        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .ready)
        XCTAssertEqual(inspectionCount, 1)
    }

    func test_commandSubmissionRefreshesVimInheritedIntegrationQuickly() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var foreground = AgentIntegrationForeground.shell
        var shellActive = false
        var inspectionCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "activity-current-refresh",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: [100],
                    shellIntegrationActive: shellActive,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .inactiveShell
        }

        foreground = .other
        shellActive = true
        center.noteInput(
            sessionID: box.sessionID,
            paneID: nil,
            registrationID: source.registrationID,
            bytes: Array("vim\r".utf8)
        )

        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID) == .ready
        }
        XCTAssertEqual(inspectionCount, 2)
    }

    func test_commandActivityDoesNotReprobeAnAlreadyReadyIntegration() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "activity-coalescing",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh",
                        tmuxSessionName: nil,
                        windowID: nil,
                        windowName: nil,
                        paneID: nil
                    ),
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: true,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }

        for _ in 0..<100 {
            center.noteInput(
                sessionID: box.sessionID,
                paneID: nil,
                registrationID: source.registrationID,
                bytes: [0x0D]
            )
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(inspectionCount, 1)
    }

    func test_providerExitImmediatelyRechecksPreviouslyReadyTopBar() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        box.processNames = ["claude"]
        box.processIDs = [100]
        let base = box.source()
        var foreground = AgentIntegrationForeground.agent
        var agentActive = true
        var inspectionCount = 0
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: box.paneID
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "provider-exit-current-refresh",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: [100],
                    shellIntegrationActive: foreground == .shell ? false : nil,
                    agentIntegrationActive: agentActive
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }

        foreground = .shell
        agentActive = false
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "unavailable",
                timestamp: 201,
                event: "WrapperExit",
                provider: "claude",
                agentPID: nil
            )[...]
        )

        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .inactiveShell
        }
        XCTAssertGreaterThanOrEqual(inspectionCount, 2)
    }

    func test_toolLifecycleBurstsDoNotReinspectAlreadyReadyForegroundIntegration() async {
        let box = AgentTestSourceBox(visibleText: "• Working…")
        box.processNames = ["codex"]
        box.processIDs = [100]
        let base = box.source()
        var inspectionCount = 0
        var observationCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: { location in
                observationCount += 1
                return await base.observe(location)
            },
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "lifecycle-ready-no-recheck",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh+tmux",
                        tmuxSessionName: "work",
                        windowID: 3,
                        windowName: "agent",
                        paneID: box.paneID
                    ),
                    foreground: .agent,
                    processIDs: [100],
                    shellIntegrationActive: false,
                    agentIntegrationActive: true
                )
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }

        for index in 0..<40 {
            center.noteOutput(
                sessionID: box.sessionID,
                paneID: box.paneID,
                registrationID: source.registrationID,
                data: Self.lifecycleOSC(
                    state: "working",
                    timestamp: UInt64(100 + index),
                    event: index.isMultiple(of: 2) ? "PreToolUse" : "PostToolUse",
                    provider: "codex"
                )[...]
            )
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(inspectionCount, 1)
        XCTAssertEqual(observationCount, 0)
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .ready)
    }

    func test_transientCurrentShellProbeFailureRetriesWithoutUserAction() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "transient-current-shell-probe",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                return AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh",
                        tmuxSessionName: nil,
                        windowID: nil,
                        windowName: nil,
                        paneID: nil
                    ),
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: inspectionCount == 1 ? nil : true,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)

        await waitUntil { inspectionCount >= 2 }
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }
        XCTAssertEqual(inspectionCount, 2)
    }

    func test_transientCurrentTargetFailureRetriesWithoutUserAction() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "transient-current-target",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                guard inspectionCount > 1 else { return nil }
                return AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: box.sessionID,
                        hostName: box.hostName,
                        transportLabel: "ssh",
                        tmuxSessionName: nil,
                        windowID: nil,
                        windowName: nil,
                        paneID: nil
                    ),
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: true,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)

        await waitUntil { inspectionCount >= 2 }
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }
        XCTAssertEqual(inspectionCount, 2)
    }

    func test_transientCurrentTargetFailureKeepsLastReadyStateUntilRecovery() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        var targetReadable = true
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "shell",
            paneID: box.paneID
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "preserve-ready-on-render-race",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                guard targetReadable else { return nil }
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: true,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }

        targetReadable = false
        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )
        await waitUntil { inspectionCount == 2 }
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .ready)
        XCTAssertNil(center.currentIntegrationState(sessionID: box.sessionID).action)

        targetReadable = true
        await waitUntil { inspectionCount >= 3 }
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }
    }

    func test_persistentCurrentTargetFailureDoesNotPreserveStaleInsideAgentWarning() async {
        let box = AgentTestSourceBox(visibleText: "Ready\n\n❯ ")
        let base = box.source()
        var targetReadable = true
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: box.paneID
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "bounded-stale-current-target",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                guard targetReadable else { return nil }
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .agent,
                    processIDs: [100],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            currentIntegrationTargetRetryDelaysNanoseconds: [1_000_000, 1_000_000]
        )
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .insideAgent
        }

        targetReadable = false
        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )

        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .unavailable
        }
        XCTAssertEqual(
            center.currentIntegrationState(sessionID: box.sessionID).action,
            .retry
        )
    }

    func test_pidBoundLifecycleEventSupersedesStalledPeriodicIntegrationRead() async {
        let box = AgentTestSourceBox(visibleText: "Ready\n\n❯ ")
        box.processIDs = [100]
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: box.paneID
        )
        var inspectionCount = 0
        var stalledInspection: CheckedContinuation<AgentCurrentIntegrationTarget?, Never>?
        var foreground = AgentIntegrationForeground.shell
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "lifecycle-preempts-stalled-read",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                if inspectionCount == 2 {
                    return await withCheckedContinuation { continuation in
                        stalledInspection = continuation
                    }
                }
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: [100],
                    shellIntegrationActive: foreground == .shell,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )
        await waitUntil { stalledInspection != nil }
        foreground = .agent
        center.noteOutput(
            sessionID: box.sessionID,
            paneID: box.paneID,
            registrationID: source.registrationID,
            data: Self.lifecycleOSC(
                state: "idle",
                timestamp: 200,
                event: "SessionStart",
                provider: "claude",
                agentPID: 100
            )[...]
        )

        await waitUntil { inspectionCount == 3 }
        XCTAssertEqual(center.currentIntegrationState(sessionID: box.sessionID), .ready)
        stalledInspection?.resume(returning: nil)
    }

    func test_returnRefreshWaitsForOverlappingSlowInspection() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        var inspectionCount = 0
        var firstInspection: CheckedContinuation<AgentCurrentIntegrationTarget?, Never>?
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "slow-return-current-refresh",
            probeLifecycleIntegration: { .current },
            installLifecycleIntegration: {},
            inspectCurrentIntegration: {
                inspectionCount += 1
                if inspectionCount == 1 {
                    return await withCheckedContinuation { continuation in
                        firstInspection = continuation
                    }
                }
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .other,
                    processIDs: [101],
                    shellIntegrationActive: true,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil { firstInspection != nil }

        center.noteInput(
            sessionID: box.sessionID,
            paneID: nil,
            registrationID: source.registrationID,
            bytes: [0x0D]
        )
        // Exceed the former 450ms cutoff so this proves the Return-triggered
        // refresh is queued until the overlapping read actually completes.
        try? await Task.sleep(nanoseconds: 700_000_000)
        firstInspection?.resume(returning: AgentCurrentIntegrationTarget(
            location: location,
            foreground: .shell,
            processIDs: [100],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        ))

        await waitUntil { inspectionCount == 2 }
        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }
    }

    func test_userRepairSupersedesInFlightReadInsteadOfDroppingClick() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var inspectionCount = 0
        var installCount = 0
        var installed = false
        var shellActive = false
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "repair-supersedes-read",
            probeLifecycleIntegration: { installed ? .current : .missing },
            installLifecycleIntegration: {
                installCount += 1
                installed = true
            },
            inspectCurrentIntegration: {
                inspectionCount += 1
                if inspectionCount == 2 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: shellActive,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                shellActive = true
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .notInstalled
        }

        center.requestCurrentIntegrationRefresh(
            sessionID: box.sessionID,
            supersedeCurrent: true
        )
        await waitUntil { inspectionCount == 2 }
        center.fixCurrentIntegration(sessionID: box.sessionID)

        await waitUntil { center.currentIntegrationState(sessionID: box.sessionID) == .ready }
        XCTAssertEqual(installCount, 1)
    }

    func test_currentIntegrationChecksShareOneProbeForTheSameHostRoute() async {
        let firstBox = AgentTestSourceBox(visibleText: "$ ")
        let secondBox = AgentTestSourceBox(visibleText: "$ ")
        var probeCount = 0
        var probeContinuation: CheckedContinuation<AgentLifecycleHostInstallation, Never>?

        func source(for box: AgentTestSourceBox) -> AgentSessionSource {
            let base = box.source()
            return AgentSessionSource(
                registrationID: base.registrationID,
                sessionID: base.sessionID,
                discover: base.discover,
                observe: base.observe,
                inspect: base.inspect,
                lifecycleIntegrationCacheKey: "shared-probe-host",
                probeLifecycleIntegration: {
                    probeCount += 1
                    return await withCheckedContinuation { continuation in
                        probeContinuation = continuation
                    }
                },
                installLifecycleIntegration: {},
                inspectCurrentIntegration: {
                    AgentCurrentIntegrationTarget(
                        location: AgentLocation(
                            sessionID: box.sessionID,
                            hostName: box.hostName,
                            transportLabel: "ssh",
                            tmuxSessionName: nil,
                            windowID: nil,
                            windowName: nil,
                            paneID: nil
                        ),
                        foreground: .shell,
                        processIDs: [100],
                        shellIntegrationActive: true,
                        agentIntegrationActive: false
                    )
                },
                applyLifecycleIntegrationToCurrentShell: { _ in false },
                send: base.send,
                jump: base.jump
            )
        }

        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source(for: firstBox))
        center.register(source(for: secondBox))
        center.requestCurrentIntegrationRefresh(sessionID: firstBox.sessionID)
        center.requestCurrentIntegrationRefresh(sessionID: secondBox.sessionID)
        await waitUntil { probeCount == 1 && probeContinuation != nil }

        probeContinuation?.resume(returning: .current)
        await waitUntil {
            center.currentIntegrationState(sessionID: firstBox.sessionID) == .ready
                && center.currentIntegrationState(sessionID: secondBox.sessionID) == .ready
        }

        XCTAssertEqual(probeCount, 1)
    }

    func test_routeProbeRetriesHealthyCarrierWhenInitiatingSourceClosesAndFails() async {
        let firstBox = AgentTestSourceBox(visibleText: "$ ")
        let secondBox = AgentTestSourceBox(visibleText: "$ ")
        var probeCount = 0
        var failedProbeContinuation: CheckedContinuation<Void, Never>?

        func source(
            for box: AgentTestSourceBox,
            probe: @escaping @MainActor () async throws -> AgentLifecycleHostInstallation
        ) -> AgentSessionSource {
            let base = box.source()
            return AgentSessionSource(
                registrationID: base.registrationID,
                sessionID: base.sessionID,
                discover: base.discover,
                observe: base.observe,
                inspect: base.inspect,
                lifecycleIntegrationCacheKey: "surviving-route-probe-host",
                probeLifecycleIntegration: probe,
                installLifecycleIntegration: {},
                inspectCurrentIntegration: {
                    AgentCurrentIntegrationTarget(
                        location: AgentLocation(
                            sessionID: box.sessionID,
                            hostName: box.hostName,
                            transportLabel: "ssh",
                            tmuxSessionName: nil,
                            windowID: nil,
                            windowName: nil,
                            paneID: nil
                        ),
                        foreground: .shell,
                        processIDs: [100],
                        shellIntegrationActive: true,
                        agentIntegrationActive: false
                    )
                },
                applyLifecycleIntegrationToCurrentShell: { _ in false },
                send: base.send,
                jump: base.jump
            )
        }

        let firstSource = source(for: firstBox) {
            probeCount += 1
            await withCheckedContinuation { continuation in
                failedProbeContinuation = continuation
            }
            throw NSError(domain: "closed initiating carrier", code: 1)
        }
        let secondSource = source(for: secondBox) {
            probeCount += 1
            return .current
        }
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(firstSource)
        center.register(secondSource)
        center.requestCurrentIntegrationRefresh(sessionID: firstBox.sessionID)
        await waitUntil { probeCount == 1 && failedProbeContinuation != nil }
        center.requestCurrentIntegrationRefresh(sessionID: secondBox.sessionID)

        center.unregister(
            sessionID: firstSource.sessionID,
            registrationID: firstSource.registrationID
        )
        failedProbeContinuation?.resume()

        await waitUntil {
            center.currentIntegrationState(sessionID: secondBox.sessionID) == .ready
        }
        XCTAssertEqual(probeCount, 2)
    }

    func test_cancelledInstallCannotApplyToShellAfterCenterDisables() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var installStarted = false
        var installContinuation: CheckedContinuation<Void, Never>?
        var applyCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "cancelled-current-install",
            probeLifecycleIntegration: { .missing },
            installLifecycleIntegration: {
                installStarted = true
                await withCheckedContinuation { continuation in
                    installContinuation = continuation
                }
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                applyCount += 1
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .notInstalled
        }

        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil { installStarted && installContinuation != nil }
        center.setEnabled(false)
        installContinuation?.resume()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(applyCount, 0)
    }

    func test_hiddenTerminalWaiterCannotApplyAfterSharedInstallFinishes() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var installStarted = false
        var installContinuation: CheckedContinuation<Void, Never>?
        var applyCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "hidden-current-install",
            probeLifecycleIntegration: { .missing },
            installLifecycleIntegration: {
                installStarted = true
                await withCheckedContinuation { continuation in
                    installContinuation = continuation
                }
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in
                applyCount += 1
                return true
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .notInstalled
        }

        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil { installStarted && installContinuation != nil }
        center.cancelCurrentIntegrationRequest(sessionID: box.sessionID)
        installContinuation?.resume()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(applyCount, 0)
    }

    func test_currentInstallStaysSerializedAcrossDisableAndReenable() async {
        let box = AgentTestSourceBox(visibleText: "$ ")
        let base = box.source()
        let location = AgentLocation(
            sessionID: box.sessionID,
            hostName: box.hostName,
            transportLabel: "ssh",
            tmuxSessionName: nil,
            windowID: nil,
            windowName: nil,
            paneID: nil
        )
        var installation = AgentLifecycleHostInstallation.missing
        var installCount = 0
        var installObservedCancellation = false
        var installContinuation: CheckedContinuation<Void, Never>?
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "reenable-current-install",
            probeLifecycleIntegration: { installation },
            installLifecycleIntegration: {
                installCount += 1
                await withCheckedContinuation { continuation in
                    installContinuation = continuation
                }
                installObservedCancellation = Task.isCancelled
                installation = .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: .shell,
                    processIDs: [100],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            },
            applyLifecycleIntegrationToCurrentShell: { _ in false },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .notInstalled
        }

        center.fixCurrentIntegration(sessionID: box.sessionID)
        await waitUntil { installCount == 1 && installContinuation != nil }
        center.setEnabled(false)
        center.setEnabled(true)
        center.requestCurrentIntegrationRefresh(sessionID: box.sessionID)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(installCount, 1)
        XCTAssertFalse(installObservedCancellation)

        installContinuation?.resume()
        await waitUntil {
            center.currentIntegrationState(sessionID: box.sessionID).kind == .inactiveShell
        }
        XCTAssertEqual(installCount, 1)
    }

    func test_cancelledProbeCannotUntrackReplacementAfterRapidReenable() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var probeContinuations: [CheckedContinuation<AgentLifecycleHostInstallation, Never>] = []
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-reenable-race",
            probeLifecycleIntegration: {
                await withCheckedContinuation { continuation in
                    probeContinuations.append(continuation)
                }
            },
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.setSurfaceDemand(true)
        await waitUntil { probeContinuations.count == 1 }

        center.setEnabled(false)
        center.setEnabled(true)
        center.setSurfaceDemand(true)
        await waitUntil { probeContinuations.count == 2 }

        probeContinuations[0].resume(returning: .missing)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let id = try! XCTUnwrap(center.agents.first?.id)
        center.retryLifecycleIntegrationProbe(agentID: id)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(probeContinuations.count, 2)
        probeContinuations[1].resume(returning: .current)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .installedInactive }
    }

    func test_lifecycleIntegrationReportsMissingAndOutdatedHosts() async {
        for (index, installation, expected) in [
            (0, AgentLifecycleHostInstallation.missing, AgentLifecycleIntegrationState.notInstalled),
            (1, .outdated(version: 3), .outdated(version: 3)),
        ] {
            let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
            let base = box.source()
            let source = AgentSessionSource(
                registrationID: base.registrationID,
                sessionID: base.sessionID,
                discover: base.discover,
                observe: base.observe,
                inspect: base.inspect,
                lifecycleIntegrationCacheKey: "host-\(index)",
                probeLifecycleIntegration: { installation },
                installLifecycleIntegration: {},
                send: base.send,
                jump: base.jump
            )
            let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
            center.register(source)
            center.setSurfaceDemand(true)
            await waitUntil { center.agents.first?.status == .unavailable }
            let id = try! XCTUnwrap(center.agents.first?.id)
            await waitUntil { center.lifecycleIntegrationState(agentID: id) == expected }
        }
    }

    func test_lifecycleIntegrationProbeFailureDoesNotClaimMissingAndCanRetry() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-retry",
            probeLifecycleIntegration: {
                probeCount += 1
                if probeCount == 1 {
                    throw NSError(domain: "AgentCenterProbeTest", code: 1)
                }
                return .missing
            },
            installLifecycleIntegration: {},
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.register(source)
        center.setSurfaceDemand(true)
        await waitUntil { center.agents.first?.status == .unavailable }
        let id = try! XCTUnwrap(center.agents.first?.id)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .checkUnavailable }

        XCTAssertEqual(probeCount, 1)
        center.retryLifecycleIntegrationProbe(agentID: id)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .notInstalled }
        XCTAssertEqual(probeCount, 2)
    }

    func test_lifecycleIntegrationProbeFailureRecoversAfterBoundedBackoff() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-automatic-retry",
            probeLifecycleIntegration: {
                probeCount += 1
                if probeCount == 1 {
                    throw NSError(domain: "AgentCenterProbeTest", code: 2)
                }
                return .current
            },
            installLifecycleIntegration: {},
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            integrationProbeFailureBackoffNanoseconds: 50_000_000
        )
        center.register(source)
        center.setSurfaceDemand(true)
        await waitUntil { center.agents.first != nil }
        let id = try! XCTUnwrap(center.agents.first?.id)
        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .checkUnavailable }

        await waitUntil { center.lifecycleIntegrationState(agentID: id) == .installedInactive }

        XCTAssertEqual(probeCount, 2)
    }

    func test_lifecycleIntegrationPersistentFailureStopsAfterThreeFastRetries() async {
        let box = AgentTestSourceBox(visibleText: "Done.\n\n❯ ")
        let base = box.source()
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: base.registrationID,
            sessionID: base.sessionID,
            discover: base.discover,
            observe: base.observe,
            inspect: base.inspect,
            lifecycleIntegrationCacheKey: "host-bounded-automatic-retry",
            probeLifecycleIntegration: {
                probeCount += 1
                throw NSError(domain: "AgentCenterProbeTest", code: probeCount)
            },
            installLifecycleIntegration: {},
            send: base.send,
            jump: base.jump
        )
        let center = AgentCenter(
            sendVerificationDelayNanoseconds: 1_000_000,
            integrationProbeFailureBackoffNanoseconds: 20_000_000
        )
        center.register(source)
        center.setSurfaceDemand(true)

        await waitUntil { probeCount == 4 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probeCount, 4)
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition was not met", file: file, line: line)
    }

    private static let claudePrompt = """
    Do you want to proceed?
    ❯ 1. Yes
      2. Yes, and always allow
      3. No
    """

    private static func lifecycleEvent(
        state: String,
        timestamp: UInt64,
        provider: String = "claude",
        event: String? = nil,
        agentPID: Int? = 100
    ) -> AgentLifecycleEvent {
        AgentLifecycleEvent.decode(
            json: lifecycleJSON(
                state: state,
                timestamp: timestamp,
                provider: provider,
                event: event ?? defaultLifecycleEvent(for: state),
                agentPID: agentPID
            )
        )!
    }

    private static func lifecycleOSC(
        state: String,
        timestamp: UInt64,
        event: String? = nil,
        provider: String = "claude",
        agentPID: Int? = 100
    ) -> [UInt8] {
        let payload = Data(
            lifecycleJSON(
                state: state,
                timestamp: timestamp,
                provider: provider,
                event: event ?? defaultLifecycleEvent(for: state),
                agentPID: agentPID
            ).utf8
        )
            .base64EncodedString()
        return Array("\u{1B}]1337;TesseraAgentState=\(payload)\u{07}".utf8)
    }

    private static func defaultLifecycleEvent(for state: String) -> String {
        switch state {
        case "idle": "Stop"
        case "waitingForInput": "PermissionRequest"
        case "unavailable": "StopFailure"
        default: "UserPromptSubmit"
        }
    }

    private static func lifecycleJSON(
        state: String,
        timestamp: UInt64,
        provider: String = "claude",
        event: String = "Stop",
        agentPID: Int? = 100
    ) -> String {
        let agentPIDJSON = agentPID.map(String.init) ?? "null"
        return #"{"version":8,"provider":"\#(provider)","event":"\#(event)","state":"\#(state)","reason":"test","timestampNs":"\#(timestamp)","sessionId":"provider-session","turnId":"turn","pane":"%7","notificationType":"","agentPid":\#(agentPIDJSON)}"#
    }
}

@MainActor
private final class AgentTestSourceBox {
    let registrationID = UUID()
    let sessionID: UUID
    let paneID = 7
    let hostName: String
    var visibleText: String
    var bracketedPasteEnabled: Bool
    var echoTextAfterSend: String?
    var currentInputLine: String?
    var currentInputLineAfterSend: String?
    var processNames = ["claude"]
    var processIDs = Set<Int>()
    var lifecycleEvent: AgentLifecycleEvent?
    var sentBytes: [[UInt8]] = []
    var sendResults: [Bool] = []
    var onSend: (@MainActor ([UInt8]) -> Void)?
    var sentKeys: [AgentInputKey] = []
    var onSendKey: (@MainActor (AgentInputKey) -> Void)?
    var jumpedLocations: [AgentLocation] = []

    private func insertedComposerText(from bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")
    }

    private func applySuccessfulTextInsertion(_ bytes: [UInt8]) {
        let inserted = insertedComposerText(from: bytes)
        guard !inserted.isEmpty else { return }
        let profile = processNames.contains(where: { $0.contains("codex") })
            ? SwipePadProfile.builtInCodexCLI
            : SwipePadProfile.builtInClaudeCode
        let parsed = AgentPromptParser.parse(
            visibleText: visibleText,
            profile: profile,
            currentInputLine: currentInputLine
        )
        if parsed.blockingPromptDetected,
           inserted.utf8.count == 1 {
            // Menu accelerators are consumed by the prompt rather than
            // painted into a free-form composer. An already-selected option
            // can therefore remain pixel-identical until Enter is handled.
            return
        }
        currentInputLine = (currentInputLine ?? "") + inserted
    }

    private func applySuccessfulSubmission() {
        if let echoTextAfterSend {
            visibleText = echoTextAfterSend
            if currentInputLineAfterSend == nil {
                currentInputLine = echoTextAfterSend
                    .components(separatedBy: .newlines)
                    .last
            }
        }
        if let currentInputLineAfterSend {
            currentInputLine = currentInputLineAfterSend
        }
    }

    init(
        sessionID: UUID = UUID(),
        hostName: String = "test-host",
        visibleText: String,
        bracketedPasteEnabled: Bool = false
    ) {
        self.sessionID = sessionID
        self.hostName = hostName
        self.visibleText = visibleText
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }

    func source(supportsSemanticKeys: Bool = false) -> AgentSessionSource {
        let location = AgentLocation(
            sessionID: sessionID,
            hostName: hostName,
            transportLabel: "ssh+tmux",
            tmuxSessionName: "work",
            windowID: 3,
            windowName: "agent",
            paneID: paneID
        )
        let probe: () -> AgentProbeTarget = { [self] in
            AgentProbeTarget(
                location: location,
                processNames: processNames,
                processIDs: processIDs,
                visibleText: visibleText,
                currentInputLine: currentInputLine,
                lifecycleEvent: lifecycleEvent,
                bracketedPasteEnabled: bracketedPasteEnabled
            )
        }
        let keySender: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)?
        if supportsSemanticKeys {
            keySender = { [self] _, key in
                sentKeys.append(key)
                if key == .enter {
                    applySuccessfulSubmission()
                }
                onSendKey?(key)
                return true
            }
        } else {
            keySender = nil
        }
        return AgentSessionSource(
            registrationID: registrationID,
            sessionID: sessionID,
            discover: { [probe] in .success([probe()]) },
            observe: { [probe] _ in probe() },
            inspect: { [probe] _ in probe() },
            send: { [self] _, bytes in
                sentBytes.append(bytes)
                let succeeded = sendResults.isEmpty ? true : sendResults.removeFirst()
                if succeeded {
                    if bytes == [0x0D] {
                        applySuccessfulSubmission()
                    } else {
                        applySuccessfulTextInsertion(bytes)
                    }
                    onSend?(bytes)
                }
                return succeeded
            },
            sendKey: keySender,
            jump: { [self] location in jumpedLocations.append(location) }
        )
    }
}
