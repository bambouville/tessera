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

    // MARK: Helpers

    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(_ provider: AgentProviderID) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: "provider-session")!
    }

    private func binding(generation: UInt64 = 1) -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: generation, incarnation: AgentIncarnationToken("incarnation-1")!,
                             transport: .sshTmux, tmuxSession: "work", windowID: "@1", paneID: "%2", agentPID: 42,
                             capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux])
    }

    private func summary(_ id: AgentThreadID) -> AgentThreadSummary {
        AgentThreadSummary(id: id, providerName: "Agent",
                           availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true))
    }

    private func apply(_ core: AgentCenterRuntime, _ provider: AgentProviderID, _ event: AgentLifecycleEventKind,
                       _ status: AgentStatus, _ sequence: UInt64, hint: AgentLifecycleInputHint?) async {
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
        let envelope = AgentLifecycleEnvelope(version: 9, providerID: provider, event: event, status: status,
            providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref", eventSequence: sequence)!
        _ = await core.applyLifecycle(envelope.withInputHint(hint), proof: proof, expectedSourceIdentity: "route")
    }

    private func request(_ provider: AgentProviderID, _ fixture: F.Fixture) -> AgentPromptObservationRequest {
        AgentPromptObservationRequest(providerID: provider, visibleText: fixture.text, currentCursorLine: fixture.cursorLine)!
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
