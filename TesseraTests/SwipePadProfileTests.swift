import Foundation
import XCTest
import TmuxControl
@testable import Tessera

final class SwipePadProfileTests: XCTestCase {
    func testHostileCodexShortcutCannotFallBackToLegacyMacro() {
        for cursor in [nil, "", "› 1. Yes", "Press enter to confirm"] as [String?] {
            for shortcut in [#"\x03touch /tmp/owned\r"#, #"\e"#, "tab", "unknown"] {
                let parsed = AgentPromptParser.parse(
                    visibleText: "Would you like to run the following command?\n› 1. Yes (\(shortcut))\n2. No (n)",
                    profile: .builtInCodexCLI, currentInputLine: cursor)
                XCTAssertNil(parsed.prompt, "Untrusted shortcut was made actionable: \(shortcut)")
            }
        }
    }

    func test_allBuiltInsCount() {
        // Claude, Codex, detection-only OpenCode/Pi/Kimi, and fallback.
        // Aider was retired 2026-05-16.
        XCTAssertEqual(SwipePadProfile.allBuiltIns.count, 6)
    }

    func test_additionalAgentProfilesRemainDetectionOnlyUntilLiveGatesPass() {
        let profiles: [SwipePadProfile] = [.builtInOpenCode, .builtInPi, .builtInKimi]
        XCTAssertEqual(profiles.map(\.matchProcess), ["regex:^opencode(?:$|-)", "pi", "regex:^kimi(?:$|-)"])
        XCTAssertTrue(profiles.allSatisfy { $0.agentDetection == nil })
        XCTAssertTrue(profiles.allSatisfy { profile in
            SwipeDirection.allCases.allSatisfy { !profile.binding(for: $0).isBound }
        })
    }

    func test_claudeCodeBuiltInBindings() {
        let profile = SwipePadProfile.builtInClaudeCode

        // Menu is 1=Yes / 2=Yes-always / 3=No: deny sends 3, always sends 2.
        // (Corrected 2026-08 — the old left=2↵ made "deny" grant sticky
        // consent after Claude reordered its menu. The drift test in
        // SwipePadPetalLayoutTests pins these against the parser fixture.)
        // A digit alone answers, as the shared core sends it (2026-10).
        XCTAssertEqual(profile.binding(for: .right).macro, "1")
        XCTAssertEqual(profile.binding(for: .left).macro, "3")
        XCTAssertEqual(profile.binding(for: .up).macro, "2")
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
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1", "2", "3"])
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

        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1", "2"])
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
        // The shared grammar answers with the digit alone: on this Codex row
        // it only moves the selection, and the answer planner sends Enter once
        // the same menu shows it selected. Assert the bytes the provider reads.
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1", "2", "3"])
        XCTAssertEqual(
            parsed.prompt?.options.map { MacroEncoder.encode($0.responseMacro) },
            [[0x31], [0x32], [0x33]]
        )
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
        XCTAssertEqual(parsed.prompt?.options.map(\.responseMacro), ["1", "2", "3"])
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

    func test_codexUltraComposerSuppressesStaleApproval() {
        let composer = "» Ask Codex to do anything"
        let viewport = """
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)

        \(composer)
        """
        for cursor in [nil, composer] as [String?] {
            let parsed = AgentPromptParser.parse(visibleText: viewport,
                profile: .builtInCodexCLI, currentInputLine: cursor)
            XCTAssertTrue(parsed.isIdlePrompt)
            XCTAssertFalse(parsed.blockingPromptDetected)
            XCTAssertNil(parsed.prompt)
        }
        let numbered = AgentPromptParser.parse(visibleText: "» 1. Yes",
            profile: .builtInCodexCLI, currentInputLine: "» 1. Yes")
        XCTAssertFalse(numbered.isIdlePrompt)
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

    func test_agentTerminalTextDropsRowPadding() {
        XCTAssertEqual(
            AgentTerminalText.normalized("  › 1. Yes   \u{1B}[0m\t\n      \r\n  2. No  \n\n\n\n  gpt-5.5  "),
            "› 1. Yes\n\n  2. No\n\n  gpt-5.5"
        )
    }

    /// The menu pattern's leading blanks stay on their row, yet still accept
    /// the nonbreaking space Claude draws after its glyph.
    func test_menuOptionPatternReadsMarkersOnTheirOwnRow() throws {
        let regex = try XCTUnwrap(AgentRegexCache.regex(SwipePadProfile.builtInClaudeCode.agentDetection?.menuOptionPattern ?? ""))
        let marker = { (text: String) -> String? in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
                .flatMap { Range($0.range(at: 1), in: text) }
                .map { String(text[$0]) }
        }

        XCTAssertEqual(marker("❯\u{00A0}1. Yes"), "❯")
        XCTAssertEqual(marker("  › 1. Yes (y)"), "›")
        XCTAssertEqual(marker("›\n  1. Yes"), "")
    }

    /// A freshly launched agent paints a few rows and leaves the rest of the
    /// screen as width-padded blank rows. Prompt patterns that let `\s` run
    /// across those rows backtracked for about a minute per parse on the main
    /// actor, freezing the app whenever Agent Center refreshed the pane.
    func test_promptParsingStaysFastOnWidthPaddedBlankRows() {
        let fresh = Self.paddedScreen([
            "╭─────────────────────────────────────────────────╮",
            "│ >_ OpenAI Codex (v0.157.1)                      │",
            "╰─────────────────────────────────────────────────╯",
        ], footer: "› Implement {feature}")
        let plan = Self.paddedScreen([
            "  1. Yes, implement this plan          Switch to Default and start coding.",
            "  2. Yes, clear context and implement  Fresh thread. Context: 61% used.",
            "  3. No, stay in Plan mode              Continue planning with the model.",
        ], footer: "  Press enter to confirm or esc to go back")
        let clock = ContinuousClock()
        var parsedPlan: AgentPromptParser.Result?
        let screens: [(screen: String, cursor: String?)] = [(fresh, "› Implement {feature}"), (plan, nil)]
        for profile in [SwipePadProfile.builtInCodexCLI, .builtInClaudeCode] {
            for (screen, cursor) in screens {
                let elapsed = clock.measure {
                    let parsed = AgentPromptParser.parse(visibleText: screen, profile: profile, currentInputLine: cursor)
                    if profile.id == SwipePadProfile.builtInCodexCLIID, screen == plan { parsedPlan = parsed }
                }
                XCTAssertLessThan(elapsed, .seconds(1), "\(profile.name) \(screen == plan ? "plan" : "fresh")")
            }
        }
        XCTAssertTrue(parsedPlan?.blockingPromptDetected == true)
        XCTAssertEqual(parsedPlan?.prompt?.options.map(\.id), [1, 2, 3])

        // The normalizer drops that padding; hold every built-in pattern to
        // the budget on the raw padded rows too, so neither guard relies on
        // the other.
        for profile in SwipePadProfile.allBuiltIns {
            guard let rules = profile.agentDetection else { continue }
            for pattern in rules.blockingPromptPatterns + rules.idlePromptPatterns + [rules.menuOptionPattern] {
                guard let regex = AgentRegexCache.regex(pattern) else { return XCTFail(pattern) }
                for screen in [fresh, plan] {
                    let elapsed = clock.measure {
                        _ = regex.matches(in: screen, range: NSRange(screen.startIndex..., in: screen))
                    }
                    XCTAssertLessThan(elapsed, .seconds(1), pattern)
                }
            }
        }
    }

    /// A custom profile keeps whatever patterns its owner saved. One that
    /// backtracks catastrophically on an ordinary row must cost the main actor
    /// its budget, not the watchdog kill a stalled parse led to, and the parse
    /// must report itself inconclusive rather than rule a prompt out.
    func test_promptParsingGivesUpOnARunawayPatternWithinItsBudget() {
        let profile = SwipePadProfile(
            id: UUID(),
            name: "runaway",
            matchProcess: "runaway",
            bindings: [:],
            isBuiltIn: false,
            agentDetection: AgentDetectionRules(
                blockingPromptPatterns: [#"(?m)^Do you want to proceed\?$"#],
                idlePromptPatterns: [#"(?m)^(\w+\s?)*$"#],
                responseTemplate: "{index}↵"
            )
        )
        // Unbounded, the idle pattern takes about ten seconds on this row.
        let row = Array(repeating: "ab", count: 26).joined(separator: " ") + "!"
        let screen = "Do you want to proceed?\n› 1. Yes\n  2. No\n" + row
        let clock = ContinuousClock()
        var parsed: AgentPromptParser.Result?
        let elapsed = clock.measure {
            parsed = AgentPromptParser.parse(visibleText: screen, profile: profile, currentInputLine: row)
        }

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(parsed?.timedOut, true)
        XCTAssertNil(parsed?.prompt)
        XCTAssertEqual(parsed?.blockingPromptDetected, false)
        XCTAssertEqual(parsed?.isIdlePrompt, false)
        XCTAssertEqual(parsed?.text, AgentTerminalText.normalized(screen))

        let quick = AgentPromptParser.parse(visibleText: "Do you want to proceed?\n› 1. Yes\n  2. No", profile: profile)
        XCTAssertFalse(quick.timedOut)
        XCTAssertTrue(quick.blockingPromptDetected)
    }

    /// An iPad-sized (166×54) viewport: `rows`, blank rows, then `footer`,
    /// each padded to the full width as terminal captures deliver them.
    private static func paddedScreen(_ rows: [String], footer: String) -> String {
        let width = 166, height = 54
        let padded = { (row: String) in row + String(repeating: " ", count: max(0, width - row.count)) }
        let blank = Array(repeating: "", count: height - rows.count - 1)
        return (rows + blank + [footer]).map(padded).joined(separator: "\n")
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
