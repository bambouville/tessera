import XCTest
@testable import TesseraAgentCore

/// Question hints from integration v21 hooks tell platforms to watch the
/// terminal; only the captured screen makes a thread need the person.
final class AgentLivePromptRuntimeTests: XCTestCase {
    private typealias F = AgentPromptScreenFixtures

    func testAQuestionHintWatchesTheTerminalAndOnlyTheScreenRaisesAttention() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        XCTAssertEqual(snapshot.summary.attention, .none, "the hook alone is not a question on screen")
        XCTAssertEqual(snapshot.summary.status, .working)
        let listed = await core.listSnapshot().threads.first { $0.id == id }
        XCTAssertEqual(listed?.livePromptWatch, true)

        var changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)
        let prompt = try XCTUnwrap(livePrompt(snapshot))
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.title, "Database")
        XCTAssertEqual(prompt.question, "Which database should the service use for the new ledger?")
        XCTAssertEqual(prompt.options.map(\.id), ["1", "2", "3", "4", "5"], "options answer by id, never by macro")
        XCTAssertEqual(prompt.options.map(\.role), [.choice, .choice, .choice, .freeform, .chat])
        XCTAssertEqual(prompt.acceptsText, true)
        XCTAssertEqual(prompt.isBlocking, true)
        XCTAssertEqual(prompt.controls?.map(\.kind), [.cancel])

        let generation = snapshot.deliveryGeneration
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertFalse(changed, "an unchanged question must not republish the thread")
        let unchanged = try await unwrap(core, id)
        XCTAssertEqual(unchanged.deliveryGeneration, generation)
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskChatSelected), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed, "the card follows the terminal's selection")
        let moved = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(moved)?.token, prompt.token, "moving the selection is the same prompt")
        XCTAssertEqual(moved.summary.attention, .needsYou)

        await apply(core, .claude, .postToolUse, .working, 2, hint: .question)
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertEqual(snapshot.summary.attention, .none)
        XCTAssertEqual(snapshot.summary.status, .working)
        XCTAssertEqual(snapshot.summary.livePromptWatch, false)
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        XCTAssertFalse(changed, "a late capture of the answered question cannot resurrect it")
    }

    /// The laptop's pane is shorter than Claude's dialog: the question
    /// scrolls off and the options start the screen. Only the waiting call
    /// names them, under the crop's own token. A card alone carries nothing:
    /// the next question may offer the same options.
    func testACroppedDialogKeepsItsQuestionOnlyWhileItsCallWaits() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        var changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                                   observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        var snapshot = try await unwrap(core, id)
        let full = try XCTUnwrap(livePrompt(snapshot))

        changed = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot), "a card cannot tell its question from the next one's")

        try await ingest(core, id, [askCall([(ledger, "Database", databases)])])
        changed = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        let kept = try XCTUnwrap(livePrompt(snapshot), "the call brings the replies row back")
        XCTAssertEqual(kept.title, "Database")
        XCTAssertEqual(kept.question, full.question)
        XCTAssertEqual(kept.options.map(\.label), full.options.map(\.label))
        XCTAssertEqual(kept.options.map(\.role), full.options.map(\.role))
        let bare = try XCTUnwrap(AgentPromptGrammar.observe(cropped(F.claudeAskSingle), allowingCroppedTop: true))
        XCTAssertNotEqual(kept.token, AgentPromptGrammar.actionToken(for: bare.signature), "the crop alone names no question")
        let answered = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        let screen = try XCTUnwrap(answered)
        XCTAssertEqual(kept.token, AgentPromptGrammar.actionToken(for: screen.signature), "an answer reads the crop through its call")
        XCTAssertNotEqual(kept.token, full.token)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)

        changed = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertFalse(changed, "a cropped card is as steady as a whole one")
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.token, full.token, "back in the taller pane, the whole dialog's card")

        // Answered in the terminal, and Claude asks its next question with
        // the same options before the transcript shows the answer.
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        await apply(core, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
        _ = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 3)
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot), "the call its hook closed cannot name the next question")
        let audit = "Which database should the audit log use?"
        try await ingest(core, id, [askResult("call-A"), askCall([(audit, "Audit", databases)], id: "call-B")], from: 2)
        changed = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 3)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.title, "Audit")
        XCTAssertEqual(livePrompt(snapshot)?.question, audit)
        XCTAssertNotEqual(livePrompt(snapshot)?.token, kept.token, "the same crop under the next call is another prompt")
    }

    /// An answer started on one question's crop finds the next question's
    /// identical crop once the first call is closed: its first write plans
    /// on a screen that is no longer the prompt it answers, and refuses.
    func testAnAnswerToACroppedQuestionNeverReachesTheNextOne() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(core, id, [askCall([(ledger, "Database", databases)])])
        let waiting = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        let screen = try XCTUnwrap(waiting)
        let staging = AgentPromptGrammar.actionToken(for: screen.signature)
        let goal = AgentPromptAnswerGoal.option("1")
        let first = AgentPromptAnswerPlanner.next(provider: .claude, goal: goal, expectedSignature: screen.signature,
                                                  anchor: nil, observation: screen, history: [])
        XCTAssertEqual(first.step.action, .send, "the waiting call's crop answers")

        // Meanwhile another terminal answers it, and Claude asks again with
        // the same options before this answer's first write.
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        let closed = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        XCTAssertNil(closed, "a closed call's crop answers nothing")
        await apply(core, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
        try await ingest(core, id, [askResult("call-A"), askCall([("Which database should production use?", "Production", databases)], id: "call-B")], from: 2)
        let asked = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        let next = try XCTUnwrap(asked)
        XCTAssertNotEqual(AgentPromptGrammar.actionToken(for: next.signature), staging)
        for observation in [closed, next] {
            let plan = AgentPromptAnswerPlanner.next(provider: .claude, goal: goal, expectedSignature: screen.signature,
                                                     anchor: nil, observation: observation, history: [])
            XCTAssertEqual(plan.step.refusal, .stalePrompt)
        }
    }

    /// Each hook names the call it opens or closes, so a crop reads only the
    /// call its PreToolUse named while no PostToolUse has closed it, however
    /// the transcript's pages and the hooks interleave and whatever the
    /// host's clock does between them.
    func testAHookClosesOnlyTheCallItNames() async throws {
        let staging = "Which database should staging use?"
        let pageA = [askCall([(staging, "Staging", databases)], id: "call-A", at: 300)]
        let pageB = [askResult("call-A"), askCall([(ledger, "Database", databases)], id: "call-B", at: 220)]
        func crop(_ core: AgentCenterRuntime, _ id: AgentThreadID, _ sequence: UInt64) async throws -> AgentActionPrompt? {
            _ = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: sequence)
            return livePrompt(try await unwrap(core, id))
        }
        // The page lags the hooks, and the clock stepped back between the
        // call and its closing: A's late page names nothing, B's names B.
        do {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, at: seconds(300), call: "call-A")
            await apply(core, .claude, .postToolUse, .working, 2, hint: .question, at: seconds(210), call: "call-A")
            await apply(core, .claude, .preToolUse, .working, 3, hint: .question, at: seconds(220), call: "call-B")
            try await ingest(core, id, pageA)
            let late = try await crop(core, id, 3)
            XCTAssertNil(late, "the late page's call was closed")
            try await ingest(core, id, pageB, from: 2)
            let next = try await crop(core, id, 3)
            XCTAssertEqual(next?.question, ledger)
        }
        // The page overtakes the hook that closes A: B waits in the
        // transcript, and Post(A) closes A, not B.
        do {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, at: seconds(200), call: "call-A")
            try await ingest(core, id, pageA)
            try await ingest(core, id, pageB, from: 2)
            await apply(core, .claude, .postToolUse, .working, 2, hint: .question, at: seconds(200), call: "call-A")
            let unopened = try await crop(core, id, 2)
            XCTAssertNil(unopened, "B waits for its own hook")
            await apply(core, .claude, .preToolUse, .working, 3, hint: .question, at: seconds(205), call: "call-B")
            let opened = try await crop(core, id, 3)
            XCTAssertEqual(opened?.question, ledger, "the hook for A closed only A")
        }
        // A PreToolUse delivered again after its call closed opens nothing.
        do {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
            await apply(core, .claude, .preToolUse, .working, 3, hint: .question, call: "call-A")
            try await ingest(core, id, pageA)
            let reopened = try await crop(core, id, 3)
            XCTAssertNil(reopened)
        }
    }

    /// Without both IDs a cropped dialog cannot be bound to a call: hooks from
    /// before integration 27 and a transcript projected without call IDs
    /// raise no cropped card, while the whole dialog still answers.
    func testACroppedDialogNeedsTheCallItsHookNames() async throws {
        for (label, hookCall, transcriptCall) in [("hooks naming no call", nil, "call-A"),
                                                  ("a transcript naming no call", "call-A", nil),
                                                  ("another call", "call-B", "call-A")] as [(String, String?, String?)] {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: hookCall)
            try await ingest(core, id, [askCall([(ledger, "Database", databases)], id: transcriptCall)])
            let changed = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                       observedLifecycleSequence: 1)
            XCTAssertFalse(changed, label)
            let answered = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
            XCTAssertNil(answered, label)
            let whole = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                                     observedLifecycleSequence: 1)
            XCTAssertTrue(whole, label)
            let snapshot = try await unwrap(core, id)
            XCTAssertEqual(livePrompt(snapshot)?.question, ledger, label)
        }
    }

    /// An interrupt closes the waiting call: no hook reports it, and a
    /// PreToolUse for that call arriving late cannot open it again.
    func testAnInterruptClosesTheWaitingCall() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, at: interruptTurnNanos, call: "call-A")
        let call = AgentProjectionRecord(sequence: 1, recordID: "ask-1", record: askCall([(ledger, "Database", databases)]))!
        _ = await core.apply(page: try interruptPage([call], kind: .legacy), to: id)
        let waiting = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        XCTAssertNotNil(waiting, "the waiting call names its crop")
        let interrupted = await core.apply(page: try interruptPage([call, interruptRecord(2)], kind: .legacy), to: id)
        XCTAssertTrue(interrupted.accepted)
        let stopped = try await unwrap(core, id)
        XCTAssertEqual(stopped.summary.status, .idle, "the interrupt was read")
        let closed = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        XCTAssertNil(closed)
        await apply(core, .claude, .preToolUse, .working, 2, hint: .question, at: interruptTurnNanos + 2_000_000_000, call: "call-A")
        let reopened = await core.answerScreen(cropped(F.claudeAskSingle), threadID: id)
        XCTAssertNil(reopened)

        // Every question the turn left waiting closes, one its hook never named too.
        let pair = AgentCenterRuntime()
        await pair.register(summary(id), binding: binding())
        await apply(pair, .claude, .preToolUse, .working, 1, hint: .question, at: interruptTurnNanos, call: "call-A")
        let calls = [call, AgentProjectionRecord(sequence: 2, recordID: "ask-2",
                                                 record: askCall([(ledger, "Database", databases)], id: "call-B"))!]
        _ = await pair.apply(page: try interruptPage(calls, kind: .legacy), to: id)
        let ended = await pair.apply(page: try interruptPage(calls + [interruptRecord(3)], kind: .legacy), to: id)
        XCTAssertTrue(ended.accepted)
        await apply(pair, .claude, .preToolUse, .working, 2, hint: .question, at: interruptTurnNanos + 2_000_000_000, call: "call-B")
        let whole = request(.claude, F.claudeAskSingle)
        let unbound = await pair.answerScreen(whole, threadID: id)
        XCTAssertEqual(unbound?.signature, AgentPromptGrammar.observe(whole)?.signature, "no call waits to bind the dialog")

        // The newer call's hook came, the older's never did.
        let mirror = AgentCenterRuntime()
        await mirror.register(summary(id), binding: binding())
        await apply(mirror, .claude, .preToolUse, .working, 1, hint: .question, at: interruptTurnNanos, call: "call-B")
        _ = await mirror.apply(page: try interruptPage(calls, kind: .legacy), to: id)
        let halted = await mirror.apply(page: try interruptPage(calls + [interruptRecord(3)], kind: .legacy), to: id)
        XCTAssertTrue(halted.accepted)
        await apply(mirror, .claude, .preToolUse, .working, 2, hint: .question, at: interruptTurnNanos + 2_000_000_000, call: "call-A")
        let older = await mirror.answerScreen(whole, threadID: id)
        XCTAssertEqual(older?.signature, AgentPromptGrammar.observe(whole)?.signature, "the call no hook named closed too")
    }

    /// An answer's lease holds the prompt that waited when it was granted. A
    /// hook accepted since that changes which prompt waits stops its writes;
    /// ordinary tools and the answer's own keys change nothing.
    func testAnAnswerWritesOnlyWhileItsPromptWaits() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await core.requirePromptCurrent(lease)
        await apply(core, .claude, .preToolUse, .working, 2, hint: nil)
        await apply(core, .claude, .postToolUse, .working, 3, hint: nil)
        try await core.requirePromptCurrent(lease)
        await apply(core, .claude, .postToolUse, .working, 4, hint: .question, call: "call-A")
        await assertStalePrompt(core, lease, "the question it answers closed")
        let forged = AgentActionLease(threadID: id, binding: binding(), action: .answerPrompt)
        await assertStalePrompt(core, forged, "another lease")
        await core.releaseLease(lease)

        for (label, event, status, hint) in [("the next question", .preToolUse, .working, .question),
                                             ("a permission request", .permissionRequest, .waitingForInput, nil),
                                             ("a new prompt", .userPromptSubmit, .working, nil),
                                             ("the turn's end", .stop, .finished, nil)]
            as [(String, AgentLifecycleEventKind, AgentStatus, AgentLifecycleInputHint?)] {
            let next = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
            try await core.requirePromptCurrent(next)
            let sequence = try await unwrap(core, id).summary.lastActivitySequence + 1
            await apply(core, .claude, event, status, sequence, hint: hint, call: hint == nil ? nil : "call-\(sequence)")
            await assertStalePrompt(core, next, label)
            await core.releaseLease(next)
        }
        let send = try await core.acquireLease(threadID: id, action: .interrupt, binding: binding())
        await assertStalePrompt(core, send, "a lease for another action")
    }

    /// No hook separates the questions of one call: the screen showing the
    /// next one is the transition. The answer's own selection, check boxes
    /// and typed text are not.
    func testAnotherQuestionOnScreenStopsTheAnswer() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        func show(_ fixture: F.Fixture) async {
            _ = await core.observeLivePrompt(request(.claude, fixture), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        await show(F.claudeAsk3Q1)
        let first = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await show(F.claudeAsk3Q1)
        try await core.requirePromptCurrent(first)
        await show(F.claudeAsk3Q2Multi)
        await assertStalePrompt(core, first, "the next question of the same call")
        await core.releaseLease(first)

        let second = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await show(F.claudeAsk3Q2Toggled)
        try await core.requirePromptCurrent(second)
        await core.releaseLease(second)

        await show(F.claudeAskSingle)
        let typed = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        for fixture in [F.claudeAskSingleTypeFocused, F.claudeAskSingleTyped] {
            await show(fixture)
            try await core.requirePromptCurrent(typed)
        }
    }

    /// A tab bar scrolled off says nothing about which question is shown;
    /// the one last shown still tells the next question apart, and so does
    /// the tab another terminal highlights by hand.
    func testAPlacementScrolledOffStillTellsTheNextQuestionApart() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        func show(_ text: String) async {
            _ = await core.observeLivePrompt(AgentPromptObservationRequest(providerID: .claude, visibleText: text, currentCursorLine: nil)!,
                                             threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        let batch = F.claudeAsk3Q1.text
        let question = try XCTUnwrap(batch.range(of: "Which database should the service use?"))
        await show(batch)
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await show("\n" + batch[question.lowerBound...])
        try await core.requirePromptCurrent(lease)
        await show(batch.replacingOccurrences(of: "←  ☐ Database", with: "←  ☒ Database"))
        await assertStalePrompt(core, lease, "the same question asked next, its tab bar back")
        await core.releaseLease(lease)

        let shown = "← \u{1B}[38;5;16m\u{1B}[48;5;153m ☐ Run plan \u{1B}[39m\u{1B}[49m ☐ Report  ✔ Submit  →"
        let moved = "←  ☐ Run plan \u{1B}[38;5;16m\u{1B}[48;5;153m ☐ Report \u{1B}[39m\u{1B}[49m ✔ Submit  →"
        let wide = F.claudeAskWidePhone.text
        XCTAssertTrue(wide.contains(shown))
        await show(AgentPromptGrammar.promptText(fromCapture: wide))
        let tab = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await show(AgentPromptGrammar.promptText(fromCapture: wide))
        try await core.requirePromptCurrent(tab)
        await show(AgentPromptGrammar.promptText(fromCapture: wide.replacingOccurrences(of: shown, with: moved)))
        await assertStalePrompt(core, tab, "another terminal moved to the alike question's tab")
    }

    /// Codex drops the counter once one async question is left, so the
    /// twin left after an answer elsewhere is another question.
    func testTheLastCodexAsyncQuestionIsNotItsAnsweredTwin() async throws {
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .preToolUse, .working, 1, hint: .deferredQuestion)
        func show(_ text: String) async {
            _ = await core.observeLivePrompt(AgentPromptObservationRequest(providerID: .codex, visibleText: text, currentCursorLine: nil)!,
                                             threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        let open = F.codexAsync2OpenQ1.text
        XCTAssertTrue(open.contains("  1 of 2\n"))
        await show(open)
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await show(open)
        try await core.requirePromptCurrent(lease)
        XCTAssertTrue(open.contains("   shift+← next question"))
        await show(open.replacingOccurrences(of: "  1 of 2\n", with: "").replacingOccurrences(of: "   shift+← next question", with: ""))
        await assertStalePrompt(core, lease, "the alike question left once the first is answered elsewhere")
    }

    /// The transcript can show the call answered and the next one asked
    /// before either hook arrives; that is the transition too. A transcript
    /// catching up to the waiting call is not.
    func testATranscriptThatMovesOnStopsTheAnswer() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(core, id, [askCall([(ledger, "Database", databases)], id: "call-A")])
        try await core.requirePromptCurrent(lease)
        try await ingest(core, id, [askResult("call-A"), askCall([(ledger, "Database", databases)], id: "call-B")], from: 2)
        await assertStalePrompt(core, lease, "the transcript answered the call and asked the next")
    }

    /// A page is judged against the call the answer is for, not the page
    /// before it: pages behind the hooks or catching up to them, and the
    /// transcript read again, keep the answer; the call's own result stops it.
    func testATranscriptPageIsJudgedAgainstTheAnsweredCall() async throws {
        let asked = [(ledger, "Database", databases)]
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(core, id, [askCall(asked, id: "call-A")])
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        await apply(core, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(core, id, [askCall(asked, id: "call-A")])
        try await core.requirePromptCurrent(lease)
        try await ingest(core, id, [askResult("call-A")], from: 2)
        try await core.requirePromptCurrent(lease)
        try await ingest(core, id, [askCall(asked, id: "call-B")], from: 3)
        try await core.requirePromptCurrent(lease)
        await core.releaseIngestionWindow(for: id)
        try await ingest(core, id, [askCall(asked, id: "call-A"), askResult("call-A"), askCall(asked, id: "call-B")])
        try await core.requirePromptCurrent(lease)
        try await ingest(core, id, [askResult("call-B")], from: 4)
        await assertStalePrompt(core, lease, "the answered call stopped waiting")

        // A first page that already moved past the answered call.
        let late = AgentCenterRuntime()
        await late.register(summary(id), binding: binding())
        await apply(late, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let early = try await late.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(late, id, [askCall(asked, id: "call-A"), askResult("call-A"), askCall(asked, id: "call-B")])
        await assertStalePrompt(late, early, "the transcript's first page asks the next call")
    }

    /// Reopening the detail forgets which call the transcript showed; a first
    /// page with the answered call's result still stops the answer.
    func testTheFirstPageAfterAReopenStillShowsTheAnsweredCallClosed() async throws {
        let asked = [(ledger, "Database", databases)]
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(core, id, [askCall(asked, id: "call-A")])
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await core.releaseIngestionWindow(for: id)
        try await ingest(core, id, [askCall(asked, id: "call-A"), askResult("call-A")])
        await assertStalePrompt(core, lease, "the reopened transcript shows the answered call closed")

        // A hook naming no call: the answer is for the one call the transcript showed waiting.
        let unnamed = AgentCenterRuntime()
        await unnamed.register(summary(id), binding: binding())
        await apply(unnamed, .claude, .preToolUse, .working, 1, hint: .question)
        try await ingest(unnamed, id, [askCall(asked, id: "call-A")])
        let shown = try await unnamed.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await unnamed.releaseIngestionWindow(for: id)
        try await ingest(unnamed, id, [askCall(asked, id: "call-A"), askResult("call-A")])
        await assertStalePrompt(unnamed, shown, "the reopened transcript shows the call it was granted for closed")
    }

    /// A permission asked right after a question the hooks closed: the page
    /// that catches up with the question's result is behind them, and does
    /// not stop the permission's answer.
    func testAClosedQuestionsResultDoesNotStopTheNextPermissionsAnswer() async throws {
        let asked = [(ledger, "Database", databases)]
        let bash: AgentJSONValue = .object(["type": .string("message"), "role": .string("assistant"), "blocks": .array([
            .object(["type": .string("tool_call"), "name": .string("Bash"), "preview": .string("{\"command\":\"make\"}"),
                     "toolCallID": .string("call-X")])])])
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(core, id, [askCall(asked, id: "call-A")])
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        await apply(core, .claude, .permissionRequest, .waitingForInput, 3, hint: nil)
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(core, id, [askCall(asked, id: "call-A"), askResult("call-A"), bash])
        try await core.requirePromptCurrent(lease)
    }

    /// A permission answers no question call. With no hook to close it, the
    /// call the transcript showed waiting gets its result behind the answer;
    /// another call opening is what moves the screen on.
    func testAPermissionAnswerIsBehindTheQuestionBeforeIt() async throws {
        let asked = [(ledger, "Database", databases)]
        for next in [toolCall("Bash", id: "call-X"), askCall(asked, id: "call-B")] {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            try await ingest(core, id, [askCall(asked, id: "call-A")])
            await apply(core, .claude, .permissionRequest, .waitingForInput, 1, hint: nil)
            await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 1)
            let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
            try await ingest(core, id, [askResult("call-A"), next], from: 2)
            if next == askCall(asked, id: "call-B") {
                await assertStalePrompt(core, lease, "another question opened")
            } else {
                try await core.requirePromptCurrent(lease)
            }
        }
    }

    /// A question batched with another tool: the sibling's result names the
    /// sibling, so a page with it leaves the question waiting.
    func testASiblingToolsResultLeavesTheQuestionWaiting() async throws {
        let asked = [(ledger, "Database", databases)]
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let page = [toolCall("Bash", id: "call-X"), askCall(asked, id: "call-A"), askResult("call-X")]
        try await ingest(core, id, page)
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await core.releaseIngestionWindow(for: id)
        try await ingest(core, id, page)
        try await core.requirePromptCurrent(lease)
        try await ingest(core, id, [askResult("call-A")], from: 4)
        await assertStalePrompt(core, lease, "its own result closes it")

        // The sibling written after the question, on pages after one that
        // showed the question alone.
        let later = AgentCenterRuntime()
        await later.register(summary(id), binding: binding())
        await apply(later, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(later, id, [askCall(asked, id: "call-A")])
        let answer = try await later.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(later, id, [toolCall("Read", id: "call-X")], from: 2)
        try await later.requirePromptCurrent(answer)
        try await ingest(later, id, [askResult("call-X")], from: 3)
        try await later.requirePromptCurrent(answer)
        try await ingest(later, id, [askResult("call-A")], from: 4)
        await assertStalePrompt(later, answer, "its own result closes it")

        // A sibling's result written between the batch's calls.
        let between = AgentCenterRuntime()
        await between.register(summary(id), binding: binding())
        await apply(between, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(between, id, [askCall(asked, id: "call-A"), toolCall("Read", id: "call-X")])
        let held = try await between.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(between, id, [askResult("call-X"), toolCall("Grep", id: "call-Y")], from: 3)
        try await between.requirePromptCurrent(held)
        try await ingest(between, id, [askResult("call-A")], from: 5)
        await assertStalePrompt(between, held, "its own result closes it")

        // The person's next prompt ends the turn: a question a killed session
        // left without its result waits no more.
        let resumed = AgentCenterRuntime()
        await resumed.register(summary(id), binding: binding())
        await apply(resumed, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(resumed, id, [askCall(asked, id: "call-A")])
        let orphan = try await resumed.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(resumed, id, [.object(["type": .string("user"), "text": .string("Carry on.")])], from: 2)
        await assertStalePrompt(resumed, orphan, "the next prompt started another turn")
        // So does a start, and the first frame of another process, even one
        // bound before the answer was granted.
        let started = AgentCenterRuntime()
        await started.register(summary(id), binding: binding())
        await apply(started, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(started, id, [askCall(asked, id: "call-A")])
        let beforeStart = try await started.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await apply(started, .claude, .sessionStart, .idle, 2, hint: nil, at: 2_000_000_000_000)
        await assertStalePrompt(started, beforeStart, "a start closed its question")
        let unnamed = AgentCenterRuntime()
        await unnamed.register(summary(id), binding: binding())
        await apply(unnamed, .claude, .preToolUse, .working, 1, hint: .question)
        try await ingest(unnamed, id, [askCall(asked, id: nil)])
        let wholeDialog = try await unnamed.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await apply(unnamed, .claude, .sessionStart, .idle, 2, hint: nil, at: 2_000_000_000_000)
        await assertStalePrompt(unnamed, wholeDialog, "a start ends a question no hook named")
        let rebound = AgentCenterRuntime()
        await rebound.register(summary(id), binding: binding())
        await apply(rebound, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(rebound, id, [askCall(asked, id: "call-A")])
        await rebound.replaceBinding(nil, for: id)
        await rebound.replaceBinding(binding(pid: 43), for: id)
        let beforeProof = try await rebound.acquireLease(threadID: id, action: .answerPrompt, binding: binding(pid: 43))
        await apply(rebound, .claude, .notification, .waitingForInput, 2, hint: nil, pid: 43)
        await assertStalePrompt(rebound, beforeProof, "another process's frame closed its question")
        // With a hook naming no call, the answer is for the next turn's
        // question alone, and the orphan's late result is none of its own.
        let abandoned = AgentCenterRuntime()
        await abandoned.register(summary(id), binding: binding())
        await apply(abandoned, .claude, .preToolUse, .working, 1, hint: .question)
        try await ingest(abandoned, id, [askCall(asked, id: "call-A"), .object(["type": .string("user"), "text": .string("Carry on.")]),
                                         askCall([("Which cache?", "Cache", databases)], id: "call-B")])
        let next = try await abandoned.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(abandoned, id, [askResult("call-A")], from: 4)
        try await abandoned.requirePromptCurrent(next)
        try await ingest(abandoned, id, [askResult("call-B")], from: 5)
        await assertStalePrompt(abandoned, next, "its own result closes it")

        // Two questions of one batch: Claude shows the older first, and the
        // newer waiting beside it is no transition until the older's result.
        let pair = AgentCenterRuntime()
        await pair.register(summary(id), binding: binding())
        await apply(pair, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(pair, id, [askCall(asked, id: "call-A")])
        let older = try await pair.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        try await ingest(pair, id, [askCall([("Which cache?", "Cache", databases)], id: "call-B")], from: 2)
        try await pair.requirePromptCurrent(older)
        try await ingest(pair, id, [askResult("call-A")], from: 3)
        await assertStalePrompt(pair, older, "the newer question waits now")
    }

    /// The waiting questions are the turn's Asks that no result names,
    /// oldest first; one waits only alone. Without IDs only a lone call can.
    func testTheWaitingQuestionsAreTheTurnsUnansweredAsks() {
        func message(_ blocks: AgentBlock...) -> AgentMessage {
            AgentMessage(recordID: UUID().uuidString, role: .assistant, displayTime: nil, blocks: blocks)
        }
        func user(_ blocks: AgentBlock...) -> AgentMessage {
            AgentMessage(recordID: UUID().uuidString, role: .user, displayTime: nil, blocks: blocks)
        }
        func tool(_ blocks: AgentBlock...) -> AgentMessage {
            AgentMessage(recordID: UUID().uuidString, role: .tool, displayTime: nil, blocks: blocks)
        }
        func ask(_ id: String?) -> AgentBlock { .toolCall(name: "AskUserQuestion", preview: "{}", callID: id) }
        func call(_ id: String?) -> AgentBlock { .toolCall(name: "Read", preview: "{}", callID: id) }
        func result(_ id: String?) -> AgentBlock { .toolResult(preview: "done", truncated: false, callID: id) }
        // The one waiting call, as the cropped prompt and the lease require.
        func sole(_ messages: [AgentMessage]) -> AgentClaudeQuestion.Call? {
            let calls = AgentClaudeQuestion.pendingCalls(in: messages)
            return calls.count == 1 ? calls[0] : nil
        }
        func pending(_ messages: AgentMessage...) -> String? { sole(messages)?.id }
        XCTAssertEqual(pending(message(ask("A"), call("X"))), "A")
        XCTAssertEqual(pending(message(ask("A"), call("X")), message(result("X"))), "A")
        XCTAssertEqual(pending(message(call("X"), ask("A")), message(result("X"))), "A")
        XCTAssertNil(pending(message(ask("A"), call("X")), message(result("X"), result("A"))))
        XCTAssertEqual(pending(message(ask("A"), ask("B")), message(result("B"))), "A")
        XCTAssertNil(pending(message(ask("A")), message(result("A")), message(call("X"))), "a later batch")
        XCTAssertEqual(pending(message(ask("A")), message(result("A")), message(ask("B"), call("X"))), "B")
        XCTAssertNil(pending(message(ask("A"), call("X")), message(result(nil))), "a result naming no call could be A's")
        XCTAssertNil(pending(message(ask("A"), call(nil))), "a call without an ID")
        XCTAssertNotNil(sole([message(result(nil)), message(ask(nil))]), "a lone call waits")
        XCTAssertNil(sole([message(ask(nil)), message(result(nil))]))

        // A sibling's result may land between the batch's calls.
        XCTAssertEqual(pending(message(ask("A"), call("X")), tool(result("X")), message(call("Y"))), "A")
        XCTAssertEqual(pending(message(ask("A")), tool(result("X")), message(ask("B")), tool(result("B"))), "A")
        // Two waiting at once name neither, oldest first.
        XCTAssertNil(pending(message(ask("A")), message(ask("B"))), "two questions wait")
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: [message(ask("A"), call("X")), message(ask("B"))]).map(\.id), ["A", "B"])
        XCTAssertEqual(pending(message(ask("A")), message(ask("B")), tool(result("A"))), "B")
        // The turn starts at the person's newest prompt; an interrupt is no prompt.
        XCTAssertNil(pending(message(ask("A")), user(.text("go on")), message(call("X"))), "a killed session's call")
        XCTAssertNil(pending(message(ask("A")), user(.text("go on")), message(.text("Sure."))))
        XCTAssertEqual(pending(message(ask("A")), user(.text("go on")), message(ask("B"))), "B")
        XCTAssertEqual(pending(message(ask("A")), user(.text("[Request interrupted by user for tool use]"))), "A")
        XCTAssertEqual(pending(message(ask("A")), user(.text("[Request interrupted by user]"))), "A")
        XCTAssertEqual(pending(message(ask("A"), call("X")), user(result("X"), .text("Hook context."))), "A")
        XCTAssertNil(sole([message(ask(nil)), user(.text("go on"))]))
        XCTAssertNotNil(sole([message(call(nil)), tool(result(nil)), user(.text("go on")), message(ask(nil))]))

        // Without IDs, an older question no result after it closes still waits.
        XCTAssertNil(sole([message(ask("A")), tool(result("X")), message(ask(nil))]), "A has no result")
        XCTAssertNotNil(sole([message(ask(nil)), tool(result(nil)), message(ask(nil))]), "a result naming none could be A's")

        // An earlier process's messages wait none: those written before the
        // start. A call the hooks opened since among them proves the cut
        // wrong, and the whole turn waits: a batch's sibling is not cut from
        // beside the call the hooks named.
        let dated = [AgentMessage(recordID: "old", role: .assistant, displayTime: Date(timeIntervalSince1970: 1_000), blocks: [ask("A")]),
                     AgentMessage(recordID: "new", role: .assistant, displayTime: Date(timeIntervalSince1970: 1_500), blocks: [ask("B")])]
        let start = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: dated).map(\.id), ["A", "B"])
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: dated, since: start).map(\.id), [])
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: dated, since: start, opened: ["B"]).map(\.id), ["A", "B"])
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: dated, since: start, opened: ["A"]).map(\.id), ["A", "B"])
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: Array(dated.suffix(1)), since: start, opened: ["B"]).map(\.id), ["B"])
        XCTAssertEqual(AgentClaudeQuestion.pendingCalls(in: dated, since: Date(timeIntervalSince1970: 1_200)).map(\.id), ["B"],
                       "an earlier run's question, written long before the start")
        // A clock stepped back between a batch's calls: a question written
        // within a minute of the start that no hook named, nothing closed
        // and no result answers may be the sibling.
        func stamped(_ id: String, _ seconds: TimeInterval) -> AgentMessage {
            AgentMessage(recordID: id, role: .assistant, displayTime: Date(timeIntervalSince1970: seconds), blocks: [ask(id)])
        }
        func waiting(_ messages: AgentMessage..., opened: [String] = [], named: [String] = []) -> [String?] {
            AgentClaudeQuestion.pendingCalls(in: messages, since: start, opened: opened, named: named).map(\.id)
        }
        let earlier = stamped("Z", 1_000), sibling = stamped("A", 1_990), new = stamped("B", 2_010)
        XCTAssertEqual(waiting(sibling, new), ["A", "B"])
        XCTAssertEqual(waiting(stamped("A", 1_939), new), ["B"])
        XCTAssertEqual(waiting(earlier, sibling, new), ["Z", "A", "B"])
        XCTAssertEqual(waiting(earlier, sibling, new, named: ["A"]), ["B"], "the hooks named A before the start")
        XCTAssertEqual(waiting(earlier, sibling, tool(result("A")), new), ["B"], "an answered question is drawn no more")
        XCTAssertEqual(waiting(earlier, sibling, new, opened: ["A"], named: ["A"]), ["Z", "A", "B"])
        XCTAssertEqual(waiting(sibling, message(call("X")), new), ["A", "B"])
        XCTAssertEqual(waiting(sibling, stamped("C", 1_995)), [], "no question after the start")
    }

    /// The next call drawing exactly the same dialog is another prompt: its
    /// card and its screen read differently from the closed call's.
    func testAWholeDialogIsBoundToItsCall() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        let screen = request(.claude, F.claudeAskSingle)
        func card(_ sequence: UInt64) async throws -> AgentActionToken? {
            _ = await core.observeLivePrompt(screen, threadID: id, binding: binding(), observedLifecycleSequence: sequence)
            return livePrompt(try await unwrap(core, id))?.token
        }
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let first = try await card(1)
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        await apply(core, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
        let next = try await card(3)
        XCTAssertNotNil(first)
        XCTAssertNotNil(next)
        XCTAssertNotEqual(first, next, "the same dialog for another call")
        let fresh = await core.answerScreen(screen, threadID: id)
        XCTAssertEqual(fresh.map { AgentPromptGrammar.actionToken(for: $0.signature) }, next)

        // Hooks from before integration 27 name no call: the dialog reads as it always did.
        let legacy = AgentCenterRuntime()
        await legacy.register(summary(id), binding: binding())
        await apply(legacy, .claude, .preToolUse, .working, 1, hint: .question)
        _ = await legacy.observeLivePrompt(screen, threadID: id, binding: binding(), observedLifecycleSequence: 1)
        let plain = livePrompt(try await unwrap(legacy, id))?.token
        XCTAssertEqual(plain, AgentPromptGrammar.observe(screen).map { AgentPromptGrammar.actionToken(for: $0.signature) })
    }

    /// A question's PostToolUse for another call than the waiting one (late,
    /// or replayed) records that call's closing and leaves the waiting
    /// question, its card and its answer alone.
    func testAPostForAnotherCallLeavesTheWaitingQuestion() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(core, id, [askCall([("Which database should staging use?", "Staging", databases)], id: "call-A"),
                                    askResult("call-A"), askCall([(ledger, "Database", databases)], id: "call-B")])
        await apply(core, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B")
        _ = await core.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        let card = livePrompt(try await unwrap(core, id))
        XCTAssertEqual(card?.question, ledger)
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        await apply(core, .claude, .postToolUse, .working, 3, hint: .question, call: "call-A")
        try await core.requirePromptCurrent(lease)
        let after = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(after)?.token, card?.token, "the card stays")
        XCTAssertEqual(after.summary.attention, .needsYou)
        await apply(core, .claude, .postToolUse, .working, 4, hint: .question, call: "call-B")
        await assertStalePrompt(core, lease, "its own call closed")
    }

    /// The permit a platform commits each write on at its transport goes
    /// with the transition, and with the lease.
    func testAnAnswersPermitEndsWithItsPrompt() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let lease = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        let permit = try await core.answerPermit(for: lease)
        XCTAssertTrue(permit.commitWrite())
        await apply(core, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        XCTAssertFalse(permit.commitWrite(), "a transition Core accepted stops the next write")
        await core.releaseLease(lease)

        let next = try await core.acquireLease(threadID: id, action: .answerPrompt, binding: binding())
        let held = try await core.answerPermit(for: next)
        await core.releaseLease(next)
        XCTAssertFalse(held.commitWrite(), "a released lease writes nothing")
        let send = try await core.acquireLease(threadID: id, action: .send, binding: binding())
        do {
            _ = try await core.answerPermit(for: send)
            XCTFail("a send has no answer permit")
        } catch {
            XCTAssertEqual(error as? AgentActionError, .stalePrompt)
        }
    }

    /// Every producer bounds an ID at 256 bytes and some filter it: a value
    /// that long, or one that needed filtering, may name another call, so
    /// it is dropped, never the frame that carried it.
    func testACallIDIsKeptWholeOrNotAtAll() async throws {
        let longest = String(repeating: "a", count: 255)
        XCTAssertEqual(AgentToolCallIdentity.whole("toolu_01:A.b-cde"), "toolu_01:A.b-cde")
        XCTAssertEqual(AgentToolCallIdentity.whole(longest), longest)
        for damaged in [longest + "b", "toolu_01 A", "toolu/01", "", "tóolu"] {
            XCTAssertNil(AgentToolCallIdentity.whole(damaged), damaged)
        }
        func hook(_ toolUseID: String) -> Data {
            Data(#"{"version":9,"provider":"claude","event":"PreToolUse","state":"working","reason":"question","timestampNs":"184467440","sessionId":"session-1","agentPid":42,"transcriptRef":"session_abc","toolUseId":"\#(toolUseID)"}"#.utf8)
        }
        XCTAssertEqual(AgentLifecycleHookEvent.decode(hook("toolu_A"))?.toolUseID, "toolu_A")
        let damaged = try XCTUnwrap(AgentLifecycleHookEvent.decode(hook(longest + "b")), "the frame stays")
        XCTAssertNil(damaged.toolUseID)

        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        try await ingest(core, id, [askCall([(ledger, "Database", databases)], id: longest + "b")])
        let blocks = try await unwrap(core, id).messages.flatMap(\.blocks)
        XCTAssertTrue(blocks.contains { if case .toolCall(_, _, nil) = $0 { true } else { false } }, "\(blocks)")
    }

    private func assertStalePrompt(_ core: AgentCenterRuntime, _ lease: AgentActionLease, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await core.requirePromptCurrent(lease)
            XCTFail("\(label): the answer would still write", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentActionError, .stalePrompt, label, file: file, line: line)
        }
    }

    /// A dialog first seen cropped takes its question from the waiting
    /// AskUserQuestion call whose options it shows, and only from that.
    func testACroppedDialogTakesItsQuestionFromTheWaitingCall() async throws {
        let first = "❯ 1. Postgres (Recommended)"
        let wrapped = cropped(F.claudeAskSingle, replacing: first, with: "❯ 1. Postgres\n     (Recommended)")
        let split = cropped(F.claudeAskSingle, replacing: first, with: "❯ 1. Postgres (Recomm\n     ended)")
        let cut = cropped(F.claudeAskSingle, replacing: first, with: "❯ 1. Postgres")
        let wide = cropped(F.claudeAskSingle, replacing: first, with: "❯ 1. 数据库服务\n     器")
        var servers = databases
        servers[0].label = "数据库服务器"
        let reasons = databases.map { (label: $0.label, description: "Why \($0.label).") }
        let other = askCall([("Which cache?", "Cache", [("Redis", "In memory."), ("Memcached", "Plain cache.")])])
        let batch = [askCall([(ledger, "Database", databases)]), askCall([("Which cache?", "Cache", databases)], id: "call-B")]
        for (label, calls, screen, expected) in [
            ("one question", [askCall([(ledger, "Database", databases)])], cropped(F.claudeAskSingle),
             (title: "Database", question: ledger, first: "Postgres (Recommended)")),
            ("a label wrapped onto its description", [askCall([(ledger, "Database", databases)])], wrapped,
             (title: "Database", question: ledger, first: "Postgres")),
            ("a label wrapped inside a word", [askCall([(ledger, "Database", databases)])], split,
             (title: "Database", question: ledger, first: "Postgres (Recomm")),
            ("a label with no spaces to wrap at", [askCall([(ledger, "Database", servers)])], wide,
             (title: "Database", question: ledger, first: "数据库服务")),
            ("same options twice", [askCall([(ledger, "Database", databases), ("Which cache?", "Cache", databases)])],
             cropped(F.claudeAskSingle), nil),
            ("another question's options", [other], cropped(F.claudeAskSingle), nil),
            ("the same labels described otherwise", [askCall([(ledger, "Database", reasons)])], cropped(F.claudeAskSingle), nil),
            ("a label the screen does not finish", [askCall([(ledger, "Database", databases)])], cut, nil),
            ("answered", [askCall([(ledger, "Database", databases)]), askResult()], cropped(F.claudeAskSingle), nil),
            ("cut short", [askCall([(ledger, "Database", databases)], cut: true)], cropped(F.claudeAskSingle), nil),
            ("one call of a batch", batch, cropped(F.claudeAskSingle), nil),
            ("one call of a batch whose other the hooks name last", batch, cropped(F.claudeAskSingle), nil),
        ] as [(String, [AgentJSONValue], AgentPromptObservationRequest, (title: String, question: String, first: String)?)] {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            // Claude runs the batch's calls together: B's hook comes last, A's dialog first.
            let hooks: UInt64 = label.hasSuffix("name last") ? 2 : 1
            if hooks == 2 { await apply(core, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B") }
            try await ingest(core, id, calls)
            let changed = await core.observeLivePrompt(screen, threadID: id, binding: binding(), observedLifecycleSequence: hooks)
            let snapshot = try await unwrap(core, id)
            guard let expected else {
                XCTAssertFalse(changed, label)
                XCTAssertNil(livePrompt(snapshot), label)
                continue
            }
            XCTAssertTrue(changed, label)
            let prompt = try XCTUnwrap(livePrompt(snapshot), label)
            XCTAssertEqual(prompt.title, expected.title, label)
            XCTAssertEqual(prompt.question, expected.question, label)
            XCTAssertNil(prompt.progress, label)
            XCTAssertEqual(prompt.options.map(\.label), [expected.first] + databases.dropFirst().map(\.label) + ["Type something.", "Chat about this"], label)
            XCTAssertEqual(snapshot.summary.attention, .needsYou, label)
        }

        // The older call of the batch closed by its hooks while its result is
        // still on its way: the newer waits alone.
        let lagging = AgentCenterRuntime(), id = thread(.claude)
        await lagging.register(summary(id), binding: binding())
        await apply(lagging, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(lagging, id, batch)
        await apply(lagging, .claude, .postToolUse, .working, 2, hint: .question, call: "call-A")
        await apply(lagging, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
        let raised = await lagging.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                     observedLifecycleSequence: 3)
        XCTAssertTrue(raised)
        let shown = try await unwrap(lagging, id)
        let next = try XCTUnwrap(livePrompt(shown))
        XCTAssertEqual(next.title, "Cache")
        XCTAssertEqual(next.question, "Which cache?")

        // A process that ended, by its own hook or its wrapper's, leaves its
        // question for good: a resumed turn a slash command started (no
        // message) has its own question waiting alone, the orphan still
        // unanswered above it.
        for end in [AgentLifecycleEventKind.sessionEnd, .wrapperExit] {
            let orphaned = AgentCenterRuntime()
            await orphaned.register(summary(id), binding: binding())
            await apply(orphaned, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            try await ingest(orphaned, id, [askCall([("Which cache?", "Cache", databases)])])
            await apply(orphaned, .claude, end, .unavailable, 2, hint: nil)
            await apply(orphaned, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
            try await ingest(orphaned, id, [askCall([(ledger, "Database", databases)], id: "call-B")], from: 2)
            let resumed = await orphaned.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                           observedLifecycleSequence: 3)
            XCTAssertTrue(resumed, "\(end)")
            let after = try await unwrap(orphaned, id)
            XCTAssertEqual(try XCTUnwrap(livePrompt(after), "\(end)").question, ledger)

            // The hooks named the orphan before any page showed it.
            let unseen = AgentCenterRuntime()
            await unseen.register(summary(id), binding: binding())
            await apply(unseen, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            await apply(unseen, .claude, end, .unavailable, 2, hint: nil)
            await apply(unseen, .claude, .preToolUse, .working, 3, hint: .question, call: "call-B")
            try await ingest(unseen, id, [askCall([("Which cache?", "Cache", databases)]),
                                          askCall([(ledger, "Database", databases)], id: "call-B")])
            let shown = await unseen.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                       observedLifecycleSequence: 3)
            XCTAssertTrue(shown, "\(end)")
            let resumedUnseen = try await unwrap(unseen, id)
            XCTAssertEqual(try XCTUnwrap(livePrompt(resumedUnseen), "\(end)").question, ledger)

            // A batch's hooks name each call, while the newest waits: the end
            // closes them all, before any page shows them.
            let batch = AgentCenterRuntime()
            await batch.register(summary(id), binding: binding())
            await apply(batch, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            await apply(batch, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B")
            await apply(batch, .claude, end, .unavailable, 3, hint: nil)
            await apply(batch, .claude, .preToolUse, .working, 4, hint: .question, call: "call-C")
            try await ingest(batch, id, [askCall([("Which cache?", "Cache", databases)]),
                                         askCall([("Which queue?", "Queue", databases)], id: "call-B"),
                                         askCall([(ledger, "Database", databases)], id: "call-C")])
            let next = await batch.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                     observedLifecycleSequence: 4)
            XCTAssertTrue(next, "\(end)")
        }

        // A process resuming the conversation after an end the app never
        // saw: binding the thread to it closes what the one before opened.
        let replaced = AgentCenterRuntime()
        await replaced.register(summary(id), binding: binding())
        await apply(replaced, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        await replaced.register(summary(id), binding: binding(pid: 43))
        let moved = await apply(replaced, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B", pid: 43)
        guard case .accepted = moved else { return XCTFail("\(moved)") }
        try await ingest(replaced, id, [askCall([("Which cache?", "Cache", databases)]),
                                        askCall([(ledger, "Database", databases)], id: "call-B")])
        let successor = await replaced.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(pid: 43),
                                                         observedLifecycleSequence: 2)
        XCTAssertTrue(successor)
        let afterSuccessor = try await unwrap(replaced, id)
        XCTAssertEqual(try XCTUnwrap(livePrompt(afterSuccessor)).question, ledger)
        // The platform moving the binding itself does the same.
        let rebound = AgentCenterRuntime()
        await rebound.register(summary(id), binding: binding())
        await apply(rebound, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        await rebound.replaceBinding(binding(pid: 43), for: id)
        let reboundFrame = await apply(rebound, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B", pid: 43)
        guard case .accepted = reboundFrame else { return XCTFail("\(reboundFrame)") }
        try await ingest(rebound, id, [askCall([("Which cache?", "Cache", databases)]),
                                       askCall([(ledger, "Database", databases)], id: "call-B")])
        let reboundShown = await rebound.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(pid: 43),
                                                           observedLifecycleSequence: 2)
        XCTAssertTrue(reboundShown)
        // Both platforms unbind the route before they bind the next process.
        for registers in [true, false] {
            let unbound = AgentCenterRuntime()
            await unbound.register(summary(id), binding: binding())
            await apply(unbound, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
            await unbound.replaceBinding(nil, for: id)
            if registers {
                await unbound.register(summary(id), binding: binding(pid: 43))
            } else {
                await unbound.replaceBinding(binding(pid: 43), for: id)
            }
            let frame = await apply(unbound, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B", pid: 43)
            guard case .accepted = frame else { return XCTFail("\(registers) \(frame)") }
            try await ingest(unbound, id, [askCall([("Which cache?", "Cache", databases)]),
                                           askCall([(ledger, "Database", databases)], id: "call-B")])
            let unboundShown = await unbound.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(pid: 43),
                                                               observedLifecycleSequence: 2)
            XCTAssertTrue(unboundShown, "\(registers)")
        }
        // A frame of the unbound conversation adopted from another holder of
        // the new process's pane.
        let adopted = AgentCenterRuntime()
        let holder = try XCTUnwrap(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "other-session"))
        await adopted.register(summary(id), binding: binding())
        await apply(adopted, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        await adopted.replaceBinding(nil, for: id)
        await adopted.register(summary(holder), binding: binding(pid: 43))
        let adoptedFrame = await apply(adopted, .claude, .preToolUse, .working, 2, hint: .question, call: "call-B", pid: 43)
        guard case .accepted = adoptedFrame else { return XCTFail("\(adoptedFrame)") }
        try await ingest(adopted, id, [askCall([("Which cache?", "Cache", databases)]),
                                       askCall([(ledger, "Database", databases)], id: "call-B")])
        let adoptedShown = await adopted.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(pid: 43),
                                                           observedLifecycleSequence: 2)
        XCTAssertTrue(adoptedShown)
        // The same process bound again after a discovery miss, its retained
        // frame replayed, still waits on its question.
        let rediscovered = AgentCenterRuntime()
        await rediscovered.register(summary(id), binding: binding())
        await apply(rediscovered, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(rediscovered, id, [askCall([("Which cache?", "Cache", databases)])])
        await rediscovered.replaceBinding(nil, for: id)
        await rediscovered.register(summary(id), binding: binding())
        await apply(rediscovered, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let stillShown = await rediscovered.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                              observedLifecycleSequence: 1)
        XCTAssertTrue(stillShown)
        let afterRediscovery = try await unwrap(rediscovered, id)
        XCTAssertEqual(try XCTUnwrap(livePrompt(afterRediscovery)).question, "Which cache?")

        // A session resumed where no end was ever seen: calls written before
        // its newest SessionStart are an earlier process's.
        let restarted = AgentCenterRuntime()
        await restarted.register(summary(id), binding: binding())
        await apply(restarted, .claude, .sessionStart, .idle, 1, hint: nil, at: 2_000_000_000_000)
        await apply(restarted, .claude, .preToolUse, .working, 2, hint: .question, at: 3_000_000_000_000, call: "call-B")
        try await ingest(restarted, id, [askCall([("Which cache?", "Cache", databases)], at: 1_000),
                                         askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)])
        let started = await restarted.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                        observedLifecycleSequence: 2)
        XCTAssertTrue(started)
        // Without the start, the call before it still waits beside the new one.
        let unstarted = AgentCenterRuntime()
        await unstarted.register(summary(id), binding: binding())
        await apply(unstarted, .claude, .preToolUse, .working, 2, hint: .question, at: 3_000_000_000_000, call: "call-B")
        try await ingest(unstarted, id, [askCall([("Which cache?", "Cache", databases)], at: 1_000),
                                         askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)])
        let refused = await unstarted.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                        observedLifecycleSequence: 2)
        XCTAssertFalse(refused)
        // The host's clock stepped back before the start: the earlier call,
        // read before it and opened by its own hook, closed with the start.
        let stepped = AgentCenterRuntime()
        await stepped.register(summary(id), binding: binding())
        await apply(stepped, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(stepped, id, [askCall([("Which cache?", "Cache", databases)], at: 2_500)])
        await apply(stepped, .claude, .sessionStart, .idle, 2, hint: nil, at: 2_000_000_000_000)
        await apply(stepped, .claude, .preToolUse, .working, 3, hint: .question, at: 3_000_000_000_000, call: "call-B")
        try await ingest(stepped, id, [askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)], from: 2)
        let steppedShown = await stepped.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                           observedLifecycleSequence: 3)
        XCTAssertTrue(steppedShown)
        // A start reduced late, its page read inside a batch (a replayed
        // frame after a reconnect, a slow proof): the call written after the
        // start that no hook named may be the sibling Claude draws first.
        let parted = AgentCenterRuntime()
        await parted.register(summary(id), binding: binding())
        try await ingest(parted, id, [askCall([("Which cache?", "Cache", databases)], at: 3_000)])
        await apply(parted, .claude, .sessionStart, .idle, 1, hint: nil, at: 2_000_000_000_000)
        await apply(parted, .claude, .preToolUse, .working, 2, hint: .question, at: 3_000_000_000_000, call: "call-B")
        try await ingest(parted, id, [askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)], from: 2)
        let partedShown = await parted.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                         observedLifecycleSequence: 2)
        XCTAssertFalse(partedShown)
        // Stepped back after it: the call the hooks opened since, dated before
        // the start, proves the cut wrong. Alone it waits; beside a call the
        // hooks never named (a batch's sibling, drawn first) neither does.
        for sibling in [false, true] {
            let skewed = AgentCenterRuntime()
            await skewed.register(summary(id), binding: binding())
            await apply(skewed, .claude, .sessionStart, .idle, 1, hint: nil, at: 2_000_000_000_000)
            await apply(skewed, .claude, .preToolUse, .working, 2, hint: .question, at: 3_000_000_000_000, call: "call-B")
            try await ingest(skewed, id, (sibling ? [askCall([("Which cache?", "Cache", databases)], at: 1_500)] : [])
                                + [askCall([(ledger, "Database", databases)], id: "call-B", at: 1_500)])
            let skewedShown = await skewed.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                             observedLifecycleSequence: 2)
            XCTAssertEqual(skewedShown, !sibling)
            let afterSkew = try await unwrap(skewed, id)
            XCTAssertEqual(livePrompt(afterSkew)?.question, sibling ? nil : ledger)
        }
        // A page read before the start, already holding the batch: the
        // whole batch waits.
        let early = AgentCenterRuntime()
        await early.register(summary(id), binding: binding())
        try await ingest(early, id, [askCall([("Which cache?", "Cache", databases)], at: 3_000),
                                     askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)])
        await apply(early, .claude, .sessionStart, .idle, 1, hint: nil, at: 2_000_000_000_000)
        await apply(early, .claude, .preToolUse, .working, 2, hint: .question, at: 3_000_000_000_000, call: "call-B")
        let earlyShown = await early.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                       observedLifecycleSequence: 2)
        XCTAssertFalse(earlyShown)
        // A call opened before the start is the earlier run's, closed by it
        // although no end came (hooks that name no process, a process ID
        // reused), and cut with an older one no hook named although it was
        // written just before the start.
        let pidless = AgentCenterRuntime()
        await pidless.register(summary(id), binding: binding())
        await apply(pidless, .claude, .preToolUse, .working, 1, hint: .question, at: 1_990_000_000_000, call: "call-A")
        await apply(pidless, .claude, .sessionStart, .idle, 2, hint: nil, at: 2_000_000_000_000)
        await apply(pidless, .claude, .preToolUse, .working, 3, hint: .question, at: 3_000_000_000_000, call: "call-B")
        try await ingest(pidless, id, [askCall([("Which region?", "Region", databases)], id: "call-Z", at: 1_000),
                                       askCall([("Which cache?", "Cache", databases)], at: 1_990),
                                       askCall([(ledger, "Database", databases)], id: "call-B", at: 3_000)])
        let pidlessShown = await pidless.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                           observedLifecycleSequence: 3)
        XCTAssertTrue(pidlessShown)
        // Registering another process closes nothing until Core accepts one
        // of its frames.
        let unproved = AgentCenterRuntime()
        await unproved.register(summary(id), binding: binding())
        await apply(unproved, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(unproved, id, [askCall([("Which cache?", "Cache", databases)])])
        await unproved.register(summary(id), binding: binding(pid: 43))
        await unproved.register(summary(id), binding: binding())
        await apply(unproved, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        let unprovedShown = await unproved.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                             observedLifecycleSequence: 1)
        XCTAssertTrue(unprovedShown)
        let afterUnproved = try await unwrap(unproved, id)
        XCTAssertEqual(try XCTUnwrap(livePrompt(afterUnproved)).question, "Which cache?")
        // Nor does a frame of another process that Core refuses.
        let rejected = AgentCenterRuntime()
        await rejected.register(summary(id), binding: binding())
        await apply(rejected, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        try await ingest(rejected, id, [askCall([("Which cache?", "Cache", databases)])])
        let foreign = await apply(rejected, .claude, .notification, .waitingForInput, 2, hint: nil, pid: 43)
        guard case .rejected = foreign else { return XCTFail("\(foreign)") }
        let rejectedShown = await rejected.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(),
                                                             observedLifecycleSequence: 1)
        XCTAssertTrue(rejectedShown)
        // The resumed process's own call, opened while its frames named no
        // process, stays once one is proven; the earlier process's closed at
        // the start, whether its frame named that process or none.
        for named in [true, false] {
            let proven = AgentCenterRuntime()
            await proven.register(summary(id), binding: binding())
            await apply(proven, .claude, .notification, .waitingForInput, 1, hint: nil)
            if !named {
                await proven.replaceBinding(nil, for: id)
                await proven.replaceBinding(binding(pid: nil), for: id)
            }
            await apply(proven, .claude, .preToolUse, .working, 2, hint: .question, call: "call-A", pid: named ? 42 : nil)
            await proven.replaceBinding(nil, for: id)
            await proven.replaceBinding(binding(pid: nil), for: id)
            await apply(proven, .claude, .sessionStart, .idle, 3, hint: nil, at: 2_000_000_000_000, pid: nil)
            await apply(proven, .claude, .preToolUse, .working, 4, hint: .question, at: 3_000_000_000_000, call: "call-B", pid: nil)
            try await ingest(proven, id, [askCall([("Which cache?", "Cache", databases)]),
                                          askCall([(ledger, "Database", databases)], id: "call-B")])
            await proven.replaceBinding(nil, for: id)
            await proven.replaceBinding(binding(pid: 43), for: id)
            let provenFrame = await apply(proven, .claude, .notification, .waitingForInput, 5, hint: nil,
                                          at: 3_500_000_000_000, pid: 43)
            guard case .accepted = provenFrame else { return XCTFail("\(named) \(provenFrame)") }
            let provenShown = await proven.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id, binding: binding(pid: 43),
                                                             observedLifecycleSequence: 5)
            XCTAssertTrue(provenShown, "\(named)")
            let afterProven = try await unwrap(proven, id)
            XCTAssertEqual(livePrompt(afterProven)?.question, ledger, "\(named)")
        }
        // The call the process before left waiting waits no more: a later
        // PostToolUse for another call is no sibling's.
        let resumed = AgentCenterRuntime()
        await resumed.register(summary(id), binding: binding())
        await apply(resumed, .claude, .preToolUse, .working, 1, hint: .question, call: "call-A")
        await resumed.replaceBinding(nil, for: id)
        await resumed.replaceBinding(binding(pid: 43), for: id)
        await apply(resumed, .claude, .notification, .waitingForInput, 2, hint: nil, pid: 43)
        await apply(resumed, .claude, .postToolUse, .working, 3, hint: .question, call: "call-X", pid: 43)
        let afterResume = try await unwrap(resumed, id)
        XCTAssertEqual(afterResume.summary.status, .working)
        // A start closes the calls before it, also when it names the process
        // that started and the call before it named none.
        let restartedProven = AgentCenterRuntime()
        await restartedProven.register(summary(id), binding: binding())
        await apply(restartedProven, .claude, .notification, .waitingForInput, 1, hint: nil)
        await restartedProven.replaceBinding(nil, for: id)
        await restartedProven.replaceBinding(binding(pid: nil), for: id)
        await apply(restartedProven, .claude, .preToolUse, .working, 2, hint: .question, call: "call-A", pid: nil)
        await restartedProven.replaceBinding(nil, for: id)
        await restartedProven.replaceBinding(binding(pid: 43), for: id)
        await apply(restartedProven, .claude, .sessionStart, .idle, 3, hint: nil, at: 2_000_000_000_000, pid: 43)
        await apply(restartedProven, .claude, .postToolUse, .working, 4, hint: .question, call: "call-X", pid: 43)
        let afterProvenStart = try await unwrap(restartedProven, id)
        XCTAssertEqual(afterProvenStart.summary.status, .working)
        // With that start missed, the next process's first frame closes the
        // call no frame of a process named: no start came since the earlier
        // process was proven at its own, so the call is that process's.
        let unannounced = AgentCenterRuntime()
        await unannounced.register(summary(id), binding: binding())
        await apply(unannounced, .claude, .sessionStart, .idle, 1, hint: nil, at: 1_000_000_000_000)
        await unannounced.replaceBinding(nil, for: id)
        await unannounced.replaceBinding(binding(pid: nil), for: id)
        await apply(unannounced, .claude, .preToolUse, .working, 2, hint: .question, call: "call-A", pid: nil)
        try await ingest(unannounced, id, [askCall([("Which cache?", "Cache", databases)])])
        await unannounced.replaceBinding(nil, for: id)
        await unannounced.replaceBinding(binding(pid: 43), for: id)
        await apply(unannounced, .claude, .notification, .waitingForInput, 3, hint: nil, pid: 43)
        let unannouncedShown = await unannounced.observeLivePrompt(cropped(F.claudeAskSingle), threadID: id,
                                                                   binding: binding(pid: 43), observedLifecycleSequence: 3)
        XCTAssertFalse(unannouncedShown)
    }

    func testOrdinaryToolsAndOtherEventsCarryNoHint() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        let stop = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .stop, status: .finished,
            providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref", eventSequence: 1)!
        XCTAssertNil(stop.withInputHint(.question).inputHint)
        XCTAssertNil(AgentLifecycleInputHint(reason: "question", event: .permissionRequest))
        XCTAssertEqual(AgentLifecycleInputHint(reason: "deferred-question", event: .postToolUse), .deferredQuestion)
        XCTAssertNil(AgentLifecycleInputHint(reason: "agent-turn", event: .preToolUse))
        let hinted = stop.withInputHint(nil)
        let decoded = try JSONDecoder().decode(AgentLifecycleEnvelope.self, from: JSONEncoder().encode(
            AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .preToolUse, status: .working,
                providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref", eventSequence: 2)!.withInputHint(.question)))
        XCTAssertEqual(decoded.inputHint, .question)
        XCTAssertNil(hinted.inputHint)

        await apply(core, .claude, .preToolUse, .working, 1, hint: nil)
        let snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, false)
        let changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertFalse(changed, "a menu printed by a working turn is not a prompt")
    }

    /// Hooks from before integration v21 announce no question, and a dialog
    /// raised before the app connected announces nothing: the conversation on
    /// screen is still read, and the screen alone raises and reverts its card.
    func testTheConversationOnScreenShowsAQuestionNoHookAnnounced() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: nil)
        await apply(core, .claude, .notification, .idle, 2, hint: nil)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, false)
        var changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        XCTAssertFalse(changed, "off screen, an unannounced dialog is not read")
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 2, onDisplay: true)
        XCTAssertFalse(changed, "a composer is no question, and nothing changes")

        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 2, onDisplay: true)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .question)
        XCTAssertEqual(livePrompt(snapshot)?.question, "Which database should the service use for the new ledger?")
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true, "the card keeps its watch after the conversation leaves the screen")

        // The screen raised it, so the screen answering it in the terminal reverts it.
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertEqual(snapshot.summary.attention, .none)

        await apply(core, .claude, .postToolUse, .working, 3, hint: nil)
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 2, onDisplay: true)
        XCTAssertFalse(changed, "a capture that started before the newest frame is stale on screen too")
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(generation: 2),
                                               observedLifecycleSequence: 3, onDisplay: true)
        XCTAssertFalse(changed, "another binding's capture is never read")
    }

    func testAnIdleReminderLeavesTheScreenItsQuestion() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: nil)
        var changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                                   observedLifecycleSequence: 1, onDisplay: true)
        XCTAssertTrue(changed)
        // Claude reminds an idle user while its dialog is still up.
        await apply(core, .claude, .notification, .idle, 2, hint: nil)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .question)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        // Answered in the terminal: the screen raised it, so the screen reverts it.
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 2)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertEqual(snapshot.summary.attention, .none, "no badge outlives the question")

        // A turn's end takes the attention over: a later miss keeps its completion.
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                               observedLifecycleSequence: 2, onDisplay: true)
        XCTAssertTrue(changed)
        await apply(core, .claude, .stop, .idle, 3, hint: nil)
        await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(),
                                     observedLifecycleSequence: 3, onDisplay: true)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .unreadCompletion)
    }

    func testTheCardStaysUnderATranscriptItsHeadRolledPast() async throws {
        // A busy conversation's head rolls past the rows a follower loaded.
        // The transcript still reaches the newest record through the bridge,
        // so the question on screen still belongs under it.
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        _ = await core.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        var snapshot = try await unwrap(core, id)
        _ = await core.apply(page: try projection(segment(800), lane: .before, version: 2, from: snapshot.ingestionWindow?.before), to: id)
        var live = "live"
        for (offset, start) in [903, 950, 1000].enumerated() {
            let next = "live\(offset)"
            let rolled = await core.apply(page: try projection(segment(start, total: start + 100), lane: .head,
                version: UInt64(offset + 3), from: live, live: next), to: id)
            XCTAssertTrue(rolled.accepted)
            live = next
        }
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question)
        let changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(),
                                                   observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.ingestionWindow?.bridgesToHead, true)
        XCTAssertEqual(snapshot.ingestionWindow?.atLiveHead, true)
        XCTAssertEqual(snapshot.messages.dropLast().last?.recordID, "r1099")
        XCTAssertEqual(livePrompt(snapshot)?.kind, .question, "the card sits under the newest record")
        XCTAssertEqual(snapshot.messages.last?.recordID.hasPrefix("live-prompt-"), true)
    }

    /// The field case: Claude's dialog on a phone-sized tmux pane, announced
    /// by its hook, captured with its styles. The hook sets the status; the
    /// card is the screen's.
    func testAPhoneWidthDialogItsHookAnnouncedShowsItsCard() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .notification, .waitingForInput, 1, hint: nil)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)
        XCTAssertNil(livePrompt(snapshot))
        let capture = try XCTUnwrap(AgentPromptObservationRequest(providerID: .claude,
            visibleText: AgentPromptGrammar.promptText(fromCapture: F.claudeAskWidePhone.text),
            currentCursorLine: F.claudeAskWidePhone.cursorLine))
        let changed = await core.observeLivePrompt(capture, threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .question)
        XCTAssertEqual(livePrompt(snapshot)?.progress, "☐ Run plan ☐ Report ✔ Submit")
        XCTAssertEqual(livePrompt(snapshot)?.options.count, 5)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
    }

    func testClaudePermissionKeepsItsCapturedPromptThroughItsNotification() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .permissionRequest, .waitingForInput, 1, hint: nil)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .permission)
        await apply(core, .claude, .notification, .waitingForInput, 2, hint: nil)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.question, "Do you want to proceed?", "the same dialog's notification keeps the card")
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
    }

    func testAHookDialogAnsweredInTheTerminalReleasesItsAttention() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .permissionRequest, .waitingForInput, 1, hint: nil)
        // Unseen, a miss leaves the hook's attention alone: it is the authority.
        for _ in 0..<5 {
            await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)

        await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        await apply(core, .claude, .notification, .waitingForInput, 2, hint: nil)
        for _ in 0..<2 {
            await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        }
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertEqual(snapshot.summary.attention, .needsYou, "one or two misses may be a redraw")
        let changed = await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        XCTAssertTrue(changed)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .none, "the dialog it saw was answered in the terminal")
        XCTAssertEqual(snapshot.summary.status, .working, "an approved tool runs until its hook returns")

        // A later dialog's hook raises attention again, and the count restarts.
        await apply(core, .claude, .postToolUse, .working, 3, hint: nil)
        await apply(core, .claude, .permissionRequest, .waitingForInput, 4, hint: nil)
        await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 4)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
    }

    func testTheLifecycleSequenceFencesACaptureStartedBeforeANewerFrame() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 4, hint: .question)
        var changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 3)
        XCTAssertFalse(changed)
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding())
        XCTAssertFalse(changed, "an unfenced capture is refused")
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(generation: 2), observedLifecycleSequence: 4)
        XCTAssertFalse(changed, "a capture of another route")
        changed = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 4)
        XCTAssertTrue(changed)
    }

    func testAScreenMissRevertsWhatTheScreenRaised() async throws {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .preToolUse, .working, 1, hint: .question)
        await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        let changed = await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        XCTAssertTrue(changed)
        let snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertEqual(snapshot.summary.attention, .none, "dismissed in the terminal")
        XCTAssertEqual(snapshot.summary.status, .working)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true, "the question tool has not returned yet")

        await apply(core, .claude, .stop, .finished, 2, hint: nil)
        let finished = try await unwrap(core, id)
        XCTAssertEqual(finished.summary.livePromptWatch, false, "a blocking question cannot outlive its turn")
    }

    func testCodexAsyncQuestionsStayAnswerableWhileTheTurnWorks() async throws {
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .preToolUse, .working, 1, hint: .deferredQuestion)
        await apply(core, .codex, .postToolUse, .working, 2, hint: .deferredQuestion)
        await core.observeLivePrompt(request(.codex, F.codexAsync2Collapsed), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        var snapshot = try await unwrap(core, id)
        var prompt = try XCTUnwrap(livePrompt(snapshot))
        XCTAssertEqual(prompt.kind, .deferred)
        XCTAssertEqual(prompt.title, "Questions waiting")
        XCTAssertEqual(prompt.pendingCount, 2)
        XCTAssertEqual(prompt.isBlocking, false)
        XCTAssertEqual(prompt.controls?.map(\.kind), [.open])
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .working, "the turn keeps working beside its questions")

        await apply(core, .codex, .preToolUse, .working, 3, hint: nil)
        await apply(core, .codex, .postToolUse, .working, 4, hint: nil)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .deferred, "tool events between captures keep the card")
        XCTAssertEqual(snapshot.summary.attention, .needsYou)

        await core.observeLivePrompt(request(.codex, F.codexAsync2OpenQ1), threadID: id, binding: binding(), observedLifecycleSequence: 4)
        snapshot = try await unwrap(core, id)
        prompt = try XCTUnwrap(livePrompt(snapshot))
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.isBlocking, false)
        XCTAssertEqual(snapshot.summary.status, .working)

        // Answered in the terminal: a run of empty captures ends the watch.
        for miss in 1...AgentCenterRuntime.deferredQuestionMissLimit {
            await core.observeLivePrompt(request(.codex, F.codexAsync2Done), threadID: id, binding: binding(), observedLifecycleSequence: 4)
            snapshot = try await unwrap(core, id)
            XCTAssertNil(livePrompt(snapshot))
            XCTAssertEqual(snapshot.summary.attention, .none)
            XCTAssertEqual(snapshot.summary.livePromptWatch, miss < AgentCenterRuntime.deferredQuestionMissLimit, "miss \(miss)")
        }
    }

    func testAPaintedQuestionResetsTheMissCount() async throws {
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .preToolUse, .working, 1, hint: .deferredQuestion)
        for _ in 1..<AgentCenterRuntime.deferredQuestionMissLimit {
            await core.observeLivePrompt(request(.codex, F.codexAsync2Done), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        await core.observeLivePrompt(request(.codex, F.codexAsync2Collapsed), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        await core.observeLivePrompt(request(.codex, F.codexAsync2Done), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        let snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true, "Codex paints a queued question a moment after its tool returns")
    }

    func testKimiBackgroundQuestionNeverBlocksTheThread() async throws {
        let core = AgentCenterRuntime(), id = thread(.kimi)
        await core.register(summary(id), binding: binding())
        await apply(core, .kimi, .preToolUse, .working, 1, hint: .deferredQuestion)
        await core.observeLivePrompt(request(.kimi, F.kimiAskbg), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .question)
        XCTAssertEqual(livePrompt(snapshot)?.isBlocking, false)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.status, .working)

        await apply(core, .kimi, .preToolUse, .working, 2, hint: .question)
        await core.observeLivePrompt(request(.kimi, F.kimiAskSingle), threadID: id, binding: binding(), observedLifecycleSequence: 2)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.isBlocking, true)
        XCTAssertEqual(snapshot.summary.status, .waitingForInput)
    }

    func testKimiBackgroundQuestionOutlivesItsTurn() async throws {
        // Kimi's real hook order: the background tool returns at once and the
        // turn stops while its question panel stays on screen.
        let core = AgentCenterRuntime(), id = thread(.kimi)
        await core.register(summary(id), binding: binding())
        await apply(core, .kimi, .preToolUse, .working, 1, hint: .deferredQuestion)
        await apply(core, .kimi, .postToolUse, .working, 2, hint: .deferredQuestion)
        await apply(core, .kimi, .stop, .idle, 3, hint: nil)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        await core.observeLivePrompt(request(.kimi, F.kimiAskbg), threadID: id, binding: binding(), observedLifecycleSequence: 3)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.isBlocking, false)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertNotEqual(snapshot.summary.status, .waitingForInput)

        // Answered in the terminal: the panel is gone for good.
        for _ in 0..<AgentCenterRuntime.deferredQuestionMissLimit {
            await core.observeLivePrompt(request(.kimi, F.kimiReviewAfter1), threadID: id, binding: binding(), observedLifecycleSequence: 3)
        }
        snapshot = try await unwrap(core, id)
        XCTAssertNil(livePrompt(snapshot))
        XCTAssertNotEqual(snapshot.summary.attention, .needsYou)
        XCTAssertNotEqual(snapshot.summary.livePromptWatch, true)
    }

    func testSessionEndClearsEveryPendingQuestion() async throws {
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .preToolUse, .working, 1, hint: .deferredQuestion)
        await core.observeLivePrompt(request(.codex, F.codexAsync2Collapsed), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        await apply(core, .codex, .sessionEnd, .unavailable, 2, hint: nil)
        let snapshot = await core.snapshot(for: id)
        XCTAssertNotEqual(snapshot?.summary.livePromptWatch, true)
        XCTAssertNil(snapshot.flatMap(livePrompt))
    }

    func testReconnectReplayRestoresTheWaitTheRetiredRouteHeld() async throws {
        for event in [AgentLifecycleEventKind.permissionRequest, .notification] {
            // Rediscovery may keep the frame's arrival sequence or assign a
            // new one; its source time still identifies the same frame.
            for replaySequence: UInt64 in [2, 3] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .preToolUse, .working, 1, hint: nil, at: 100)
                await apply(core, .claude, event, .waitingForInput, 2, hint: nil, at: 200)
                await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 2)
                let waiting = try await unwrap(core, id)
                XCTAssertEqual(livePrompt(waiting)?.kind, .permission)

                await core.replaceBinding(nil, for: id)
                var snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.attention, .none, "a retired route's pane may be gone")
                XCTAssertEqual(snapshot.summary.status, .idle)

                await core.register(summary(id), binding: binding())
                let beforeReplay = try await unwrap(core, id)
                await apply(core, .claude, event, .waitingForInput, replaySequence, hint: nil, at: 200)
                snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.attention, .needsYou, "\(event) replayed as \(replaySequence)")
                XCTAssertEqual(snapshot.summary.status, .waitingForInput)
                XCTAssertEqual(snapshot.summary.livePromptWatch, true)
                XCTAssertEqual(snapshot.attentionEpoch, waiting.attentionEpoch, "the same wait must not alert again")
                XCTAssertEqual(snapshot.deliveryGeneration, beforeReplay.deliveryGeneration)
                XCTAssertNil(livePrompt(snapshot), "only the screen supplies the controls")

                await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(),
                    observedLifecycleSequence: replaySequence)
                snapshot = try await unwrap(core, id)
                XCTAssertEqual(livePrompt(snapshot)?.kind, .permission)
                XCTAssertEqual(snapshot.summary.attention, .needsYou)
            }
        }
    }

    func testReplayRestoresAScreenRaisedApprovalUnderItsWatchWithoutAlertingAgain() async throws {
        // Codex's hook only says an approval may be pending; the screen raised
        // the attention. The restored watch rechecks it, so it comes back as
        // the same alert rather than a new one.
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .permissionRequest, .waitingForInput, 1, hint: nil, at: 100)
        await core.observeLivePrompt(request(.codex, F.codexExecApproval), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        let approving = try await unwrap(core, id)
        XCTAssertEqual(approving.summary.attention, .needsYou)
        await core.replaceBinding(nil, for: id)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .permissionRequest, .waitingForInput, 1, hint: nil, at: 100)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        XCTAssertEqual(snapshot.attentionEpoch, approving.attentionEpoch)
        await core.observeLivePrompt(request(.codex, F.codexExecApproval), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(livePrompt(snapshot)?.kind, .permission)
        XCTAssertEqual(snapshot.attentionEpoch, approving.attentionEpoch, "the same approval must not alert again")

        await core.observeLivePrompt(request(.codex, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .none, "one miss still ends what the screen raised")
    }

    func testARestoredDialogTheScreenHadShownStillEndsOnARunOfMisses() async throws {
        // Approved elsewhere while a long tool runs: no frame follows yet.
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .notification, .waitingForInput, 1, hint: nil, at: 100)
        await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        await core.replaceBinding(nil, for: id)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .notification, .waitingForInput, 1, hint: nil, at: 100)
        for miss in 1...AgentCenterRuntime.hookPromptMissLimit {
            let before = try await unwrap(core, id)
            XCTAssertEqual(before.summary.attention, .needsYou, "miss \(miss)")
            await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        }
        let snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .none)
        XCTAssertEqual(snapshot.summary.status, .working)
    }

    func testReplayKeepsACompletionReadWhileTheRouteWasRetired() async throws {
        let core = AgentCenterRuntime(), id = thread(.codex)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .preToolUse, .working, 1, hint: .deferredQuestion, at: 100)
        await apply(core, .codex, .stop, .idle, 2, hint: nil, at: 200)
        let finished = try await unwrap(core, id)
        XCTAssertEqual(finished.summary.attention, .unreadCompletion)
        await core.replaceBinding(nil, for: id)
        let read = await core.acknowledgeCompletion(threadID: id, observedEpoch: try XCTUnwrap(finished.attentionEpoch))
        XCTAssertTrue(read)
        await core.register(summary(id), binding: binding())
        await apply(core, .codex, .stop, .idle, 2, hint: nil, at: 200)
        let snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .none)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true, "the queued question is still watched")
    }

    func testReplayRestoresWhatOnlyTheScreenRaisedOnlyUnderAWatch() async throws {
        // A blocking dialog the conversation on screen showed comes back
        // watched, and one miss still ends it.
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .notification, .idle, 1, hint: nil, at: 100)
        await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(),
            observedLifecycleSequence: 1, onDisplay: true)
        var snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        await core.replaceBinding(nil, for: id)
        await core.register(summary(id), binding: binding())
        await apply(core, .claude, .notification, .idle, 1, hint: nil, at: 100)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        XCTAssertEqual(snapshot.summary.livePromptWatch, true)
        await core.observeLivePrompt(request(.claude, F.claudeAskAfterEsc), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        snapshot = try await unwrap(core, id)
        XCTAssertEqual(snapshot.summary.attention, .none)

        // A background question no hook announced has nothing left to watch
        // it, so it must be seen again.
        let codex = AgentCenterRuntime(), codexID = thread(.codex)
        await codex.register(summary(codexID), binding: binding())
        await apply(codex, .codex, .notification, .idle, 1, hint: nil, at: 100)
        await codex.observeLivePrompt(request(.codex, F.codexAsync2Collapsed), threadID: codexID, binding: binding(),
            observedLifecycleSequence: 1, onDisplay: true)
        snapshot = try await unwrap(codex, codexID)
        XCTAssertEqual(livePrompt(snapshot)?.isBlocking, false)
        XCTAssertEqual(snapshot.summary.attention, .needsYou)
        await codex.replaceBinding(nil, for: codexID)
        await codex.register(summary(codexID), binding: binding())
        await apply(codex, .codex, .notification, .idle, 1, hint: nil, at: 100)
        snapshot = try await unwrap(codex, codexID)
        XCTAssertEqual(snapshot.summary.attention, .none)
        XCTAssertEqual(snapshot.summary.livePromptWatch, false)

        let later = AgentCenterRuntime()
        await later.register(summary(id), binding: binding())
        await apply(later, .claude, .notification, .waitingForInput, 1, hint: nil, at: 100)
        await later.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id, binding: binding(), observedLifecycleSequence: 1)
        await later.replaceBinding(nil, for: id)
        await later.register(summary(id), binding: binding())
        await apply(later, .claude, .postToolUse, .working, 2, hint: nil, at: 200)
        await apply(later, .claude, .notification, .waitingForInput, 1, hint: nil, at: 100)
        snapshot = try await unwrap(later, id)
        XCTAssertEqual(snapshot.summary.attention, .none, "the agent moved on since that frame")
        XCTAssertEqual(snapshot.summary.status, .working)
    }

    func testClaudeInterruptEndsWorkingTurnWithoutUnreadCompletion() async throws {
        for kind in InterruptPageKind.allCases {
            for bootstrap in [false, true] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                if !bootstrap {
                    let initial = try interruptPage([interruptRecord(1, text: "Work on this")], kind: kind)
                    let result = await core.apply(page: initial, to: id)
                    XCTAssertTrue(result.accepted)
                }
                let before = try await unwrap(core, id)
                let page = try interruptPage([interruptRecord(2)], kind: kind,
                    operation: bootstrap ? .bootstrap : .updates, version: bootstrap ? 1 : 2,
                    from: bootstrap || kind == .legacy ? nil : "live1")
                let result = await core.apply(page: page, to: id)
                XCTAssertTrue(result.accepted)
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle, "\(kind)")
                XCTAssertEqual(stopped.summary.attention, .none)
                XCTAssertNil(stopped.unreadCompletionKey)
                XCTAssertEqual(stopped.deliveryGeneration, before.deliveryGeneration + 1)
                XCTAssertEqual(stopped.attentionEpoch, before.attentionEpoch)
                let listed = await core.listSnapshot().threads.first { $0.id == id }
                XCTAssertEqual(listed?.status, .idle)
                XCTAssertEqual(listed?.attention, AgentAttention.none)

                _ = await core.apply(page: page, to: id)
                let replayed = try await unwrap(core, id)
                XCTAssertEqual(replayed.deliveryGeneration, stopped.deliveryGeneration)
                XCTAssertEqual(replayed.summary.status, .idle)
            }
        }
    }

    func testClaudeToolInterruptClearsPermissionPrompt() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .preToolUse, .working, 1, hint: .question, at: interruptTurnNanos)
            await apply(core, .claude, .permissionRequest, .waitingForInput, 2, hint: nil, at: interruptTurnNanos)
            let observed = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                binding: binding(), observedLifecycleSequence: 2)
            XCTAssertTrue(observed)
            let waiting = try await unwrap(core, id)
            XCTAssertEqual(waiting.summary.status, .waitingForInput)
            XCTAssertEqual(waiting.summary.attention, .needsYou)
            XCTAssertNotNil(livePrompt(waiting))

            let page = try interruptPage([interruptRecord(1, text: "[Request interrupted by user for tool use]")], kind: kind)
            let result = await core.apply(page: page, to: id)
            XCTAssertTrue(result.accepted)
            let stopped = try await unwrap(core, id)
            XCTAssertEqual(stopped.summary.status, .idle, "\(kind)")
            XCTAssertEqual(stopped.summary.attention, .none)
            XCTAssertEqual(stopped.summary.livePromptWatch, false)
            XCTAssertNil(livePrompt(stopped))
            XCTAssertNil(stopped.unreadCompletionKey)
            XCTAssertEqual(stopped.attentionEpoch, waiting.attentionEpoch)
            let stale = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                binding: binding(), observedGeneration: waiting.deliveryGeneration, onDisplay: true)
            XCTAssertFalse(stale)

            await core.replaceBinding(nil, for: id)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .permissionRequest, .waitingForInput, 2, hint: nil, at: interruptTurnNanos)
            let reconnected = try await unwrap(core, id)
            XCTAssertEqual(reconnected.summary.status, .idle)
            XCTAssertEqual(reconnected.summary.attention, .none)
            XCTAssertEqual(reconnected.summary.livePromptWatch, false)
        }
    }

    func testClaudeToolInterruptFencesSequenceBasedPromptCaptures() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .permissionRequest, .waitingForInput, 1, hint: nil, at: interruptTurnNanos)
            _ = await core.apply(page: try interruptPage([interruptRecord(1)], kind: kind), to: id)
            for sequence: UInt64 in [1, 2] {
                let stale = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                    binding: binding(), observedLifecycleSequence: sequence, onDisplay: true)
                XCTAssertFalse(stale, "\(kind): no newer lifecycle frame has been accepted")
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle)
                XCTAssertEqual(stopped.summary.attention, .none)
                XCTAssertNil(livePrompt(stopped))
            }
            await apply(core, .claude, .subagentStop, .working, 2, hint: nil, at: interruptTurnNanos + 2_000_000_000)
            let neutral = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                binding: binding(), observedLifecycleSequence: 2, onDisplay: true)
            XCTAssertFalse(neutral, "a subagent callback cannot reopen the interrupted root turn")
            await apply(core, .claude, .userPromptSubmit, .working, 3, hint: nil, at: interruptTurnNanos + 5_000_000_000)
            let working = try await unwrap(core, id)
            XCTAssertEqual(working.summary.status, .working)
            await apply(core, .claude, .permissionRequest, .waitingForInput, 4, hint: nil, at: interruptTurnNanos + 6_000_000_000)
            let current = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                binding: binding(), observedLifecycleSequence: 4, onDisplay: true)
            XCTAssertTrue(current, "the next turn's prompt remains observable")
        }
    }

    func testClaudeInterruptFencesDelayedLifecycleFrames() async throws {
        for kind in InterruptPageKind.allCases {
            for (event, status) in [(AgentLifecycleEventKind.preToolUse, AgentStatus.working),
                                    (.stop, .finished), (.sessionEnd, .unavailable), (.wrapperExit, .unavailable)] {
                for delay: UInt64 in [1_000_000_000, 2_000_000_000] {
                    let core = AgentCenterRuntime(), id = thread(.claude)
                    await core.register(summary(id), binding: binding())
                    await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                    _ = await core.apply(page: try interruptPage([
                        interruptRecord(1, at: interruptTurnNanos + 2_000_000_000)], kind: kind), to: id)
                    let stopped = try await unwrap(core, id)
                    XCTAssertEqual(stopped.summary.status, .idle)

                    let result = await apply(core, .claude, event, status, 2, hint: .question,
                        at: interruptTurnNanos + delay)
                    XCTAssertEqual(result, .accepted(threadID: id))
                    let delayed = try await unwrap(core, id)
                    XCTAssertEqual(delayed.summary.status, .idle, "\(kind) \(event) \(delay)")
                    XCTAssertEqual(delayed.summary.attention, .none)
                    XCTAssertEqual(delayed.summary.livePromptWatch, false)
                    XCTAssertNil(livePrompt(delayed))
                    XCTAssertNil(delayed.unreadCompletionKey)
                    XCTAssertEqual(delayed.deliveryGeneration, stopped.deliveryGeneration)
                    XCTAssertEqual(delayed.attentionEpoch, stopped.attentionEpoch)
                    let stale = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id,
                        binding: binding(), observedLifecycleSequence: 2, onDisplay: true)
                    XCTAssertFalse(stale)

                    await apply(core, .claude, .userPromptSubmit, .working, 3, hint: nil,
                        at: interruptTurnNanos + 3_000_000_000)
                    let working = try await unwrap(core, id)
                    await apply(core, .claude, event, status, 4, hint: .question, at: interruptTurnNanos + delay)
                    let replayed = try await unwrap(core, id)
                    XCTAssertEqual(replayed.summary.status, .working)
                    XCTAssertEqual(replayed.summary.attention, .none)
                    XCTAssertEqual(replayed.summary.livePromptWatch, false)
                    XCTAssertEqual(replayed.deliveryGeneration, working.deliveryGeneration)
                }
            }
        }
    }

    func testClaudeToolInterruptFencesDelayedPermissionRequests() async throws {
        for kind in InterruptPageKind.allCases {
            for delay: UInt64 in [1_000_000_000, 2_000_000_000] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                _ = await core.apply(page: try interruptPage([interruptRecord(1,
                    text: "[Request interrupted by user for tool use]", at: interruptTurnNanos + 2_000_000_000)],
                    kind: kind), to: id)
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle)

                let result = await apply(core, .claude, .permissionRequest, .waitingForInput, 2, hint: nil,
                    at: interruptTurnNanos + delay)
                XCTAssertEqual(result, .accepted(threadID: id))
                let delayed = try await unwrap(core, id)
                XCTAssertEqual(delayed.summary.status, .idle, "\(kind) \(delay)")
                XCTAssertEqual(delayed.summary.attention, .none)
                XCTAssertEqual(delayed.summary.livePromptWatch, false)
                XCTAssertNil(livePrompt(delayed))
                XCTAssertEqual(delayed.deliveryGeneration, stopped.deliveryGeneration)
                XCTAssertEqual(delayed.attentionEpoch, stopped.attentionEpoch)
                let stale = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                    binding: binding(), observedLifecycleSequence: 2, onDisplay: true)
                XCTAssertFalse(stale)
            }
        }
    }

    func testClaudeNewerRootFrameClearsInterruptFence() async throws {
        for kind in InterruptPageKind.allCases {
            for event in [AgentLifecycleEventKind.userPromptSubmit, .preToolUse] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                let records = [interruptRecord(1, at: interruptTurnNanos + 2_000_000_000)]
                let page = try interruptPage(records, kind: kind)
                _ = await core.apply(page: page, to: id)
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle)

                let result = await apply(core, .claude, event, .working, 2, hint: nil,
                    at: interruptTurnNanos + 3_000_000_000)
                XCTAssertEqual(result, .accepted(threadID: id))
                let working = try await unwrap(core, id)
                XCTAssertEqual(working.summary.status, .working)
                _ = await core.apply(page: page, to: id)
                _ = await core.apply(page: try interruptPage(records, kind: kind, epoch: "resumed"), to: id)
                let replayed = try await unwrap(core, id)
                XCTAssertEqual(replayed.summary.status, .working, "\(kind) \(event)")
                XCTAssertEqual(replayed.summary.attention, .none)
                XCTAssertEqual(replayed.deliveryGeneration, working.deliveryGeneration)
                let current = await core.observeLivePrompt(request(.claude, F.claudeAskSingle), threadID: id,
                    binding: binding(), observedLifecycleSequence: 2, onDisplay: true)
                XCTAssertTrue(current)
            }
        }
    }

    func testClaudeInterruptEndsTurnRestoredFromSubagentStart() async throws {
        for kind in InterruptPageKind.allCases {
            for childCallback in [false, true] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                var restored = summary(id)
                restored.status = .working
                await core.register(restored, binding: binding())
                await apply(core, .claude, .subagentStart, .working, 1, hint: nil, at: interruptTurnNanos)
                if childCallback {
                    await apply(core, .claude, .subagentStop, .working, 2, hint: nil,
                        at: interruptTurnNanos + 3_000_000_000)
                }
                let working = try await unwrap(core, id)
                XCTAssertEqual(working.summary.status, .working)
                XCTAssertNil(working.summary.lastActivity)
                _ = await core.apply(page: try interruptPage([interruptRecord(1, text: "Work on this")], kind: kind), to: id)
                let result = await core.apply(page: try interruptPage([
                    interruptRecord(2, at: interruptTurnNanos + 2_000_000_000)], kind: kind,
                    operation: .updates, version: 2, from: kind == .legacy ? nil : "live1"), to: id)
                XCTAssertTrue(result.accepted)
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle, "\(kind) \(childCallback)")
                XCTAssertEqual(stopped.summary.attention, .none)
                XCTAssertEqual(stopped.attentionEpoch, working.attentionEpoch)
                XCTAssertNil(stopped.unreadCompletionKey)
            }
        }
    }

    func testClaudeInterruptOlderThanRestoredSubagentStartIsIgnored() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            var restored = summary(id)
            restored.status = .working
            await core.register(restored, binding: binding())
            await apply(core, .claude, .subagentStart, .working, 1, hint: nil, at: interruptTurnNanos)
            let working = try await unwrap(core, id)
            let result = await core.apply(page: try interruptPage([
                interruptRecord(1, at: interruptTurnNanos - 1_000_000_000)], kind: kind), to: id)
            XCTAssertTrue(result.accepted)
            let ignored = try await unwrap(core, id)
            XCTAssertEqual(ignored.summary.status, .working, "\(kind)")
            XCTAssertEqual(ignored.summary.attention, .none)
            XCTAssertEqual(ignored.deliveryGeneration, working.deliveryGeneration)
        }
    }

    func testClaudeUntimestampedFramesKeepInterruptBehavior() async throws {
        for kind in InterruptPageKind.allCases {
            for (event, status, attention) in [(AgentLifecycleEventKind.preToolUse, AgentStatus.working, AgentAttention.none),
                                              (.permissionRequest, .waitingForInput, .needsYou)] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                _ = await core.apply(page: try interruptPage([interruptRecord(1)], kind: kind), to: id)
                let stopped = try await unwrap(core, id)
                XCTAssertEqual(stopped.summary.status, .idle)
                await apply(core, .claude, event, status, 2, hint: nil)
                let current = try await unwrap(core, id)
                XCTAssertEqual(current.summary.status, status, "\(kind) \(event)")
                XCTAssertEqual(current.summary.attention, attention)
                let observed = await core.observeLivePrompt(request(.claude, F.claudePermBash), threadID: id,
                    binding: binding(), observedLifecycleSequence: 2, onDisplay: true)
                XCTAssertTrue(observed)
            }
        }
    }

    func testClaudeInterruptFollowedByMetadataEndsTurn() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
            _ = await core.apply(page: try interruptPage([interruptRecord(1, text: "Work on this")], kind: kind), to: id)
            let records = [interruptRecord(2)] + ["cost-state", "queue-operation", "metadata"].enumerated().map { index, type in
                AgentProjectionRecord(sequence: UInt64(index + 3), recordID: "metadata-\(index)",
                    record: .object(["type": .string(type)]))!
            }
            let result = await core.apply(page: try interruptPage(records, kind: kind, operation: .updates,
                version: 2, from: kind == .legacy ? nil : "live1"), to: id)
            XCTAssertTrue(result.accepted)
            let stopped = try await unwrap(core, id)
            XCTAssertEqual(stopped.summary.status, .idle, "\(kind)")
            XCTAssertEqual(stopped.summary.attention, .none)
        }
    }

    func testClaudeInterruptOlderThanRootActivityIsIgnored() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
            await apply(core, .claude, .preToolUse, .working, 2, hint: nil, at: interruptTurnNanos + 5_000_000_000)
            let before = try await unwrap(core, id)
            let result = await core.apply(page: try interruptPage([interruptRecord(1)], kind: kind), to: id)
            XCTAssertTrue(result.accepted)
            let after = try await unwrap(core, id)
            XCTAssertEqual(after.summary.status, .working, "\(kind)")
            XCTAssertEqual(after.summary.attention, .none)
            XCTAssertEqual(after.deliveryGeneration, before.deliveryGeneration)
        }
    }

    func testClaudeInterruptReplayCannotEndNewerTurn() async throws {
        for kind in InterruptPageKind.allCases {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
            let records = [interruptRecord(1)]
            let page = try interruptPage(records, kind: kind)
            _ = await core.apply(page: page, to: id)
            let stopped = try await unwrap(core, id)
            XCTAssertEqual(stopped.summary.status, .idle)
            await apply(core, .claude, .userPromptSubmit, .working, 2, hint: nil, at: interruptTurnNanos + 5_000_000_000)
            let working = try await unwrap(core, id)
            XCTAssertEqual(working.summary.status, .working)
            _ = await core.apply(page: page, to: id)
            // A fresh reader admits the same old marker again, rather than
            // relying only on the transaction's duplicate check.
            _ = await core.apply(page: try interruptPage(records, kind: kind, epoch: "resumed"), to: id)
            let replayed = try await unwrap(core, id)
            XCTAssertEqual(replayed.summary.status, .working, "\(kind)")
            XCTAssertEqual(replayed.summary.attention, .none)
            XCTAssertEqual(replayed.deliveryGeneration, working.deliveryGeneration)
        }
    }

    func testCodexAndKimiInterruptTextDoNotEndTurn() async throws {
        for provider in [AgentProviderID.codex, .kimi] {
            for kind in InterruptPageKind.allCases {
                let core = AgentCenterRuntime(), id = thread(provider)
                await core.register(summary(id), binding: binding())
                await apply(core, provider, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                let result = await core.apply(page: try interruptPage([interruptRecord(1)], kind: kind), to: id)
                XCTAssertTrue(result.accepted)
                let snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.status, .working, "\(provider) \(kind)")
                XCTAssertEqual(snapshot.summary.attention, .none)
            }
        }
    }

    func testClaudeInterruptRequiresANewerTimestampAndKnownRootActivity() async throws {
        let times: [(UInt64?, UInt64?)] = [(nil, interruptTurnNanos + 1_000_000_000),
            (interruptTurnNanos, interruptTurnNanos), (interruptTurnNanos, nil)]
        for kind in InterruptPageKind.allCases {
            for (rootTime, markerTime) in times {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: rootTime)
                _ = await core.apply(page: try interruptPage([interruptRecord(1, at: markerTime)], kind: kind), to: id)
                let snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.status, .working, "\(kind)")
            }
        }
    }

    func testClaudeInterruptInOlderHistoryCannotEndTurn() async throws {
        for kind in InterruptPageKind.allCases {
            for role in [AgentRole.user, .assistant] {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                _ = await core.apply(page: try interruptPage([interruptRecord(2, text: "Newer work", role: role)], kind: kind), to: id)
                let before = try await unwrap(core, id)
                // Its timestamp passes the lifecycle fence, but its record order
                // proves this marker belongs to the older page.
                let history = try interruptPage([interruptRecord(1)], kind: kind, operation: .history, version: 2, from: before.cursor)
                let result = await core.apply(page: history, to: id)
                XCTAssertTrue(result.accepted)
                let snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.status, .working, "\(kind) \(role)")
                XCTAssertEqual(snapshot.deliveryGeneration, before.deliveryGeneration)
            }
        }
    }

    func testClaudeInterruptBackfilledByAHeadRefreshCannotEndTurn() async throws {
        for kind in [InterruptPageKind.legacy, .window] {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
            let assistant = interruptRecord(2, text: "Newer work", role: .assistant)
            _ = await core.apply(page: try interruptPage([assistant], kind: kind), to: id)
            let before = try await unwrap(core, id)
            let result = await core.apply(page: try interruptPage([interruptRecord(1), assistant], kind: kind,
                operation: .updates, version: 2, from: kind == .legacy ? nil : "live1"), to: id)
            XCTAssertTrue(result.accepted)
            let snapshot = try await unwrap(core, id)
            XCTAssertEqual(snapshot.summary.status, .working, "\(kind)")
            XCTAssertEqual(snapshot.deliveryGeneration, before.deliveryGeneration)
        }
    }

    func testClaudeInterruptRetainedRevisionCanEndTurn() async throws {
        for kind in [InterruptPageKind.ingestion, .window] {
            let core = AgentCenterRuntime(), id = thread(.claude)
            await core.register(summary(id), binding: binding())
            await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
            let metadata = AgentProjectionRecord(sequence: 2, recordID: "metadata", record: .object(["type": .string("metadata")]))!
            _ = await core.apply(page: try interruptPage([interruptRecord(1, text: "Work on this"), metadata], kind: kind), to: id)
            let window = kind == .window ? try AgentIngestionWindowTransaction(lane: .revisions, version: 2) : nil
            let page = AgentProjectionPage(sourceIdentity: "source", from: "live1", records: [interruptRecord(1, revision: 2)],
                cursor: nil, hasMore: false, ingestion: AgentIngestionRange(epoch: "interrupts", requestID: "revision",
                    operation: .updates, liveCursor: "live2", window: window)!)!
            let result = await core.apply(page: page, to: id)
            XCTAssertTrue(result.accepted)
            let stopped = try await unwrap(core, id)
            XCTAssertEqual(stopped.summary.status, .idle, "\(kind)")
            XCTAssertEqual(stopped.summary.attention, .none)
        }
    }

    func testClaudeInterruptRequiresAnExactSingleRootUserTextBlock() async throws {
        let records = [interruptRecord(1, text: "[Request interrupted by user] quoted"),
            interruptRecord(1, role: .assistant),
            interruptRecord(1, extraBlocks: [.object(["type": .string("text"), "text": .string("more")])]),
            interruptRecord(1, attributes: ["isSidechain": .bool(true)]),
            interruptRecord(1, attributes: ["isSubagent": .bool(true)])]
        for kind in InterruptPageKind.allCases {
            for record in records {
                let core = AgentCenterRuntime(), id = thread(.claude)
                await core.register(summary(id), binding: binding())
                await apply(core, .claude, .userPromptSubmit, .working, 1, hint: nil, at: interruptTurnNanos)
                _ = await core.apply(page: try interruptPage([record], kind: kind), to: id)
                let snapshot = try await unwrap(core, id)
                XCTAssertEqual(snapshot.summary.status, .working, "\(kind)")
            }
        }
    }

    // MARK: Helpers

    private enum InterruptPageKind: CaseIterable { case legacy, ingestion, window }
    private var interruptTurnNanos: UInt64 { 1_793_124_116_000_000_000 }

    private func interruptRecord(_ sequence: UInt64, text: String = "[Request interrupted by user]",
                                 at timestamp: UInt64? = 1_793_124_117_000_000_000, role: AgentRole = .user,
                                 extraBlocks: [AgentJSONValue] = [], attributes: [String: AgentJSONValue] = [:],
                                 revision: UInt64 = 1) -> AgentProjectionRecord {
        var body = attributes
        body["type"] = .string("message"); body["role"] = .string(role.rawValue)
        body["blocks"] = .array([.object(["type": .string("text"), "text": .string(text)])] + extraBlocks)
        if let timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            body["timestamp"] = .string(formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000_000_000)))
        }
        return AgentProjectionRecord(sequence: sequence, recordID: "interrupt-\(sequence)", record: .object(body), revision: revision)!
    }

    private func interruptPage(_ records: [AgentProjectionRecord], kind: InterruptPageKind,
                               operation: AgentIngestionRange.Operation = .bootstrap, version: UInt64 = 1,
                               from: String? = nil, epoch: String = "interrupts") throws -> AgentProjectionPage {
        let window = kind == .window ? try AgentIngestionWindowTransaction(
            lane: operation == .bootstrap ? .bootstrap : operation == .history ? .before : .head,
            version: version, segmentID: "interrupts\(version)", before: "before\(version)", after: "after\(version)",
            hasOlder: true, hasNewer: false) : nil
        let ingestion = kind == .legacy ? nil : AgentIngestionRange(epoch: epoch, requestID: "interrupts\(version)",
            operation: operation, liveCursor: operation == .history ? nil : "live\(version)", window: window)!
        return AgentProjectionPage(sourceIdentity: "source", from: from, records: records,
            cursor: operation == .updates ? nil : "before\(version)", hasMore: operation != .updates, ingestion: ingestion)!
    }

    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(_ provider: AgentProviderID) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: "provider-session")!
    }

    /// A route proven for process `pid`; without one it can only observe.
    private func binding(generation: UInt64 = 1, pid: Int? = 42) -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: generation, incarnation: AgentIncarnationToken("incarnation-1")!,
                             transport: .sshTmux, tmuxSession: "work", windowID: "@1", paneID: "%2", agentPID: pid,
                             capabilities: pid == nil ? [.observe] : [.observe, .send, .interrupt, .promptAnswer, .tmux])
    }

    private func summary(_ id: AgentThreadID) -> AgentThreadSummary {
        AgentThreadSummary(id: id, providerName: "Agent",
                           availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true))
    }

    @discardableResult
    private func apply(_ core: AgentCenterRuntime, _ provider: AgentProviderID, _ event: AgentLifecycleEventKind,
                       _ status: AgentStatus, _ sequence: UInt64, hint: AgentLifecycleInputHint?,
                       at sourceTime: UInt64? = nil, call: String? = nil, pid: Int? = 42) async -> AgentLifecycleAcceptance {
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(pid: pid), sourceIdentity: "route",
                                               processIDs: Set(pid.map { [$0] } ?? []))
        let envelope = AgentLifecycleEnvelope(version: 9, providerID: provider, event: event, status: status,
            providerSessionID: "provider-session", agentPID: pid, transcriptRef: "ref", eventSequence: sequence,
            sourceTimestampNanoseconds: sourceTime)!
        return await core.applyLifecycle(envelope.withInputHint(hint, toolUseID: call), proof: proof, expectedSourceIdentity: "route")
    }

    private func request(_ provider: AgentProviderID, _ fixture: F.Fixture) -> AgentPromptObservationRequest {
        AgentPromptObservationRequest(providerID: provider, visibleText: fixture.text, currentCursorLine: fixture.cursorLine)!
    }

    /// The fixture in a pane too short for it: the dialog's question and
    /// everything above its first option scrolled off.
    private func cropped(_ fixture: F.Fixture, replacing row: String? = nil, with replacement: String = "") -> AgentPromptObservationRequest {
        var rows = fixture.text.components(separatedBy: "\n")
        if let row { rows = rows.map { $0 == row ? replacement : $0 } }
        let text = rows.drop { !$0.hasPrefix("❯ 1.") }.joined(separator: "\n")
        return AgentPromptObservationRequest(providerID: .claude, visibleText: text, currentCursorLine: nil)!
    }

    private let ledger = "Which database should the service use for the new ledger?"
    /// The options `F.claudeAskSingle` draws.
    private let databases = [(label: "Postgres (Recommended)", description: "Mature, transactional, already deployed."),
                             (label: "SQLite", description: "Embedded file, zero operations."),
                             (label: "DynamoDB", description: "Managed key-value store.")]

    private func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }

    private func ingest(_ core: AgentCenterRuntime, _ id: AgentThreadID, _ records: [AgentJSONValue], from first: Int = 1,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let records = records.enumerated().map { index, record in
            AgentProjectionRecord(sequence: UInt64(first + index), recordID: "ask-\(first + index)", record: record)!
        }
        let page = AgentProjectionPage(sourceIdentity: "source", from: nil, records: records, cursor: nil, hasMore: false)!
        let accepted = await core.apply(page: page, to: id).accepted
        XCTAssertTrue(accepted, file: file, line: line)
    }

    /// Claude's call with tool-use ID `id`, written `at` seconds on the host's clock, when given.
    private func askCall(_ questions: [(question: String, header: String, options: [(label: String, description: String)])],
                         id: String? = "call-A", cut: Bool = false, at written: UInt64? = nil) -> AgentJSONValue {
        let input: [String: Any] = ["questions": questions.map { question in
            ["question": question.question, "header": question.header, "multiSelect": false,
             "options": question.options.map { ["label": $0.label, "description": $0.description] }] as [String: Any]
        }]
        var preview = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        if cut { preview = String(preview.prefix(preview.count / 2)) }
        var block: [String: AgentJSONValue] = ["type": .string("tool_call"), "name": .string("AskUserQuestion"), "preview": .string(preview)]
        if let id { block["toolCallID"] = .string(id) }
        var record: [String: AgentJSONValue] = [
            "type": .string("message"), "role": .string("assistant"), "blocks": .array([.object(block)])]
        if let written {
            record["timestamp"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(written))))
        }
        return .object(record)
    }

    private func toolCall(_ name: String, id: String) -> AgentJSONValue {
        .object(["type": .string("message"), "role": .string("assistant"), "blocks": .array([
            .object(["type": .string("tool_call"), "name": .string(name), "preview": .string("{}"), "toolCallID": .string(id)])])])
    }

    private func askResult(_ id: String = "call-A") -> AgentJSONValue {
        .object(["type": .string("message"), "role": .string("tool"),
                 "blocks": .array([.object(["type": .string("tool_result"), "preview": .string("User answered."), "toolCallID": .string(id)])])])
    }

    private func unwrap(_ core: AgentCenterRuntime, _ id: AgentThreadID, file: StaticString = #filePath, line: UInt = #line) async throws -> AgentThreadSnapshot {
        let snapshot = await core.snapshot(for: id)
        return try XCTUnwrap(snapshot, file: file, line: line)
    }

    private func segment(_ start: Int, count: Int = 100, total: Int = 1000) throws -> AgentIngestionSegment {
        try .init(id: "s\(start)", source: "source", before: "b\(start)", after: "a\(start + count)",
            hasOlder: start > 0, hasNewer: start + count < total,
            records: (start..<(start + count)).map { .init(sequence: UInt64($0), recordID: "r\($0)",
                record: .object(["type": .string("assistant"), "text": .string("hello")]))! })
    }

    private func projection(_ segment: AgentIngestionSegment, lane: AgentIngestionWindowTransaction.Lane,
                            version: UInt64, from: String? = nil, live: String? = "live") throws -> AgentProjectionPage {
        let operation: AgentIngestionRange.Operation = lane == .bootstrap ? .bootstrap : (lane == .before || lane == .after) ? .history : .updates
        let window = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: segment.id,
            before: segment.before, after: segment.after, hasOlder: segment.hasOlder, hasNewer: segment.hasNewer)
        return AgentProjectionPage(sourceIdentity: segment.source, from: from, records: segment.records,
            cursor: operation == .updates || !segment.hasOlder ? nil : segment.before,
            hasMore: operation != .updates && segment.hasOlder, summary: nil,
            ingestion: .init(epoch: "epoch", requestID: "tx\(version)", operation: operation,
                liveCursor: operation == .history ? nil : live, window: window)!)!
    }

    private func livePrompt(_ snapshot: AgentThreadSnapshot) -> AgentActionPrompt? {
        for message in snapshot.messages {
            for case .actionPrompt(let prompt) in message.blocks where message.recordID.hasPrefix("live-prompt-") { return prompt }
        }
        return nil
    }
}
