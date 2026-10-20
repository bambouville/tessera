import XCTest
@testable import TesseraAgentCore

/// The "agent just finished" pipeline: route retirement and rediscovery,
/// durable completion reads, notification epochs and record-free
/// acknowledgement.
final class AgentAttentionLifecycleTests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(_ provider: AgentProviderID = .codex) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: "provider-session")!
    }

    private func binding(generation: UInt64 = 1, incarnation: String = "incarnation-1") -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: generation,
            incarnation: AgentIncarnationToken(incarnation)!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", agentPID: 42,
            capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux])
    }

    private func summary(_ id: AgentThreadID, attention: AgentAttention = .none,
                         status: AgentStatus = .unavailable) -> AgentThreadSummary {
        AgentThreadSummary(id: id, providerName: "Codex", status: status, attention: attention,
            availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true))
    }

    private func proof(_ binding: AgentTerminalBinding, route: String) -> AgentLifecycleBindingProof {
        AgentLifecycleBindingProof(hostID: hostID, binding: binding, sourceIdentity: route, processIDs: [42])
    }

    private func envelope(_ id: AgentThreadID, _ event: AgentLifecycleEventKind, _ status: AgentStatus,
                          arrival: UInt64, timestamp: UInt64) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(version: 9, providerID: id.providerID, event: event, status: status,
            providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl",
            eventSequence: arrival, sourceTimestampNanoseconds: timestamp)!
    }

    private func stop(_ id: AgentThreadID, arrival: UInt64, timestamp: UInt64 = 1_000) -> AgentLifecycleEnvelope {
        envelope(id, .stop, .finished, arrival: arrival, timestamp: timestamp)
    }

    // MARK: - F1: a retired route rediscovered with the retained payload

    /// Transport drop retires the route; the reconnect registers a new binding
    /// and the pane's retained `@tessera_agent_state` replays the same Stop.
    func testRetainedStopRediscoveredOnANewRouteIsListedAndStaysUnread() async {
        let core = AgentCenterRuntime(), id = thread()
        let first = binding()
        await core.register(summary(id), binding: first)
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(first, route: "route-1"), expectedSourceIdentity: "route-1")
        var list = await core.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id])

        await core.replaceBinding(nil, for: id)
        list = await core.listSnapshot()
        XCTAssertTrue(list.threads.isEmpty, "a retired route is not an open agent")

        let second = binding(generation: 2, incarnation: "incarnation-2")
        await core.register(summary(id, attention: .unreadCompletion, status: .finished), binding: second)
        let acceptance = await core.applyLifecycle(stop(id, arrival: 2), proof: proof(second, route: "route-2"),
                                                   expectedSourceIdentity: "route-2")
        XCTAssertEqual(acceptance, .accepted(threadID: id))
        list = await core.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id], "the rediscovered live agent must be listed again")
        XCTAssertEqual(list.threads.first?.attention, .unreadCompletion)
        XCTAssertEqual(list.threads.first?.status, .finished)
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.binding, second)
    }

    /// A transient discovery miss re-registers the very same binding.
    func testRetainedStopRediscoveredOnTheSameRouteIsListedAgain() async {
        let core = AgentCenterRuntime(), id = thread()
        await core.register(summary(id), binding: binding())
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        await core.replaceBinding(nil, for: id)
        await core.register(summary(id, attention: .unreadCompletion, status: .finished), binding: binding())
        _ = await core.applyLifecycle(stop(id, arrival: 2), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let list = await core.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id])
        XCTAssertEqual(list.threads.first?.attention, .unreadCompletion)
    }

    /// Route adoption must not resurrect an acknowledged completion, nor
    /// publish a new delivery generation for a replayed frame.
    func testRediscoveredAcknowledgedStopIsListedButStaysRead() async {
        let core = AgentCenterRuntime(), id = thread()
        let first = binding()
        await core.register(summary(id), binding: first)
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(first, route: "route-1"), expectedSourceIdentity: "route-1")
        let finished = await core.snapshot(for: id)!
        let acknowledged = await core.acknowledgeTerminal(threadID: id, binding: first, observedGeneration: finished.deliveryGeneration)
        XCTAssertTrue(acknowledged)
        await core.replaceBinding(nil, for: id)
        let second = binding(generation: 2, incarnation: "incarnation-2")
        await core.register(summary(id, attention: .unreadCompletion, status: .finished), binding: second)
        let registered = await core.snapshot(for: id)!
        _ = await core.applyLifecycle(stop(id, arrival: 2), proof: proof(second, route: "route-2"), expectedSourceIdentity: "route-2")
        let list = await core.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id])
        XCTAssertEqual(list.threads.first?.attention, AgentAttention.none)
        XCTAssertEqual(list.threads.first?.status, .idle)
        let replayed = await core.snapshot(for: id)
        XCTAssertEqual(replayed?.deliveryGeneration, registered.deliveryGeneration,
                       "a replayed frame adopts the route without invalidating observed generations")
    }

    /// A duplicate frame proves only its own registered binding. It cannot
    /// move another thread's route.
    func testDuplicateFrameDoesNotAdoptAnUnregisteredBinding() async {
        let core = AgentCenterRuntime(), id = thread()
        await core.register(summary(id), binding: binding())
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        await core.replaceBinding(nil, for: id)
        let stranger = binding(generation: 9, incarnation: "incarnation-9")
        let acceptance = await core.applyLifecycle(stop(id, arrival: 2), proof: proof(stranger, route: "route-9"),
                                                   expectedSourceIdentity: "route-9")
        XCTAssertEqual(acceptance, .rejected(.staleBinding))
        let list = await core.listSnapshot()
        XCTAssertTrue(list.threads.isEmpty)
    }

    // MARK: - F4: one alert per entry into an attention state

    /// The root cause: `deliveryGeneration` moves for the same finish, so a
    /// platform keyed on it alerted again. The epoch does not move.
    func testAttentionEpochIsStableAcrossIdleNotificationAndRebinding() async {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        let route = proof(binding(), route: "route-1")
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: route, expectedSourceIdentity: "route-1")
        let afterStop = await core.snapshot(for: id)!
        _ = await core.applyLifecycle(envelope(id, .notification, .idle, arrival: 2, timestamp: 61_000), proof: route,
                                      expectedSourceIdentity: "route-1")
        let afterIdle = await core.snapshot(for: id)!
        // Reconnection retires the old carrier before registering its successor.
        await core.replaceBinding(nil, for: id)
        await core.register(summary(id), binding: binding(generation: 2, incarnation: "incarnation-2"))
        let afterRebind = await core.snapshot(for: id)!
        XCTAssertEqual([afterStop, afterIdle, afterRebind].map(\.summary.attention),
                       [.unreadCompletion, .unreadCompletion, .unreadCompletion])
        XCTAssertEqual(Set([afterStop, afterIdle, afterRebind].map(\.deliveryGeneration)).count, 3,
                       "delivery generations keep fencing stale actions")
        XCTAssertEqual(afterStop.attentionEpoch, 1)
        XCTAssertEqual(afterIdle.attentionEpoch, 1)
        XCTAssertEqual(afterRebind.attentionEpoch, 1)
        let event = await core.attentionEvent(for: id, routeToken: AgentRouteToken())
        XCTAssertEqual(event?.attentionEpoch, 1)
    }

    func testAttentionEpochAdvancesOnlyWhenEnteringAttention() async {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        let route = proof(binding(), route: "route-1")
        func epoch() async -> UInt64? { await core.snapshot(for: id)?.attentionEpoch }
        _ = await core.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 1, timestamp: 10), proof: route, expectedSourceIdentity: "route-1")
        var value = await epoch()
        XCTAssertEqual(value, 0, "working is not attention")
        _ = await core.applyLifecycle(stop(id, arrival: 2, timestamp: 20), proof: route, expectedSourceIdentity: "route-1")
        value = await epoch()
        XCTAssertEqual(value, 1)
        _ = await core.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 3, timestamp: 30), proof: route, expectedSourceIdentity: "route-1")
        value = await epoch()
        XCTAssertEqual(value, 1, "leaving attention keeps the epoch")
        _ = await core.applyLifecycle(envelope(id, .permissionRequest, .waitingForInput, arrival: 4, timestamp: 40), proof: route, expectedSourceIdentity: "route-1")
        value = await epoch()
        XCTAssertEqual(value, 2, "a request is a new entry")
        _ = await core.applyLifecycle(stop(id, arrival: 5, timestamp: 50), proof: route, expectedSourceIdentity: "route-1")
        value = await epoch()
        XCTAssertEqual(value, 3, "needsYou to unreadCompletion is a new entry")
    }

    // MARK: - F5: reading clears a finish without a record to point at

    func testAcknowledgeCompletionClearsAFinishedThreadWithoutRecords() async {
        let core = AgentCenterRuntime(), id = thread()
        await core.register(summary(id), binding: binding())
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let finished = await core.snapshot(for: id)!
        XCTAssertTrue(finished.messages.isEmpty)
        let recordRead = await core.acknowledge(threadID: id, visibleRecordID: "none")
        XCTAssertFalse(recordRead, "there is no record to acknowledge")
        let stale = await core.acknowledgeCompletion(threadID: id, observedEpoch: finished.attentionEpoch! + 1)
        XCTAssertFalse(stale)
        let read = await core.acknowledgeCompletion(threadID: id, observedEpoch: finished.attentionEpoch!)
        XCTAssertTrue(read)
        let after = await core.snapshot(for: id)!
        XCTAssertEqual(after.summary.attention, AgentAttention.none)
        XCTAssertEqual(after.summary.status, .idle)
        XCTAssertGreaterThan(after.deliveryGeneration, finished.deliveryGeneration)
        let repeated = await core.acknowledgeCompletion(threadID: id, observedEpoch: finished.attentionEpoch!)
        XCTAssertFalse(repeated, "a repeat changes nothing")
        let list = await core.listSnapshot()
        XCTAssertEqual(list.threads.first?.attention, AgentAttention.none)
    }

    /// An older view cannot clear a newer finish, nor a request for input.
    func testAcknowledgeCompletionIsFencedByTheObservedEpoch() async {
        let core = AgentCenterRuntime(), id = thread(.claude)
        await core.register(summary(id), binding: binding())
        let route = proof(binding(), route: "route-1")
        _ = await core.applyLifecycle(stop(id, arrival: 1, timestamp: 10), proof: route, expectedSourceIdentity: "route-1")
        let first = await core.snapshot(for: id)!.attentionEpoch!
        _ = await core.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 2, timestamp: 20), proof: route, expectedSourceIdentity: "route-1")
        _ = await core.applyLifecycle(stop(id, arrival: 3, timestamp: 30), proof: route, expectedSourceIdentity: "route-1")
        let olderView = await core.acknowledgeCompletion(threadID: id, observedEpoch: first)
        XCTAssertFalse(olderView)
        let second = await core.snapshot(for: id)!.attentionEpoch!
        _ = await core.applyLifecycle(envelope(id, .permissionRequest, .waitingForInput, arrival: 4, timestamp: 40), proof: route, expectedSourceIdentity: "route-1")
        let request = await core.snapshot(for: id)!
        let clearedRequest = await core.acknowledgeCompletion(threadID: id, observedEpoch: request.attentionEpoch!)
        XCTAssertFalse(clearedRequest, "reading does not answer a request")
        XCTAssertEqual(request.summary.attention, .needsYou)
        XCTAssertNotEqual(second, request.attentionEpoch)
    }

    // MARK: - F3: completion read state survives a relaunch

    private func metadata(_ snapshot: AgentThreadSnapshot) -> AgentThreadMetadata {
        AgentThreadMetadata(threadID: snapshot.summary.id, unreadCompletionKey: snapshot.unreadCompletionKey,
                            acknowledgedCompletionKey: snapshot.acknowledgedCompletionKey)
    }

    /// Codex and Kimi have no idle notification: the retained Stop is the
    /// pane's state for as long as the agent waits, and a relaunch replays it.
    func testRelaunchDoesNotResurrectAnAcknowledgedRetainedStop() async {
        let before = AgentCenterRuntime(), id = thread()
        await before.register(summary(id), binding: binding())
        _ = await before.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let finished = await before.snapshot(for: id)!
        XCTAssertNotNil(finished.unreadCompletionKey)
        _ = await before.acknowledgeCompletion(threadID: id, observedEpoch: finished.attentionEpoch!)
        let read = await before.snapshot(for: id)!
        XCTAssertNil(read.unreadCompletionKey)
        XCTAssertEqual(read.acknowledgedCompletionKey, finished.unreadCompletionKey)

        let after = AgentCenterRuntime()
        await after.configure(metadata: [metadata(read)])
        await after.register(summary(id, attention: .unreadCompletion, status: .finished), binding: binding())
        _ = await after.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let list = await after.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id])
        XCTAssertEqual(list.threads.first?.attention, AgentAttention.none, "an acknowledged finish stays read after a relaunch")
        XCTAssertEqual(list.threads.first?.status, .idle)
        let event = await after.attentionEvent(for: id, routeToken: AgentRouteToken())
        XCTAssertNil(event, "and it is not delivered again")
    }

    /// A different retained Stop is a new finish, read or not.
    func testRelaunchStillReportsANewerRetainedStop() async {
        let after = AgentCenterRuntime(), id = thread()
        let acknowledged = AgentCenterRuntime.completionKey(stop(id, arrival: 1, timestamp: 1_000))
        await after.configure(metadata: [AgentThreadMetadata(threadID: id, acknowledgedCompletionKey: acknowledged)])
        await after.register(summary(id), binding: binding())
        _ = await after.applyLifecycle(stop(id, arrival: 1, timestamp: 2_000), proof: proof(binding(), route: "route-1"),
                                       expectedSourceIdentity: "route-1")
        let snapshot = await after.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.attention, .unreadCompletion)
        XCTAssertEqual(snapshot.acknowledgedCompletionKey, acknowledged)
        XCTAssertNotEqual(snapshot.unreadCompletionKey, acknowledged)
    }

    /// Claude's idle prompt overwrites the retained Stop about 60 s later.
    func testUnreadFinishSurvivesRelaunchAfterIdlePrompt() async {
        let before = AgentCenterRuntime(), id = thread(.claude)
        await before.register(summary(id), binding: binding())
        let route = proof(binding(), route: "route-1")
        _ = await before.applyLifecycle(stop(id, arrival: 1), proof: route, expectedSourceIdentity: "route-1")
        _ = await before.applyLifecycle(envelope(id, .notification, .idle, arrival: 2, timestamp: 61_000), proof: route,
                                        expectedSourceIdentity: "route-1")
        let unread = await before.snapshot(for: id)!
        XCTAssertEqual(unread.summary.attention, .unreadCompletion)
        XCTAssertNotNil(unread.unreadCompletionKey)

        let after = AgentCenterRuntime()
        await after.configure(metadata: [metadata(unread)])
        await after.register(summary(id), binding: binding())
        _ = await after.applyLifecycle(envelope(id, .notification, .idle, arrival: 1, timestamp: 61_000), proof: route,
                                       expectedSourceIdentity: "route-1")
        let restored = await after.snapshot(for: id)!
        XCTAssertEqual(restored.summary.attention, .unreadCompletion, "the unread finish survives the relaunch")
        XCTAssertEqual(restored.unreadCompletionKey, unread.unreadCompletionKey)
        XCTAssertEqual(restored.attentionEpoch, 1)
        _ = await after.acknowledgeCompletion(threadID: id, observedEpoch: restored.attentionEpoch!)
        let read = await after.snapshot(for: id)!
        XCTAssertNil(read.unreadCompletionKey)
        XCTAssertEqual(read.acknowledgedCompletionKey, unread.unreadCompletionKey)
    }

    /// New work (or a request) supersedes a stored unread finish, and the
    /// superseded finish is not restored again by a later relaunch.
    func testNewerWorkSupersedesAStoredUnreadFinish() async {
        let id = thread(.claude)
        let pending = AgentCenterRuntime.completionKey(stop(id, arrival: 1, timestamp: 1_000))
        let after = AgentCenterRuntime()
        await after.configure(metadata: [AgentThreadMetadata(threadID: id, unreadCompletionKey: pending)])
        await after.register(summary(id), binding: binding())
        _ = await after.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 1, timestamp: 90_000),
                                       proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let working = await after.snapshot(for: id)!
        XCTAssertEqual(working.summary.attention, AgentAttention.none)
        XCTAssertNil(working.unreadCompletionKey, "the platform persists the superseded state")
    }

    /// Stored read state that arrives after the first replayed frame (the
    /// platform's store read races discovery) still clears that finish.
    func testLateStoredAcknowledgementClearsAnAlreadyReplayedStop() async {
        let core = AgentCenterRuntime(), id = thread()
        await core.register(summary(id), binding: binding())
        _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
        let replayed = await core.snapshot(for: id)!
        XCTAssertEqual(replayed.summary.attention, .unreadCompletion)
        await core.configure(metadata: [AgentThreadMetadata(threadID: id, acknowledgedCompletionKey: replayed.unreadCompletionKey)])
        let reconciled = await core.snapshot(for: id)!
        XCTAssertEqual(reconciled.summary.attention, AgentAttention.none)
        XCTAssertEqual(reconciled.summary.status, .idle)
        XCTAssertNil(reconciled.unreadCompletionKey)
        XCTAssertGreaterThan(reconciled.deliveryGeneration, replayed.deliveryGeneration)
    }

    /// Every read path records the finish as read, not only the new one.
    func testRecordAndTerminalReadsRecordTheAcknowledgedCompletion() async {
        for path in ["record", "terminal"] {
            let core = AgentCenterRuntime(), id = thread()
            await core.register(summary(id), binding: binding())
            let page = AgentProjectionPage(sourceIdentity: "source", records: [
                AgentProjectionRecord(sequence: 1, recordID: "newest", record: .object([
                    "type": .string("assistant"), "text": .string("done")]))!,
            ], cursor: nil, hasMore: false)!
            _ = await core.apply(page: page, to: id)
            _ = await core.applyLifecycle(stop(id, arrival: 1), proof: proof(binding(), route: "route-1"), expectedSourceIdentity: "route-1")
            let finished = await core.snapshot(for: id)!
            if path == "record" {
                _ = await core.acknowledge(threadID: id, visibleRecordID: "newest")
            } else {
                _ = await core.acknowledgeTerminal(threadID: id, binding: binding(), observedGeneration: finished.deliveryGeneration)
            }
            let read = await core.snapshot(for: id)!
            XCTAssertEqual(read.summary.attention, AgentAttention.none, path)
            XCTAssertNil(read.unreadCompletionKey, path)
            XCTAssertEqual(read.acknowledgedCompletionKey, finished.unreadCompletionKey, path)
        }
    }

    /// The stored key is content-free: no transcript locator, no path.
    func testCompletionKeyCarriesNoTranscriptLocator() {
        let id = thread()
        let key = AgentCenterRuntime.completionKey(stop(id, arrival: 7, timestamp: 1_788_703_213_997_213_000))
        XCTAssertEqual(key, "c1:18d2c0189ee74548:2a")
        XCTAssertNil(AgentCenterRuntime.completionKey(AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .stop,
            status: .finished, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl", eventSequence: 7)!),
            "an arrival sequence is process-local, never a durable identity")
    }
}
