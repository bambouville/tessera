import XCTest
@testable import TesseraAgentCore

final class TesseraAgentCoreTests: XCTestCase {
    func testLateInventoryCannotDowngradePaneRegistrationBeforeFirstLifecycle() async throws {
        let core = AgentCenterRuntime(), id = thread(provider: .codex)
        await core.register(summary(id), binding: binding())
        let before = await core.snapshot(for: id)
        try await core.registerInventoryPage([AgentThreadSummary(id: id, providerName: "Codex",
            availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false))])
        let after = await core.snapshot(for: id)
        XCTAssertEqual(after, before, "inventory cannot interleave between pane registration and lifecycle reduction")
        let list = await core.listSnapshot()
        XCTAssertTrue(list.threads.isEmpty, "preserving a registration does not itself prove a live route")
    }

    func testLateInventoryCannotDowngradeProvenLiveLifecycle() async throws {
        let core = AgentCenterRuntime(), id = thread(provider: .codex)
        await core.register(summary(id), binding: binding())
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
        let event = AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .permissionRequest,
            status: .waitingForInput, providerSessionID: "provider-session", agentPID: 42,
            transcriptRef: "ref", eventSequence: 1)!
        _ = await core.applyLifecycle(event, proof: proof, expectedSourceIdentity: "route")
        let beforeSnapshot = await core.snapshot(for: id)
        let before = try XCTUnwrap(beforeSnapshot)
        let historical = AgentThreadSummary(id: id, providerName: "Codex",
            availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false))
        try await core.registerInventoryPage([historical])
        let after = await core.snapshot(for: id)
        XCTAssertEqual(after, before, "stale inventory arriving between batches cannot replace proved live state")
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("host-observation")!, transport: .ssh, capabilities: [.observe])
        await core.registerInventorySummary(historical, binding: observation)
        let afterObservation = await core.snapshot(for: id)
        XCTAssertEqual(afterObservation, before, "the Android observational-bind path must preserve the same live proof")
    }

    func testBoundedInventoryPageMatchesIndividualRegistrationAndPreservesBinding() async throws {
        let individual = AgentCenterRuntime(), batched = AgentCenterRuntime()
        let live = thread(provider: .codex)
        for core in [individual, batched] { await core.register(summary(live), binding: binding()) }
        var page: [AgentThreadSummary] = [summary(live)]
        for index in 1..<100 {
            let id = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "batch-\(index)")!
            page.append(summary(id))
        }
        for item in page { await individual.register(item) }
        try await batched.registerInventoryPage(page)
        for item in page {
            let expected = await individual.snapshot(for: item.id)
            let actual = await batched.snapshot(for: item.id)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual?.binding, item.id == live ? binding() : nil)
        }
        let expectedList = await individual.listSnapshot(), actualList = await batched.listSnapshot()
        XCTAssertEqual(actualList, expectedList)
    }

    func testOversizedInventoryPageIsAtomicAndDisabledRuntimeStaysEmpty() async throws {
        let core = AgentCenterRuntime()
        let page = (0..<101).map { index in
            summary(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "oversized-\(index)")!)
        }
        do { try await core.registerInventoryPage(page); XCTFail("oversized page accepted") }
        catch { XCTAssertEqual(error as? AgentIngestionError, .capacityExceeded) }
        for row in page {
            let snapshot = await core.snapshot(for: row.id)
            XCTAssertNil(snapshot, "rejected page must not partially register")
        }
        await core.setEnabled(false)
        try await core.registerInventoryPage(Array(page.prefix(100)))
        let snapshot = await core.snapshot(for: page[0].id)
        XCTAssertNil(snapshot)
    }

    func testTransientPermissionIsClearedWhenAuthorityIsRevoked() async {
        for boundary in ["replace", "register", "retire", "disable", "end"] {
            let core = AgentCenterRuntime()
            let id = thread(provider: .codex)
            await core.register(summary(id), binding: binding())
            let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
            let event = AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .permissionRequest,
                status: .waitingForInput, providerSessionID: "provider-session", agentPID: 42,
                transcriptRef: "ref", eventSequence: 1)!
            _ = await core.applyLifecycle(event, proof: proof, expectedSourceIdentity: "route")
            let prompt = AgentPromptObservationRequest(providerID: .codex,
                visibleText: "Would you like to run the following command?\n› 1. Yes (y)\n  2. No (n)",
                currentCursorLine: "› 1. Yes (y)")!
            let before = await core.snapshot(for: id)!
            await core.observeLivePrompt(prompt, threadID: id, binding: binding(), observedGeneration: before.deliveryGeneration)
            let observed = await core.snapshot(for: id)!
            await core.observeLivePrompt(prompt, threadID: id, binding: binding(), observedGeneration: observed.deliveryGeneration)
            let repeated = await core.snapshot(for: id)!
            XCTAssertEqual(repeated.deliveryGeneration, observed.deliveryGeneration, "identical polls must not re-notify")
            let replacement = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 2,
                incarnation: AgentIncarnationToken("replacement")!, transport: .ssh, agentPID: 42, capabilities: [.observe])
            switch boundary {
            case "replace": await core.replaceBinding(replacement, for: id)
            case "register":
                // Capability revocation re-proves the same process; a
                // competing carrier cannot replace a live registration.
                let current = binding()
                let observing = AgentTerminalBinding(liveSessionID: current.liveSessionID,
                    carrierGeneration: current.carrierGeneration, incarnation: current.incarnation,
                    transport: current.transport, tmuxSession: current.tmuxSession,
                    windowID: current.windowID, paneID: current.paneID, agentPID: current.agentPID,
                    capabilities: [.observe])
                await core.register(summary(id), binding: observing)
            case "retire": await core.retireProjection(for: id)
            case "disable": await core.setEnabled(false)
            default:
                _ = await core.applyLifecycle(AgentLifecycleEnvelope(version: 9, providerID: .codex,
                    event: .sessionEnd, status: .unavailable, providerSessionID: "provider-session", agentPID: 42,
                    transcriptRef: "ref", eventSequence: 2)!, proof: proof, expectedSourceIdentity: "route")
            }
            let cleared = await core.snapshot(for: id)!
            XCTAssertEqual(cleared.summary.attention, .none, boundary)
            XCTAssertNotEqual(cleared.summary.status, .waitingForInput, boundary)
            XCTAssertTrue(cleared.messages.isEmpty, boundary)
        }
    }

    func testRetainedEventDedupDoesNotTreatRemoteClockAsOrdering() async {
        let core = AgentCenterRuntime()
        let id = thread(provider: .codex)
        await core.register(summary(id), binding: binding())
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
        func event(_ kind: AgentLifecycleEventKind, _ status: AgentStatus, _ arrival: UInt64, _ timestamp: UInt64) -> AgentLifecycleEnvelope {
            .init(version: 9, providerID: .codex, event: kind, status: status,
                  providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref",
                  eventSequence: arrival, sourceTimestampNanoseconds: timestamp)!
        }
        _ = await core.applyLifecycle(event(.preToolUse, .working, 1, 100), proof: proof, expectedSourceIdentity: "route")
        _ = await core.applyLifecycle(event(.stop, .finished, 2, 100), proof: proof, expectedSourceIdentity: "route")
        let finished = await core.snapshot(for: id)!
        XCTAssertEqual(finished.summary.attention, .unreadCompletion, "distinct hooks may share the fallback clock tick")
        _ = await core.acknowledgeTerminal(threadID: id, binding: binding(), observedGeneration: finished.deliveryGeneration)
        _ = await core.applyLifecycle(event(.stop, .finished, 3, 100), proof: proof, expectedSourceIdentity: "route")
        let visited = await core.snapshot(for: id)!
        XCTAssertEqual(visited.summary.attention, .none)
        _ = await core.applyLifecycle(event(.preToolUse, .working, 4, 90), proof: proof, expectedSourceIdentity: "route")
        let later = await core.snapshot(for: id)!
        XCTAssertEqual(later.summary.status, .working, "a wall-clock correction cannot reject a newer arrival")
    }

    func testCodexPermissionNeedsCurrentHumanPromptAndDoesNotResetHistory() async {
        let core = AgentCenterRuntime()
        let id = thread(provider: .codex)
        await core.register(summary(id), binding: binding())
        let page = AgentProjectionPage(sourceIdentity: "transcript", records: [
            record(10, "message", ["type": .string("assistant"), "text": .string("Working")])
        ], cursor: "older", hasMore: true)!
        _ = await core.apply(page: page, to: id)
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
        func event(_ kind: AgentLifecycleEventKind, _ status: AgentStatus, _ sequence: UInt64) -> AgentLifecycleEnvelope {
            .init(version: 9, providerID: .codex, event: kind, status: status,
                  providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref", eventSequence: sequence)!
        }
        _ = await core.applyLifecycle(event(.permissionRequest, .waitingForInput, 1), proof: proof, expectedSourceIdentity: "route")
        var snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.attention, AgentAttention.none)
        XCTAssertEqual(snapshot?.summary.status, .working)
        let prompt = AgentPromptObservationRequest(providerID: .codex,
            visibleText: "Would you like to run the following command?\n› 1. Yes (y)\n  2. No (n)",
            currentCursorLine: "› 1. Yes (y)")!
        let permissionGeneration = snapshot!.deliveryGeneration
        await core.observeLivePrompt(prompt, threadID: id, binding: binding(), observedGeneration: permissionGeneration)
        snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.attention, .needsYou)
        XCTAssertEqual(snapshot?.messages.count, 2)
        XCTAssertEqual(snapshot?.cursor, "older")
        _ = await core.applyLifecycle(event(.postToolUse, .working, 2), proof: proof, expectedSourceIdentity: "route")
        await core.observeLivePrompt(prompt, threadID: id, binding: binding(), observedGeneration: permissionGeneration)
        snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.attention, AgentAttention.none, "a late prompt observation cannot resurrect a resolved approval")
        XCTAssertEqual(snapshot?.messages.count, 1)
        XCTAssertEqual(snapshot?.cursor, "older")
        _ = await core.applyLifecycle(event(.permissionRequest, .waitingForInput, 3), proof: proof, expectedSourceIdentity: "route")
        await core.observeLivePrompt(prompt, threadID: id, binding: binding(), observedGeneration: permissionGeneration)
        let newerPermission = await core.snapshot(for: id)
        XCTAssertEqual(newerPermission?.summary.attention, AgentAttention.none, "an old capture cannot answer a new permission epoch")
        _ = await core.applyLifecycle(event(.stop, .finished, 4), proof: proof, expectedSourceIdentity: "route")
        snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.attention, .unreadCompletion)
    }

    func testTerminalVisitAcknowledgesOnlyExactCompletionGeneration() async {
        let core = AgentCenterRuntime()
        let id = thread()
        await core.register(summary(id), binding: binding())
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "route", processIDs: [42])
        let stop = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .stop, status: .finished,
            providerSessionID: "provider-session", agentPID: 42, transcriptRef: "ref", eventSequence: 1)!
        _ = await core.applyLifecycle(stop, proof: proof, expectedSourceIdentity: "route")
        let before = await core.snapshot(for: id)!
        let wrongBinding = await core.acknowledgeTerminal(threadID: id, binding: binding(generation: 2), observedGeneration: before.deliveryGeneration)
        let wrongGeneration = await core.acknowledgeTerminal(threadID: id, binding: binding(), observedGeneration: before.deliveryGeneration + 1)
        XCTAssertFalse(wrongBinding)
        XCTAssertFalse(wrongGeneration)
        let acknowledged = await core.acknowledgeTerminal(threadID: id, binding: binding(), observedGeneration: before.deliveryGeneration)
        XCTAssertTrue(acknowledged, "visiting a terminal must work before any transcript has loaded")
        _ = await core.applyLifecycle(stop, proof: proof, expectedSourceIdentity: "route")
        let after = await core.snapshot(for: id)
        XCTAssertEqual(after?.summary.attention, AgentAttention.none)
        XCTAssertEqual(after?.summary.status, .idle, "repeated discovery cannot restore the green finished dot")
    }

    func testChildMetadataCannotReplaceMainAgentThroughAliases() {
        let normalizer = AgentTranscriptNormalizer()
        for object: [String: AgentJSONValue] in [
            ["type": .string("permission-mode"), "mode": .string("plan")],
            ["type": .string("cost-state"), "totalDuration": .number(1000), "totalLinesAdded": .number(3)],
            ["type": .string("session-title"), "text": .string("child title")],
            ["type": .string("metadata"), "model": .string("child model"), "used_tokens": .number(123)],
            ["type": .string("queue-operation"), "count": .number(2)],
        ] {
            var child = object
            child["isSidechain"] = .bool(true)
            XCTAssertEqual(normalizer.normalize(providerID: .claude, record: record(0, "child", child)), .init())
        }
        let child = normalizer.normalize(providerID: .claude, record: record(0, "visible", [
            "type": .string("assistant"), "text": .string("child work"), "isSidechain": .bool(true), "model": .string("child model"),
        ]))
        XCTAssertNotNil(child.message)
        XCTAssertNil(child.model)
    }


    /// Hooks emit locators up to 4,096 bytes, but envelopes and projection
    /// carry at most 2,048. A longer one parses as unlocatable, so the
    /// platforms revoke the conversation it replaced instead of building an
    /// envelope Core refuses and leaving that conversation live.
    func test_hookLocatorLongerThanTheEnvelopeCarriesParsesAsUnlocatable() {
        for (length, kept) in [(AgentLifecycleEnvelope.maximumLocatorBytes, true),
                               (AgentLifecycleEnvelope.maximumLocatorBytes + 1, false), (4_096, false)] {
            let locator = String(repeating: "A", count: length)
            let payload = "{\"version\":9,\"provider\":\"claude\",\"event\":\"SessionStart\",\"state\":\"idle\",\"reason\":\"session-start\",\"timestampNs\":\"1788703213997213000\",\"sessionId\":\"session-b\",\"turnId\":\"\",\"notificationType\":\"\",\"permissionMode\":\"\",\"agentPid\":99227,\"transcriptRef\":\"\(locator)\",\"agentId\":\"\",\"agentType\":\"\",\"rootAgentId\":\"\"}"
            let parsed = AgentLifecycleHookEvent.decode(Data(payload.utf8))
            XCTAssertNotNil(parsed, "\(length)")
            XCTAssertEqual(parsed?.transcriptRef, kept ? locator : nil, "\(length)")
            XCTAssertEqual(parsed?.providerSessionID, "session-b")
            let envelope = parsed.flatMap {
                AgentLifecycleEnvelope(version: $0.version, providerID: $0.providerID, event: $0.event, status: $0.status,
                    providerSessionID: $0.providerSessionID, agentPID: $0.agentPID, transcriptRef: $0.transcriptRef)
            }
            XCTAssertEqual(envelope != nil, kept, "\(length)")
        }
    }

    /// Captured verbatim from a live `@tessera_agent_state` pane option on a
    /// Mac running Claude Code, not hand-modelled. Claude writes every unset
    /// optional as "", and the envelope built from a parsed frame used to
    /// reject exactly that, so Core refused its own output for every real agent
    /// on both platforms and reported it only as `command_failed`.
    func test_realClaudePanePayloadParsesAndBuildsAnEnvelope() {
        let payload = "{\"version\":9,\"provider\":\"claude\",\"event\":\"SessionStart\",\"state\":\"idle\",\"reason\":\"session-start\",\"timestampNs\":\"1788703213997213000\",\"sessionId\":\"7610a301-b065-449f-a321-323b6f6c88ce\",\"turnId\":\"\",\"notificationType\":\"\",\"permissionMode\":\"\",\"agentPid\":99227,\"transcriptRef\":\"L1VzZXJzL2hvdXplLy5jbGF1ZGUvcHJvamVjdHMvLVVzZXJzLWhvdXplLXByb2plY3RzLXRlc3NlcmEvNzYxMGEzMDEtYjA2NS00NDlmLWEzMjEtMzIzYjZmNmM4OGNlLmpzb25s\",\"agentId\":\"\",\"agentType\":\"\",\"rootAgentId\":\"\"}"
        let parsed = AgentLifecycleHookEvent.decode(Data(payload.utf8))
        XCTAssertNotNil(parsed, "a live pane payload must parse")
        guard let parsed else { return }
        XCTAssertNil(parsed.agentID, "an empty agentId means unset, not a zero-length identifier")
        XCTAssertNil(parsed.agentType)
        XCTAssertNil(parsed.rootAgentID)
        XCTAssertEqual(parsed.providerSessionID, "7610a301-b065-449f-a321-323b6f6c88ce")

        let envelope = AgentLifecycleEnvelope(
            version: parsed.version,
            providerID: parsed.providerID,
            event: parsed.event,
            status: parsed.status,
            providerSessionID: parsed.providerSessionID,
            agentPID: parsed.agentPID,
            transcriptRef: parsed.transcriptRef,
            agentID: parsed.agentID,
            agentType: parsed.agentType,
            rootAgentID: parsed.rootAgentID
        )
        XCTAssertNotNil(envelope, "Core must accept an envelope built from its own parsed frame")

        // And the same frame must survive the ABI round trip the platforms use.
        let encoded = try? JSONEncoder().encode(envelope)
        XCTAssertNotNil(encoded)
        if let encoded {
            XCTAssertNoThrow(try JSONDecoder().decode(AgentLifecycleEnvelope.self, from: encoded))
        }
    }
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(provider: AgentProviderID = .claude, session: String = "provider-session") -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: session)!
    }

    private func binding(generation: UInt64 = 1) -> AgentTerminalBinding {
        AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: generation,
            incarnation: AgentIncarnationToken("incarnation-1")!,
            transport: .sshTmux,
            tmuxSession: "work",
            windowID: "@1",
            paneID: "%2",
            agentPID: 42,
            capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux]
        )
    }

    private func summary(_ id: AgentThreadID, actions: Bool = true) -> AgentThreadSummary {
        AgentThreadSummary(
            id: id,
            providerName: "Claude Code",
            availability: .init(content: true, status: true, actions: actions, spawn: true, fork: true, search: true)
        )
    }

    private func record(_ sequence: UInt64, _ id: String, _ object: [String: AgentJSONValue]) -> AgentProjectionRecord {
        AgentProjectionRecord(sequence: sequence, recordID: id, record: .object(object))!
    }

    /// Both records are copied verbatim out of a live Claude transcript. The
    /// normalizer read `title`/`text` and `cost`/`duration`/`lines_*`, none of
    /// which Claude ever writes, so a real session's title fell through to the
    /// literal placeholder "Untitled" -- the exact row Agent Center showed for
    /// a running agent -- and its cost stayed empty.
    /// Codex keeps its LLM-written title in `state_N.sqlite`, not in the
    /// rollout transcript, so the projector attaches it to `session_meta` --
    /// the one record that carries the session id. Verbatim shape from a real
    /// projection of `~/.codex/sessions/.../rollout-*.jsonl`.
    func test_realCodexSessionMetaCarriesTheLLMTitle() {
        let normalizer = AgentTranscriptNormalizer()

        let meta = normalizer.normalize(providerID: .codex, record: record(1, "r1", [
            "type": .string("session_meta"),
            "provider": .string("codex"),
            "title": .string("Run integration tests and fix issues"),
            "project": .string("tessera"),
            "branch": .string("main"),
        ]))
        XCTAssertEqual(meta.title, "Run integration tests and fix issues")
        XCTAssertEqual(meta.projectBasename, "tessera")
        XCTAssertEqual(meta.branch, "main")

        // An untitled codex thread, a codex too old to have the column, or no
        // state database at all: the projector omits the field entirely and
        // the rest of the record must still land.
        let untitled = normalizer.normalize(providerID: .codex, record: record(2, "r2", [
            "type": .string("session_meta"),
            "provider": .string("codex"),
            "project": .string("tessera"),
            "branch": .string("main"),
        ]))
        XCTAssertNil(untitled.title)
        XCTAssertEqual(untitled.projectBasename, "tessera")

        // `turn_context` repeats through the rollout and carries no session
        // id, so it never gets a title and must not blank the one in place.
        let turn = normalizer.normalize(providerID: .codex, record: record(3, "r3", [
            "type": .string("turn_context"),
            "provider": .string("codex"),
            "model": .string("gpt-5"),
        ]))
        XCTAssertNil(turn.title)
        XCTAssertEqual(turn.model, "gpt-5")
    }

    func test_realClaudeTranscriptRecordsNormalizeTitleAndCost() {
        let normalizer = AgentTranscriptNormalizer()

        let title = normalizer.normalize(providerID: .claude, record: record(1, "r1", [
            "type": .string("ai-title"),
            "aiTitle": .string("Ctrl L and Enter keyboard accessory bar"),
            "sessionId": .string("7610a301-b065-449f-a321-323b6f6c88ce"),
        ]))
        XCTAssertEqual(title.title, "Ctrl L and Enter keyboard accessory bar")

        // An `ai-title` carrying no usable title must leave the existing title
        // alone rather than overwrite it with a placeholder.
        let blank = normalizer.normalize(providerID: .claude, record: record(2, "r2", [
            "type": .string("ai-title"),
            "sessionId": .string("7610a301-b065-449f-a321-323b6f6c88ce"),
        ]))
        XCTAssertNil(blank.title)

        let cost = normalizer.normalize(providerID: .claude, record: record(3, "r3", [
            "type": .string("cost-state"),
            "sessionId": .string("7610a301-b065-449f-a321-323b6f6c88ce"),
            "totalCostUSD": .number(12.494347),
            "totalLinesAdded": .number(4),
            "totalLinesRemoved": .number(2),
            "totalDuration": .number(1_515_462),
        ]))
        XCTAssertEqual(cost.cost?.totalCost, 12.494347)
        XCTAssertEqual(cost.cost?.linesAdded, 4)
        XCTAssertEqual(cost.cost?.linesRemoved, 2)
        // `totalDuration` is milliseconds.
        XCTAssertEqual(cost.cost?.durationSeconds ?? 0, 1_515.462, accuracy: 0.001)
        // The record carries no context-window fields; publishing an all-nil
        // context here would erase a real one.
        XCTAssertNil(cost.context)
    }

    func test_projectionOrderingUsesSequenceAndNormalizesMetadata() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(
            sourceIdentity: "source-1",
            records: [
                record(2, "r2", ["type": .string("assistant"), "text": .string("newest")]),
                record(1, "r1", ["type": .string("user"), "isMeta": .bool(true), "text": .string("must not be human")]),
                record(3, "r3", ["type": .string("ai-title"), "title": .string("final title")]),
                record(4, "r4", ["type": .string("cost-state"), "cost": .number(1.25), "duration": .number(4), "lines_added": .number(9), "lines_removed": .number(3)]),
                record(5, "r5", ["type": .string("queue-operation"), "pending": .number(2)])
            ],
            cursor: "cursor-5",
            hasMore: false
        )!

        let applied = await runtime.apply(page: page, to: id)
        XCTAssertEqual(applied, .applied)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.map(\.recordID), ["r2"])
        XCTAssertEqual(snapshot.messages.first?.role, .assistant)
        XCTAssertEqual(snapshot.activity.first?.kind, .system)
        XCTAssertEqual(snapshot.summary.title, "final title")
        XCTAssertEqual(snapshot.summary.cost.totalCost, 1.25)
        XCTAssertEqual(snapshot.summary.cost.linesAdded, 9)
        XCTAssertEqual(snapshot.summary.queuedMessageCount, 2)
        let duplicate = await runtime.apply(page: page, to: id)
        XCTAssertEqual(duplicate, .duplicate)
    }

    /// Verbatim shape from a real projection of the opencode conversation
    /// store: opencode writes its own LLM title onto the session row, so the
    /// projector emits it as a `session-title` record ahead of the parts.
    func test_realOpencodeAndPiSessionTitlesNormalizeAsTitles() {
        let normalizer = AgentTranscriptNormalizer()

        let opencode = normalizer.normalize(providerID: .opencode, record: record(0, "opencode-title-ses_f87639ea6ffedcrNaPdzgzE0lP", [
            "type": .string("session-title"),
            "provider": .string("opencode"),
            "sessionID": .string("ses_f87639ea6ffedcrNaPdzgzE0lP"),
            "title": .string("Purpose of calc.py"),
        ]))
        XCTAssertEqual(opencode.title, "Purpose of calc.py")
        XCTAssertEqual(opencode.titleProvenance, .native)

        // pi has no LLM-written title. `sessionName` is the name a person gave
        // the session with -n or /name, which still outranks any fallback.
        let pi = normalizer.normalize(providerID: .pi, record: record(0, "pi-title-61523ee7cb38c3e51ec33ae5b95d9c0e", [
            "type": .string("session-title"),
            "provider": .string("pi"),
            "sessionID": .string("01a0789e-4284-7605-b065-7dc819c473ec"),
            "title": .string("Calc audit"),
        ]))
        XCTAssertEqual(pi.title, "Calc audit")
        XCTAssertEqual(pi.titleProvenance, .native)
    }

    func test_titleFallsBackToTheOpeningPromptWhenNoProviderNamesTheSession() async {
        let id = thread(provider: .opencode, session: "ses_unnamed")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(1, "r1", ["type": .string("user"), "text": .string("  Explain why the   scroll router\ndrops mosh gestures  ")]),
                record(2, "r2", ["type": .string("assistant"), "text": .string("Because SSP syncs visible state only.")]),
            ],
            cursor: nil,
            hasMore: false
        )!
        let applied = await runtime.apply(page: page, to: id)
        XCTAssertEqual(applied, .applied)

        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.titleProvenance, .prompt)
        XCTAssertEqual(
            snapshot.summary.titleSeed,
            "Explain why the scroll router drops mosh gestures",
            "the seed is the opening prompt collapsed to one line, whitespace and all"
        )
        XCTAssertEqual(snapshot.summary.title, snapshot.summary.titleSeed)
    }

    func test_aNativeTitleWinsWhoeverArrivesFirstAndTheSeedSurvives() async {
        let id = thread(provider: .opencode, session: "ses_titled")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        // The title record is sequence 0 -- the projector emits it ahead of the
        // parts -- but a page can arrive with the prompt already applied, so
        // the winner must be decided by provenance rather than by arrival.
        let page = AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(0, "r0", ["type": .string("session-title"), "title": .string("Purpose of calc.py")]),
                record(1, "r1", ["type": .string("user"), "text": .string("In one sentence, what does calc.py do?")]),
            ],
            cursor: nil,
            hasMore: false
        )!
        let applied = await runtime.apply(page: page, to: id)
        XCTAssertEqual(applied, .applied)

        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Purpose of calc.py")
        XCTAssertEqual(snapshot.summary.titleProvenance, .native)
        XCTAssertEqual(
            snapshot.summary.titleSeed,
            "In one sentence, what does calc.py do?",
            "the seed is still recorded so a platform can offer a better fallback elsewhere"
        )

        // Discovery re-announces a thread with the placeholder summary many
        // times. That must not knock the resolved title back to "Untitled".
        await runtime.register(summary(id), binding: binding())
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Purpose of calc.py")
        XCTAssertEqual(snapshot.summary.titleSeed, "In one sentence, what does calc.py do?")
    }

    func test_aGeneratedTitleOutranksThePromptButNeverTheProvidersOwn() async {
        let generated = thread(provider: .pi, session: "unnamed")
        let native = thread(provider: .opencode, session: "titled")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(generated), binding: binding())
        await runtime.register(summary(native), binding: binding())
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "a",
            records: [record(1, "a1", ["type": .string("user"), "text": .string("port the render ledger to Android")])],
            cursor: nil, hasMore: false
        )!, to: generated)
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "b",
            records: [
                record(0, "b0", ["type": .string("session-title"), "title": .string("Purpose of calc.py")]),
                record(1, "b1", ["type": .string("user"), "text": .string("In one sentence, what does calc.py do?")]),
            ],
            cursor: nil, hasMore: false
        )!, to: native)

        let pending = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertEqual(
            pending.map(\.threadID), [generated],
            "only a thread whose title is still a clipped prompt is worth an on-device summary"
        )

        let promotedGeneration = await runtime.applyGeneratedTitle("Android render ledger port", for: generated, seed: pending[0].seed)
        XCTAssertTrue(promotedGeneration)
        let promoted = await runtime.snapshot(for: generated)!
        XCTAssertEqual(promoted.summary.title, "Android render ledger port")
        XCTAssertEqual(promoted.summary.titleProvenance, .generated)

        let displacedNative = await runtime.applyGeneratedTitle("Calculator explainer", for: native, seed: "In one sentence, what does calc.py do?")
        XCTAssertFalse(displacedNative, "an on-device summary must not displace the title the agent wrote itself")
        let nativeTitle = await runtime.snapshot(for: native)!.summary.title
        XCTAssertEqual(nativeTitle, "Purpose of calc.py")

        let stale = await runtime.applyGeneratedTitle("Stale answer", for: generated, seed: "a prompt this thread no longer has")
        XCTAssertFalse(stale, "generation is asynchronous, so an answer to a prompt the thread has moved past is dropped")
    }

    func test_theCharacterBudgetReclipsOnlyTitlesRestingOnThePrompt() async {
        let clipped = thread(provider: .pi, session: "long")
        let named = thread(provider: .opencode, session: "named")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(clipped), binding: binding())
        await runtime.register(summary(named), binding: binding())
        let opening = "Investigate why the Agent Center list stays empty on Android against a live tmux pane"
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "a",
            records: [record(1, "a1", ["type": .string("user"), "text": .string(opening)])],
            cursor: nil, hasMore: false
        )!, to: clipped)
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "b",
            records: [record(0, "b0", ["type": .string("session-title"), "title": .string("Agent Center empty list")])],
            cursor: nil, hasMore: false
        )!, to: named)

        await runtime.setTitleCharacterBudget(28)
        let narrow = await runtime.snapshot(for: clipped)!.summary
        XCTAssertEqual(narrow.title, "Investigate why the Agent\u{2026}", "a clipped prompt ends on a word")
        XCTAssertEqual(narrow.titleSeed, opening, "clipping is presentation; the seed keeps the whole prompt")
        let namedTitle = await runtime.snapshot(for: named)!.summary.title
        XCTAssertEqual(namedTitle, "Agent Center empty list", "a real title is a phrase, not a truncation, so a narrower row must not shorten it")

        await runtime.setTitleCharacterBudget(1_000)
        let widened = await runtime.snapshot(for: clipped)!.summary.title
        XCTAssertEqual(widened, opening, "a wider row restores the prompt the earlier budget cut")
    }

    /// Tier 1 can fail as well as be absent: a provider that writes a title
    /// field the adapter cannot read must degrade to the same place an
    /// untitled thread does, not to a title of "null" or to the record type
    /// name. Every shape here came from asking what a provider could write
    /// into the field the projector reads.
    func test_aTitleRecordThatCannotBeReadNormalizesToNoTitleAtAll() {
        let normalizer = AgentTranscriptNormalizer()
        let malformed: [(String, [String: AgentJSONValue])] = [
            ("claude with no title field at all", [
                "type": .string("ai-title"), "provider": .string("claude"),
            ]),
            ("claude with a null title", [
                "type": .string("ai-title"), "provider": .string("claude"), "aiTitle": .null,
            ]),
            ("claude with a structured title", [
                "type": .string("ai-title"), "provider": .string("claude"),
                "aiTitle": .object(["text": .string("Purpose of calc.py")]),
            ]),
            ("opencode with a numeric title", [
                "type": .string("session-title"), "provider": .string("opencode"), "title": .number(7),
            ]),
            ("pi with a boolean title", [
                "type": .string("session-title"), "provider": .string("pi"), "title": .bool(true),
            ]),
        ]
        for (label, object) in malformed {
            let normalized = normalizer.normalize(providerID: .claude, record: record(0, "r0", object))
            XCTAssertNil(normalized.title, "\(label) must yield no title rather than a placeholder one")
        }
    }

    /// The waterfall has to survive a tier-1 record that arrives and fails,
    /// not only one that never arrives. A title that reads as empty is applied
    /// nowhere: the thread stays on the prompt tier, is still offered to the
    /// on-device summariser, and accepts the summary when it comes back.
    func test_aTitleRecordThatFailsToParseFallsThroughToTheGeneratedTier() async {
        let opening = "Explain why the scroll router drops mosh gestures"
        // Each of these is a tier-1 record that reached the reducer and could
        // not be turned into a title: an unreadable payload, a title that is
        // empty, and one that is only whitespace.
        let cases: [(String, AgentJSONValue)] = [
            ("unreadable", .object(["text": .string("Purpose of calc.py")])),
            ("empty", .string("")),
            ("whitespace", .string("   \n\t ")),
        ]
        for (label, title) in cases {
            let id = thread(provider: .opencode, session: "ses_\(label)")
            let runtime = AgentCenterRuntime()
            await runtime.register(summary(id), binding: binding())
            let applied = await runtime.apply(page: AgentProjectionPage(
                sourceIdentity: "source",
                records: [
                    record(0, "r0", ["type": .string("session-title"), "title": title]),
                    record(1, "r1", ["type": .string("user"), "text": .string(opening)]),
                ],
                cursor: nil,
                hasMore: false
            )!, to: id)
            XCTAssertEqual(applied, .applied, "\(label): the rest of the page must still land")

            let fallen = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(fallen.titleProvenance, .prompt, "\(label): a title that failed to parse claims nothing")
            XCTAssertEqual(fallen.title, opening, "\(label): the row shows the prompt, never the failed record")
            XCTAssertEqual(fallen.titleSeed, opening)

            let pending = await runtime.threadsAwaitingGeneratedTitle()
            XCTAssertEqual(
                pending.map(\.threadID), [id],
                "\(label): tier 2 is offered exactly as it would be for a thread the provider never titled"
            )
            let accepted = await runtime.applyGeneratedTitle("Mosh scroll routing", for: id, seed: pending[0].seed)
            XCTAssertTrue(accepted, "\(label): the on-device summary outranks the prompt it summarised")
            let summarised = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(summarised.title, "Mosh scroll routing")
            XCTAssertEqual(summarised.titleProvenance, .generated)
        }
    }

    /// A provider can start writing a title it cannot serialise halfway
    /// through a session. The failed record must not demote a title the
    /// waterfall has already settled on, and must not re-offer generation for
    /// a thread that already has a summary.
    func test_aTitleRecordThatFailsLaterNeverDemotesASettledTitle() async {
        let id = thread(provider: .pi, session: "01a0789e-4284-7605-b065-7dc819c473ec")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "source",
            records: [record(1, "r1", ["type": .string("user"), "text": .string("port the render ledger to Android")])],
            // This test exercises a malformed later title, so the initial
            // prompt must be known to be the opening prompt.
            cursor: nil,
            hasMore: false
        )!, to: id)
        let pending = await runtime.threadsAwaitingGeneratedTitle()
        let summarised = await runtime.applyGeneratedTitle("Android render ledger port", for: id, seed: pending[0].seed)
        XCTAssertTrue(summarised)

        let applied = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(2, "r2", ["type": .string("session-title"), "title": .number(7)]),
                record(3, "r3", ["type": .string("assistant"), "text": .string("Ported.")]),
            ],
            cursor: "3",
            hasMore: false
        )!, to: id)
        XCTAssertEqual(applied, .applied)

        let settled = await runtime.snapshot(for: id)!.summary
        XCTAssertEqual(settled.title, "Android render ledger port")
        XCTAssertEqual(settled.titleProvenance, .generated)
        let stillPending = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertTrue(stillPending.isEmpty, "a thread that already carries a summary is not summarised twice")
    }

    /// When the adapter itself fails -- the projector reports `adapterOutdated`
    /// and the platform retires the projection -- the thread loses the seed
    /// along with the transcript, so there is nothing to summarise until a
    /// page arrives again. Once one does, the waterfall restarts from the
    /// bottom rather than staying stuck on the provider name.
    func test_aRetiredProjectionRestartsTheWaterfallWhenPagesReturn() async {
        let id = thread(provider: .pi, session: "retired")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(0, "r0", ["type": .string("session-title"), "title": .string("Calc audit")]),
                record(1, "r1", ["type": .string("user"), "text": .string("audit calc.py for rounding drift")]),
            ],
            cursor: nil,
            hasMore: false
        )!, to: id)
        let named = await runtime.snapshot(for: id)!.summary.titleProvenance
        XCTAssertEqual(named, .native)

        await runtime.retireProjection(for: id, reason: .integrationOutdated)
        let retired = await runtime.snapshot(for: id)!.summary
        XCTAssertEqual(retired.titleProvenance, .placeholder)
        XCTAssertEqual(retired.title, retired.providerName, "no transcript, no title but the provider name")
        XCTAssertNil(retired.titleSeed)
        let pendingAfterRetirement = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertTrue(
            pendingAfterRetirement.isEmpty,
            "tier 2 summarises the opening prompt, and a retired projection no longer holds one"
        )

        _ = await runtime.apply(page: AgentProjectionPage(
            sourceIdentity: "source-2",
            records: [record(1, "s1", ["type": .string("user"), "text": .string("audit calc.py for rounding drift")])],
            cursor: nil,
            hasMore: false
        )!, to: id)
        let recovered = await runtime.snapshot(for: id)!.summary
        XCTAssertEqual(recovered.titleProvenance, .prompt)
        XCTAssertEqual(recovered.title, "audit calc.py for rounding drift")
        let pendingAfterRecovery = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertEqual(
            pendingAfterRecovery.map(\.threadID), [id],
            "the thread is offered to the on-device summariser again as soon as it has a prompt"
        )
    }

    func test_projectionGapRequestsResyncAndSourceReplacementDropsOnlyContent() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let first = AgentProjectionPage(sourceIdentity: "one", records: [record(1, "one", ["type": .string("assistant"), "text": .string("first")])], cursor: "1", hasMore: true)!
        let firstResult = await runtime.apply(page: first, to: id)
        XCTAssertEqual(firstResult, .applied)
        let gap = AgentProjectionPage(sourceIdentity: "one", records: [record(3, "three", ["type": .string("assistant")])], cursor: "3", hasMore: false)!
        let gapResult = await runtime.apply(page: gap, to: id)
        XCTAssertEqual(gapResult, .resyncRequired)
        let replacement = AgentProjectionPage(sourceIdentity: "two", records: [record(1, "new", ["type": .string("assistant"), "text": .string("replacement content")])], cursor: nil, hasMore: false)!
        let replacementResult = await runtime.apply(page: replacement, to: id)
        XCTAssertEqual(replacementResult, .sourceReset)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.map(\.recordID), ["new"])
        XCTAssertEqual(snapshot.summary.id, id)
    }

    func test_olderCursorPageMergesWithNewestPageAndRemainsIdempotent() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let newest = AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(3, "three", ["type": .string("assistant"), "text": .string("three")]),
                record(4, "four", ["type": .string("assistant"), "text": .string("four")]),
            ],
            cursor: "older",
            hasMore: true
        )!
        let older = AgentProjectionPage(
            sourceIdentity: "source",
            records: [
                record(1, "one", ["type": .string("assistant"), "text": .string("one")]),
                record(2, "two", ["type": .string("assistant"), "text": .string("two")]),
            ],
            cursor: nil,
            hasMore: false
        )!
        let newestResult = await runtime.apply(page: newest, to: id)
        let olderResult = await runtime.apply(page: older, to: id)
        let duplicateResult = await runtime.apply(page: older, to: id)
        let merged = await runtime.snapshot(for: id)
        XCTAssertEqual(newestResult, .applied)
        XCTAssertEqual(olderResult, .applied)
        XCTAssertEqual(duplicateResult, .duplicate)
        XCTAssertEqual(merged?.messages.map(\.recordID), ["one", "two", "three", "four"])
        _ = await runtime.apply(page: newest, to: id)
        let refreshed = await runtime.snapshot(for: id)
        XCTAssertNil(refreshed?.cursor, "a tail refresh must not revive an exhausted older cursor")
        XCTAssertEqual(refreshed?.hasMore, false)
    }

    func test_visibleTailRefreshKeepsOldestCursorUntilSourceChanges() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        func page(_ source: String, _ sequence: UInt64, _ cursor: String) -> AgentProjectionPage {
            AgentProjectionPage(sourceIdentity: source, records: [
                record(sequence, "\(source)-\(sequence)", ["type": .string("assistant"), "text": .string("content")])
            ], cursor: cursor, hasMore: true)!
        }
        let newest = page("original", 3, "C2")
        _ = await runtime.apply(page: newest, to: id)
        _ = await runtime.apply(page: page("original", 2, "C1"), to: id)
        _ = await runtime.apply(page: newest, to: id)
        let refreshed = await runtime.snapshot(for: id)
        XCTAssertEqual(refreshed?.cursor, "C1")
        _ = await runtime.apply(page: page("replacement", 3, "new-C2"), to: id)
        let replaced = await runtime.snapshot(for: id)
        XCTAssertEqual(replaced?.cursor, "new-C2", "source rotation still invalidates old continuation")
    }

    func test_lateDuplicateOlderPageCannotRewindOrReviveExhaustedHistory() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        func page(_ sequence: UInt64, from: String?, cursor: String?) -> AgentProjectionPage {
            AgentProjectionPage(sourceIdentity: "source", from: from, records: [
                record(sequence, "record-\(sequence)", ["type": .string("assistant"), "text": .string("content")])
            ], cursor: cursor, hasMore: cursor != nil)!
        }
        _ = await runtime.apply(page: page(3, from: nil, cursor: "C2"), to: id)
        let middle = page(2, from: "C2", cursor: "C1")
        _ = await runtime.apply(page: middle, to: id)
        _ = await runtime.apply(page: page(1, from: "C1", cursor: nil), to: id)
        _ = await runtime.apply(page: middle, to: id)
        let exhausted = await runtime.snapshot(for: id)
        XCTAssertNil(exhausted?.cursor)
        XCTAssertEqual(exhausted?.hasMore, false)
    }

    func test_sourceResetPurgesAllProjectionDerivedState() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let original = AgentProjectionPage(
            sourceIdentity: "first",
            records: [
                record(1, "title", ["type": .string("ai-title"), "title": .string("private title")]),
                record(2, "edit", ["type": .string("edit"), "path": .string("/private/path"), "diff": .string("secret diff")]),
            ],
            cursor: "cursor",
            hasMore: true
        )!
        let originalResult = await runtime.apply(page: original, to: id)
        XCTAssertEqual(originalResult, .applied)
        let replacement = AgentProjectionPage(sourceIdentity: "second", records: [record(1, "new", ["type": .string("assistant"), "text": .string("new content")])], cursor: nil, hasMore: false)!
        let replacementResult = await runtime.apply(page: replacement, to: id)
        XCTAssertEqual(replacementResult, .sourceReset)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.map(\.recordID), ["new"])
        XCTAssertEqual(snapshot.turns.flatMap(\.messages).map(\.recordID), ["new"])
        XCTAssertTrue(snapshot.activity.isEmpty)
        XCTAssertTrue(snapshot.changes.edits.isEmpty)
        XCTAssertEqual(snapshot.summary.preview, "new content")
        XCTAssertNil(snapshot.summary.projectBasename)
        XCTAssertEqual(snapshot.summary.title, "Claude Code")
    }

    func test_perThreadRetentionPrunesDerivedDisplayStateWithRecords() async throws {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let diff = String(repeating: "x", count: 16_000)
        for pageIndex in 0..<30 {
            let first = UInt64(pageIndex * 10 + 1)
            let records = (0..<10).map { offset in
                record(first + UInt64(offset), "edit-\(pageIndex)-\(offset)", [
                    "type": .string("edit"), "path": .string("Sources/\(pageIndex)-\(offset).swift"), "diff": .string(diff),
                ])
            }
            let page = AgentProjectionPage(sourceIdentity: "source", records: records, cursor: "\(first + 9)", hasMore: true)!
            let result = await runtime.apply(page: page, to: id)
            XCTAssertEqual(result, .applied)
        }
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertLessThan(snapshot.messages.count, 300)
        XCTAssertEqual(Set(snapshot.messages.map(\.recordID)), Set(snapshot.changes.edits.map(\.id)))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(snapshot).count, AgentCenterRuntime.perThreadContentLimitBytes)
    }

    func test_longProjectionActionTokenDegradesToRecordTokenWithoutTrap() {
        let normalized = AgentTranscriptNormalizer().normalize(
            providerID: .claude,
            record: record(1, "safe-record", [
                "type": .string("permission"),
                "actionToken": .string(String(repeating: "x", count: 513)),
                "title": .string("Continue?"),
            ])
        )
        guard case .actionPrompt(let prompt)? = normalized.message?.blocks.first else {
            return XCTFail("expected a bounded action prompt")
        }
        XCTAssertEqual(prompt.token.rawValue, "safe-record")
    }

    func test_deepProjectionJSONIsRejectedBeforeUnboundedRecursion() {
        let nested = String(repeating: "{\"x\":", count: 64) + "null" + String(repeating: "}", count: 64)
        let data = Data("{\"sequence\":1,\"recordID\":\"deep\",\"record\":\(nested)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentProjectionRecord.self, from: data))
    }

    func test_overlongRemoteSearchExcerptIsCappedRatherThanRejectingSnapshot() throws {
        let data = Data("{\"threadID\":{\"hostID\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\",\"providerID\":{\"rawValue\":\"claude\"},\"providerSessionID\":\"provider-session\"},\"recordID\":\"record\",\"excerpt\":\"\(String(repeating: "x", count: 2_000))\"}".utf8)
        let result = try JSONDecoder().decode(AgentSearchResult.self, from: data)
        XCTAssertEqual(result.excerpt.utf8.count, AgentSearchResult.maximumExcerptBytes)
    }

    func test_lifecycleAcceptsV8AndV9ButRejectsStaleBindingAndPID() {
        let validator = AgentLifecycleValidator(registry: .builtIn)
        let current = binding()
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: current, sourceIdentity: "source", processIDs: [42])
        let v8 = AgentLifecycleEnvelope(version: 8, providerID: .claude, event: .preToolUse, status: .working, providerSessionID: "provider-session", agentPID: 42)!
        XCTAssertEqual(validator.validate(v8, proof: proof, expectedBinding: current, expectedSourceIdentity: "source"), .accepted(threadID: thread()))
        let v9 = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .idle, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVlX3JlZg")!
        XCTAssertEqual(validator.validate(v9, proof: proof, expectedBinding: current, expectedSourceIdentity: "source"), .accepted(threadID: thread()))
        XCTAssertEqual(validator.validate(v9, proof: proof, expectedBinding: binding(generation: 2), expectedSourceIdentity: "source"), .rejected(.staleBinding))
        let stalePID = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .idle, providerSessionID: "provider-session", agentPID: 77, transcriptRef: "b3BhcXVlX3JlZg")!
        XCTAssertEqual(validator.validate(stalePID, proof: proof, expectedBinding: current, expectedSourceIdentity: "source"), .rejected(.pidMismatch))

        let observeOnly = AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("observe-only")!,
            transport: .ssh,
            capabilities: [.observe]
        )
        let pendingPID = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .working, providerSessionID: "provider-session", transcriptRef: "b3BhcXVlX3JlZg")!
        let observeProof = AgentLifecycleBindingProof(hostID: hostID, binding: observeOnly, sourceIdentity: "source", processIDs: [])
        XCTAssertEqual(validator.validate(pendingPID, proof: observeProof, expectedBinding: observeOnly, expectedSourceIdentity: "source"), .accepted(threadID: thread()))
    }

    func testRepeatedBindingDoesNotResetLifecycleStatusOrReorderWorkingAgents() async {
        let core = AgentCenterRuntime()
        let id = thread()
        await core.register(summary(id), binding: binding())
        let event = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .preToolUse,
            status: .working, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "live-route", processIDs: [42])
        _ = await core.applyLifecycle(event, proof: proof, expectedSourceIdentity: "live-route")
        let activity = await core.snapshot(for: id)!.summary.lastActivitySequence
        for pass in 0..<4 {
            await core.register(.init(id: id, providerName: "Claude", lastActivitySequence: UInt64(pass + 100),
                lastActivity: Date(), availability: summary(id).availability), binding: binding())
            let rebound = await core.snapshot(for: id)
            XCTAssertEqual(rebound?.summary.status, .working, "a discovery placeholder cannot reset lifecycle-owned status")
            XCTAssertEqual(rebound?.summary.lastActivitySequence, activity, "rediscovery is not provider activity, even before the first transcript page")
            _ = await core.applyLifecycle(event, proof: proof, expectedSourceIdentity: "live-route")
            let duplicate = await core.snapshot(for: id)
            XCTAssertEqual(duplicate?.summary.status, .working, "deduplicating the event must not strand unavailable state")
        }
    }

    /// A transcript page used to overwrite the identity that the next
    /// lifecycle frame was validated against, so a thread stopped accepting
    /// lifecycle the moment its first page landed.
    func test_lifecycleStillAcceptedAfterATranscriptPageSetsTheSourceIdentity() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let route = "android:11111111-2222-3333-4444-555555555555:3:%3"
        let start = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .idle, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: route, processIDs: [42])
        let started = await runtime.applyLifecycle(start, proof: proof, expectedSourceIdentity: route)
        XCTAssertEqual(started, .accepted(threadID: id))

        let page = AgentProjectionPage(sourceIdentity: "1000004:8a3f2:12ab:17bd9c1", records: [record(1, "message", ["type": .string("assistant"), "text": .string("ready")])], cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: page, to: id)

        let working = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .userPromptSubmit, status: .working, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        let resumed = await runtime.applyLifecycle(working, proof: proof, expectedSourceIdentity: route)
        XCTAssertEqual(resumed, .accepted(threadID: id))
        let snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.status, .working)
    }

    /// Two agents in two panes of one tmux session are the normal case on a
    /// developer machine, and Agent Center listed only one of them.
    func test_twoPanesOnOneHostKeepTwoDistinctThreads() async {
        let runtime = AgentCenterRuntime()
        func paneBinding(_ pane: String, _ window: String, pid: Int) -> AgentTerminalBinding {
            AgentTerminalBinding(
                liveSessionID: sessionID,
                carrierGeneration: 1,
                incarnation: AgentIncarnationToken("\(sessionID.uuidString):1:\(pid)")!,
                transport: .sshTmux,
                tmuxSession: "tessera-6d7ab28a",
                windowID: window,
                paneID: pane,
                agentPID: pid,
                capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux]
            )
        }
        let first = thread(session: "7610a301-b065-449f-a321-323b6f6c88ce")
        let second = thread(session: "e2f9297a-3772-4f32-a7f7-a2a41c2575a6")
        let firstBinding = paneBinding("%11", "@11", pid: 99_227)
        let secondBinding = paneBinding("%3", "@3", pid: 21_524)
        XCTAssertNotEqual(firstBinding, secondBinding)

        await runtime.register(summary(first), binding: firstBinding)
        await runtime.register(summary(second), binding: secondBinding)

        func lifecycle(_ session: String, _ event: AgentLifecycleEventKind, _ status: AgentStatus, pid: Int) -> AgentLifecycleEnvelope {
            AgentLifecycleEnvelope(
                version: 9, providerID: .claude, event: event, status: status,
                providerSessionID: session, agentPID: pid, transcriptRef: "b3BhcXVl"
            )!
        }
        let firstRoute = "android:\(sessionID.uuidString):1:%11"
        let secondRoute = "android:\(sessionID.uuidString):1:%3"
        let firstProof = AgentLifecycleBindingProof(hostID: hostID, binding: firstBinding, sourceIdentity: firstRoute, processIDs: [99_227])
        let secondProof = AgentLifecycleBindingProof(hostID: hostID, binding: secondBinding, sourceIdentity: secondRoute, processIDs: [21_524])

        let a = await runtime.applyLifecycle(
            lifecycle("7610a301-b065-449f-a321-323b6f6c88ce", .sessionStart, .idle, pid: 99_227),
            proof: firstProof, expectedSourceIdentity: firstRoute
        )
        XCTAssertEqual(a, .accepted(threadID: first))
        let b = await runtime.applyLifecycle(
            lifecycle("e2f9297a-3772-4f32-a7f7-a2a41c2575a6", .preToolUse, .working, pid: 21_524),
            proof: secondProof, expectedSourceIdentity: secondRoute
        )
        XCTAssertEqual(b, .accepted(threadID: second))

        let listed = await runtime.listSnapshot().threads.map(\.id)
        XCTAssertEqual(
            Set(listed), Set([first, second]),
            "one pane's lifecycle must not evict the other pane's thread"
        )
    }

    func test_lifecycleSourceBindingAndChildStopCannotOverwriteRootCompletion() async {
        let provisional = thread(session: "provisional")
        let durable = thread(session: "durable")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(provisional), binding: binding())
        // Transcript provenance, shaped the way the remote projector really
        // reports it: the transcript file's dev/inode/size/mtime. It shares no
        // namespace with the route identity below.
        let page = AgentProjectionPage(sourceIdentity: "1000004:8a3f2:12ab:17bd9c1", records: [record(1, "message", ["type": .string("assistant"), "text": .string("ready")])], cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: page, to: provisional)

        let start = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .idle, providerSessionID: "durable", agentPID: 42, transcriptRef: "b3BhcXVl")!
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "registered-source", processIDs: [42])
        _ = await runtime.applyLifecycle(start, proof: proof, expectedSourceIdentity: "registered-source")

        // Having claimed the thread, a different route may not relabel it —
        // and the transcript page above must not be what decides that.
        let wrongProof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "other-source", processIDs: [42])
        let wrongAcceptance = await runtime.applyLifecycle(start, proof: wrongProof, expectedSourceIdentity: "other-source")
        XCTAssertEqual(wrongAcceptance, .rejected(.sourceMismatch))
        let provisionalSnapshot = await runtime.snapshot(for: provisional)
        let durableSnapshot = await runtime.snapshot(for: durable)
        XCTAssertNil(provisionalSnapshot)
        XCTAssertEqual(durableSnapshot?.summary.id, durable)
        XCTAssertEqual(durableSnapshot?.messages, [], "a new conversation cannot inherit the previous transcript")
        XCTAssertNil(durableSnapshot?.summary.model)
        XCTAssertNil(durableSnapshot?.summary.preview)

        let stop = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .stop, status: .finished, providerSessionID: "durable", agentPID: 42, transcriptRef: "b3BhcXVl")!
        _ = await runtime.applyLifecycle(stop, proof: proof, expectedSourceIdentity: "registered-source")
        let childStop = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .subagentStop, status: .working, providerSessionID: "durable", agentPID: 42, transcriptRef: "b3BhcXVl", agentID: "child", agentType: "Explore", rootAgentID: "root")!
        _ = await runtime.applyLifecycle(childStop, proof: proof, expectedSourceIdentity: "registered-source")
        let snapshot = await runtime.snapshot(for: durable)
        XCTAssertEqual(snapshot?.summary.status, .finished)
        XCTAssertEqual(snapshot?.summary.attention, .unreadCompletion)
    }

    func test_attentionIsPerThreadAndVisibleAcknowledgementClearsOnlySelectedThread() async {
        let first = thread(session: "one")
        let second = thread(session: "two")
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(first), binding: binding())
        await runtime.register(summary(second), binding: binding(generation: 2))
        let firstPage = AgentProjectionPage(sourceIdentity: "one", records: [record(1, "first", ["type": .string("assistant"), "text": .string("first")])], cursor: nil, hasMore: false)!
        let secondPage = AgentProjectionPage(sourceIdentity: "two", records: [record(1, "second", ["type": .string("assistant"), "text": .string("second")])], cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: firstPage, to: first)
        _ = await runtime.apply(page: secondPage, to: second)
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "one", processIDs: [42])
        let lifecycle = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .permissionRequest, status: .waitingForInput, providerSessionID: "one", agentPID: 42, transcriptRef: "b3BhcXVl")!
        _ = await runtime.applyLifecycle(lifecycle, proof: proof, expectedSourceIdentity: "one")
        await runtime.acknowledge(threadID: first, visibleRecordID: "first")
        let firstAttention = await runtime.snapshot(for: first)?.summary.attention
        let secondAttention = await runtime.snapshot(for: second)?.summary.attention
        XCTAssertEqual(firstAttention, AgentAttention.none)
        XCTAssertEqual(secondAttention, AgentAttention.none)
    }

    func test_acknowledgementMustMatchNewestVisibleRecord() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(
            sourceIdentity: "one",
            records: [
                record(1, "older", ["type": .string("assistant"), "text": .string("older")]),
                record(2, "newest", ["type": .string("assistant"), "text": .string("newest")])
            ],
            cursor: nil,
            hasMore: false
        )!
        _ = await runtime.apply(page: page, to: id)
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "one", processIDs: [42])
        let lifecycle = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .permissionRequest, status: .waitingForInput, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        _ = await runtime.applyLifecycle(lifecycle, proof: proof, expectedSourceIdentity: "one")

        await runtime.acknowledge(threadID: id, visibleRecordID: "older")
        let attentionAfterOlder = await runtime.snapshot(for: id)?.summary.attention
        XCTAssertEqual(attentionAfterOlder, .needsYou)
        await runtime.acknowledge(threadID: id, visibleRecordID: "newest")
        let attentionAfterNewest = await runtime.snapshot(for: id)?.summary.attention
        XCTAssertEqual(attentionAfterNewest, AgentAttention.none)
    }

    func test_duplicateLifecycleCannotResurrectAcknowledgedAttention() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(
            sourceIdentity: "one",
            records: [record(1, "newest", ["type": .string("assistant"), "text": .string("done")])],
            cursor: nil,
            hasMore: false
        )!
        _ = await runtime.apply(page: page, to: id)
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "one", processIDs: [42])
        let completion = AgentLifecycleEnvelope(
            version: 9,
            providerID: .claude,
            event: .stop,
            status: .finished,
            providerSessionID: "provider-session",
            agentPID: 42,
            transcriptRef: "b3BhcXVl",
            eventSequence: 100
        )!

        _ = await runtime.applyLifecycle(completion, proof: proof, expectedSourceIdentity: "one")
        await runtime.acknowledge(threadID: id, visibleRecordID: "newest")
        await runtime.register(summary(id), binding: binding())
        _ = await runtime.applyLifecycle(completion, proof: proof, expectedSourceIdentity: "one")

        let duplicateSnapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(duplicateSnapshot?.summary.attention, AgentAttention.none)
    }

    func test_newWorkingTransitionSupersedesUnreadCompletion() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(), sourceIdentity: "one", processIDs: [42])
        let completion = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .stop, status: .finished, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl", eventSequence: 100)!
        let nextTask = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .preToolUse, status: .working, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl", eventSequence: 101)!

        _ = await runtime.applyLifecycle(completion, proof: proof, expectedSourceIdentity: "one")
        _ = await runtime.applyLifecycle(nextTask, proof: proof, expectedSourceIdentity: "one")

        let nextTaskSnapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(nextTaskSnapshot?.summary.attention, AgentAttention.none)
        XCTAssertEqual(nextTaskSnapshot?.summary.status, .working)
    }

    func test_structuredPromptWorkflowAndChangesRemainCanonical() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let options: AgentJSONValue = .array([
            .object(["id": .string("allow"), "label": .string("Allow once"), "default": .bool(true)]),
            .object(["id": .string("deny"), "label": .string("Deny")])
        ])
        let tasks: AgentJSONValue = .array([
            .object(["id": .string("t1"), "title": .string("Inspect"), "state": .string("completed")]),
            .object(["id": .string("t2"), "title": .string("Implement"), "owner": .string("worker"), "state": .string("working")])
        ])
        let page = AgentProjectionPage(
            sourceIdentity: "one",
            records: [
                record(1, "prompt", ["type": .string("permission"), "title": .string("Run tests?"), "actionToken": .string(AgentPromptGrammar.actionToken(for: "forged-live-signature").rawValue), "options": options]),
                record(2, "workflow", ["type": .string("workflow"), "tasks": tasks]),
                record(3, "edit", ["type": .string("edit"), "path": .string("Sources/App.swift"), "additions": .number(4), "deletions": .number(1), "diff": .string("@@")]),
                record(4, "totals", ["type": .string("cost-state"), "cost": .number(2.5), "lines_added": .number(4), "lines_removed": .number(1)])
            ],
            cursor: "4",
            hasMore: false
        )!
        let applyResult = await runtime.apply(page: page, to: id)
        XCTAssertEqual(applyResult, .applied)
        let snapshot = await runtime.snapshot(for: id)!
        guard case .text(let prompt) = snapshot.messages[0].blocks[0] else { return XCTFail("remote prompt must be presentation-only") }
        XCTAssertEqual(prompt, "Run tests?\nAllow once\nDeny")
        guard case .workflowTasks(let workflow) = snapshot.messages[1].blocks[0] else { return XCTFail("missing structured workflow") }
        XCTAssertEqual(workflow.map(\.state), [.completed, .working])
        XCTAssertEqual(snapshot.changes.edits.first?.path, "Sources/App.swift")
        XCTAssertEqual(snapshot.changes.authoritativeTotals.totalCost, 2.5)
        XCTAssertEqual(snapshot.activity.map(\.kind), [.permission, .workflow, .tool])
    }

    func test_oneActionLeaseAndBindingReplacementInvalidatesIt() async throws {
        let id = thread()
        let runtime = AgentCenterRuntime()
        let old = binding()
        await runtime.register(summary(id), binding: old)
        let lease = try await runtime.acquireLease(threadID: id, action: .send, binding: old)
        await XCTAssertThrowsErrorAsync { _ = try await runtime.acquireLease(threadID: id, action: .send, binding: old) }
        await runtime.replaceBinding(binding(generation: 2), for: id)
        await runtime.releaseLease(lease)
        _ = try await runtime.acquireLease(threadID: id, action: .send, binding: binding(generation: 2))
    }

    func test_launchRequiresCurrentTmuxBindingAndProviderCapability() {
        let validator = AgentLaunchValidator(registry: .builtIn)
        let intent = AgentLaunchIntent(kind: .fork(source: .init(threadID: thread()), name: nil), liveSessionID: sessionID, providerID: .claude, workingDirectory: AgentRemotePath("/work")!, task: "review", placement: .split(windowID: "@1", paneID: "%1", axis: .right), isolation: .currentWorktree)!
        if case .failure(let error) = validator.validate(intent, binding: binding()) {
            XCTFail("expected valid launch, got \(error)")
        }
        if case .failure(let error) = validator.validate(intent, binding: nil) {
            XCTAssertEqual(error, .staleBinding)
        } else {
            XCTFail("missing binding should fail")
        }
        let noFork = AgentLaunchIntent(kind: .fork(source: .init(threadID: thread(provider: .codex)), name: nil), liveSessionID: sessionID, providerID: .codex, workingDirectory: AgentRemotePath("/work")!, task: "review", placement: .split(windowID: "@1", paneID: "%1", axis: .right), isolation: .currentWorktree)!
        if case .failure(let error) = validator.validate(noFork, binding: binding()) {
            XCTAssertEqual(error, .unavailable)
        } else {
            XCTFail("Codex fork should remain unavailable")
        }
    }

    func test_launchRejectsBranchAndTaskInjectionAndProducesArgumentVector() {
        let validator = AgentLaunchValidator(registry: .builtIn)
        let invalid = AgentLaunchIntent(kind: .spawn(name: nil), liveSessionID: sessionID, providerID: .claude, workingDirectory: AgentRemotePath("/work")!, task: "review", placement: .newWindow(name: nil), isolation: .newWorktree(branch: "feat/x; touch /tmp/pwn"))!
        if case .failure(let error) = validator.validate(invalid, binding: binding()) {
            XCTAssertEqual(error, .invalidLaunch)
        } else {
            XCTFail("shell metacharacters in a branch must fail closed")
        }

        let task = "review 'quoted' && printf harmless"
        let safe = AgentLaunchIntent(kind: .spawn(name: nil), liveSessionID: sessionID, providerID: .codex, workingDirectory: AgentRemotePath("~/work")!, task: task, placement: .newWindow(name: "review"), isolation: .currentWorktree)!
        guard case .success(let plan) = validator.plan(safe, binding: binding()) else { return XCTFail("valid argv plan should succeed") }
        XCTAssertEqual(plan.providerArguments, ["codex", task])
    }

    func test_decoderRejectsInvalidNestedIdentityAndLifecycleValues() throws {
        let valid = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .idle, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["transcriptRef"] = "../../secret"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentLifecycleEnvelope.self, from: JSONSerialization.data(withJSONObject: object)))

        let id = thread()
        var identity = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(id)) as? [String: Any])
        identity["providerSessionID"] = "bad\u{0001}id"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentThreadID.self, from: JSONSerialization.data(withJSONObject: identity)))

        let oversizedRequest = Data(#"{"v":1,"kind":"project","provider":"claude","limitBytes":262145,"limitRecords":100}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentProjectionRequest.self, from: oversizedRequest))
        let oversizedRecordID = String(repeating: "r", count: 513)
        let invalidRecord = try JSONSerialization.data(withJSONObject: ["sequence": 1, "recordID": oversizedRecordID, "record": [:]])
        XCTAssertThrowsError(try JSONDecoder().decode(AgentProjectionRecord.self, from: invalidRecord))
    }

    func test_execFramesFenceGenerationAndBoundEachStreamClass() {
        XCTAssertNotNil(AgentExecFrame(carrierGeneration: 7, kind: .stdout(Data(repeating: 1, count: AgentExecFrame.maximumFrameBytes))))
        XCTAssertNil(AgentExecFrame(carrierGeneration: 7, kind: .stdout(Data(repeating: 1, count: AgentExecFrame.maximumFrameBytes + 1))))
        XCTAssertNotNil(AgentExecFrame(carrierGeneration: 7, kind: .stderr(Data(repeating: 1, count: AgentExecFrame.maximumDiagnosticBytes))))
        XCTAssertNil(AgentExecFrame(carrierGeneration: 7, kind: .stderr(Data(repeating: 1, count: AgentExecFrame.maximumDiagnosticBytes + 1))))
        XCTAssertEqual(AgentExecFrame(carrierGeneration: 7, kind: .exit(status: 0))?.carrierGeneration, 7)
    }

    func test_disablingPurgesContentAndActionAuthority() async {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(sourceIdentity: "one", records: [record(1, "one", ["type": .string("assistant"), "text": .string("secret")])], cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: page, to: id)
        await runtime.setEnabled(false)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(snapshot.summary.availability.reason, .disabled)
        await XCTAssertThrowsErrorAsync { _ = try await runtime.acquireLease(threadID: id, action: .send, binding: self.binding()) }
    }

    func test_retiringProjectionPurgesContentAndAuthorityWithoutDisablingRuntime() async {
        let id = thread(provider: .opencode)
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: binding())
        let page = AgentProjectionPage(
            sourceIdentity: "opencode:live",
            records: [record(1, "one", ["type": .string("assistant"), "text": .string("secret")])],
            cursor: "older",
            hasMore: true
        )!
        _ = await runtime.apply(page: page, to: id)

        await runtime.retireProjection(for: id)

        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertNil(snapshot.cursor)
        XCTAssertFalse(snapshot.hasMore)
        XCTAssertEqual(snapshot.summary.availability.reason, .integrationOutdated)
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.acquireLease(threadID: id, action: .send, binding: self.binding())
        }
    }

    func test_unknownRecordsAndTierAGatesDegradeHonestly() {
        let unknown = AgentTranscriptNormalizer().normalize(providerID: .claude, record: record(1, "unknown", ["type": .string("future")]))
        XCTAssertNil(unknown.message, "Unknown provider records belong in Activity, not Live chat")
        XCTAssertEqual(unknown.activity?.kind, .system)
        let openCode = AgentProviderRegistry.builtIn.manifest(for: .opencode)!
        XCTAssertFalse(openCode.hasTranscript)
        XCTAssertTrue(openCode.actions.isEmpty)
        let enabled = AgentProviderCapabilityGate().manifest(
            openCode,
            enabling: AgentAdapterConformance(
                providerID: .opencode,
                adapterID: "opencode-sqlite-v1",
                sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.opencode]!,
                liveGatePassed: true
            )
        )
        XCTAssertTrue(enabled.hasTranscript)
        XCTAssertEqual(enabled.conversation, .sqliteQuery(adapterID: AgentOpenCodeSQLiteAdapter.adapterID))
        XCTAssertEqual(enabled.actions, [.send, .interrupt])
        let denied = AgentProviderCapabilityGate().manifest(
            openCode,
            enabling: AgentAdapterConformance(
                providerID: .opencode,
                adapterID: "opencode-sqlite-v1",
                sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.opencode]!,
                liveGatePassed: false
            )
        )
        XCTAssertFalse(denied.hasTranscript)
    }

    func test_tierCAdaptersRejectSchemaDriftAndKeepPiLineFramingStrict() throws {
        XCTAssertThrowsError(try AgentOpenCodeSQLiteAdapter.validate(schema: .init(tables: ["session": ["id", "title", "directory", "version", "time_created", "time_updated"], "message": ["id", "session_id", "time_created", "time_updated", "data"], "part": ["id", "message_id", "session_id", "time_created", "data"]])))
        let openCodeSchema = AgentOpenCodeSQLiteSchema(tables: ["session": ["id", "title", "directory", "version", "time_created", "time_updated"], "message": ["id", "session_id", "time_created", "time_updated", "data"], "part": ["id", "message_id", "session_id", "time_created", "time_updated", "data"]])
        XCTAssertNoThrow(try AgentOpenCodeSQLiteAdapter.validate(schema: openCodeSchema))
        XCTAssertNil(AgentOpenCodeSQLiteAdapter.liveConformance(schema: openCodeSchema, liveGatePassed: false))
        XCTAssertEqual(AgentOpenCodeSQLiteAdapter.liveConformance(schema: openCodeSchema, liveGatePassed: true)?.adapterID, AgentOpenCodeSQLiteAdapter.adapterID)
        let cursor = AgentOpenCodeCursor(sessionID: "session", partID: "part")!
        XCTAssertEqual(try AgentOpenCodeSQLiteAdapter.decode(cursor: AgentOpenCodeSQLiteAdapter.encode(cursor: cursor)), cursor)
        let record = try AgentOpenCodeSQLiteAdapter.normalize(
            sequence: 3,
            sessionID: "session",
            partID: "part",
            message: .object(["role": .string("assistant")]),
            part: .object(["type": .string("text"), "text": .string("redacted")])
        )
        XCTAssertEqual(record.recordID, "opencode-part")
        XCTAssertEqual(record.record.objectValue?["provider"], .string("opencode"))
        XCTAssertEqual(record.record.objectValue?["blocks"]?.arrayValue?.first?.objectValue?["text"], .string("redacted"))
        let request = try AgentPiRPCAdapter.getState(id: "pi-probe")
        let requestFields = try AgentPiRPCAdapter.decodeLine(request).objectValue
        XCTAssertEqual(requestFields?["type"], .string("get_state"))
        XCTAssertEqual(requestFields?["id"], .string("pi-probe"))
        XCTAssertNil(requestFields?["jsonrpc"])
        XCTAssertNoThrow(try AgentPiRPCAdapter.decodeLine(Data("{\"id\":\"pi-probe\"}\r\n".utf8)))
        XCTAssertThrowsError(try AgentPiRPCAdapter.decodeLine(Data("{\"id\":\"pi-probe\"}\n{\"id\":\"other\"}\n".utf8)))
    }

    func test_piRPCStateProbeIsNonceCorrelatedButCannotEnableTheNativeReader() throws {
        let request = try AgentPiRPCAdapter.getState(id: "pi-probe-1")
        XCTAssertEqual(try AgentPiRPCAdapter.decodeLine(request).objectValue?["type"], .string("get_state"))
        let line = Data(#"{"type":"response","id":"pi-probe-1","command":"get_state","success":true,"data":{"isStreaming":true,"sessionId":"session-42","sessionFile":"/redacted/session.jsonl","messageCount":5,"pendingMessageCount":2}}"#.utf8) + Data([0x0A])
        let state = try AgentPiRPCAdapter.decodeStateResponse(line, expectedRequestID: "pi-probe-1")
        XCTAssertTrue(state.isStreaming)
        XCTAssertEqual(state.sessionID, "session-42")
        XCTAssertEqual(state.messageCount, 5)
        XCTAssertEqual(state.pendingMessageCount, 2)
        let conformance = try XCTUnwrap(AgentPiRPCAdapter.liveConformance(for: state))
        let pi = AgentProviderCapabilityGate().manifest(
            AgentProviderRegistry.builtIn.manifest(for: .pi)!,
            enabling: conformance
        )
        XCTAssertEqual(pi.lifecycle, .unavailable)
        XCTAssertFalse(pi.hasTranscript, "An old RPC probe cannot attest the new persisted-session reader")
        XCTAssertTrue(pi.actions.isEmpty)

        XCTAssertThrowsError(try AgentPiRPCAdapter.decodeStateResponse(line, expectedRequestID: "other-probe"))
        let missingIdentity = Data(#"{"type":"response","id":"pi-probe-1","command":"get_state","success":true,"data":{"isStreaming":false,"sessionId":null,"sessionFile":null,"messageCount":0,"pendingMessageCount":0}}"#.utf8) + Data([0x0A])
        XCTAssertThrowsError(try AgentPiRPCAdapter.decodeStateResponse(missingIdentity, expectedRequestID: "pi-probe-1"))
    }

    func test_piRPCNormalizesOnlyDocumentedEventsAndRejectsMalformedInput() throws {
        let update: AgentJSONValue = .object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string("redacted")
            ])
        ])
        let record = try AgentPiRPCAdapter.normalize(sequence: 7, event: update)
        XCTAssertEqual(record.recordID, "pi-7-message_update")
        XCTAssertEqual(record.record.objectValue?["type"], .string("message"))
        XCTAssertEqual(record.record.objectValue?["text"], .string("redacted"))
        XCTAssertThrowsError(try AgentPiRPCAdapter.normalize(sequence: 8, event: .object(["type": .string("message_update")])))
        XCTAssertThrowsError(try AgentPiRPCAdapter.prompt(id: "pi-prompt", message: "bad\u{0000}payload"))
    }

    func test_kimiWireAndLifecycleMapOnlyDocumentedFields() throws {
        let wire: AgentJSONValue = .object([
            "type": .string("context.append_loop_event"),
            "event": .object([
                "type": .string("content.part"),
                "part": .object(["type": .string("text"), "text": .string("redacted")]),
            ]),
        ])
        let record = try AgentKimiWireAdapter.normalize(sequence: 4, wire: wire)
        XCTAssertEqual(record.recordID, "kimi-4-context-append_loop_event")
        XCTAssertEqual(record.record.objectValue?["type"], .string("message"))
        XCTAssertEqual(record.record.objectValue?["blocks"]?.arrayValue?.first?.objectValue?["text"], .string("redacted"))
        XCTAssertNotNil(AgentKimiWireAdapter.liveConformance(sessionIndexPassed: true, hookConfigurationPassed: true))
        XCTAssertNil(AgentKimiWireAdapter.liveConformance(sessionIndexPassed: true, hookConfigurationPassed: false))
        let lifecycle = AgentKimiWireAdapter.lifecycle(["event": .string("Stop"), "state": .string("finished"), "session_id": .string("kimi-session"), "transcript_ref": .string("b3BhcXVl")])
        XCTAssertEqual(lifecycle?.providerID, .kimi)
        XCTAssertEqual(lifecycle?.event, .stop)
    }

    func test_terminalCandidateAppearsWithoutFabricatedThreadIdentityAndPromotesCleanly() async {
        let runtime = AgentCenterRuntime()
        let candidateID = AgentSourceCandidateID(
            hostID: hostID,
            providerID: .claude,
            sourceIdentity: "live-source"
        )!
        let fallback = AgentFallbackSnapshot(
            status: .unavailable,
            location: "host · pane %2",
            integrationAvailable: false,
            liveTail: "working without identity",
            prompt: nil,
            binding: binding()
        )
        await runtime.registerCandidate(
            candidateID,
            fallback: fallback,
            providerName: "Claude Code",
            title: "Live Claude",
            hostDisplayLabel: "host"
        )

        var list = await runtime.listSnapshot()
        XCTAssertTrue(list.threads.isEmpty)
        XCTAssertEqual(list.candidates.map(\.id), [candidateID])
        XCTAssertEqual(list.candidates.first?.fallback.liveTail, "working without identity")

        let durable = thread()
        await runtime.promoteCandidate(candidateID, to: summary(durable))
        list = await runtime.listSnapshot()
        XCTAssertTrue(list.candidates.isEmpty)
        XCTAssertEqual(list.threads.map(\.id), [durable])
        let promotedBinding = await runtime.snapshot(for: durable)?.binding
        XCTAssertEqual(promotedBinding, binding())
    }

    func test_actionLeaseRequiresTheSpecificBindingCapability() async {
        let id = thread()
        let observeOnly = AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("observe-only")!,
            transport: .ssh,
            capabilities: [.observe]
        )
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id), binding: observeOnly)
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.acquireLease(threadID: id, action: .send, binding: observeOnly)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.acquireLease(threadID: id, action: .interrupt, binding: observeOnly)
        }
    }

    func test_typedActionPayloadsAndOutcomesCannotBeMisapplied() {
        let id = thread()
        let currentBinding = binding()
        let send = AgentTextSendRequest(threadID: id, binding: currentBinding, text: "ship it", queueWhenWorking: false)!
        XCTAssertTrue(AgentABIActionPayload(text: send).isValid(for: .send, threadID: id, binding: currentBinding))
        XCTAssertFalse(AgentABIActionPayload(text: send).isValid(for: .queue, threadID: id, binding: currentBinding))
        XCTAssertFalse(AgentABIActionPayload(targetBinding: currentBinding).isValid(for: .send, threadID: id, binding: currentBinding))
        XCTAssertTrue(AgentABIActionPayload(targetBinding: currentBinding).isValid(for: .interrupt, threadID: id, binding: currentBinding))

        XCTAssertNil(AgentActionResultOutcome(status: .verified, action: .send))
        XCTAssertNotNil(AgentActionResultOutcome(status: .verified, action: .send, verification: "prompt.advanced"))
        XCTAssertNil(AgentActionResultOutcome(status: .verified, action: .send, verification: "prompt advanced"))
        XCTAssertNil(AgentActionResultOutcome(status: .cancelled, action: .send, verification: "not allowed"))
        XCTAssertNotNil(AgentActionResultOutcome(status: .cancelled, action: .send))
        XCTAssertThrowsError(try JSONDecoder().decode(AgentActionResultOutcome.self, from: Data(#"{"status":"verified","action":"send"}"#.utf8)))
    }

    func test_openTerminalLeaseIsBoundNavigationNotProviderMutation() async throws {
        let id = thread(provider: .opencode)
        let observeOnly = AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("observe-only")!,
            transport: .ssh,
            capabilities: [.observe]
        )
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id, actions: false), binding: observeOnly)
        let lease = try await runtime.acquireLease(threadID: id, action: .openTerminal, binding: observeOnly)
        XCTAssertEqual(lease.action, .openTerminal)
        XCTAssertTrue(AgentABIActionPayload(targetBinding: observeOnly).isValid(for: .openTerminal, threadID: id, binding: observeOnly))
    }

    func test_tierCRegistryAlwaysDerivesFromDisabledBuiltInManifest() {
        let untrusted = AgentProviderManifest(
            id: .opencode,
            displayName: "Spoofed",
            processMatchers: [],
            lifecycle: .rpc,
            conversation: .sqliteQuery(adapterID: "untrusted"),
            actions: [.spawn, .fork]
        )
        let gate = AgentProviderCapabilityGate()
        let denied = gate.hardenedRegistry(requested: [untrusted], conformances: []).manifest(for: .opencode)!
        XCTAssertEqual(denied.displayName, "OpenCode")
        XCTAssertFalse(denied.hasTranscript)
        XCTAssertTrue(denied.actions.isEmpty)

        let forged = AgentAdapterConformance(providerID: .opencode, adapterID: "opencode-sqlite-v1", sourceFixtureDigest: String(repeating: "a", count: 64), liveGatePassed: true)!
        XCTAssertFalse(gate.hardenedRegistry(requested: [untrusted], conformances: [forged]).manifest(for: .opencode)!.hasTranscript)
        let conformance = AgentAdapterConformance(providerID: .opencode, adapterID: "opencode-sqlite-v1", sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.opencode]!, liveGatePassed: true)!
        let enabled = gate.hardenedRegistry(requested: [untrusted], conformances: [conformance]).manifest(for: .opencode)!
        XCTAssertTrue(enabled.hasTranscript)
        XCTAssertEqual(enabled.conversation, .sqliteQuery(adapterID: AgentOpenCodeSQLiteAdapter.adapterID))
        XCTAssertEqual(enabled.actions, [.send, .interrupt])
    }

    func test_piTierCRegistryRequiresTheExactLiveRPCConformance() {
        let untrusted = AgentProviderManifest(
            id: .pi,
            displayName: "Spoofed Pi",
            processMatchers: [],
            lifecycle: .hooks(version: 1),
            conversation: .projectedJSONL(adapterID: "untrusted"),
            actions: [.spawn]
        )
        let gate = AgentProviderCapabilityGate()
        let denied = gate.hardenedRegistry(requested: [untrusted], conformances: []).manifest(for: .pi)!
        XCTAssertEqual(denied.displayName, "Pi")
        XCTAssertFalse(denied.hasTranscript)
        XCTAssertTrue(denied.actions.isEmpty)

        let wrongAdapter = AgentAdapterConformance(
            providerID: .pi,
            adapterID: "pi-rpc-jsonl-v0",
            sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.pi]!,
            liveGatePassed: true
        )!
        XCTAssertFalse(gate.hardenedRegistry(requested: [untrusted], conformances: [wrongAdapter]).manifest(for: .pi)!.hasTranscript)
        let enabled = AgentAdapterConformance(
            providerID: .pi,
            adapterID: AgentPiSessionAdapter.adapterID,
            sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.pi]!,
            liveGatePassed: true
        )!
        let manifest = gate.hardenedRegistry(requested: [untrusted], conformances: [enabled]).manifest(for: .pi)!
        XCTAssertEqual(manifest.lifecycle, .unavailable)
        XCTAssertEqual(manifest.conversation, .projectedJSONL(adapterID: AgentPiSessionAdapter.adapterID))
        XCTAssertTrue(manifest.actions.isEmpty)
    }

    func test_sharedPromptGrammarRequiresCursorOwnershipAndPreservesProviderMacros() {
        let claude = AgentPromptObservationRequest(
            providerID: .claude,
            visibleText: """
            rm -rf generated
            Quick safety check:
            › 1. Yes, proceed
              2. No
            """,
            currentCursorLine: "› 1. Yes, proceed"
        )!
        let claudeResult = AgentPromptGrammar.observe(claude)!
        XCTAssertEqual(claudeResult.options.map(\.responseMacro), ["1", "2"], "a digit alone answers; Enter would reach the composer")
        XCTAssertTrue(claudeResult.options.first?.isDefault == true)

        let codex = AgentPromptObservationRequest(
            providerID: .codex,
            visibleText: """
            Would you like to run the following command?
            › 1. Yes (y)
              2. No (n)
            """,
            currentCursorLine: "› 1. Yes (y)"
        )!
        XCTAssertEqual(AgentPromptGrammar.observe(codex)?.options.map(\.responseMacro), ["y", "n"])

        let spoofedShortcut = AgentPromptObservationRequest(
            providerID: .codex,
            visibleText: """
            Would you like to run the following command?
            › 1. Yes (rm -rf /)
            """,
            currentCursorLine: "› 1. Yes (rm -rf /)"
        )!
        XCTAssertNil(AgentPromptGrammar.observe(spoofedShortcut), "display text must never become a response macro")

        let staleCursor = AgentPromptObservationRequest(
            providerID: .codex,
            visibleText: codex.visibleText,
            currentCursorLine: "› describe the next task"
        )!
        XCTAssertNil(AgentPromptGrammar.observe(staleCursor))
    }

    func test_searchSnapshotCapsPerHostRatherThanGlobally() {
        let otherHost = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let otherThread = AgentThreadID(hostID: otherHost, providerID: .codex, providerSessionID: "other")!
        let first = (0...100).map {
            AgentSearchResult(threadID: thread(), recordID: "a-\($0)", excerpt: "needle")
        }
        let second = (0..<100).map {
            AgentSearchResult(threadID: otherThread, recordID: "b-\($0)", excerpt: "needle")
        }
        let snapshot = AgentSearchSnapshot(results: first + second)
        XCTAssertEqual(snapshot.results.filter { $0.threadID.hostID == hostID }.count, 100)
        XCTAssertEqual(snapshot.results.filter { $0.threadID.hostID == otherHost }.count, 100)
        XCTAssertEqual(snapshot.results.count, 200)
    }

    func test_launchReceiptRequiresCorrelatedPlanAndWorktreeProof() {
        let intent = AgentLaunchIntent(
            kind: .spawn(name: nil),
            liveSessionID: sessionID,
            providerID: .claude,
            workingDirectory: AgentRemotePath("~/project")!,
            task: "add a test",
            placement: .newWindow(name: nil),
            isolation: .newWorktree(branch: "agent/test")
        )!
        let requestID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let plan = AgentLaunchPlan(requestID: requestID, intent: intent, providerArguments: ["claude", "add a test"], humanReadableSummary: "Launch Claude")!
        XCTAssertFalse(AgentLaunchReceipt(value: "legacy")!.verifies(plan))
        XCTAssertFalse(AgentLaunchReceipt(value: "receipt", requestID: requestID, createdWorktree: false)!.verifies(plan))
        XCTAssertTrue(AgentLaunchReceipt(value: "receipt", requestID: requestID, windowID: "@1", paneID: "%2", createdWorktree: true)!.verifies(plan))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}

}
