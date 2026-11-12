import XCTest
@testable import TesseraAgentCore

/// Live prompt screens captured from the real TUIs, and the answer planner
/// driven across them one write at a time.
final class AgentPromptScreenTests: XCTestCase {
    private typealias F = AgentPromptScreenFixtures

    // MARK: Screens

    func testClaudeQuestionPermissionAndReviewScreens() throws {
        let ask = try observe(F.claudeAskSingle)
        XCTAssertEqual(ask.kind, .question)
        XCTAssertTrue(ask.isBlocking)
        XCTAssertEqual(ask.title, "Database")
        XCTAssertEqual(ask.question, "Which database should the service use for the new ledger?")
        XCTAssertEqual(ask.options.map(\.label), ["Postgres (Recommended)", "SQLite", "DynamoDB", "Type something.", "Chat about this"])
        XCTAssertEqual(ask.options.map(\.role), [.choice, .choice, .choice, .freeform, .chat])
        XCTAssertEqual(ask.options.map(\.responseMacro), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(ask.options.first?.detail, "Mature, transactional, already deployed.")
        XCTAssertEqual(ask.selectedOptionID, "1")
        XCTAssertEqual(ask.freeformOption?.id, "4")
        XCTAssertEqual(ask.textFocus, .optionKey)
        XCTAssertNil(ask.entry)
        XCTAssertEqual(ask.controls.map(\.kind), [.cancel])

        let focused = try observe(F.claudeAskSingleTypeFocused)
        XCTAssertEqual(focused.entry, AgentPromptEntry(optionID: "4", text: ""))
        let typed = try observe(F.claudeAskSingleTyped)
        XCTAssertEqual(typed.entry, AgentPromptEntry(optionID: "4", text: "abc 123"))
        XCTAssertEqual(typed.freeformOption?.label, "Type something.", "typed text is the entry, never the option label")

        let bash = try observe(F.claudePermBash)
        XCTAssertEqual(bash.kind, .permission)
        XCTAssertEqual(bash.question, "Do you want to proceed?")
        XCTAssertEqual(bash.options.map(\.label).first, "Yes")
        XCTAssertEqual(bash.options.map(\.label).last, "No")
        XCTAssertNil(bash.textFocus)
        XCTAssertEqual(try observe(F.claudePermWrite).question, "Do you want to create new_file.txt?")
        let plan = try observe(F.claudePlanApproval)
        XCTAssertEqual(plan.kind, .permission)
        XCTAssertEqual(plan.question, "Exit plan mode?")

        let first = try observe(F.claudeAsk3Q1)
        XCTAssertEqual(first.kind, .question)
        XCTAssertEqual(first.progress, "☐ Database ☐ Features ☐ PR ✔ Submit")

        let multi = try observe(F.claudeAsk3Q2Multi)
        XCTAssertEqual(multi.kind, .multiSelect)
        XCTAssertEqual(multi.options.map(\.isChecked), [false, false, false, false, nil])
        XCTAssertEqual(multi.controls, [.init(kind: .next, label: "Next"), .init(kind: .cancel, label: "Cancel")])
        XCTAssertNil(multi.textFocus, "a multi-select text row needs arrow keys, which the planner does not drive")
        XCTAssertFalse(multi.options.contains(where: \.acceptsText))
        XCTAssertEqual(try observe(F.claudeAsk3Q2Toggled).options.map(\.isChecked), [true, false, true, false, nil])
        XCTAssertEqual(try observe(F.claudeAsk3Q2Row4Typed).options.map(\.isChecked), [true, false, true, true, nil])

        let review = try observe(F.claudeAsk3Review)
        XCTAssertEqual(review.kind, .review)
        XCTAssertEqual(review.question, "Ready to submit your answers?")
        XCTAssertEqual(review.options.map(\.label), ["Submit answers", "Cancel"])
    }

    func testCodexQuestionScreens() throws {
        let collapsed = try observe(F.codexAsync2Collapsed)
        XCTAssertEqual(collapsed.kind, .deferred)
        XCTAssertFalse(collapsed.isBlocking)
        XCTAssertFalse(collapsed.blocksComposer, "the collapsed summary sits above a live composer")
        XCTAssertEqual(collapsed.pendingCount, 2)
        XCTAssertTrue(collapsed.options.isEmpty)
        XCTAssertEqual(collapsed.controls.map(\.kind), [.open])
        XCTAssertEqual(try observe(F.codexAsyncCountdown).pendingCount, 1)

        let open = try observe(F.codexAsync2OpenQ1)
        XCTAssertEqual(open.kind, .question)
        XCTAssertFalse(open.isBlocking)
        XCTAssertTrue(open.blocksComposer)
        XCTAssertEqual(open.progress, "1 of 2")
        XCTAssertEqual(open.options.map(\.label), ["Postgres", "SQLite", "Other"])
        XCTAssertEqual(open.options.map(\.role), [.choice, .choice, .freeform])
        XCTAssertEqual(open.controls.map(\.kind), [.skip])
        XCTAssertEqual(open.textFocus, .optionKey)

        let text = try observe(F.codexAsync2AfterQ1)
        XCTAssertEqual(text.kind, .textEntry)
        XCTAssertTrue(text.options.isEmpty)
        XCTAssertEqual(text.textFocus, .focused)
        XCTAssertEqual(text.entry, AgentPromptEntry(optionID: nil, text: ""), "the placeholder is not an answer")
        XCTAssertEqual(try observe(F.codexAsync2Q2Typed).entry, AgentPromptEntry(optionID: nil, text: "Weekend, 2 to 4 am"))

        XCTAssertEqual(try observe(F.codexAsync1OtherFocused).entry, AgentPromptEntry(optionID: "4", text: ""))
        let other = try observe(F.codexAsync1OtherTyped)
        XCTAssertEqual(other.entry, AgentPromptEntry(optionID: "4", text: "CockroachDB 24"))
        XCTAssertEqual(other.freeformOption?.label, "Other")

        let blocking = try observe(F.codexRuiPlan)
        XCTAssertEqual(blocking.kind, .question)
        XCTAssertTrue(blocking.isBlocking)
        XCTAssertEqual(blocking.progress, "Question 1/1 (1 unanswered)")
        XCTAssertEqual(blocking.options.map(\.label), ["Postgres (Recommended)", "SQLite", "None of the above"])
        XCTAssertEqual(blocking.options.first?.detail, "Transactional and deployed.")
        XCTAssertEqual(blocking.textFocus, .selectThenTab)
        XCTAssertEqual(try observe(F.codexRuiNotesOpen).entry, AgentPromptEntry(optionID: "3", text: ""))
        XCTAssertEqual(try observe(F.codexRuiNotesTyped).entry, AgentPromptEntry(optionID: "3", text: "CockroachDB instead"))

        let approval = try observe(F.codexExecApproval)
        XCTAssertEqual(approval.kind, .permission)
        XCTAssertEqual(approval.options.map(\.responseMacro), ["y", "p", "\u{1b}"])
    }

    /// Codex 0.162 raises an execpolicy `prompt` rule's approval under the
    /// running exec cell, with a collapsed "+ Show details" row and a reason
    /// that wraps; the cursor sits on the "Press enter" row.
    func testCodexExecpolicyApprovalUnderRunningCell() throws {
        let rows = Array(repeating: "", count: 37) + [
            "• Running cat src/auth/keys.ts; sed -n 1,80p src/tokens.ts; npm run migrate:tokens -- --dr…",
            "    + Show details",
            "",
            "  Would you like to run the following command?",
            "",
            "  Environment: local",
            "",
            "  Reason: `/bin/bash -lc 'cat src/auth/keys.ts; sed -n 1,80p src/tokens.ts; npm run",
            "  migrate:tokens -- --dry-run'` requires approval: Token migrations need a person to approve them.",
            "",
            "  $ cat src/auth/keys.ts; sed -n 1,80p src/tokens.ts; npm run migrate:tokens -- --dry-run",
            "",
            "› 1. Yes, proceed (y)",
            "  2. No, and tell Codex what to do differently (esc)",
            "",
            "  Press enter to confirm or esc to cancel",
        ]
        let fixture = F.Fixture(cursorRow: rows.count - 1, cursorVisible: true, text: rows.joined(separator: "\n"))
        let approval = try XCTUnwrap(parse(fixture, provider: .codex))
        XCTAssertEqual(approval.kind, .permission)
        XCTAssertTrue(approval.isBlocking)
        XCTAssertEqual(approval.options.map(\.responseMacro), ["y", "\u{1b}"])
    }

    func testCodexDeferredQuestionsWithUltraComposer() throws {
        for fixture in [F.codexAsync2Collapsed, F.codexAsyncCountdown] {
            let ordinary = try XCTUnwrap(parse(fixture, provider: .codex))
            let ultra = fixture.text.replacingOccurrences(of: "› Ask Codex", with: "» Ask Codex")
            let observed = try XCTUnwrap(parse(ultra, .codex, cursor: "» Ask Codex to do anything"))
            XCTAssertEqual(observed.kind, .deferred)
            XCTAssertEqual(observed.pendingCount, ordinary.pendingCount)
            XCTAssertEqual(observed.identity, ordinary.identity)
            XCTAssertEqual(observed.signature, ordinary.signature)
            XCTAssertEqual(observed.controls.map(\.kind), [.open])
            XCTAssertFalse(observed.blocksComposer)
            XCTAssertNil(parse(ultra.replacingOccurrences(of: "» Ask Codex", with: "« Ask Codex"), .codex, cursor: nil))
            XCTAssertNil(parse(ultra.replacingOccurrences(of: "» Ask Codex", with: "»Ask Codex"), .codex, cursor: nil))
        }
    }

    func testKimiQuestionScreens() throws {
        let ask = try observe(F.kimiAskSingle)
        XCTAssertEqual(ask.kind, .question)
        XCTAssertEqual(ask.question, "Which database should the service use for the new ledger?")
        XCTAssertEqual(ask.options.map(\.label), ["Postgres", "SQLite", "Other"])
        XCTAssertEqual(ask.options.map(\.role), [.choice, .choice, .freeform])
        XCTAssertEqual(ask.options.map(\.responseMacro), ["1", "2", "3"])
        XCTAssertEqual(ask.textFocus, .optionKey)
        XCTAssertEqual(ask.controls.map(\.kind), [.cancel])
        XCTAssertEqual(try observe(F.kimiOtherFocused).entry, AgentPromptEntry(optionID: "3", text: ""))
        let typed = try observe(F.kimiOtherTyped)
        XCTAssertEqual(typed.entry, AgentPromptEntry(optionID: "3", text: "abc 12"))
        XCTAssertEqual(typed.freeformOption?.label, "Other")

        let multi = try observe(F.kimiAsk2Multi)
        XCTAssertEqual(multi.kind, .multiSelect)
        XCTAssertEqual(multi.options.map(\.label), ["Search", "Export", "Other"])
        XCTAssertEqual(multi.options.map(\.isChecked), [false, false, false])
        XCTAssertEqual(multi.options.map(\.responseMacro), ["1", "2", "3"], "Kimi numbers check boxes by order")
        XCTAssertEqual(multi.controls.map(\.kind), [.next, .cancel])
        XCTAssertEqual(try observe(F.kimiAsk2MultiToggled).options.map(\.isChecked), [false, true, false])

        for review in [F.kimiAskAfter2, F.kimiAsk2Review] {
            let observed = try observe(review)
            XCTAssertEqual(observed.kind, .review)
            XCTAssertEqual(observed.options.map(\.label), ["Submit", "Cancel"])
        }

        let bash = try observe(F.kimiBash)
        XCTAssertEqual(bash.kind, .permission)
        XCTAssertEqual(bash.question, "Run this command?")
        XCTAssertEqual(bash.options.map(\.label), ["Approve once", "Approve for this session", "Reject", "Reject with feedback"])
        XCTAssertTrue(bash.controls.isEmpty)
        XCTAssertEqual(try observe(F.kimiAskbg).kind, .question, "only the hook tells a background question apart")
    }

    func testScreensWithoutAPromptParseNothing() {
        for (name, fixture) in [("claudeAskAfterEsc", F.claudeAskAfterEsc), ("codexAsync2Done", F.codexAsync2Done),
                                ("codexRuiAfter2", F.codexRuiAfter2), ("kimiReviewAfter1", F.kimiReviewAfter1)] {
            XCTAssertNil(parse(fixture, provider: provider(name)), name)
        }
    }

    /// A dialog replaces the composer at the bottom of the screen. The same
    /// rows merely printed as output sit above a composer or a status line.
    func testAMenuThatIsNoLongerAtTheBottomIsNotActionable() {
        let rule = String(repeating: "─", count: 80)
        let claudeComposer = "\n\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"
        for fixture in [F.claudeAskSingle, F.claudePermBash, F.claudeAsk3Q2Multi, F.claudeAsk3Review] {
            XCTAssertNil(parse(fixture.text + claudeComposer, .claude, cursor: "❯ "))
        }
        let codexComposer = "\n\n› Ask Codex to do anything\n\n  GPT-6-Sol default · /home/dev/work…"
        for fixture in [F.codexAsync2OpenQ1, F.codexAsync2AfterQ1, F.codexRuiPlan] {
            XCTAssertNil(parse(fixture.text + codexComposer, .codex, cursor: "› Ask Codex to do anything"))
        }
        let kimiOutput = "\n\n• Tool result received\n  more output\n  more output\n  more output\n  more output\n  done"
        for fixture in [F.kimiAskSingle, F.kimiAsk2Multi, F.kimiBash] {
            XCTAssertNil(parse(fixture.text + kimiOutput, .kimi, cursor: nil))
        }
        // Codex's collapsed summary belongs directly above the composer.
        XCTAssertNil(parse(F.codexAsync2Collapsed.text + "\n" + Array(repeating: "output", count: 12).joined(separator: "\n"), .codex, cursor: nil))
    }

    func testMenusOfOtherProvidersAreNotRead() {
        XCTAssertNil(parse(F.kimiAskSingle, provider: .claude))
        XCTAssertNil(parse(F.claudeAskSingle, provider: .kimi))
        XCTAssertNil(parse(F.kimiAskSingle, provider: .opencode))
    }

    func testSignatureIgnoresTheSelectionAndIdentityIgnoresAnswerProgress() throws {
        let ask = try observe(F.claudeAskSingle)
        XCTAssertEqual(try observe(F.claudeAskChatSelected).signature, ask.signature, "moving the selection is the same prompt")
        XCTAssertEqual(try observe(F.claudeAskSingleTypeFocused).signature, ask.signature)
        let typed = try observe(F.claudeAskSingleTyped)
        XCTAssertNotEqual(typed.signature, ask.signature)
        XCTAssertEqual(typed.identity, ask.identity)

        let multi = try observe(F.claudeAsk3Q2Multi), toggled = try observe(F.claudeAsk3Q2Toggled)
        XCTAssertNotEqual(toggled.signature, multi.signature, "a toggled check box is visible progress")
        XCTAssertEqual(toggled.identity, multi.identity)
        XCTAssertEqual(try observe(F.claudeAsk3Q2Row4Typed).identity, multi.identity)
        XCTAssertNotEqual(try observe(F.claudeAsk3Q1).identity, multi.identity)

        let kimiMulti = try observe(F.kimiAsk2Multi), kimiToggled = try observe(F.kimiAsk2MultiToggled)
        XCTAssertNotEqual(kimiToggled.signature, kimiMulti.signature)
        XCTAssertEqual(kimiToggled.identity, kimiMulti.identity)
        XCTAssertEqual(try observe(F.kimiOtherTyped).identity, try observe(F.kimiAskSingle).identity)

        let rui = try observe(F.codexRuiPlan)
        XCTAssertEqual(try observe(F.codexRuiNotesOpen).identity, rui.identity)
        XCTAssertEqual(try observe(F.codexRuiNotesTyped).identity, rui.identity)
        let async1 = try observe(F.codexAsync1Open)
        XCTAssertEqual(try observe(F.codexAsync1OtherFocused).signature, async1.signature)
        XCTAssertEqual(try observe(F.codexAsync1OtherTyped).identity, async1.identity)
        let text = try observe(F.codexAsync2AfterQ1), textTyped = try observe(F.codexAsync2Q2Typed)
        XCTAssertNotEqual(textTyped.signature, text.signature)
        XCTAssertEqual(textTyped.identity, text.identity)

        let countdown = try observe(F.codexAsyncCountdown)
        let later = try XCTUnwrap(parse(F.codexAsyncCountdown.text.replacingOccurrences(of: "· 14s", with: "· 13s"), .codex, cursor: nil))
        XCTAssertEqual(later.signature, countdown.signature, "a ticking countdown is the same prompt")
        XCTAssertNotEqual(try observe(F.codexAsync2Collapsed).signature, countdown.signature)
        XCTAssertEqual(try observe(F.codexAsync2Collapsed).identity, countdown.identity)
    }

    /// Questions of one call can share their words and options. Their place
    /// in the batch keeps them apart; the answer's own progress does not.
    func testQuestionsOfOneBatchThatReadAlikeAreDifferentPrompts() throws {
        let q1 = try observe(F.claudeAsk3Q1)
        XCTAssertFalse(same(try replacing(F.claudeAsk3Q1, .claude, "←  ☐ Database", "←  ☒ Database"), q1),
                       "the same question asked once Database is answered")
        let multi = try observe(F.claudeAsk3Q2Multi), toggled = try observe(F.claudeAsk3Q2Toggled)
        XCTAssertTrue(same(toggled, multi), "a toggle marks its own tab")
        XCTAssertTrue(same(try observe(F.claudeAsk3Q2Row4Typed), multi), "so does typed text, with its box")
        let next = try replacing(F.claudeAsk3Q2Multi, .claude, "☐ Features", "☒ Features")
        XCTAssertFalse(same(next, multi), "the same check boxes asked once Features is answered")
        XCTAssertFalse(same(next, toggled))
        let single = try observe(F.claudeAskSingle)
        XCTAssertFalse(same(try replacing(F.claudeAskSingle, .claude, "☐ Database", "☐ Storage"), single),
                       "a single question's chip is its title")
        XCTAssertTrue(same(try replacing(F.claudeAskSingle, .claude, "☐ Database", "☒ Database"), single))
        XCTAssertTrue(F.claudeAskSingleTyped.text.contains("☐ Database"), "typed text leaves its chip unmarked")
        XCTAssertTrue(same(try observe(F.claudeAskSingleTyped), single))

        // Alike questions can differ only in their descriptions, which wrap
        // wherever the width puts the row break, inside a word too.
        let described = try replacing(F.claudeAsk3Q1, .claude, "     Transactional.\n", "     Transactional and deployed.\n")
        XCTAssertFalse(same(described, q1), "a description tells alike questions apart")
        for wrapped in ["     Transactional and\n     deployed.\n", "     Transactional and depl\n     oyed.\n"] {
            XCTAssertTrue(same(try replacing(F.claudeAsk3Q1, .claude, "     Transactional.\n", wrapped), described), wrapped)
        }
        // A label wider than the pane wraps into the rows its description takes.
        let label = try replacing(F.claudeAsk3Q1, .claude, "❯ 1. Postgres\n", "❯ 1. Postgres managed service\n")
        XCTAssertFalse(same(label, q1))
        XCTAssertTrue(same(try replacing(F.claudeAsk3Q1, .claude, "❯ 1. Postgres\n", "❯ 1. Postgres managed\n     service\n"), label))
        // The option's bound cuts a long description where the width put it:
        // a word wider than the row breaks inside it, and each break joins
        // back as a space.
        let word = Array(String(repeating: "abcdefghij", count: 120))
        func wrapping(_ width: Int) -> String {
            stride(from: 0, to: word.count, by: width).map { "     \(String(word[$0..<min(word.count, $0 + width)]))\n" }.joined()
        }
        let cutShort = try replacing(F.claudeAsk3Q1, .claude, "     Transactional.\n", wrapping(100))
        XCTAssertEqual(cutShort.options.first?.detail?.count, 1_024)
        XCTAssertFalse(same(cutShort, q1))
        XCTAssertTrue(same(try replacing(F.claudeAsk3Q1, .claude, "     Transactional.\n", wrapping(40)), cutShort))
        // Just under the bound, a label wrapped at one width only pushes the
        // description past it: the head every width shows counts either way.
        let under = Array(String(repeating: "abcdefghij", count: 101))
        let rows = stride(from: 0, to: under.count, by: 100).map { "     \(String(under[$0..<min(under.count, $0 + 100)]))\n" }.joined()
        let fits = try replacing(F.claudeAsk3Q1, .claude, "❯ 1. Postgres\n     Transactional.\n", "❯ 1. Postgres managed service\n" + rows)
        XCTAssertEqual(fits.options.first?.detail?.count, 1_020)
        let pushed = try replacing(F.claudeAsk3Q1, .claude, "❯ 1. Postgres\n     Transactional.\n", "❯ 1. Postgres managed\n     service\n" + rows)
        XCTAssertEqual(pushed.options.first?.detail?.count, 1_024)
        XCTAssertTrue(same(pushed, fits))
        // So is the question, wrapped at a space or inside a word.
        let asked = "Which database should the service use?\n"
        XCTAssertTrue(same(try replacing(F.claudeAsk3Q1, .claude, asked, "Which database should the\nservice use?\n"), q1))
        XCTAssertTrue(same(try replacing(F.claudeAsk3Q1, .claude, asked, "Which database should the serv\nice use?\n"), q1))

        let kimi = try observe(F.kimiAsk2)
        XCTAssertFalse(same(try replacing(F.kimiAsk2, .kimi, "   Database   (○) Features   Submit",
                                          "  (✓) Database   Features    Submit"), kimi))
        let kimiDescribed = try replacing(F.kimiAsk2, .kimi, "         Transactional.\n", "         Transactional and deployed.\n")
        XCTAssertFalse(same(kimiDescribed, kimi))
        XCTAssertTrue(same(try replacing(F.kimiAsk2, .kimi, "         Transactional.\n", "         Transactional and\n         deployed.\n"),
                           kimiDescribed))

        let rui = try observe(F.codexRuiPlan)
        let first = try replacing(F.codexRuiPlan, .codex, "Question 1/1 (1 unanswered)", "Question 1/2 (2 unanswered)")
        XCTAssertTrue(same(try replacing(F.codexRuiPlan, .codex, "Question 1/1 (1 unanswered)", "Question 1/2 (1 unanswered)"), first),
                      "the unanswered count is progress")
        XCTAssertFalse(same(try replacing(F.codexRuiPlan, .codex, "Question 1/1 (1 unanswered)", "Question 2/2 (1 unanswered)"), first))
        XCTAssertFalse(same(first, rui))
        XCTAssertTrue(same(try replacing(F.codexRuiPlan, .codex, "  Which database should we use?\n",
                                         "  Which database should we u\n  se?\n"), rui), "the question read without its row breaks")
        XCTAssertFalse(same(try replacing(F.codexRuiPlan, .codex, "Embedded, zero operations.", "Embedded, one file."), rui),
                       "a description tells alike questions apart")
        let async = try observe(F.codexAsync2OpenQ1)
        XCTAssertFalse(same(try replacing(F.codexAsync2OpenQ1, .codex, "  1 of 2\n", "  2 of 2\n"), async))
        let lone = F.codexAsync2OpenQ1.text.replacingOccurrences(of: "  1 of 2\n", with: "")
            .replacingOccurrences(of: "   shift+← next question", with: "")
        let last = try XCTUnwrap(parse(lone, .codex, cursor: nil))
        XCTAssertNil(last.progress)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(last.placement), ["others": "0", "position": "1 of 1"])
        XCTAssertFalse(same(last, async), "the question left once its twin is answered has no counter, and no next question")
        let question = "  Which database should the service use?\n"
        let long = (1...10).map { "  Which database should service \($0) use?\n" }.joined()
        let tall = try replacing(F.codexAsync2OpenQ1, .codex, question, long)
        XCTAssertEqual(tall.progress, "1 of 2", "a long question keeps its counter past the rows its text keeps")
        let longAlone = lone.replacingOccurrences(of: question, with: long)
        XCTAssertFalse(same(try XCTUnwrap(parse(longAlone, .codex, cursor: nil)), tall))
        let options = "\n  › 1. Postgres\n    2. SQLite\n    3. Other\n\n  enter submit   ctrl+] skip   ⌥+↓ main prompt   shift+← next question"
        let cut = try XCTUnwrap(parse(long + options, .codex, cursor: nil))
        XCTAssertEqual(AgentPromptObservationResult.placementParts(cut.placement), ["others": "1"],
                       "the screen's top may have cut the counter off; the footer still names the next question")
        XCTAssertTrue(same(cut, tall))
        // A bulleted row is the question's own: the counter above it heads them all.
        let bulleted = try replacing(F.codexAsync2OpenQ1, .codex, question,
                                     "  Which database should the service use?\n  • Postgres is managed.\n  Pick one.\n")
        XCTAssertEqual(bulleted.question, "Which database should the service use? • Postgres is managed. Pick one.")
        XCTAssertEqual(bulleted.progress, "1 of 2")
        // The question's text is the same at every width.
        for wrapped in ["  Which database should the\n  service use?\n", "  Which database should the serv\n  ice use?\n"] {
            XCTAssertTrue(same(try replacing(F.codexAsync2OpenQ1, .codex, question, wrapped), async), wrapped)
        }
        XCTAssertTrue(same(try replacing(F.codexAsync2OpenQ1, .codex, question, (1...10).map { "  Which database should servi\n  ce \($0) use?\n" }.joined()), tall))
        let text = try observe(F.codexAsync2AfterQ1)
        XCTAssertNil(text.progress)
        let counted = F.codexAsync2AfterQ1.text.replacingOccurrences(of: "  Describe the rollout window you prefer.\n\n  Type",
                                                                    with: "  2 of 2\n  Describe the rollout window you prefer.\n\n  Type")
            .replacingOccurrences(of: "⌥+↓ main prompt", with: "⌥+↓ main prompt   shift+← next question")
        let twin = try XCTUnwrap(parse(counted, .codex, cursor: nil))
        XCTAssertEqual(twin.progress, "2 of 2")
        XCTAssertEqual(twin.identity, text.identity)
        XCTAssertFalse(same(text, twin), "so is a lone text question")
    }

    /// A long part is bounded alone: the others stay whole and still compare.
    func testAPlacementBoundsEachPartAlone() throws {
        let long = String(repeating: "Ledger import ", count: 40) + "plan"
        let placement = try XCTUnwrap(AgentPromptObservationResult.placement(["answered": "1", "chip": long, "tab": "2"]))
        let parts = AgentPromptObservationResult.placementParts(placement)
        XCTAssertEqual(parts["answered"], "1")
        XCTAssertEqual(parts["tab"], "2")
        XCTAssertLessThanOrEqual(try XCTUnwrap(parts["chip"]).utf8.count, 128)
        XCTAssertNotEqual(parts["chip"], AgentPromptObservationResult.placementParts(
            AgentPromptObservationResult.placement(["chip": long + "s"]))["chip"], "a bounded part keeps its tail's hash")
        let result = try XCTUnwrap(AgentPromptObservationResult(signature: "s", options: [], kind: .textEntry, placement: placement))
        XCTAssertEqual(result.placement, placement, "bounding is idempotent")
        let decoded = try JSONDecoder().decode(AgentPromptObservationResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.placement, placement)
        XCTAssertTrue(result.isSameQuestion(identity: "s", placement: "tab=2"))
        XCTAssertFalse(result.isSameQuestion(identity: "s", placement: "tab=3"))
    }

    /// Plain text loses Claude's highlighted tab; the capture's background
    /// keeps it, so a terminal moving to an alike question's tab, nothing
    /// answered, shows another prompt.
    func testTheHighlightedTabTellsAlikeQuestionsApart() throws {
        let shown = "← \u{1B}[38;5;16m\u{1B}[48;5;153m ☐ Run plan \u{1B}[39m\u{1B}[49m ☐ Report  ✔ Submit  →"
        let moved = "←  ☐ Run plan \u{1B}[38;5;16m\u{1B}[48;5;153m ☐ Report \u{1B}[39m\u{1B}[49m ✔ Submit  →"
        let wide = try observe(F.claudeAskWidePhone)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(wide.placement), ["answered": "0", "tab": "1"])
        let next = try replacing(F.claudeAskWidePhone, .claude, shown, moved)
        XCTAssertEqual(next.identity, wide.identity)
        XCTAssertFalse(same(next, wide), "the same question on the next tab")
        let bounded = try XCTUnwrap(parse(AgentPromptGrammar.promptText(fromCapture: F.claudeAskWidePhone.text.replacingOccurrences(
            of: shown, with: moved)), .claude, cursor: nil))
        XCTAssertEqual(AgentPromptObservationResult.placementParts(bounded.placement)["tab"], "2", "the bound keeps backgrounds")
        let plain = try XCTUnwrap(parse(AgentPromptGrammar.withoutEscapes(F.claudeAskWidePhone.text), .claude, cursor: nil))
        XCTAssertNil(AgentPromptObservationResult.placementParts(plain.placement)["tab"])
        XCTAssertTrue(same(plain, next), "a screen without backgrounds says nothing of its tab")

        let review = try observe(F.claudeReviewTallPhone)
        XCTAssertNil(review.placement, "a review is no question of the batch")

        // An answer that left for the field is not the next tab's.
        var drive = try Drive(.claude, .text("abc"), F.claudeAskWidePhone)
        XCTAssertEqual(drive.next(F.claudeAskWidePhone), .send("4", .focus))
        XCTAssertEqual(drive.next(next), .refuse(.verificationFailed))
    }

    /// Codex 0.166 draws its modifier keys as glyphs ("⌃] skip"), and a
    /// phone wraps the hints onto a second row; the panel and its Skip stay.
    func testCodexAsyncPanelsReadTheirGlyphHintsAtEveryWidth() throws {
        let wide = try observe(F.codexAsync166OpenQ1), phone = try observe(F.codexAsync166OpenQ1Phone)
        for observed in [wide, phone] {
            XCTAssertEqual(observed.kind, .question)
            XCTAssertEqual(observed.question, "Which database should the service use?")
            XCTAssertEqual(observed.options.map(\.label), ["Postgres", "SQLite", "Other"])
            XCTAssertEqual(observed.controls.map(\.kind), [.skip])
            XCTAssertEqual(AgentPromptObservationResult.placementParts(observed.placement), ["others": "1", "position": "1 of 2"])
        }
        XCTAssertEqual(phone.identity, wide.identity)
        XCTAssertEqual(try observe(F.codexAsync2OpenQ1).identity, wide.identity, "the same question as Codex 0.159 drew it")
        var skip = try Drive(.codex, .control(.skip), F.codexAsync166OpenQ1Phone)
        XCTAssertEqual(skip.next(F.codexAsync166OpenQ1Phone).semanticKey, .controlRightBracket)
    }

    /// An async question of several paragraphs reads whole, its counter alone
    /// a blank row above the first: twins that differ only there are two
    /// questions, and answering one moves on to the other.
    func testCodexAsyncQuestionsOfSeveralParagraphsReadWhole() throws {
        let first = try observe(F.codexAsyncParagraphsQ1), second = try observe(F.codexAsyncParagraphsQ2)
        XCTAssertEqual(first.kind, .textEntry)
        XCTAssertEqual(first.question, "Staging takes the first rollout. Describe the rollout window you prefer.")
        XCTAssertEqual(first.progress, "1 of 2")
        XCTAssertEqual(AgentPromptObservationResult.placementParts(first.placement), ["others": "1", "position": "1 of 2"])
        XCTAssertEqual(second.question, "Production takes the second rollout. Describe the rollout window you prefer.",
                       "the panel's two blank rows end the twin left alone")
        XCTAssertNil(second.progress)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(second.placement), ["others": "0", "position": "1 of 1"])
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertFalse(same(second, first))

        let paragraph = "  1 of 2\n\n  Staging takes the first rollout.\n"
        let other = try replacing(F.codexAsyncParagraphsQ1, .codex, paragraph, "  2 of 2\n\n  Production takes the second rollout.\n")
        XCTAssertEqual(other.identity, second.identity)
        XCTAssertFalse(same(other, first))
        XCTAssertTrue(same(try replacing(F.codexAsyncParagraphsQ1, .codex, paragraph,
                                         "  1 of 2\n\n  Staging takes the\n  first rollout.\n"), first), "a phone's wrap")
        let listed = try replacing(F.codexAsyncParagraphsQ1, .codex, paragraph,
                                   "  1 of 2\n\n  Staging takes the first rollout.\n\n  • Weekdays only\n  • Never on a Friday\n")
        XCTAssertEqual(listed.question, "Staging takes the first rollout. • Weekdays only • Never on a Friday "
                       + "Describe the rollout window you prefer.")
        XCTAssertEqual(listed.progress, "1 of 2", "a bulleted paragraph is the question's own")
        // Past two blank rows inside the question, its rows cannot be told
        // from the transcript's: its tail reads alike at every crop, and the
        // footer tells that others wait.
        let spacedText = F.codexAsyncParagraphsQ1.text.replacingOccurrences(of: "first rollout.\n\n  Describe",
                                                                            with: "first rollout.\n\n\n  Describe")
        let spaced = try XCTUnwrap(parse(spacedText, .codex, cursor: nil))
        XCTAssertEqual(spaced.question, "Describe the rollout window you prefer.", "two blank rows inside the question")
        XCTAssertNil(spaced.progress)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(spaced.placement), ["others": "1"])
        let spacedRows = spacedText.components(separatedBy: "\n")
        let counterRow = try XCTUnwrap(spacedRows.firstIndex(of: "  1 of 2"))
        for crop in [counterRow, counterRow + 1, counterRow + 2] {
            let spacedCut = try XCTUnwrap(parse(spacedRows[crop...].joined(separator: "\n"), .codex, cursor: nil), "\(crop)")
            XCTAssertEqual(spacedCut.identity, spaced.identity, "\(crop)")
            XCTAssertEqual(spacedCut.placement, spaced.placement, "\(crop)")
        }
        let ending = try replacing(F.codexAsyncParagraphsQ2, .codex, "\n  Describe the rollout window you prefer.\n",
                                   "\n  Pick a window:\n  • Weekdays\n  • Weekends\n")
        XCTAssertEqual(ending.question, "Production takes the second rollout. Pick a window: • Weekdays • Weekends")
        // The counter tells that others wait, however the footer is drawn
        // (a repaint cut short, a field focused). Codex draws none for the
        // question left alone, so a paragraph that reads as one is taken for it.
        let unhinted = try replacing(F.codexAsyncParagraphsQ1, .codex, "   ⇧← next question", "")
        XCTAssertEqual(AgentPromptObservationResult.placementParts(unhinted.placement), ["others": "1", "position": "1 of 2"])
        XCTAssertEqual(unhinted.identity, first.identity)
        XCTAssertTrue(same(unhinted, first))
        let counterLike = try replacing(F.codexAsyncParagraphsQ2, .codex, "\n  Production takes the second rollout.\n", "\n  3 of 4\n")
        XCTAssertEqual(counterLike.progress, "3 of 4")
        XCTAssertEqual(counterLike.question, "Describe the rollout window you prefer.")
        // The screen's top may have cut the counter off; the text still tells.
        let below = F.codexAsyncParagraphsQ1.text.components(separatedBy: "\n").drop { !$0.hasPrefix("  Staging") }
        let cut = try XCTUnwrap(parse(below.joined(separator: "\n"), .codex, cursor: nil))
        XCTAssertEqual(cut.question, first.question)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(cut.placement), ["others": "1"])
        XCTAssertTrue(same(cut, first))
        XCTAssertFalse(same(cut, second))
        // Cropped at the blank between paragraphs, the twins read alike but
        // for the next question the first one's footer still names.
        func cropped(_ fixture: F.Fixture) throws -> AgentPromptObservationResult {
            let rows = fixture.text.components(separatedBy: "\n")
            let last = try XCTUnwrap(rows.lastIndex { $0.hasPrefix("  Describe") })
            return try XCTUnwrap(parse(rows[(last - 1)...].joined(separator: "\n"), .codex, cursor: nil))
        }
        let croppedFirst = try cropped(F.codexAsyncParagraphsQ1), croppedSecond = try cropped(F.codexAsyncParagraphsQ2)
        XCTAssertEqual(croppedFirst.identity, croppedSecond.identity)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(croppedFirst.placement), ["others": "1"])
        XCTAssertFalse(same(croppedSecond, croppedFirst))
        XCTAssertFalse(same(croppedFirst, croppedSecond))
        // A transcript row above one blank row is no paragraph of the question,
        // nor one Codex marks with ↳ at the panel's indent; the paragraphs
        // below it read as they do once it scrolls off.
        for (row, replacement) in [("• Queued follow-up inputs\n\n\n", "• Queued follow-up inputs\n\n"),
                                   ("• Queued follow-up inputs\n\n\n", "  ↳ also bump the version\n\n")] {
            let text = F.codexAsyncParagraphsQ2.text.replacingOccurrences(of: row, with: replacement)
            let near = try XCTUnwrap(parse(text, .codex, cursor: nil))
            XCTAssertEqual(near.question, second.question, replacement)
            let rows = text.components(separatedBy: "\n")
            let below = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("  Production takes") })
            let scrolled = try XCTUnwrap(parse(rows[below...].joined(separator: "\n"), .codex, cursor: nil))
            XCTAssertEqual(scrolled.identity, near.identity, replacement)
        }
        // A queued follow-up of two paragraphs, with or without its first.
        let followUp = F.codexAsyncParagraphsQ2.text.replacingOccurrences(of: "• Queued follow-up inputs\n\n\n",
            with: "• Queued follow-up inputs\n  ↳ also bump the version\n\n    and the changelog\n\n\n")
        let followed = try XCTUnwrap(parse(followUp, .codex, cursor: nil))
        XCTAssertEqual(followed.question, second.question)
        XCTAssertEqual(followed.identity, second.identity)
        let followRows = followUp.components(separatedBy: "\n")
        let laterParagraph = try XCTUnwrap(followRows.firstIndex(of: "    and the changelog"))
        let followCut = try XCTUnwrap(parse(followRows[laterParagraph...].joined(separator: "\n"), .codex, cursor: nil))
        XCTAssertEqual(followCut.identity, second.identity)
        XCTAssertEqual(followCut.placement, second.placement)
        // Nor is a row past two blank rows the counter, whatever it reads.
        let pastCounter = try replacing(F.codexAsyncParagraphsQ2, .codex, "• Queued follow-up inputs\n\n\n", "  3 of 4\n\n\n")
        XCTAssertEqual(pastCounter.question, second.question)
        XCTAssertEqual(pastCounter.placement, second.placement)
        let edge = try replacing(F.codexAsyncParagraphsQ2, .codex, "\n\n  Production takes", "\n\nProduction takes")
        XCTAssertEqual(edge.question, "Describe the rollout window you prefer.")
        // A transcript item's continuation rows may be indented as far as the
        // panel's; its first row is not.
        let item = try replacing(F.codexAsyncParagraphsQ2, .codex, "• Working (8s • esc to interrupt)\n\n• Queued follow-up inputs\n",
                                 "• Ran the migration\n  └ 3 tables changed\n")
        XCTAssertEqual(item.question, second.question)
        XCTAssertEqual(AgentPromptObservationResult.placementParts(item.placement), ["others": "0", "position": "1 of 1"])
        let abutting = try replacing(F.codexAsyncParagraphsQ2, .codex,
                                     "• Queued follow-up inputs\n\n\n  Production takes the second rollout.\n\n  Describe",
                                     "• Queued follow-up inputs\n  Describe")
        XCTAssertEqual(abutting.question, "Describe the rollout window you prefer.", "a transcript row right above")
        for (fixture, hint) in [(F.codexAsync166OpenQ1, "   ⇧← next question"), (F.codexAsync2OpenQ1, "   shift+← next question")] {
            let headed = try observe(fixture), bare = try replacing(fixture, .codex, hint, "")
            XCTAssertEqual(bare.placement, headed.placement, "the counter heading the question's rows")
            XCTAssertEqual(bare.identity, headed.identity)
        }
        // Codex marks queued inputs and replies with ↳, at the panel's indent.
        let queued = try replacing(F.codexAsyncParagraphsQ2, .codex, "• Queued follow-up inputs\n\n\n",
                                   "  ↳ also bump the version\n\n\n")
        XCTAssertEqual(queued.question, second.question)
        XCTAssertEqual(try XCTUnwrap(parse(F.codexAsyncParagraphsQ2.text.replacingOccurrences(of: "  Describe the rollout window you prefer.\n\n  Type",
            with: "  ↳ also bump the version\n  Describe the rollout window you prefer.\n\n  Type"), .codex, cursor: nil)).question,
            "Describe the rollout window you prefer.", "a ↳ row right above")
        // At the screen's top, rows past two blank ones may be the transcript's.
        let rows = F.codexAsyncParagraphsQ2.text.components(separatedBy: "\n")
        let panelTop = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("  Production takes") })
        let topped = try XCTUnwrap(parse((["    Postgres", "", ""] + rows[panelTop...]).joined(separator: "\n"), .codex, cursor: nil))
        XCTAssertEqual(topped.question, second.question)
        XCTAssertEqual(topped.identity, second.identity)
        // A panel as far out as the transcript cannot be told from it.
        let flush = F.codexAsyncParagraphsQ2.text.components(separatedBy: "\n")
            .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(parse(flush, .codex, cursor: nil)).question, "Describe the rollout window you prefer.")

        let typed = F.Fixture(cursorRow: nil, cursorVisible: false,
                              text: F.codexAsyncParagraphsQ1.text.replacingOccurrences(of: "  Type your answer", with: "  Staging mornings"))
        var drive = try Drive(.codex, .text("Staging mornings"), F.codexAsyncParagraphsQ1)
        XCTAssertEqual(drive.next(F.codexAsyncParagraphsQ1), .send("Staging mornings", .type))
        XCTAssertEqual(drive.next(typed), .send("\r", .submit))
        XCTAssertEqual(drive.next(F.codexAsyncParagraphsQ2), .done, "the twin is the next question, not this one unanswered")
    }

    /// Kimi elides a phone's tab bar where the width cuts it. Each tab's
    /// mark, by its place, tells the questions apart at any width.
    func testAnElidedKimiTabBarStillTellsAlikeQuestionsApart() throws {
        let bar = "   Database   (○) Features   Submit"
        let elided = try replacing(F.kimiAsk2, .kimi, bar, "   Database   (○) Features   S...")
        XCTAssertEqual(elided.progress, "Database (○) Features S...")
        XCTAssertEqual(AgentPromptObservationResult.placementParts(elided.placement), ["tab1": "-", "tab2": "○", "tab3": "-"])
        XCTAssertTrue(same(try observe(F.kimiAsk2), elided), "the whole bar")
        for narrower in ["   Database   (○) Feat...", "   Database   (○...", "   Database   ...", "   Data…"] {
            XCTAssertTrue(same(try replacing(F.kimiAsk2, .kimi, bar, narrower), elided), narrower)
        }
        XCTAssertFalse(same(try replacing(F.kimiAsk2, .kimi, bar, "  (✓) Database   Features    S..."), elided))
        let long = try replacing(F.kimiAsk2, .kimi, bar, "   Which database the service will use for its led...")
        XCTAssertEqual(AgentPromptObservationResult.placementParts(long.placement), ["tab1": "-"], "cut before any mark")
        XCTAssertFalse(same(try replacing(F.kimiAsk2, .kimi, bar, "  (✓) Which database the service will use for i..."), long))
        XCTAssertEqual(try observe(F.kimiReviewTallPhone).progress, "(✓) Import lever (✓) Release (✓) Audit check S...")
    }

    /// A pane about as tall as the dialog can scroll its tab bar or chip off
    /// between steps, here as the typed answer grows. What is off screen says
    /// nothing; the answer goes on.
    func testATabBarScrolledOffBetweenStepsKeepsTheAnswer() throws {
        func scrolled(_ fixture: F.Fixture, from question: String) throws -> F.Fixture {
            let start = try XCTUnwrap(fixture.text.range(of: question), question).lowerBound
            return F.Fixture(cursorRow: nil, cursorVisible: false, text: "\n" + fixture.text[start...])
        }
        let typed = try scrolled(F.claudeAskSingleTyped, from: "Which database should the service use for the new ledger?")
        XCTAssertNil(try XCTUnwrap(parse(typed.text, .claude, cursor: nil)).placement)
        var single = try Drive(.claude, .text("abc 123"), F.claudeAskSingle)
        XCTAssertEqual(single.next(F.claudeAskSingle), .send("4", .focus))
        XCTAssertEqual(single.next(F.claudeAskSingleTypeFocused), .send("abc 123", .type))
        XCTAssertEqual(single.next(typed), .send("\r", .submit), "the chip scrolled off")

        let focused = F.Fixture(cursorRow: nil, cursorVisible: false, text: F.claudeAsk3Q1.text
            .replacingOccurrences(of: "❯ 1. Postgres", with: "  1. Postgres")
            .replacingOccurrences(of: "  3. Type something.", with: "❯ 3. Type something."))
        let batchTyped = try scrolled(F.Fixture(cursorRow: nil, cursorVisible: false,
            text: focused.text.replacingOccurrences(of: "❯ 3. Type something.", with: "❯ 3. abc 123")),
            from: "Which database should the service use?")
        var batch = try Drive(.claude, .text("abc 123"), F.claudeAsk3Q1)
        XCTAssertEqual(batch.next(F.claudeAsk3Q1), .send("3", .focus))
        XCTAssertEqual(batch.next(focused), .send("abc 123", .type))
        XCTAssertEqual(batch.next(batchTyped), .send("\r", .submit), "the tab bar scrolled off")
    }

    /// The arrow out of a focused field is not an answer. If the question it
    /// left was answered meanwhile, its twin asked next gets no digit.
    func testAnArrowThenAnAlikeNextQuestionWritesNoDigit() throws {
        let focused = F.Fixture(cursorRow: nil, cursorVisible: false, text: F.claudeAsk3Q1.text
            .replacingOccurrences(of: "❯ 1. Postgres", with: "  1. Postgres")
            .replacingOccurrences(of: "  3. Type something.", with: "❯ 3. Type something."))
        let twin = F.claudeAsk3Q1.text.replacingOccurrences(of: "←  ☐ Database", with: "←  ☒ Database")
        var drive = try Drive(.claude, .option("1"), focused)
        XCTAssertEqual(drive.next(focused), .send("\u{1b}[A", .navigate))
        XCTAssertEqual(drive.next(twin), .refuse(.verificationFailed))

        var own = try Drive(.claude, .option("1"), focused)
        XCTAssertEqual(own.next(focused), .send("\u{1b}[A", .navigate))
        XCTAssertEqual(own.next(F.claudeAsk3Q1), .send("1", .select), "its own question still takes the digit")
    }

    private func same(_ shown: AgentPromptObservationResult, _ other: AgentPromptObservationResult) -> Bool {
        shown.isSameQuestion(identity: other.identity, placement: other.placement)
    }

    private func replacing(_ fixture: F.Fixture, _ provider: AgentProviderID, _ from: String, _ to: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> AgentPromptObservationResult {
        XCTAssertTrue(fixture.text.contains(from), from, file: file, line: line)
        return try XCTUnwrap(parse(fixture.text.replacingOccurrences(of: from, with: to), provider, cursor: nil), to,
                             file: file, line: line)
    }

    func testEveryFixtureStaysWithinTheObservationBounds() throws {
        for (name, fixture) in F.all {
            guard let observed = parse(fixture, provider: provider(name)) else { continue }
            XCTAssertLessThanOrEqual(observed.signature.utf8.count, 1_024, name)
            XCTAssertLessThanOrEqual(observed.identity.utf8.count, 1_024, name)
            let decoded = try JSONDecoder().decode(AgentPromptObservationResult.self, from: JSONEncoder().encode(observed))
            XCTAssertEqual(decoded, observed, name)
        }
    }

    // MARK: Captures

    /// Both apps capture a tmux pane with `capture-pane -e -N`: SGR and OSC 8
    /// links arrive with its cells, and none of them is a cell. Android
    /// mirrors these cases (AgentLivePromptTest).
    func testEscapesAreRemovedAndOnlyTheirCellsRemain() {
        let cases: [(String, String)] = [
            ("\u{1B}[38;5;246m3.\u{1B}[39m Stop", "3. Stop"),
            ("\u{1B}[1;38;2;215;119;87m❯\u{1B}[0m 1.", "❯ 1."),
            ("\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07} text", "link text"),
            ("\u{1B}]8;id=1;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\", "link"),
            ("\u{1B}(Bplain\u{1B}7\u{1B}=", "plain"),
            ("row\u{1B}[38;5\nnext", "row\nnext"),
            ("row\u{1B}\nnext", "row\nnext"),
            ("\u{1B}❯ 1.", "❯ 1."),
            ("\u{1B}]8;;unterminated\nnext", "\nnext"),
            ("\u{1B}]8;;a\u{1B}[31mred", "red"),
            ("\u{1B}[31m\u{1B}[0m", ""),
            ("end\u{1B}", "end"),
            ("\u{1B}\u{1B}[31mred", "red"),
            ("plain ☐ row", "plain ☐ row"),
        ]
        for (raw, plain) in cases { XCTAssertEqual(AgentPromptGrammar.withoutEscapes(raw), plain, raw.debugDescription) }
        XCTAssertEqual(AgentPromptGrammar.promptText(fromCapture: "\u{1B}[1mdiscard\u{1B}[0m\na\n\u{1B}[2mb\u{1B}[22m", limit: 3), "a\nb")
        // Backgrounds stay, each row on its own (Claude's current tab).
        let backgrounds: [(String, String)] = [
            ("a\u{1B}[38;5;16m\u{1B}[48;5;153mb\u{1B}[39m\u{1B}[49mc", "a\u{1B}[0;48;5;153mb\u{1B}[0mc"),
            ("\u{1B}[44mab\ncd\u{1B}[0m", "\u{1B}[0;44mab\u{1B}[0m\n\u{1B}[0;44mcd\u{1B}[0m"),
            ("\u{1B}[7mx\u{1B}[27my", "\u{1B}[0;7mx\u{1B}[0my"),
            ("\u{1B}[7;104mx\u{1B}[0my", "\u{1B}[0;7;104mx\u{1B}[0my"),
            ("\u{1B}[48:2::1:2:3mx", "\u{1B}[0;48;2;1;2;3mx\u{1B}[0m"),
            ("\u{1B}[48;2;1;2;3mx\u{1B}[48;2;1;2;3my", "\u{1B}[0;48;2;1;2;3mxy\u{1B}[0m"),
            ("\u{1B}[38;5;48mx\u{1B}[38;2;48;5;153my", "xy"),
            ("\u{1B}[48;5mx\u{1B}[48;5;256my\u{1B}[?7mz", "xyz"),
            ("\u{1B}[44m\u{1B}[0m\u{1B}[45m", ""),
            ("\u{1B}[44m\u{1B}[38;5\nx", "\n\u{1B}[0;44mx\u{1B}[0m"),
        ]
        for (raw, kept) in backgrounds {
            XCTAssertEqual(AgentPromptGrammar.promptText(fromCapture: raw), kept, raw.debugDescription)
            XCTAssertEqual(AgentPromptGrammar.withoutEscapes(kept), AgentPromptGrammar.withoutEscapes(raw), raw.debugDescription)
        }
        // The bound counts cells, not the styles around them.
        let rows = (1...40).map { "  \($0). " + String(repeating: "option", count: 12) }
        let styled = rows.map { $0.map { "\u{1B}[38;5;246m\($0)" }.joined() + "\u{1B}[39m" }.joined(separator: "\n")
        XCTAssertGreaterThan(styled.utf8.count, 16_384)
        XCTAssertEqual(AgentPromptGrammar.promptText(fromCapture: styled), rows.joined(separator: "\n"))
    }

    /// Every screen reads the same through the styles tmux captures with it,
    /// whether a platform removed them before bounding or sent them along.
    func testEveryScreenReadsTheSameWithTheStylesTmuxCaptures() throws {
        for (name, fixture) in F.all {
            let styled = fixture.text.components(separatedBy: "\n").map { row in
                row.isEmpty ? row : "\u{1B}[38;5;246m" + row.replacingOccurrences(of: " ", with: "\u{1B}[39m \u{1B}[2m") + "\u{1B}[0m"
            }.joined(separator: "\n")
            let cursor = fixture.cursorLine.map { "\u{1B}[1m\($0)\u{1B}[22m" }
            let plain = parse(fixture, provider: provider(name))
            let bounded = try XCTUnwrap(AgentPromptObservationRequest(providerID: provider(name),
                visibleText: AgentPromptGrammar.promptText(fromCapture: styled), currentCursorLine: cursor), name)
            XCTAssertEqual(AgentPromptGrammar.observe(bounded), plain, name)
            if let sent = AgentPromptObservationRequest(providerID: provider(name), visibleText: styled, currentCursorLine: cursor) {
                XCTAssertEqual(AgentPromptGrammar.observe(sent), plain, name)
            }
        }
    }

    /// A phone sizes the tmux window to itself (56 columns on an Android
    /// phone, 49 on an iPhone in portrait): the dialogs wrap their questions,
    /// details and key hints, a short pane scrolls a tall dialog's top off, and
    /// Kimi elides its hints' tail. The card reads the same question as the
    /// wide screen does.
    func testPhoneWidthDialogsReadTheirWholeQuestion() throws {
        let plan = "Which plan should the next run use? The last run of the ledger import (src/…/import/batch_job.py, "
            + "120 rows per batch) finished in 244 s against a 164–190 s budget, and the retry pass after it took 62.6 s "
            + "for 33,945 rows. The fast path is about 1.7× quicker than the current one, but it skips the checksum pass, "
            + "so a corrupt batch would only show up in the nightly audit. Which trade-off do you want?"
        let phone = try observe(F.claudeAskWidePhone), narrow = try observe(F.claudeAskWideNarrow)
        for ask in [phone, narrow] {
            XCTAssertEqual(ask.kind, .question)
            XCTAssertEqual(ask.question, plan, "the quote rail and the row breaks are not the question's")
            XCTAssertEqual(ask.progress, "☐ Run plan ☐ Report ✔ Submit")
            XCTAssertEqual(ask.options.map(\.label), ["Keep the current plan (safe)", "Switch to the fast path", "Stop and report",
                                                      "Type something.", "Chat about this"])
            XCTAssertEqual(ask.options.map(\.role), [.choice, .choice, .choice, .freeform, .chat])
            XCTAssertEqual(ask.options[1].detail, "Skip the checksum pass for this run, keep a copy of every batch, and rely on "
                + "the nightly audit to catch a corrupt one.")
            XCTAssertEqual(ask.controls.map(\.kind), [.cancel], "the wrapped key hints still offer Esc")
        }
        XCTAssertEqual(narrow.identity, phone.identity, "the same question on every device")

        let short = try observe(F.claudeAskWideShortPane)
        XCTAssertEqual(short.kind, .question)
        XCTAssertNil(short.progress, "the tabs scrolled off with the dialog's top")
        XCTAssertTrue(plan.hasSuffix(try XCTUnwrap(short.question)))
        XCTAssertEqual(short.options.map(\.label), phone.options.map(\.label))

        let rui = try observe(F.codexRuiPhone)
        XCTAssertEqual(rui.question, "Which database should we use?")
        XCTAssertEqual(rui.options.map(\.detail), ["Transactional and deployed.", "Embedded, zero operations.",
                                                   "Optionally, add details in notes (tab)"])
        XCTAssertEqual(rui.identity, try observe(F.codexRuiPlan).identity)
        // Open, the notes field's hints wrap onto two rows.
        let notes = try observe(F.codexRuiNotesOpenPhone), wide = try observe(F.codexRuiNotesOpen)
        XCTAssertEqual(notes.entry, wide.entry)
        XCTAssertEqual(notes.entry?.optionID, "3")
        XCTAssertEqual(notes.identity, wide.identity)
        XCTAssertTrue(same(notes, wide))

        let kimi = try observe(F.kimiAskPhone)
        XCTAssertEqual(kimi.question, "Which database should the service use for the new ledger?")
        XCTAssertEqual(kimi.identity, try observe(F.kimiAskSingle).identity)
        XCTAssertEqual(kimi.controls.map(\.kind), [.cancel], "Kimi elides \"esc cancel\"; Esc still cancels")
        let review = try observe(F.kimiReviewElidedPhone)
        XCTAssertEqual(review.kind, .review)
        XCTAssertEqual(review.controls.map(\.kind), [.cancel])
    }

    /// The key hints anchor a dialog whose top scrolled off; the same rows
    /// under a composer, or hints that only look wrapped, anchor nothing.
    func testWrappedHintsAnchorOnlyADialog() {
        let rule = String(repeating: "─", count: 56)
        let composer = "\n\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"
        for fixture in [F.claudeAskWidePhone, F.claudeAskWideShortPane, F.codexRuiPhone] {
            let provider: AgentProviderID = fixture.text == F.codexRuiPhone.text ? .codex : .claude
            XCTAssertNil(parse(fixture.text + composer, provider, cursor: "❯ "))
        }
        // Output that merely ends in a hint-like row is not a footer run.
        let printed = F.claudeAskSingle.text.replacingOccurrences(of: "Enter to select · ↑/↓ to navigate · Esc to cancel",
                                                                  with: "Saved the report.\nEnter to select · ↑/↓ to navigate · Esc to cancel")
        XCTAssertNil(parse(printed, .claude, cursor: nil))
        // Without its rule, a menu printed as transcript output, or options
        // cropped away from their question, is not a dialog.
        let hints = "Enter to select · ↑/↓ to navigate · Esc to cancel"
        let example = "Which database should we use?\n  1. Postgres\n  2. Type something.\n\n\(hints)"
        XCTAssertNotNil(parse(example, .claude, cursor: nil))
        XCTAssertNil(parse("⏺ Documentation example (not an active dialog)\n" + example, .claude, cursor: nil))
        XCTAssertNil(parse("❯ 1. Proceed\n  2. Type something.\n\n\(hints)", .claude, cursor: nil))
        // Codex wraps whole hints; a row above them that is not hints is
        // no part of them, and the dialog's options stay out of reach.
        let codex = "  Question 1/1\n  Which database should we use?\n\n  › 1. Postgres\n    2. SQLite\n"
        let codexHints = "  tab to add notes | enter to submit answer\n  esc to interrupt"
        XCTAssertEqual(parse(codex + "\n" + codexHints, .codex, cursor: nil)?.options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertEqual(parse(codex + codexHints, .codex, cursor: nil)?.options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertNil(parse(codex + "\n  Answer submitted.\n" + codexHints, .codex, cursor: nil))
    }

    /// A pane shorter than Claude's dialog scrolls its question off, so its
    /// options start the screen over live key hints. Only a caller that
    /// knows the question reads them, and their signature marks the crop.
    func testOptionsCroppedFromTheirQuestionReadOnlyOnRequest() throws {
        let rows = F.claudeAskSingle.text.components(separatedBy: "\n")
        let text = rows.drop { !$0.hasPrefix("❯ 1.") }.joined(separator: "\n")
        let request = AgentPromptObservationRequest(providerID: .claude, visibleText: text, currentCursorLine: nil)!
        XCTAssertNil(AgentPromptGrammar.observe(request))
        let cropped = try XCTUnwrap(AgentPromptGrammar.observe(request, allowingCroppedTop: true))
        XCTAssertTrue(cropped.isCropped)
        XCTAssertEqual(cropped.kind, .question)
        XCTAssertNil(cropped.title)
        XCTAssertNil(cropped.question)
        XCTAssertEqual(cropped.options.map(\.label), ["Postgres (Recommended)", "SQLite", "DynamoDB", "Type something.", "Chat about this"])
        XCTAssertEqual(cropped.options.map(\.role), [.choice, .choice, .choice, .freeform, .chat])
        XCTAssertEqual(cropped.controls.map(\.kind), [.cancel])
        let full = try observe(F.claudeAskSingle)
        XCTAssertNotEqual(cropped.signature, full.signature, "a token for the whole dialog never answers its crop")
        let whole = try XCTUnwrap(AgentPromptGrammar.observe(self.request(F.claudeAskSingle), allowingCroppedTop: true))
        XCTAssertFalse(whole.isCropped)
        XCTAssertEqual(whole.signature, full.signature, "a dialog shown whole reads the same either way")
        XCTAssertEqual(try JSONDecoder().decode(AgentPromptObservationResult.self, from: JSONEncoder().encode(cropped)), cropped)

        // Transcript output, a permission (it needs its question) and options
        // with no live hints under them stay out even on request.
        let hints = "Enter to select · ↑/↓ to navigate · Esc to cancel"
        for screen in ["⏺ Documentation example (not an active dialog)\n❯ 1. Proceed\n  2. Type something.\n\n\(hints)",
                       "❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No\n\nEsc to cancel · Tab to amend",
                       "❯ 1. Proceed\n  2. Type something.\n"] {
            let screenRequest = AgentPromptObservationRequest(providerID: .claude, visibleText: screen, currentCursorLine: nil)!
            XCTAssertNil(AgentPromptGrammar.observe(screenRequest, allowingCroppedTop: true), screen)
        }

        // The answer verifies the cropped screen itself.
        var answer = Drive(.claude, .option("2"), expected: cropped.signature)
        XCTAssertEqual(answer.next(full), .refuse(.stalePrompt), "the token names the crop, not the whole dialog")
        answer = Drive(.claude, .option("2"), expected: cropped.signature)
        XCTAssertEqual(answer.next(cropped), .send("2", .select))
        XCTAssertEqual(answer.next(F.claudeAskAfterEsc), .done)
    }

    /// A review of long questions runs taller than any fixed search for its
    /// top rule, or than the pane. Claude's shows no key hints, so its own
    /// last rows anchor it once the rule scrolls off.
    func testTallReviewsStillOfferSubmit() throws {
        for fixture in [F.claudeReviewTallPhone, F.claudeReviewTallerPhone, F.claudeReviewScrolledShort] {
            let review = try observe(fixture)
            XCTAssertEqual(review.kind, .review)
            XCTAssertTrue(review.isBlocking)
            XCTAssertEqual(review.question, "Ready to submit your answers?")
            XCTAssertEqual(review.options.map(\.label), ["Submit answers", "Cancel"])
        }
        XCTAssertEqual(try observe(F.claudeReviewTallPhone).progress, "☒ Import lever ☒ Release ☒ Audit check ✔ Submit")
        XCTAssertNil(try observe(F.claudeReviewScrolledShort).progress, "the tabs scrolled off with the rule")
        var submit = try Drive(.claude, .option("1"), F.claudeReviewScrolledShort)
        XCTAssertEqual(submit.next(F.claudeReviewScrolledShort), .send("1", .select))

        for fixture in [F.kimiReviewTallPhone, F.kimiReviewScrolledPhone] {
            let review = try observe(fixture)
            XCTAssertEqual(review.kind, .review)
            XCTAssertEqual(review.options.map(\.label), ["Submit", "Cancel"])
        }

        // Without a rule, only Claude's own review tail anchors: its last
        // question row over exactly Submit answers and Cancel, with no
        // transcript output above, at the bottom of the screen.
        let tail = "   → Batch the vendor reads\n\nReady to submit your answers?\n\n❯ 1. Submit answers\n  2. Cancel"
        XCTAssertEqual(parse(tail, .claude, cursor: nil)?.kind, .review)
        XCTAssertNil(parse("⏺ Printed:\n" + tail, .claude, cursor: nil))
        XCTAssertNil(parse("  ⎿  Printed:\n" + tail, .claude, cursor: nil))
        XCTAssertNil(parse(tail + "\n  3. Save a draft", .claude, cursor: nil))
        XCTAssertNil(parse(tail.replacingOccurrences(of: "Ready to submit your answers?", with: "Ready to ship?"), .claude, cursor: nil))
        let rule = String(repeating: "─", count: 56)
        XCTAssertNil(parse(F.claudeReviewScrolledShort.text + "\n\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts", .claude, cursor: nil))
        // A question may wrap onto a glyph: under its rule, or behind the
        // rail, it is still the question's.
        let hints = "Enter to select · ↑/↓ to navigate · Esc to cancel"
        let options = "\n\n❯ 1. Keep it\n  2. Type something.\n\n\(hints)"
        let wrapped = "\(rule)\n ☐ Symbols\n\nShould the parser skip every row that starts with\n⏺ glyphs?" + options
        XCTAssertEqual(parse(wrapped, .claude, cursor: nil)?.question, "Should the parser skip every row that starts with ⏺ glyphs?")
        XCTAssertEqual(parse("\(rule)\n ☐ Symbols\n\n│ ⏺ means recording. Keep that symbol?" + options, .claude, cursor: nil)?.kind, .question)
        let railed = F.claudeReviewScrolledShort.text.replacingOccurrences(of: "keeping the audit order stable?", with: "⏺ rows keep the audit order?")
        XCTAssertEqual(parse(railed, .claude, cursor: nil)?.kind, .review)

        // Kimi draws the transcript's prompts (✨) and replies (●) one column
        // in, where its panel has only labels: never inside a panel, however
        // far up the rule above them is. Question text wraps deeper.
        for printed in [" ✨ Printed review\n", " ● Collected your answers\n"] {
            XCTAssertNil(parse(printed + F.kimiReviewScrolledPhone.text, .kimi, cursor: nil), printed)
        }
        let kimiRule = " " + String(repeating: "─", count: 54)
        func panel(_ first: String) -> String {
            ([kimiRule, first] + Array(repeating: "   Documentation continuation", count: 25)
                + [" Ready to submit your answers?", "", "  → [1] Submit", "    [2] Cancel", "",
                   "  ↑↓ select  1/2 choose  ↵ confirm", kimiRule, " Mock  ~/work"]).joined(separator: "\n")
        }
        XCTAssertEqual(parse(panel("   Printed example:"), .kimi, cursor: nil)?.kind, .review)
        XCTAssertNil(parse(panel(" ● Printed example:"), .kimi, cursor: nil))
        XCTAssertNil(parse(panel(" ✨ Printed example:"), .kimi, cursor: nil))
        let bullet = F.kimiReviewScrolledPhone.text.replacingOccurrences(of: "nightly import (src/", with: "● nightly import (src/")
        XCTAssertEqual(parse(bullet, .kimi, cursor: nil)?.kind, .review)
        let wrappedKimi = F.kimiAskPhone.text.replacingOccurrences(of: "ledger?", with: "● ledger?")
        XCTAssertEqual(try XCTUnwrap(parse(wrappedKimi, .kimi, cursor: nil)).question,
                       "Which database should the service use for the new ● ledger?", "a wrapped question row sits deeper")
    }

    // MARK: Planner

    func testPlannerDistinguishesNamedKeysFromAnswerText() throws {
        var typed = try Drive(.claude, .text("abc 123"), F.claudeAskSingle)
        XCTAssertNil(typed.next(F.claudeAskSingle).semanticKey, "an option digit stays text")
        XCTAssertNil(typed.next(F.claudeAskSingleTypeFocused).semanticKey)
        let submit = typed.next(F.claudeAskSingleTyped)
        XCTAssertEqual(submit.semanticKey, .enter)
        XCTAssertEqual(submit.bytes, "\r", "raw and older consumers retain their byte output")

        var leave = try Drive(.claude, .option("1"), F.claudeAskSingleTypeFocused)
        XCTAssertEqual(leave.next(F.claudeAskSingleTypeFocused).semanticKey, .up)
        var cancel = try Drive(.claude, .control(.cancel), F.claudeAskSingle)
        XCTAssertEqual(cancel.next(F.claudeAskSingle).semanticKey, .escape)
        var next = try Drive(.claude, .control(.next), F.claudeAsk3Q2Multi)
        XCTAssertEqual(next.next(F.claudeAsk3Q2Multi).semanticKey, .tab)
        var open = try Drive(.codex, .control(.open), F.codexAsync2Collapsed)
        XCTAssertEqual(open.next(F.codexAsync2Collapsed).semanticKey, .shiftLeft)
        var skip = try Drive(.codex, .control(.skip), F.codexAsync2OpenQ1)
        XCTAssertEqual(skip.next(F.codexAsync2OpenQ1).semanticKey, .controlRightBracket)
    }

    func testPlannerKeyMetadataIsAdditiveToTheEncodedStep() throws {
        let legacy = Data(#"{"action":"send","bytes":"\r","phase":"submit"}"#.utf8)
        let step = try JSONDecoder().decode(AgentPromptAnswerStep.self, from: legacy)
        XCTAssertEqual(step.bytes, "\r")
        XCTAssertNil(step.semanticKey)
        let named = AgentPromptAnswerStep.send("\r", .submit)
        let encoded = try JSONEncoder().encode(named)
        XCTAssertEqual(try JSONDecoder().decode(AgentPromptAnswerStep.self, from: encoded), named)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(fields["bytes"], "\r")
        XCTAssertEqual(fields["semanticKey"], "Enter")
    }

    func testClaudeOptionAnswersWithItsDigitAlone() throws {
        var drive = try Drive(.claude, .option("2"), F.claudeAskSingle)
        XCTAssertEqual(drive.next(F.claudeAskSingle), .send("2", .select))
        XCTAssertEqual(drive.next(F.claudeAskAfterEsc), .done)
    }

    func testClaudeTypedAnswerFocusesTypesAndSubmits() throws {
        var drive = try Drive(.claude, .text("abc 123"), F.claudeAskSingle)
        XCTAssertEqual(drive.next(F.claudeAskSingle), .send("4", .focus))
        XCTAssertEqual(drive.next(F.claudeAskSingle), .wait, "the digit has not repainted yet")
        XCTAssertEqual(drive.next(F.claudeAskSingleTypeFocused), .send("abc 123", .type))
        XCTAssertEqual(drive.next(F.claudeAskSingleTypeFocused), .wait)
        XCTAssertEqual(drive.next(F.claudeAskSingleTyped), .send("\r", .submit))
        XCTAssertEqual(drive.next(F.claudeAskAfterEsc), .done)
    }

    func testATextRowIsNeverAnsweredAsAnOption() throws {
        var drive = try Drive(.claude, .option("4"), F.claudeAskSingle)
        XCTAssertEqual(drive.next(F.claudeAskSingle), .refuse(.unsupported))
        var multi = try Drive(.claude, .text("Audit log"), F.claudeAsk3Q2Multi)
        XCTAssertEqual(multi.next(F.claudeAsk3Q2Multi), .refuse(.unsupported))
        var permission = try Drive(.claude, .text("no"), F.claudePermBash)
        XCTAssertEqual(permission.next(F.claudePermBash), .refuse(.unsupported))
    }

    func testTextNeverLandsOnSomeoneElsesDraft() throws {
        var drive = try Drive(.claude, .text("hello"), F.claudeAskSingleTyped)
        XCTAssertEqual(drive.next(F.claudeAskSingleTyped), .refuse(.occupied))
        var option = try Drive(.claude, .option("1"), F.claudeAskSingleTyped)
        XCTAssertEqual(option.next(F.claudeAskSingleTyped), .refuse(.occupied), "leaving the field would drop its text")
    }

    /// A digit typed while a text field has focus lands in the field.
    func testAnOptionFirstLeavesAFocusedEmptyField() throws {
        var drive = try Drive(.claude, .option("1"), F.claudeAskSingleTypeFocused)
        XCTAssertEqual(drive.next(F.claudeAskSingleTypeFocused), .send("\u{1b}[A", .navigate))
        XCTAssertEqual(drive.next(F.claudeAskSingleTypeFocused), .wait)
        XCTAssertEqual(drive.next(F.claudeAskSingle), .send("1", .select))
        XCTAssertEqual(drive.next(F.claudeAskAfterEsc), .done)

        var kimi = try Drive(.kimi, .option("2"), F.kimiOtherFocused)
        XCTAssertEqual(kimi.next(F.kimiOtherFocused), .send("\u{1b}[A", .navigate))
        XCTAssertEqual(kimi.next(F.kimiAskSingle), .send("2", .select))
        XCTAssertEqual(kimi.next(F.kimiAskAfter2), .done)

        var stuck = try Drive(.codex, .option("1"), F.codexAsync1OtherFocused)
        XCTAssertEqual(stuck.next(F.codexAsync1OtherFocused), .send("\u{1b}[A", .navigate))
        for _ in 0..<AgentPromptAnswerPlanner.maximumWaits { XCTAssertEqual(stuck.next(F.codexAsync1OtherFocused), .wait) }
        XCTAssertEqual(stuck.next(F.codexAsync1OtherFocused), .refuse(.verificationFailed))
    }

    func testAFocusKeyThatLeavesThePromptFailsVerification() throws {
        var drive = try Drive(.claude, .text("abc 123"), F.claudeAskSingle)
        XCTAssertEqual(drive.next(F.claudeAskSingle), .send("4", .focus))
        XCTAssertEqual(drive.next(F.claudeAskAfterEsc), .refuse(.verificationFailed),
                       "a focus key cannot answer: the prompt vanishing means something else acted")
    }

    func testAKeyThatNeverRepaintsFailsWithoutAnotherWrite() throws {
        var drive = try Drive(.claude, .option("1"), F.claudePermBash)
        XCTAssertEqual(drive.next(F.claudePermBash), .send("1", .select))
        for _ in 0..<AgentPromptAnswerPlanner.maximumWaits { XCTAssertEqual(drive.next(F.claudePermBash), .wait) }
        XCTAssertEqual(drive.next(F.claudePermBash), .refuse(.verificationFailed))
    }

    func testAStaleOrMissingPromptRefusesTheFirstWrite() throws {
        var drive = try Drive(.claude, .option("1"), F.claudeAskSingle)
        XCTAssertEqual(drive.next(F.claudeAskSingleTyped), .refuse(.stalePrompt))
        var gone = try Drive(.claude, .option("1"), F.claudeAskSingle)
        XCTAssertEqual(gone.next(F.claudeAskAfterEsc), .refuse(.stalePrompt))
        var other = try Drive(.claude, .option("1"), F.claudeAskSingle)
        XCTAssertEqual(other.next(F.claudeAsk3Q1), .refuse(.stalePrompt))
    }

    func testClaudeMultiSelectTogglesAndLeavesThroughNext() throws {
        var toggle = try Drive(.claude, .option("1"), F.claudeAsk3Q2Multi)
        XCTAssertEqual(toggle.next(F.claudeAsk3Q2Multi), .send("1", .select))
        XCTAssertEqual(toggle.next(F.claudeAsk3Q2Toggled), .done, "the toggled box is the answer")

        // Tab from a choice row advances to the next question.
        var next = try Drive(.claude, .control(.next), F.claudeAsk3Q2Toggled)
        XCTAssertEqual(next.next(F.claudeAsk3Q2Toggled), .send("\t", .control))
        XCTAssertEqual(next.next(F.claudeAsk3Review), .done)

        // Tab from the text row lands on Next, and Enter there advances.
        var fromText = try Drive(.claude, .control(.next), F.claudeAsk3Q2Row4Typed)
        XCTAssertEqual(fromText.next(F.claudeAsk3Q2Row4Typed), .send("\t", .control))
        let onNext = F.claudeAsk3Q2Row4Typed.text
            .replacingOccurrences(of: "❯ 4. [✔] Audit log", with: "  4. [✔] Audit log")
            .replacingOccurrences(of: "     Next", with: "❯    Next")
        XCTAssertEqual(try XCTUnwrap(parse(onNext, .claude, cursor: nil)).controls.first, .init(kind: .next, label: "Next", isSelected: true))
        XCTAssertEqual(fromText.next(onNext), .send("\r", .control))
        XCTAssertEqual(fromText.next(F.claudeAsk3Review), .done)

        // A selected Next is answered by Enter from the first write.
        var selected = Drive(.claude, .control(.next), expected: try XCTUnwrap(parse(onNext, .claude, cursor: nil)).signature)
        XCTAssertEqual(selected.next(onNext), .send("\r", .control))
    }

    func testClaudeReviewSubmits() throws {
        var drive = try Drive(.claude, .option("1"), F.claudeAsk3Review)
        XCTAssertEqual(drive.next(F.claudeAsk3Review), .send("1", .select))
        XCTAssertEqual(drive.next(F.claudeAskAfterEsc), .done)
    }

    func testCancelAndOpenAreFixedKeys() throws {
        var cancel = try Drive(.claude, .control(.cancel), F.claudeAskSingle)
        XCTAssertEqual(cancel.next(F.claudeAskSingle), .send("\u{1b}", .control))
        XCTAssertEqual(cancel.next(F.claudeAskAfterEsc), .done)
        var missing = try Drive(.claude, .control(.skip), F.claudeAskSingle)
        XCTAssertEqual(missing.next(F.claudeAskSingle), .refuse(.unsupported), "a control the screen does not offer")
    }

    func testCodexAsyncQuestionsOpenAnswerAndSkip() throws {
        var open = try Drive(.codex, .control(.open), F.codexAsync2Collapsed)
        XCTAssertEqual(open.next(F.codexAsync2Collapsed), .send("\u{1b}[1;2D", .control))
        XCTAssertEqual(open.next(F.codexAsync2OpenQ1), .done)

        var option = try Drive(.codex, .option("2"), F.codexAsync2OpenQ1)
        XCTAssertEqual(option.next(F.codexAsync2OpenQ1), .send("2", .select))
        XCTAssertEqual(option.next(F.codexAsync2OpenQ1), .wait, "a question panel acts on its digit; no Enter follows")
        XCTAssertEqual(option.next(F.codexAsync2AfterQ1), .done)

        var text = try Drive(.codex, .text("Weekend, 2 to 4 am"), F.codexAsync2AfterQ1)
        XCTAssertEqual(text.next(F.codexAsync2AfterQ1), .send("Weekend, 2 to 4 am", .type))
        XCTAssertEqual(text.next(F.codexAsync2Q2Typed), .send("\r", .submit))
        XCTAssertEqual(text.next(F.codexAsync2Done), .done)

        var other = try Drive(.codex, .text("CockroachDB 24"), F.codexAsync1Open)
        XCTAssertEqual(other.next(F.codexAsync1Open), .send("4", .focus))
        XCTAssertEqual(other.next(F.codexAsync1OtherFocused), .send("CockroachDB 24", .type))
        XCTAssertEqual(other.next(F.codexAsync1OtherTyped), .send("\r", .submit))
        XCTAssertEqual(other.next(F.codexAsync2Done), .done)

        var skip = try Drive(.codex, .control(.skip), F.codexAsync2OpenQ1)
        XCTAssertEqual(skip.next(F.codexAsync2OpenQ1), .send("\u{1d}", .control))
        XCTAssertEqual(skip.next(F.codexAsync2AfterQ1), .done)
    }

    /// Codex request_user_input answers on a digit, so its notes field is
    /// reached by moving the selection one repaint at a time, then Tab.
    func testCodexBlockingQuestionReachesItsNotesWithArrowsThenTab() throws {
        let plan = F.codexRuiPlan.text
        func selecting(_ row: Int) -> String {
            let rows = ["1. Postgres (Recommended)", "2. SQLite                 ", "3. None of the above      "]
            var text = plan.replacingOccurrences(of: "  › 1. Postgres (Recommended)", with: "    1. Postgres (Recommended)")
            text = text.replacingOccurrences(of: "    \(rows[row - 1])", with: "  › \(rows[row - 1])")
            return text
        }
        XCTAssertEqual(try XCTUnwrap(parse(selecting(2), .codex, cursor: nil)).selectedOptionID, "2")
        XCTAssertEqual(try XCTUnwrap(parse(selecting(3), .codex, cursor: nil)).selectedOptionID, "3")

        var drive = try Drive(.codex, .text("CockroachDB instead"), F.codexRuiPlan)
        XCTAssertEqual(drive.next(plan), .send("\u{1b}[B", .navigate))
        XCTAssertEqual(drive.next(selecting(2)), .wait, "one arrow per repaint")
        XCTAssertEqual(drive.next(selecting(2)), .send("\u{1b}[B", .navigate))
        XCTAssertEqual(drive.next(selecting(3)), .send("\t", .focus), "the notes row is selected")
        XCTAssertEqual(drive.next(F.codexRuiNotesOpen), .send("CockroachDB instead", .type))
        XCTAssertEqual(drive.next(F.codexRuiNotesTyped), .send("\r", .submit))
        XCTAssertEqual(drive.next(F.codexRuiAfter2), .done)

        // A note wider than the field wraps onto rows of its own.
        let long = "CockroachDB with a replica in the east region and a standby in the west region, "
            + "both on NVMe disks with nightly backups"
        for fixture in [F.codexRuiNotesWrapped, F.codexRuiNotesWrappedPhone] {
            let wrapped = try observe(fixture)
            XCTAssertEqual(wrapped.entry, AgentPromptEntry(optionID: "3", text: long))
            XCTAssertEqual(wrapped.identity, try observe(F.codexRuiPlan).identity)
            var typing = try Drive(.codex, .text(long), F.codexRuiNotesOpen)
            XCTAssertEqual(typing.next(F.codexRuiNotesOpen), .send(long, .type))
            XCTAssertEqual(typing.next(fixture), .send("\r", .submit))
        }
        // A word wider than the row breaks inside it (after a slash here),
        // and a note taller than the field scrolls: the field still shows
        // what was typed.
        let path = "/srv/ledger/migrations/2026-11-06/0042_split_the_ledger_tables_into_hot_and_cold_partitions_by_quarter.sql"
        let longer = "CockroachDB with a replica in the east region and a standby in the west region, schema at " + path
            + " which the platform team reviews every quarter. Keep nightly backups for thirty days and weekly ones for a year, "
            + "restore drills every month, and page the on-call engineer when replication lag passes ten seconds for more "
            + "than five minutes during business hours or thirty seconds at any other time, with dashboards for both regions "
            + "kept next to the release calendar so the change freeze is visible to everyone."
        let broken = try observe(F.codexRuiNotesBroken), scrolled = try observe(F.codexRuiNotesScrolledPhone)
        XCTAssertEqual(broken.entry?.text, longer.replacingOccurrences(of: "ledger/migrations", with: "ledger/ migrations"))
        XCTAssertTrue(try XCTUnwrap(scrolled.entry?.text).hasPrefix("when replication lag"))
        XCTAssertTrue(longer.hasSuffix(try XCTUnwrap(scrolled.entry?.text)))
        for fixture in [F.codexRuiNotesBroken, F.codexRuiNotesScrolledPhone] {
            var typing = try Drive(.codex, .text(longer), F.codexRuiNotesOpen)
            XCTAssertEqual(typing.next(F.codexRuiNotesOpen), .send(longer, .type))
            XCTAssertEqual(typing.next(fixture), .send("\r", .submit))
        }
        // Rows indented as far as the field are no note's, and the field
        // starts at the footer's indent.
        let flushNote = F.codexRuiNotesWrappedPhone.text.replacingOccurrences(of: "    region and", with: "  region and")
        XCTAssertNil(parse(flushNote, .codex, cursor: nil))
        let unmarked = F.codexRuiNotesWrappedPhone.text.replacingOccurrences(of: "  › CockroachDB with a replica in the east\n", with: "")
            .replacingOccurrences(of: "    region and", with: "    › region and")
        XCTAssertNil(parse(unmarked, .codex, cursor: nil))
        // With no blank row above the field and its marker row gone, the walk
        // ends on the selected option: that is no note.
        let underOptions = F.codexRuiNotesWrappedPhone.text
            .replacingOccurrences(of: "(tab)\n\n  › CockroachDB with a replica in the east\n", with: "(tab)\n")
        XCTAssertNotEqual(underOptions, F.codexRuiNotesWrappedPhone.text)
        XCTAssertNil(parse(underOptions, .codex, cursor: nil))
        // A note of its own that reads like an option, under its blank row, is one.
        let numbered = F.codexRuiNotesWrappedPhone.text
            .replacingOccurrences(of: "  › CockroachDB with a replica in the east", with: "  › 1. CockroachDB with a replica in the")
        XCTAssertEqual(try XCTUnwrap(parse(numbered, .codex, cursor: nil)).entry?.text,
                       "1. CockroachDB with a replica in the region and a standby in the west region, both on NVMe disks with nightly backups")

        var option = try Drive(.codex, .option("1"), F.codexRuiPlan)
        XCTAssertEqual(option.next(plan), .send("1", .select))
        XCTAssertEqual(option.next(F.codexRuiAfter2), .done)
    }

    /// A Codex list row that requires explicit confirmation only moves the
    /// selection on its digit; Enter follows once the same menu shows it.
    func testCodexExplicitConfirmationRowGetsEnterOnlyAfterTheMove() throws {
        func menu(selected: Int) -> String {
            let rows = ["1. Switch to a smaller model", "2. Keep current model", "3. Keep current model and never ask again"]
            return (["  Approaching rate limits", "  You are close to your usage limit.", ""]
                + rows.enumerated().map { ($0.offset + 1 == selected ? "› " : "  ") + $0.element }
                + ["", "  Press enter to confirm or esc to go back"]).joined(separator: "\n")
        }
        let cursor = "  Press enter to confirm or esc to go back"
        let first = try XCTUnwrap(parse(menu(selected: 1), .codex, cursor: cursor))
        XCTAssertEqual(first.options.map(\.responseMacro), ["1", "2", "3"])

        var move = Drive(.codex, .option("2"), expected: first.signature)
        XCTAssertEqual(move.next(first), .send("2", .select))
        XCTAssertEqual(move.next(try XCTUnwrap(parse(menu(selected: 2), .codex, cursor: cursor))), .send("\r", .confirm))
        XCTAssertEqual(move.next(nil), .done)

        var same = Drive(.codex, .option("1"), expected: first.signature)
        XCTAssertEqual(same.next(first), .send("1", .select))
        for _ in 0..<3 { XCTAssertEqual(same.next(first), .wait) }
        XCTAssertEqual(same.next(first), .send("\r", .confirm), "an unchanged menu after its repaint window")
        XCTAssertEqual(same.next(first), .wait)

        // A letter-keyed approval acts on its key: Enter would reach the composer.
        var approval = try Drive(.codex, .option("1"), F.codexExecApproval)
        XCTAssertEqual(approval.next(F.codexExecApproval), .send("y", .select))
        for _ in 0..<AgentPromptAnswerPlanner.maximumWaits { XCTAssertEqual(approval.next(F.codexExecApproval), .wait) }
        XCTAssertEqual(approval.next(F.codexExecApproval), .refuse(.verificationFailed))
    }

    func testKimiTypedAnswerWaitsForItsWholeText() throws {
        var drive = try Drive(.kimi, .text("abc 123"), F.kimiAskSingle)
        XCTAssertEqual(drive.next(F.kimiAskSingle), .send("3", .focus))
        XCTAssertEqual(drive.next(F.kimiOtherFocused), .send("abc 123", .type))
        XCTAssertEqual(drive.next(F.kimiOtherTyped), .wait, "a partial repaint of the typed text")
        let whole = F.kimiOtherTyped.text.replacingOccurrences(of: "abc 12", with: "abc 123")
        XCTAssertEqual(drive.next(whole), .send("\r", .submit))
        XCTAssertEqual(drive.next(F.kimiAskAfter2), .done)
    }

    func testKimiMultiSelectTogglesAndAdvances() throws {
        var toggle = try Drive(.kimi, .option("2"), F.kimiAsk2Multi)
        XCTAssertEqual(toggle.next(F.kimiAsk2Multi), .send("2", .select))
        XCTAssertEqual(toggle.next(F.kimiAsk2MultiToggled), .done)
        var next = try Drive(.kimi, .control(.next), F.kimiAsk2MultiToggled)
        XCTAssertEqual(next.next(F.kimiAsk2MultiToggled), .send("\t", .control))
        XCTAssertEqual(next.next(F.kimiAsk2Review), .done)
    }

    func testTypedTextIsOnePrintableLine() {
        XCTAssertEqual(AgentPromptAnswerPlanner.sanitizedText("  two\nlines\tand\u{1b}[2J an\u{7}swer \u{2028}"), "two lines and[2J answer")
        XCTAssertEqual(AgentPromptAnswerPlanner.sanitizedText(String(repeating: "x", count: 3_000)).count, 2_000)
        XCTAssertFalse(AgentPromptAnswerGoal.text("\n\t\u{1b}").isValid)
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("…ong answer that scrolled", "a very long answer that scrolled"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("abc", "abc 123"))
        // Rows read back joined by a space: a word broken across them still
        // shows, head or tail, but other words do not.
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("schema at /srv/ledger/ migrations/0042.sql", "schema at /srv/ledger/migrations/0042.sql"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("ledger/ migrations/0042.sql", "schema at /srv/ledger/migrations/0042.sql"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("schema at /srv/led", "schema at /srv/ledger/migrations/0042.sql"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("schema at /srv/ledger/ migrations/0043.sql", "schema at /srv/ledger/migrations/0042.sql"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("ledger/ migrations", "schema at /srv/ledger/migrations/0042.sql"),
                       "a middle part shows neither end")
        // Row breaks only add spaces: one the text holds is never lost.
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("schemaat/srv/ledger", "schema at /srv/ledger"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("schema at /srv/ledger/migrations/0042.sqlwhich", "schema at /srv/ledger/migrations/0042.sql which"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("ledger/migrations/0042.sqlwhich", "schema at /srv/ledger/migrations/0042.sql which"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("led ger/migrations/0042.sql which", "schema at /srv/ledger/migrations/0042.sql which"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("… /srv/ledger/migrations/0042.sql which", "schema at /srv/ledger/migrations/0042.sql which"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("schema at /srv/ledger/migra", "schema at /srv/ledger/migrations/0042.sql"),
                       "the head may end inside a word")
        // Conjoining jamo a dropped space lets merge into one syllable.
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("\u{1100}\u{1161}", "\u{1100} \u{1161}"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("\u{1100} \u{1161}", "\u{1100} \u{1161}"))
        // An ellipsis the text holds itself is no cut.
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("Not sure…", "Not sure…"))
        XCTAssertTrue(AgentPromptAnswerPlanner.shows("…later", "…later"))
        XCTAssertFalse(AgentPromptAnswerPlanner.shows("Not sure", "Not sure…"))
    }

    /// A field that already holds text before anything was typed is the
    /// answer only if it holds all of it, its runs of spaces aside: someone
    /// else's text that reads alike, or a part of the answer, is theirs.
    func testAFieldTypedInByOthersIsNotTheAnswer() throws {
        func holding(_ text: String) -> F.Fixture {
            F.Fixture(cursorRow: nil, cursorVisible: false,
                      text: F.codexAsyncParagraphsQ1.text.replacingOccurrences(of: "  Type your answer", with: "  \(text)"))
        }
        let answer = "Staging mornings, then production"
        for (shown, expected) in [(answer, AgentPromptAnswerStep.send("\r", .submit)),
                                  ("Staging  mornings,  then production", .send("\r", .submit)),
                                  ("Stagingmornings, then production", .refuse(.occupied)),
                                  ("Staging mornings, then", .refuse(.occupied)),
                                  ("mornings, then production", .refuse(.occupied))] {
            var drive = try Drive(.codex, .text(answer), holding(shown))
            XCTAssertEqual(drive.next(holding(shown)), expected, shown)
        }
        // An answer ending in an ellipsis, typed or found, reads back whole.
        var typed = try Drive(.codex, .text("Not sure…"), F.codexAsyncParagraphsQ1)
        XCTAssertEqual(typed.next(F.codexAsyncParagraphsQ1), .send("Not sure…", .type))
        XCTAssertEqual(typed.next(holding("Not sure…")), .send("\r", .submit))
        var found = try Drive(.codex, .text("Not sure…"), holding("Not sure…"))
        XCTAssertEqual(found.next(holding("Not sure…")), .send("\r", .submit))
    }

    func testPlanInputRoundTripsAndRejectsMalformedGoals() throws {
        let observed = try observe(F.claudeAskSingle)
        let plan = AgentPromptAnswerPlanner.next(provider: .claude, goal: .option("1"), expectedSignature: observed.signature,
                                                 anchor: nil, observation: observed, history: [])
        let input = AgentPromptAnswerPlanInput(goal: .option("2"), expectedSignature: observed.signature,
                                               anchor: plan.anchor, history: [.select, .wait])
        XCTAssertTrue(input.isValid)
        XCTAssertEqual(try JSONDecoder().decode(AgentPromptAnswerPlanInput.self, from: JSONEncoder().encode(input)), input)
        XCTAssertEqual(try JSONDecoder().decode(AgentPromptAnswerPlan.self, from: JSONEncoder().encode(plan)), plan)
        for malformed in [#"{"kind":"option"}"#, #"{"kind":"option","optionID":"1","text":"x"}"#,
                          #"{"kind":"text","text":"\n"}"#, #"{"kind":"control","control":"reboot"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(AgentPromptAnswerGoal.self, from: Data(malformed.utf8)), malformed)
        }
        let overlong = AgentPromptAnswerPlanInput(goal: .option("1"), expectedSignature: observed.signature, anchor: plan.anchor,
                                                  history: Array(repeating: .wait, count: AgentPromptAnswerPlanner.maximumSteps + 1))
        XCTAssertFalse(overlong.isValid)
    }

    // MARK: Helpers

    private func provider(_ name: String) -> AgentProviderID {
        name.hasPrefix("claude") ? .claude : name.hasPrefix("codex") ? .codex : .kimi
    }

    private func parse(_ fixture: F.Fixture, provider: AgentProviderID) -> AgentPromptObservationResult? {
        AgentPromptGrammar.observe(AgentPromptObservationRequest(providerID: provider, visibleText: fixture.text,
                                                                 currentCursorLine: fixture.cursorLine)!)
    }

    private func parse(_ text: String, _ provider: AgentProviderID, cursor: String?) -> AgentPromptObservationResult? {
        AgentPromptGrammar.observe(AgentPromptObservationRequest(providerID: provider, visibleText: text, currentCursorLine: cursor)!)
    }

    private func request(_ fixture: F.Fixture) -> AgentPromptObservationRequest {
        AgentPromptObservationRequest(providerID: .claude, visibleText: fixture.text, currentCursorLine: fixture.cursorLine)!
    }

    private func observe(_ fixture: F.Fixture, file: StaticString = #filePath, line: UInt = #line) throws -> AgentPromptObservationResult {
        let name = F.all.first { $0.fixture.text == fixture.text }?.name ?? ""
        return try XCTUnwrap(parse(fixture, provider: provider(name)), name, file: file, line: line)
    }

    /// One answer, replayed the way both platforms run it.
    private struct Drive {
        let provider: AgentProviderID
        let goal: AgentPromptAnswerGoal
        let expected: String
        var anchor: AgentPromptAnswerAnchor?
        var history: [AgentPromptAnswerPhase] = []

        init(_ provider: AgentProviderID, _ goal: AgentPromptAnswerGoal, expected: String) {
            self.provider = provider; self.goal = goal; self.expected = expected
        }

        init(_ provider: AgentProviderID, _ goal: AgentPromptAnswerGoal, _ shown: F.Fixture) throws {
            let observed = try XCTUnwrap(Self.parse(shown.text, provider, cursor: shown.cursorLine))
            self.init(provider, goal, expected: observed.signature)
        }

        mutating func next(_ screen: F.Fixture) -> AgentPromptAnswerStep {
            next(Self.parse(screen.text, provider, cursor: screen.cursorLine))
        }

        mutating func next(_ text: String) -> AgentPromptAnswerStep { next(Self.parse(text, provider, cursor: nil)) }

        mutating func next(_ observation: AgentPromptObservationResult?) -> AgentPromptAnswerStep {
            let plan = AgentPromptAnswerPlanner.next(provider: provider, goal: goal, expectedSignature: expected,
                                                     anchor: anchor, observation: observation, history: history)
            anchor = plan.anchor
            if let phase = plan.step.phase { history.append(phase) }
            return plan.step
        }

        private static func parse(_ text: String, _ provider: AgentProviderID, cursor: String?) -> AgentPromptObservationResult? {
            AgentPromptGrammar.observe(AgentPromptObservationRequest(providerID: provider, visibleText: text, currentCursorLine: cursor)!)
        }
    }
}
