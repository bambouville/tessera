import XCTest
import ImageIO
import UniformTypeIdentifiers
import Observation
import TesseraCore
import TmuxControl
@testable import Tessera

@MainActor
final class AgentCenterV2CoordinatorTests: XCTestCase {
    func testSendAnywayIsOneShotAndRetainsTheDraftMergedAfterRefusal() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        var sends: [AgentCenterV2PresentationModel.ComposerSend] = []
        model.onAction = { if case .send(let request) = $0 { sends.append(request) } }
        model.setDraft("original message", for: thread.summary.id)
        model.sendDraft(for: thread, queueWhenWorking: true)
        let original = try XCTUnwrap(sends.first)
        model.finishSend(original)
        model.setDraft("newer draft\n\"/tmp/attachment.png\"", for: thread.summary.id)
        let returned = model.returnUnsentText(original.text, for: thread.summary.id)
        XCTAssertEqual(returned, .merged)
        model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Codex", draft: returned)
        model.offerSendAnyway(for: original, refusal: .init(error: .inputNotReady,
            reason: "composer-unrecognized", attempts: 12, shape: nil), draft: returned)
        XCTAssertNotNil(model.sendAnywayCandidate)
        model.sendAnyway()
        model.sendAnyway()
        XCTAssertEqual(sends.count, 2, "approval is consumed before asynchronous dispatch")
        let forced = sends[1]
        XCTAssertEqual(forced.text, original.text)
        XCTAssertEqual(forced.threadID, original.threadID)
        XCTAssertEqual(forced.binding, original.binding)
        XCTAssertTrue(forced.queueWhenWorking)
        XCTAssertEqual(forced.composerVerification, .userOverride)
        XCTAssertEqual(forced.draftToReplace, "original message\n\nnewer draft\n\"/tmp/attachment.png\"")
        XCTAssertEqual(forced.replacementDraft, "newer draft\n\"/tmp/attachment.png\"")
        XCTAssertNil(model.capabilityNotice)
        XCTAssertNil(model.sendAnywayCandidate)
        model.finishSend(forced)
        model.sendAnyway()
        XCTAssertEqual(sends.count, 2, "finishing the action cannot restore its old approval")
        model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Codex", draft: .merged)
        model.offerSendAnyway(for: original, refusal: .init(error: .inputNotReady,
            reason: "composer-unrecognized", attempts: 12, shape: nil), draft: .merged)
        XCTAssertNil(model.sendAnywayCandidate, "a repeated callback cannot recreate a consumed approval")
    }

    func testSendAnywayExpiresOnDraftRouteSelectionNoticeAndNewActionChanges() throws {
        for change in ["draft", "route", "selection", "dismiss", "notice", "send", "attachments", "disable"] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let thread = try XCTUnwrap(model.selectedThread)
            var sends: [AgentCenterV2PresentationModel.ComposerSend] = []
            model.onAction = { if case .send(let request) = $0 { sends.append(request) } }
            model.setDraft("message", for: thread.summary.id)
            model.sendDraft(for: thread)
            let original = try XCTUnwrap(sends.first)
            model.finishSend(original)
            model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Codex", draft: .restored)
            model.offerSendAnyway(for: original, refusal: .init(error: .inputNotReady,
                reason: "composer-unrecognized", attempts: 12, shape: nil), draft: .restored)
            XCTAssertNotNil(model.sendAnywayCandidate, change)
            switch change {
            case "draft": model.setDraft("edited scope", for: thread.summary.id)
            case "route":
                model.apply(thread: .init(summary: thread.summary, messages: thread.messages, cursor: thread.cursor,
                    hasMore: thread.hasMore, binding: nil))
            case "selection": model.selectedThreadID = nil
            case "dismiss": model.capabilityNotice = nil
            case "notice": model.reportUnavailable("Another action failed.")
            case "send": model.sendDraft(for: thread)
            case "attachments": model.prepareAttachments(for: thread)
            default: model.clearForExperimentDisable()
            }
            XCTAssertNil(model.sendAnywayCandidate, change)
            let count = sends.count
            model.sendAnyway()
            XCTAssertEqual(sends.count, count, "an expired approval cannot send: \(change)")
        }
    }

    func testSendAnywayDoesNotOfferStaleEditedOriginalOrGenericVerificationFailure() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        var request: AgentCenterV2PresentationModel.ComposerSend?
        model.onAction = { if case .send(let value) = $0 { request = value } }
        model.setDraft("message", for: thread.summary.id)
        model.sendDraft(for: thread)
        let original = try XCTUnwrap(request)
        model.finishSend(original)
        model.setDraft("message with revised scope", for: thread.summary.id)
        let returned = model.returnUnsentText(original.text, for: thread.summary.id, boxWasCleared: false)
        model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Codex", draft: returned)
        model.offerSendAnyway(for: original, refusal: .init(error: .inputNotReady,
            reason: "composer-unrecognized", attempts: 12, shape: nil), draft: returned)
        XCTAssertNil(model.sendAnywayCandidate, "do not replay the original after it was revised")
        model.setDraft(original.text, for: thread.summary.id)
        model.reportActionError(.verificationFailed)
        XCTAssertNil(model.sendAnywayCandidate, "a failure after text reached the terminal may be ambiguous")
        model.offerSendAnyway(for: original, refusal: .init(error: .unavailable,
            reason: "receipt", attempts: 0, shape: nil), draft: .restored)
        XCTAssertNil(model.sendAnywayCandidate, "receipt failures do not bypass verification")
    }

    func testSendAnywayCannotReappearAfterScopeChangedDuringOriginalGuard() throws {
        for change in ["select-away-and-back", "binding-away-and-back", "another-action"] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let thread = try XCTUnwrap(model.selectedThread)
            var refused: AgentCenterV2PresentationModel.ComposerSend?
            model.onAction = { if case .send(let request) = $0 { refused = request } }
            model.setDraft("message", for: thread.summary.id)
            model.sendDraft(for: thread)
            let request = try XCTUnwrap(refused)
            switch change {
            case "select-away-and-back": model.selectedThreadID = nil; model.selectedThreadID = thread.summary.id
            case "binding-away-and-back":
                model.apply(thread: .init(summary: thread.summary, messages: thread.messages, cursor: thread.cursor,
                    hasMore: thread.hasMore, binding: nil))
                model.apply(thread: thread)
            default: model.invalidateSendAnyway()
            }
            model.finishSend(request)
            model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Codex", draft: .restored)
            model.offerSendAnyway(for: request, refusal: .init(error: .inputNotReady,
                reason: "composer-unrecognized", attempts: 12, shape: nil), draft: .restored)
            XCTAssertNil(model.sendAnywayCandidate, "an old in-flight refusal cannot recreate its approval: \(change)")
        }
    }

    func testCoordinatorSendAnywayKeepsReceiptPathAndRemovesOnlyReturnedMessage() async throws {
        var writes: [Data] = [], keys: [AgentInputKey] = []
        let fixture = await makeFinishedAgentFixture(transport: "ssh+tmux",
            send: { _, bytes in writes.append(Data(bytes)); return true },
            sendKey: { _, key in keys.append(key); return true })
        let coordinator = fixture.coordinator, model = coordinator.presentation
        coordinator.setSurfaceDemand(true)
        model.selectedThreadID = fixture.threadID
        let thread = try XCTUnwrap(model.threadSnapshots[fixture.threadID])
        let binding = try XCTUnwrap(thread.binding)
        model.setDraft("original", for: fixture.threadID)
        model.sendDraft(for: thread)
        let accepted = await waitUntil { model.draftBinding(for: fixture.threadID).isEmpty }
        XCTAssertTrue(accepted)
        model.setDraft("typed since", for: fixture.threadID)
        let offered = await waitUntil(attempts: 150) { model.sendAnywayCandidate != nil && model.pendingSends[fixture.threadID] == nil }
        XCTAssertTrue(offered)
        XCTAssertEqual(model.draftBinding(for: fixture.threadID), "original\n\ntyped since")
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(coordinator.bridge.threadSnapshots[fixture.threadID]?.outgoingMessages?.isEmpty ?? true)
        // Discovery rebuilds adapters from the session-owned source. Rebuild
        // it here, too: the retry must use that production endpoint rather
        // than depend on the object that observed the original refusal.
        let session = try XCTUnwrap(coordinator.sessionRoutes[binding.liveSessionID])
        let route = try XCTUnwrap(coordinator.threadRoutes[fixture.threadID])
        coordinator.terminalAdapters[fixture.threadID] = coordinator.makeTerminalAdapter(
            threadID: fixture.threadID, session: session, thread: route)
        model.sendAnyway()
        let submitted = await waitUntil { writes.count == 1 && keys.count == 1 && model.pendingSends[fixture.threadID] == nil }
        XCTAssertTrue(submitted)
        XCTAssertEqual(writes, [Data("\u{1b}[200~original\u{1b}[201~".utf8)],
            "the regenerated endpoint uses the production paste encoding exactly once")
        XCTAssertEqual(keys, [.enter])
        XCTAssertEqual(model.draftBinding(for: fixture.threadID), "typed since")
        XCTAssertEqual(coordinator.bridge.threadSnapshots[fixture.threadID]?.outgoingMessages?.map(\.status), [.sentUnconfirmed],
            "this fixture has no transcript frontier; an admitted send remains pending a canonical record")
        XCTAssertNil(model.sendAnywayCandidate)
        let canonical = try XCTUnwrap(AgentProjectionRecord(sequence: 0, recordID: "override-canonical-receipt",
            record: .object(["type": .string("message"), "provider": .string("codex"), "role": .string("user"),
                "blocks": .array([.object(["type": .string("text"), "text": .string("original")])])])))
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "send-anyway-receipt:1:2:8:1",
            records: [canonical], cursor: nil, hasMore: false))
        let applied = await coordinator.bridge.apply(page: page, to: fixture.threadID)
        XCTAssertTrue(applied.accepted)
        await coordinator.synchronizePresentation(refreshLaunchSuggestions: false)
        let received = try XCTUnwrap(model.threadSnapshots[fixture.threadID])
        XCTAssertEqual(received.messages.map(\.role), [.user])
        XCTAssertEqual(received.messages.first?.blocks, [.text("original")])
        XCTAssertEqual(received.outgoingMessages?.map(\.status), [.observed],
            "the canonical opening prompt reconciles the same acknowledged override")
        XCTAssertEqual(model.draftBinding(for: fixture.threadID), "typed since")
        XCTAssertEqual(writes.count, 1, "receipt reconciliation cannot replay terminal input")
        XCTAssertEqual(keys.count, 1)
        coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
        await coordinator.setExperimentEnabled(false)
    }

    func testIncompleteTmuxDiscoveryCannotRetireEveryThread() {
        let valid = "@1\t%2\t42\tzsh\t\twindow\twith tab"
        XCTAssertTrue(AgentSessionSourceFactory.hasCompleteDiscoveryPaneReply([valid]))
        XCTAssertFalse(AgentSessionSourceFactory.hasCompleteDiscoveryPaneReply([]))
        XCTAssertFalse(AgentSessionSourceFactory.hasCompleteDiscoveryPaneReply([""]))
        XCTAssertFalse(AgentSessionSourceFactory.hasCompleteDiscoveryPaneReply([valid, "wrong reply"]))
        XCTAssertFalse(AgentSessionSourceFactory.hasCompleteDiscoveryPaneReply([valid, valid]))
    }

    /// mosh-server drops SGR 2, so its replica of the tmux window shows
    /// Claude's DIM suggestion as a typed draft. Sends on the side channel
    /// read tmux's own capture of the pane even when it is recorded as rendered.
    func testMoshSideChannelActionsInspectTmuxCaptureNotTheLocalGrid() {
        let pane = PaneId(5)
        XCTAssertTrue(AgentSessionSourceFactory.actionInspectionUsesLocalGrid(controlPath: .inline, renderedPaneID: pane, paneID: pane))
        XCTAssertFalse(AgentSessionSourceFactory.actionInspectionUsesLocalGrid(controlPath: .inline, renderedPaneID: PaneId(6), paneID: pane))
        XCTAssertFalse(AgentSessionSourceFactory.actionInspectionUsesLocalGrid(controlPath: .inline, renderedPaneID: nil, paneID: pane))
        XCTAssertFalse(AgentSessionSourceFactory.actionInspectionUsesLocalGrid(controlPath: .sideChannel, renderedPaneID: pane, paneID: pane))
        XCTAssertFalse(AgentSessionSourceFactory.actionInspectionUsesLocalGrid(controlPath: .sideChannel, renderedPaneID: nil, paneID: pane))
    }

    /// Replies shaped like tmux 3.6a's `capture-pane -p -e -N` of Claude Code
    /// 2.1.283 showing a suggestion under output that holds a file hyperlink.
    /// The same pane typed by hand stays occupied.
    func testTmuxCaptureOfClaudeSuggestionIsAnEmptyComposer() async {
        func capture(_ composer: String) async -> AgentSessionSourceFactory.PaneCapture? {
            let rows = [
                "see \u{1b}]8;;file:///tmp/x.swift\u{1b}\\x.swift\u{1b}]8;;\u{1b}\\ done    ",
                "\u{1b}[38;2;136;136;136m────────\u{1b}[39m            ",
                composer,
                "\u{1b}[38;2;136;136;136m────────\u{1b}[39m            ",
                "  \u{1b}[2m? for shortcuts\u{1b}[0m",
            ]
            return await AgentSessionSourceFactory.capturePane(paneID: PaneId(5)) { command in
                command.hasPrefix("capture-pane ") ? .success(rows) : .success(["2:2:1"])
            }
        }
        func safety(_ capture: AgentSessionSourceFactory.PaneCapture?) -> AgentComposerEvidence.Safety? {
            capture.map {
                AgentComposerEvidence.safety(provider: "claude", visibleText: $0.text, cursorRow: $0.cursorRow,
                    cursorColumn: $0.cursorColumn, cursorVisible: $0.cursorVisible, requireEmpty: true,
                    queueWhenWorking: false, screen: $0.screenEvidence)
            }
        }
        let suggested = await capture("❯ \u{1b}[7mb\u{1b}[0;2mundle option a in WG-1\u{1b}[0m               ")
        XCTAssertNil(suggested?.screenEvidence)
        XCTAssertEqual(safety(suggested), .readyReturn)
        let typed = await capture("❯ \u{1b}[7mb\u{1b}[0mundle option a in WG-1               ")
        XCTAssertEqual(safety(typed), .occupied)
    }

    func testRefreshCooldownKeepsGenericPendingButDoesNotDelayLifecycle() {
        var queue = AgentCenterV2SessionRefreshQueue()
        queue.enqueue(paneID: nil, lifecycle: nil)
        XCTAssertNil(queue.dequeue(allowGeneric: false))
        XCTAssertFalse(queue.isEmpty)
        queue.enqueue(paneID: 2, lifecycle: lifecycleEvent(turnID: "urgent", timestampNanoseconds: 20))
        XCTAssertEqual(queue.dequeue(allowGeneric: false)?.lifecycle?.turnID, "urgent")
        XCTAssertFalse(queue.isEmpty)
        XCTAssertNil(queue.dequeue()?.lifecycle)
        XCTAssertTrue(queue.isEmpty)
    }

    func testChattyOutputHasBoundedDiscoveryRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-rate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        let sessionID = UUID()
        var discoveries = 0
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { discoveries += 1; return .success([]) }, observe: { _ in nil },
            inspect: { _ in nil }, automaticallyProbeLifecycleIntegration: false,
            send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [.builtInCodexCLI] })
        for _ in 0..<30 {
            coordinator.scheduleSessionRefresh(sessionID: sessionID)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(discoveries, 0)
        XCTAssertLessThanOrEqual(discoveries, 2, "Terminal chunks must not issue all-pane remote probes per packet")
        await coordinator.setExperimentEnabled(false)
    }

    func testACardStaysVisibleWhileAnotherListInstanceStillShowsIt() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "layout-flip")!
        // Two columns become one: the new list's row appears first.
        coordinator.presentation.onAction?(.cardVisibility(id, true))
        coordinator.presentation.onAction?(.cardVisibility(id, true))
        let both = await waitUntil { coordinator.ingestionVisibleCardCounts[id] == 2 }
        XCTAssertTrue(both)
        coordinator.presentation.onAction?(.cardVisibility(id, false))
        let oneLeft = await waitUntil { coordinator.ingestionVisibleCardCounts[id] == 1 }
        XCTAssertTrue(oneLeft)
        XCTAssertTrue(coordinator.ingestionVisibleCards.contains(id))
        coordinator.presentation.onAction?(.cardVisibility(id, false))
        let gone = await waitUntil { coordinator.ingestionVisibleCardCounts[id] == nil }
        XCTAssertTrue(gone)
        XCTAssertFalse(coordinator.ingestionVisibleCards.contains(id))
        await coordinator.setExperimentEnabled(false)
    }

    func testLivePromptWatchOutcomesDoNotOutliveTheirHostOrAgentCenter() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        let hostID = UUID()
        let id = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "watch-outcome")!
        func source() -> AgentSessionSource {
            AgentSessionSource(registrationID: UUID(), sessionID: UUID(),
                discover: { .success([]) }, observe: { _ in nil },
                inspect: { _ in nil }, automaticallyProbeLifecycleIntegration: false,
                send: { _, _ in false }, jump: { _ in })
        }
        let first = source()
        coordinator.registerSessionSource(first, hostID: hostID, profiles: { [.builtInCodexCLI] })
        coordinator.startLivePromptWatch(id)
        XCTAssertNotNil(coordinator.livePromptWatchOutcomes[id]?.exit, "a refusal is logged while its host has a session")
        coordinator.unregisterSessionSource(sessionID: first.sessionID, registrationID: first.registrationID)
        XCTAssertNil(coordinator.livePromptWatchOutcomes[id])
        // A watch ending after that cleanup must not bring its outcome back.
        coordinator.startLivePromptWatch(id)
        XCTAssertNil(coordinator.livePromptWatchOutcomes[id])

        let second = source()
        coordinator.registerSessionSource(second, hostID: hostID, profiles: { [.builtInCodexCLI] })
        coordinator.startLivePromptWatch(id)
        XCTAssertNotNil(coordinator.livePromptWatchOutcomes[id])
        await coordinator.setExperimentEnabled(false)
        XCTAssertNil(coordinator.livePromptWatchOutcomes[id])
        coordinator.startLivePromptWatch(id)
        XCTAssertNil(coordinator.livePromptWatchOutcomes[id], "nor after Agent Center is disabled")
    }

    func testRetainedCompletionDoesNotRearmAfterExactTerminalVisit() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-visit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            await coordinator.setApplicationActive(true)
            let sessionID = UUID(), hostID = UUID()
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let location = AgentLocation(sessionID: sessionID, hostName: "fixture", transportLabel: transport,
                tmuxSessionName: pane == nil ? nil : "fixture", windowID: pane == nil ? nil : 1,
                windowName: pane == nil ? nil : "fixture", paneID: pane)
            let target = AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42],
                visibleText: "completed", lifecycleEvent: pane == nil ? nil : lifecycleEvent(turnID: "first", timestampNanoseconds: 100),
                bracketedPasteEnabled: false)
            var discoveries = 0
            let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
                discover: { discoveries += 1; return .success([target]) }, observe: { _ in nil },
                inspect: { _ in target }, automaticallyProbeLifecycleIntegration: false,
                send: { _, _ in false }, jump: { _ in })
            coordinator.registerSessionSource(source, hostID: hostID, profiles: { [.builtInCodexCLI] })
            if pane == nil {
                coordinator.scheduleSessionRefresh(sessionID: sessionID,
                    lifecycle: lifecycleEvent(turnID: "first", timestampNanoseconds: 100))
            }
            let id = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "session")!
            let completed = await waitUntil { coordinator.presentation.threadSnapshots[id]?.summary.attention == .unreadCompletion }
            XCTAssertTrue(completed, transport)
            coordinator.setSwipePadFocus(sessionID: sessionID, paneID: pane)
            let acknowledged = await waitUntil { coordinator.presentation.threadSnapshots[id]?.summary.status == .idle }
            XCTAssertTrue(acknowledged, transport)
            coordinator.clearSwipePadFocus(sessionID: sessionID)
            let previous = discoveries
            // Generic discovery runs on a floor, and with no surface open that
            // floor is a minute (`AgentCenterV2DiscoveryPolicy`). What this
            // case is about is that the rediscovery does not re-arm a cleared
            // completion, not how long the worker waits before running it.
            coordinator.sessionDiscoveryAfter[sessionID] = .distantPast
            coordinator.scheduleSessionRefresh(sessionID: sessionID)
            let rediscovered = await waitUntil { discoveries > previous && coordinator.sessionRefreshIsIdle(sessionID) }
            XCTAssertTrue(rediscovered)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.attention, AgentAttention.none, transport)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.status, .idle, transport)
            coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: source.registrationID)
            await coordinator.setExperimentEnabled(false)
        }
    }

    /// A finish with no transcript record is read from Agent Center through
    /// the epoch-fenced completion action, and the read survives a relaunch:
    /// the pane's retained Stop replayed into a fresh coordinator stays read.
    func testVisibleCompletionWithoutRecordsIsReadAndStaysReadAfterRelaunch() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-completion-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appendingPathComponent("metadata.json")
            let sessionID = UUID(), hostID = UUID()
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let id = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "session")!
            func run(_ coordinator: AgentCenterV2Coordinator) async -> AgentSessionSource {
                let location = AgentLocation(sessionID: sessionID, hostName: "fixture", transportLabel: transport,
                    tmuxSessionName: pane == nil ? nil : "fixture", windowID: pane == nil ? nil : 1,
                    windowName: pane == nil ? nil : "fixture", paneID: pane)
                let target = AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42],
                    visibleText: "completed", lifecycleEvent: pane == nil ? nil : lifecycleEvent(turnID: "first", timestampNanoseconds: 100),
                    bracketedPasteEnabled: false)
                let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
                    discover: { .success([target]) }, observe: { _ in nil },
                    inspect: { _ in target }, automaticallyProbeLifecycleIntegration: false,
                    send: { _, _ in false }, jump: { _ in })
                coordinator.registerSessionSource(source, hostID: hostID, profiles: { [.builtInCodexCLI] })
                if pane == nil {
                    coordinator.scheduleSessionRefresh(sessionID: sessionID,
                        lifecycle: lifecycleEvent(turnID: "first", timestampNanoseconds: 100))
                }
                return source
            }

            let first = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: fileURL))
            await first.setExperimentEnabled(true)
            await first.setApplicationActive(true)
            let firstSource = await run(first)
            let finished = await waitUntil { first.presentation.threadSnapshots[id]?.summary.attention == .unreadCompletion }
            XCTAssertTrue(finished, transport)
            let snapshot = try XCTUnwrap(first.presentation.threadSnapshots[id])
            XCTAssertTrue(snapshot.messages.isEmpty, transport)
            let epoch = try XCTUnwrap(snapshot.attentionEpoch)
            first.presentation.selectedThreadID = id
            first.presentation.onAction?(.completionVisible(threadID: id, attentionEpoch: epoch &+ 1))
            first.presentation.onAction?(.completionVisible(threadID: id, attentionEpoch: epoch))
            let read = await waitUntil { first.presentation.threadSnapshots[id]?.summary.attention == AgentAttention.none }
            XCTAssertTrue(read, transport)
            XCTAssertEqual(first.presentation.threadSnapshots[id]?.summary.status, .idle, transport)
            var stored: AgentThreadMetadata?
            for _ in 0..<100 {
                stored = await AppleAgentMetadataRepository(fileURL: fileURL).metadata(for: id)
                if stored?.acknowledgedCompletionKey != nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(stored?.acknowledgedCompletionKey, transport)
            XCTAssertNil(stored?.unreadCompletionKey, transport)
            first.unregisterSessionSource(sessionID: sessionID, registrationID: firstSource.registrationID)

            // Relaunch: a fresh runtime reads the same document, then the pane
            // replays its retained Stop.
            let second = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: fileURL))
            await second.setExperimentEnabled(true)
            await second.setApplicationActive(true)
            let secondSource = await run(second)
            let replayed = await waitUntil {
                second.presentation.threadSnapshots[id]?.activity.contains { $0.kind == .lifecycle } == true
            }
            XCTAssertTrue(replayed, transport)
            XCTAssertEqual(second.presentation.threadSnapshots[id]?.summary.status, .idle, transport)
            XCTAssertEqual(second.presentation.threadSnapshots[id]?.summary.attention, AgentAttention.none, transport)
            second.unregisterSessionSource(sessionID: sessionID, registrationID: secondSource.registrationID)
            await second.setExperimentEnabled(false)
            await first.setExperimentEnabled(false)
        }
    }

    /// The top-bar attention chip lists the finished agent with its exact
    /// pane, and "open pane" focuses that pane through the live route without
    /// a detour through Agent Center. Visiting the pane is what clears it.
    func testAttentionChipOpensFinishedAgentsExactPaneOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let fixture = await makeFinishedAgentFixture(transport: transport)
            let coordinator = fixture.coordinator
            var opened: [AgentTerminalBinding] = []
            var revealedInAgentCenter: [AgentThreadID] = []
            coordinator.onOpenExactTerminal = { opened.append($0) }
            coordinator.onRevealThread = { revealedInAgentCenter.append($0) }

            let entries = coordinator.attentionEntries()
            XCTAssertEqual(entries.map(\.threadID), [fixture.threadID], transport)
            XCTAssertEqual(entries.first?.kind, .finished, transport)
            XCTAssertEqual(coordinator.attentionBadgeCounts.finished, entries.count, transport)
            let binding = try XCTUnwrap(entries.first?.terminalBinding, transport)
            XCTAssertEqual(binding.liveSessionID, fixture.sessionID, transport)
            XCTAssertEqual(binding.paneID, fixture.location.paneID.map(String.init), transport)
            XCTAssertEqual(binding.windowID, fixture.location.windowID.map(String.init), transport)

            let didReveal = await coordinator.revealAttentionTerminal(threadID: fixture.threadID)
            XCTAssertTrue(didReveal, transport)
            XCTAssertEqual(fixture.jumps(), [fixture.location], transport)
            XCTAssertEqual(opened, [binding], transport)
            XCTAssertTrue(revealedInAgentCenter.isEmpty, transport)
            XCTAssertNil(coordinator.presentation.capabilityNotice, transport)

            // Arriving at the pane is the visit that marks it checked.
            coordinator.setSwipePadFocus(sessionID: fixture.sessionID, paneID: fixture.location.paneID)
            let cleared = await waitUntil { coordinator.attentionEntries().isEmpty }
            XCTAssertTrue(cleared, transport)
            XCTAssertEqual(coordinator.attentionBadgeCounts.finished, 0, transport)
            coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
            await coordinator.setExperimentEnabled(false)
        }
    }

    /// A pane that closed after the list was drawn, and a session that
    /// disconnected, both land on the thread in Agent Center. Neither moves
    /// terminal focus nor starts a connection.
    func testAttentionChipFallsBackToAgentCenterWhenThePaneIsGone() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let fixture = await makeFinishedAgentFixture(transport: transport)
            let coordinator = fixture.coordinator
            var opened: [AgentTerminalBinding] = []
            var revealedInAgentCenter: [AgentThreadID] = []
            coordinator.onOpenExactTerminal = { opened.append($0) }
            coordinator.onRevealThread = { revealedInAgentCenter.append($0) }
            XCTAssertNotNil(coordinator.attentionEntries().first?.terminalBinding, transport)

            // The pane closed between drawing the list and the tap.
            fixture.closePane()
            let didReveal = await coordinator.revealAttentionTerminal(threadID: fixture.threadID)
            XCTAssertFalse(didReveal, transport)
            XCTAssertTrue(fixture.jumps().isEmpty, transport)
            XCTAssertTrue(opened.isEmpty, transport)
            XCTAssertNotNil(coordinator.presentation.capabilityNotice, transport)
            coordinator.reviewAttentionThread(fixture.threadID)
            XCTAssertEqual(revealedInAgentCenter, [fixture.threadID], transport)
            XCTAssertEqual(coordinator.presentation.selectedThreadID, fixture.threadID, transport)
            XCTAssertEqual(coordinator.presentation.pendingNarrowThreadNavigation, fixture.threadID, transport)

            // Disconnected session: the row stays reviewable, not reachable.
            coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
            let unreachable = coordinator.attentionEntries().first { $0.threadID == fixture.threadID }
            if let unreachable {
                XCTAssertEqual(unreachable.destination, .agentCenter, transport)
            }
            let afterDisconnect = await coordinator.revealAttentionTerminal(threadID: fixture.threadID)
            XCTAssertFalse(afterDisconnect, transport)
            XCTAssertTrue(fixture.jumps().isEmpty, transport)
            XCTAssertTrue(opened.isEmpty, transport)
            await coordinator.setExperimentEnabled(false)
        }
    }

    /// Focus that was already on the pane (it arrived while the app was
    /// inactive) reports no focus change, so the jump itself re-checks it.
    func testOpeningTheAlreadyFocusedPaneMarksItChecked() async {
        let fixture = await makeFinishedAgentFixture(transport: "ssh+tmux")
        let coordinator = fixture.coordinator
        await coordinator.setApplicationActive(false)
        coordinator.setSwipePadFocus(sessionID: fixture.sessionID, paneID: fixture.location.paneID)
        await coordinator.setApplicationActive(true)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.attentionEntries().map(\.threadID), [fixture.threadID])

        let didReveal = await coordinator.revealAttentionTerminal(threadID: fixture.threadID)
        XCTAssertTrue(didReveal)
        let cleared = await waitUntil { coordinator.attentionEntries().isEmpty }
        XCTAssertTrue(cleared)
        coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
        await coordinator.setExperimentEnabled(false)
    }

    /// The Agent Center list's search filter survives leaving Agent Center.
    /// It must not hide attention from terminal chrome: the chip, sidebar and
    /// compact badges, and the background keep-alive count every live agent.
    /// Terminal chrome reads per-session attention from bound threads only;
    /// it must agree with every thread snapshot and not redraw on a no-op.
    func testSessionAttentionMatchesSnapshotsAcrossTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let fixture = await makeFinishedAgentFixture(transport: transport)
            let coordinator = fixture.coordinator
            func fromSnapshots(_ sessionID: UUID, _ windowID: Int?) -> [Bool] {
                let snapshots = coordinator.presentation.threadSnapshots.values.filter { snapshot in
                    guard let binding = snapshot.binding, binding.liveSessionID == sessionID else { return false }
                    return windowID == nil || binding.windowID == windowID.map(String.init)
                }
                return [!snapshots.isEmpty,
                        snapshots.contains { $0.summary.attention == .needsYou || $0.summary.status == .waitingForInput },
                        snapshots.contains { $0.summary.attention == .unreadCompletion }]
            }
            for (sessionID, windowID) in [(fixture.sessionID, nil), (fixture.sessionID, fixture.location.windowID),
                                          (fixture.sessionID, 9_999), (UUID(), nil)] {
                let attention = coordinator.sessionAttention(sessionID: sessionID, windowID: windowID)
                XCTAssertEqual([attention.hasAgent, attention.needsInput, attention.unreadCompletion],
                               fromSnapshots(sessionID, windowID), "\(transport) window=\(String(describing: windowID))")
            }
            XCTAssertTrue(coordinator.sessionAttention(sessionID: fixture.sessionID).hasAgent, transport)
            XCTAssertEqual(coordinator.sessionAttention(sessionID: fixture.sessionID).total, 1, transport)

            var redrawn = false
            withObservationTracking { _ = coordinator.sessionAttention(sessionID: fixture.sessionID) } onChange: { redrawn = true }
            await coordinator.synchronizePresentation(refreshLaunchSuggestions: false)
            XCTAssertFalse(redrawn, "an unchanged publish must not redraw terminal chrome (\(transport))")
            coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
            await coordinator.setExperimentEnabled(false)
            let attention = coordinator.sessionAttention(sessionID: fixture.sessionID)
            XCTAssertEqual([attention.hasAgent, attention.needsInput, attention.unreadCompletion], [false, false, false],
                           "a disabled Agent Center marks no terminal (\(transport))")
            XCTAssertEqual(attention.total, 0, transport)
            XCTAssertTrue(coordinator.presentation.threadSnapshots.values.allSatisfy { $0.messages.isEmpty && ($0.outgoingMessages ?? []).isEmpty },
                          "disabling purges content; the presentation must not be refilled from the bridge's cache (\(transport))")
            // The fixture has no messages, so the cache is proven by what Core
            // changed on disable: every thread reports it.
            XCTAssertEqual(coordinator.bridge.threadSnapshots[fixture.threadID]?.summary.availability.reason, .disabled,
                           "the bridge must reload what Core purged (\(transport))")
            XCTAssertTrue(coordinator.presentation.threadSnapshots.values.allSatisfy { $0.summary.availability.reason == .disabled },
                          "no presented thread may keep pre-disable state (\(transport))")
        }
    }

    /// The fixture's pane shows no composer, so every send is refused before
    /// its first byte once the readiness window closes.
    func testRefusedSendReturnsTheMessageOnceAndNeverAfterDisable() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            for mode in ["refused", "disabled", "re-enabled"] {
                let fixture = await makeFinishedAgentFixture(transport: transport)
                let coordinator = fixture.coordinator
                let presentation = coordinator.presentation
                // Sends come from a visible composer; without one the receipt
                // is refused at once, before any typing could land.
                coordinator.setSurfaceDemand(true)
                let thread = try XCTUnwrap(presentation.threadSnapshots[fixture.threadID])
                XCTAssertEqual(thread.binding?.capabilities.contains(.send), true, transport)
                XCTAssertNil(coordinator.bridge.lastActionError, transport)
                presentation.setDraft("first message", for: fixture.threadID)
                presentation.sendDraft(for: thread)
                let accepted = await waitUntil { presentation.draftBinding(for: fixture.threadID).isEmpty }
                XCTAssertTrue(accepted, "\(transport): acceptance clears the box")
                if mode == "refused" {
                    presentation.setDraft("typed since", for: fixture.threadID)
                } else {
                    await coordinator.setExperimentEnabled(false)
                    if mode == "re-enabled" { await coordinator.setExperimentEnabled(true) }
                }
                // The bridge records the refusal just before handing it back,
                // so the checks below run once the send has really settled.
                var settled = false
                for _ in 0..<3 where !settled {
                    settled = await waitUntil { coordinator.bridge.lastActionError != nil }
                }
                XCTAssertTrue(settled, "\(transport) \(mode): the send settles")
                let reported = await waitUntil(attempts: 25) { presentation.capabilityNotice?.hasPrefix("Not sent") == true }
                if mode == "refused" {
                    XCTAssertTrue(reported, transport)
                    XCTAssertEqual(presentation.capabilityNotice?.contains("input wasn't ready"), true,
                                   "\(transport): \(presentation.capabilityNotice ?? "")")
                    XCTAssertEqual(presentation.draftBinding(for: fixture.threadID), "first message\n\ntyped since", transport)
                    XCTAssertEqual(presentation.capabilityNotice?.hasSuffix("above what you typed since."), true, transport)
                    XCTAssertNil(presentation.pendingSends[fixture.threadID], transport)
                } else {
                    XCTAssertFalse(reported, "\(transport) \(mode): a refusal after disable reports nothing")
                    XCTAssertEqual(presentation.draftBinding(for: fixture.threadID), "", "\(transport) \(mode): disabling purged the draft")
                }
                await coordinator.setExperimentEnabled(false)
            }
        }
    }

    func testAttentionCountsIgnoreTheAgentCenterListFilter() async {
        let fixture = await makeFinishedAgentFixture(transport: "ssh+tmux")
        let coordinator = fixture.coordinator
        XCTAssertEqual(coordinator.attentionBadgeCounts.finished, 1)
        coordinator.scheduleSearch(query: "no-thread-matches-this-query")
        let filtered = await waitUntil { coordinator.bridge.listSnapshot.threads.isEmpty }
        XCTAssertTrue(filtered)
        await coordinator.synchronizePresentation()
        XCTAssertTrue(coordinator.presentation.listSnapshot.threads.isEmpty, "precondition: the list is filtered")

        XCTAssertEqual(coordinator.attentionBadgeCounts.finished, 1)
        XCTAssertEqual(coordinator.attentionBadgeCounts.waiting, 0)
        XCTAssertEqual(coordinator.attentionBadgeCounts.total, 1)
        XCTAssertEqual(coordinator.attentionEntries().map(\.threadID), [fixture.threadID])
        coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
        await coordinator.setExperimentEnabled(false)
    }

    /// Disabling Agent Center keeps the core's reduced state, and the
    /// disable path re-synchronizes presentation from it. No badge may count
    /// that state once the feature is off.
    func testAttentionCountsAreZeroOnceAgentCenterIsDisabled() async {
        let fixture = await makeFinishedAgentFixture(transport: "mosh")
        let coordinator = fixture.coordinator
        XCTAssertEqual(coordinator.attentionBadgeCounts.finished, 1)
        await coordinator.setExperimentEnabled(false)
        XCTAssertEqual(coordinator.attentionBadgeCounts.waiting, 0)
        XCTAssertEqual(coordinator.attentionBadgeCounts.finished, 0)
        XCTAssertEqual(coordinator.attentionBadgeCounts.working, 0)
        XCTAssertEqual(coordinator.attentionBadgeCounts.total, 0)
        XCTAssertTrue(coordinator.attentionEntries().isEmpty)
    }

    func testPaneProviderIndexDoesNotObserveTranscriptPublications() async throws {
        let fixture = await makeFinishedAgentFixture(transport: "ssh+tmux")
        let coordinator = fixture.coordinator
        let paneID = try XCTUnwrap(fixture.location.paneID)
        XCTAssertEqual(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID), "codex")
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: UUID(), paneID: paneID))
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID + 1))

        var redrawn = false
        withObservationTracking {
            _ = coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID)
        } onChange: { redrawn = true }
        let snapshot = try XCTUnwrap(coordinator.presentation.threadSnapshots[fixture.threadID])
        var summary = snapshot.summary
        summary.preview = "New transcript preview"
        coordinator.presentation.apply(thread: .init(summary: summary, messages: snapshot.messages,
            cursor: snapshot.cursor, hasMore: snapshot.hasMore, binding: snapshot.binding))
        await coordinator.synchronizePresentation(refreshLaunchSuggestions: false)
        XCTAssertFalse(redrawn, "transcript changes and an unchanged provider index must not redraw chrome")
        coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID))
        XCTAssertTrue(redrawn, "retiring the registration must clear the observed provider immediately")
        await coordinator.setExperimentEnabled(false)
    }

    func testPaneProviderIndexRequiresCurrentBindingsAndRejectsMixedProviders() async throws {
        let fixture = await makeFinishedAgentFixture(transport: "ssh+tmux")
        let coordinator = fixture.coordinator
        let paneID = try XCTUnwrap(fixture.location.paneID)
        let route = try XCTUnwrap(coordinator.threadRoutes[fixture.threadID])
        let original = try XCTUnwrap(coordinator.presentation.threadSnapshots[fixture.threadID])
        let otherID = try XCTUnwrap(AgentThreadID(hostID: fixture.threadID.hostID, providerID: .claude, providerSessionID: "other"))
        let otherSummary = AgentThreadSummary(id: otherID, providerName: "Claude", availability: original.summary.availability)
        let other = AgentThreadSnapshot(summary: otherSummary, messages: [], cursor: nil, hasMore: false, binding: route.binding)
        coordinator.presentation.apply(thread: other)
        coordinator.threadRoutes[otherID] = route
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID))
        coordinator.threadRoutes[otherID] = nil
        XCTAssertEqual(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID), "codex")

        coordinator.threadRoutes[fixture.threadID] = .init(registrationID: UUID(), location: route.location,
            profile: route.profile, binding: route.binding, sourceIdentity: route.sourceIdentity)
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID))
        coordinator.threadRoutes[fixture.threadID] = route
        coordinator.presentation.apply(thread: .init(summary: original.summary, messages: [], cursor: nil, hasMore: false, binding: nil))
        coordinator.threadRoutes[fixture.threadID] = route
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID), "a stale snapshot binding cannot identify a pane")
        coordinator.presentation.apply(thread: original)
        coordinator.threadRoutes[fixture.threadID] = route
        XCTAssertEqual(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID), "codex")
        await coordinator.setExperimentEnabled(false)
        XCTAssertNil(coordinator.paneAgentProvider(sessionID: fixture.sessionID, paneID: paneID))
        coordinator.unregisterSessionSource(sessionID: fixture.sessionID, registrationID: fixture.registrationID)
    }

    private struct FinishedAgentFixture {
        let coordinator: AgentCenterV2Coordinator
        let sessionID: UUID
        let registrationID: UUID
        let threadID: AgentThreadID
        let location: AgentLocation
        let jumps: @MainActor () -> [AgentLocation]
        let closePane: @MainActor () -> Void
    }

    private func makeFinishedAgentFixture(
        transport: String,
        send: (@MainActor (AgentLocation, [UInt8]) async -> Bool)? = nil,
        sendKey: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)? = nil
    ) async -> FinishedAgentFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-attention-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        let sessionID = UUID(), hostID = UUID(), registrationID = UUID()
        let pane: Int? = transport.contains("tmux") ? 21 : nil
        let location = AgentLocation(sessionID: sessionID, hostName: "fixture", transportLabel: transport,
            tmuxSessionName: pane == nil ? nil : "fixture", windowID: pane == nil ? nil : 3,
            windowName: pane == nil ? nil : "agent", paneID: pane)
        let target = AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42],
            visibleText: "completed", lifecycleEvent: pane == nil ? nil : lifecycleEvent(turnID: "first", timestampNanoseconds: 100),
            bracketedPasteEnabled: false)
        final class Recorder { var jumps: [AgentLocation] = []; var paneOpen = true }
        let recorder = Recorder()
        let source = AgentSessionSource(registrationID: registrationID, sessionID: sessionID,
            discover: { .success([target]) }, observe: { _ in nil },
            inspect: { _ in recorder.paneOpen ? target : nil }, automaticallyProbeLifecycleIntegration: false,
            send: send ?? { _, _ in false }, sendKey: sendKey, jump: { recorder.jumps.append($0) })
        coordinator.registerSessionSource(source, hostID: hostID, profiles: { [.builtInCodexCLI] })
        if pane == nil {
            coordinator.scheduleSessionRefresh(sessionID: sessionID,
                lifecycle: lifecycleEvent(turnID: "first", timestampNanoseconds: 100))
        }
        let threadID = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "session")!
        let completed = await waitUntil {
            coordinator.presentation.threadSnapshots[threadID]?.summary.attention == .unreadCompletion
                && coordinator.attentionEntries().first?.terminalBinding != nil
        }
        XCTAssertTrue(completed, transport)
        // The entry appears midway through the discovery refresh, which then
        // republishes SwipePad evidence. Left running, that late publish marks
        // a focused pane checked whenever a test next reactivates the app.
        let settled = await waitUntil { coordinator.sessionRefreshIsIdle(sessionID) }
        XCTAssertTrue(settled, "\(transport): discovery refresh did not settle")
        return FinishedAgentFixture(
            coordinator: coordinator,
            sessionID: sessionID,
            registrationID: registrationID,
            threadID: threadID,
            location: location,
            jumps: { recorder.jumps },
            closePane: { recorder.paneOpen = false }
        )
    }

    func testIdenticalSnapshotsDoNotInvalidateNativePresentation() {
        let model = AgentCenterV2Fixture.makeModel()
        let list = model.listSnapshot
        let thread = model.selectedThread!
        var changed = false
        withObservationTracking {
            _ = model.listSnapshot
            _ = model.threadSnapshots
        } onChange: { changed = true }
        model.apply(list: list)
        model.apply(thread: thread)
        XCTAssertFalse(changed, "unchanged discovery must not repaint the native transcript")
    }

    func testSelectedTranscriptIgnoresOtherThreadsPublishes() throws {
        // Other agents publish several times a second; the selected detail
        // must not be re-evaluated for them (it stuttered mid-scroll).
        let model = AgentCenterV2PresentationModel()
        let availability = AgentAvailability(content: true, status: true, actions: false, spawn: false, fork: false, search: false)
        let host = UUID()
        let selected = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "selected"))
        let sibling = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "sibling"))
        var selectedSummary = AgentThreadSummary(id: selected, providerName: "Claude", status: .working, availability: availability)
        var siblingSummary = AgentThreadSummary(id: sibling, providerName: "Claude", status: .working, availability: availability)
        let messages = (0..<50).map { AgentMessage(recordID: "r\($0)", role: .assistant, displayTime: nil, blocks: [.text("row \($0)")]) }
        model.apply(thread: .init(summary: selectedSummary, messages: messages, cursor: nil, hasMore: false, binding: nil))
        model.apply(thread: .init(summary: siblingSummary, messages: [], cursor: nil, hasMore: false, binding: nil))
        model.selectedThreadID = selected
        XCTAssertEqual(model.selectedThread?.messages.count, 50)

        func invalidates(_ change: () -> Void) -> Bool {
            var fired = false
            withObservationTracking { _ = model.selectedThread } onChange: { fired = true }
            change()
            return fired
        }
        XCTAssertFalse(invalidates {
            siblingSummary.preview = "working"
            model.apply(thread: .init(summary: siblingSummary, messages: [], cursor: nil, hasMore: false, binding: nil))
        }, "another thread's publish must not invalidate the selected transcript")
        XCTAssertFalse(invalidates {
            model.apply(thread: .init(summary: selectedSummary, messages: messages, cursor: nil, hasMore: false, binding: nil))
        }, "re-applying an unchanged snapshot is not a change")
        XCTAssertTrue(invalidates {
            selectedSummary.preview = "new reply"
            model.apply(thread: .init(summary: selectedSummary, messages: messages, cursor: nil, hasMore: false, binding: nil))
        })
        XCTAssertEqual(model.selectedThread?.summary.preview, "new reply")

        // A lifecycle hook republishes activity and list stamps the detail
        // never shows: the detail's copy holds, the exact snapshot moves.
        func invalidatesDetail(_ change: () -> Void) -> Bool {
            var fired = false
            withObservationTracking { _ = model.selectedThreadForDetail } onChange: { fired = true }
            change()
            return fired
        }
        XCTAssertFalse(invalidatesDetail {
            selectedSummary.lastActivity = Date(timeIntervalSince1970: 1_000)
            selectedSummary.lastActivitySequence += 1
            model.apply(thread: .init(summary: selectedSummary, messages: messages,
                activity: [.init(id: "lifecycle-0-PostToolUse", sequence: 1, kind: .lifecycle, title: "PostToolUse")],
                cursor: nil, hasMore: false, binding: nil, deliveryGeneration: 1))
        }, "a lifecycle-only republish must not re-render the selected transcript")
        XCTAssertEqual(model.selectedThread?.activity.count, 1)
        XCTAssertEqual(model.selectedThreadForDetail?.activity.count, 0)
        XCTAssertTrue(invalidatesDetail {
            selectedSummary.status = .waitingForInput
            model.apply(thread: .init(summary: selectedSummary, messages: messages, cursor: nil, hasMore: false, binding: nil))
        }, "a status the header shows re-renders it")
        XCTAssertEqual(model.selectedThreadForDetail?.summary.status, .waitingForInput)

        XCTAssertTrue(invalidates { model.selectedThreadID = sibling })
        XCTAssertEqual(model.selectedThread?.summary.id, sibling)
        XCTAssertEqual(model.selectedThreadForDetail?.summary.id, sibling)
        XCTAssertTrue(invalidates { model.threadSnapshots.removeValue(forKey: sibling) })
        XCTAssertNil(model.selectedThread, "a removed selection is not kept alive by the stored copy")
        XCTAssertNil(model.selectedThreadForDetail)
    }

    /// `detailRendersSame` ignores only the fields the detail never shows.
    /// A new snapshot field must be compared there or listed as hidden.
    /// Every snapshot field is either compared or deliberately hidden, and
    /// `detailRendersSame` really does treat each one that way: a new field
    /// fails here until someone decides whether the detail renders it.
    func testDetailComparisonCoversEverySnapshotField() throws {
        let thread = try XCTUnwrap(AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "fields"))
        let summary = AgentThreadSummary(id: thread, providerName: "Claude",
            availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false))
        let base = AgentThreadSnapshot(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil)
        let preview = try JSONDecoder().decode(AgentLivePreview.self, from: Data(#"{"id":"p","text":"streaming","hasGap":false}"#.utf8))
        let window = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"""
            {"version":1,"epoch":"e","viewportSegmentIDs":["s"],"headSegmentID":"s","hasOlder":true,"hasNewer":false,
             "atLiveHead":true,"transition":"bootstrap","retainsOutgoing":false}
            """#.utf8))
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("fields")!, transport: .ssh, tmuxSession: nil, windowID: nil, paneID: nil,
            agentPID: 42, capabilities: [.observe])
        func variant(_ field: String) -> AgentThreadSnapshot? {
            switch field {
            case "version": return .init(version: 2, summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil)
            case "summary":
                var working = summary; working.status = .working
                return .init(summary: working, messages: [], cursor: nil, hasMore: false, binding: nil)
            case "messages":
                return .init(summary: summary, messages: [AgentMessage(recordID: "m", role: .assistant, displayTime: nil, blocks: [.text("x")])],
                    cursor: nil, hasMore: false, binding: nil)
            case "turns":
                return .init(summary: summary, messages: [], turns: [AgentTurn(id: "t", firstSequence: 1, lastSequence: 1, state: .completed, messages: [])],
                    cursor: nil, hasMore: false, binding: nil)
            case "activity":
                return .init(summary: summary, messages: [], activity: [AgentActivityEvent(id: "a", sequence: 1, kind: .lifecycle, title: "started")],
                    cursor: nil, hasMore: false, binding: nil)
            case "changes":
                return .init(summary: summary, messages: [], changes: AgentChangeSummary(authoritativeTotals: .init(linesAdded: 1)),
                    cursor: nil, hasMore: false, binding: nil)
            case "lineage":
                return .init(summary: summary, messages: [], lineage: AgentThreadLineage(sourceTurnID: "t"), cursor: nil, hasMore: false, binding: nil)
            case "cursor": return .init(summary: summary, messages: [], cursor: "older", hasMore: false, binding: nil)
            case "hasMore": return .init(summary: summary, messages: [], cursor: nil, hasMore: true, binding: nil)
            case "binding": return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: binding)
            case "deliveryGeneration":
                return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, deliveryGeneration: 1)
            case "outgoingMessages":
                return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil,
                    outgoingMessages: [AgentOutgoingMessage(id: UUID(), text: "x", status: .awaitingReceipt)])
            case "livePreview": return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, livePreview: preview)
            case "ingestionWindow": return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, ingestionWindow: window)
            case "attentionEpoch": return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, attentionEpoch: 1)
            case "unreadCompletionKey":
                return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, unreadCompletionKey: "k")
            case "acknowledgedCompletionKey":
                return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, acknowledgedCompletionKey: "k")
            case "conversationEnded":
                return .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil, conversationEnded: true)
            default: return nil
            }
        }
        let fields = Mirror(reflecting: base).children.compactMap(\.label)
        XCTAssertTrue(AgentCenterV2PresentationModel.detailHiddenFields.isSubset(of: Set(fields)))
        for field in fields {
            let changed = try XCTUnwrap(variant(field), "new snapshot field `\(field)`: decide whether the detail renders it")
            XCTAssertNotEqual(changed, base, "the \(field) variant must differ")
            XCTAssertEqual(AgentCenterV2PresentationModel.detailRendersSame(base, changed),
                           AgentCenterV2PresentationModel.detailHiddenFields.contains(field), field)
        }
        // Inside the summary, only the list's activity fields are hidden.
        var listOnly = summary
        listOnly.lastActivity = Date(); listOnly.lastActivitySequence = 9; listOnly.preview = "latest"
        XCTAssertTrue(AgentCenterV2PresentationModel.detailRendersSame(base,
            .init(summary: listOnly, messages: [], cursor: nil, hasMore: false, binding: nil)))
        var retitled = summary; retitled.title = "renamed"
        XCTAssertFalse(AgentCenterV2PresentationModel.detailRendersSame(base,
            .init(summary: retitled, messages: [], cursor: nil, hasMore: false, binding: nil)))
    }

    func testThreadPublishesNeverReplaceACandidateTheUserChose() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let chosen = try XCTUnwrap(AgentSourceCandidateID(hostID: thread.summary.id.hostID, providerID: .codex, sourceIdentity: "chosen"))
        model.selectCandidate(chosen)
        model.apply(thread: thread)
        XCTAssertNil(model.selectedThreadID, "a working agent's publish must not take over the user's pick")
        XCTAssertEqual(model.selectedCandidateID, chosen)
        // The list's fallback candidate is not a choice: a thread replaces it.
        model.selectedCandidateID = nil
        model.selectedCandidateID = AgentSourceCandidateID(hostID: thread.summary.id.hostID, providerID: .codex, sourceIdentity: "fallback")
        model.apply(thread: thread)
        XCTAssertEqual(model.selectedThreadID, thread.summary.id)
    }

    /// A working agent's refreshes pass through "preparing" constantly. Over
    /// a transcript on screen that row only moved the conversation up and
    /// down; it shows for an empty transcript, and a failure always shows.
    func testReadProgressShowsOnlyWhileTheTranscriptIsEmpty() async throws {
        func status(_ state: String, _ recovery: String, _ code: String) throws -> AgentIngestionReadStatus {
            try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string(state),
                "domain": .string("source"), "recovery": .string(recovery), "code": .string(code)]))
        }
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let shown = try XCTUnwrap(model.selectedThread)
        XCTAssertFalse(shown.messages.isEmpty)
        let runtime = AgentCenterRuntime()
        let emptyID = try XCTUnwrap(AgentThreadID(hostID: shown.summary.id.hostID, providerID: .claude, providerSessionID: "empty-transcript"))
        await runtime.register(AgentThreadSummary(id: emptyID, title: "Empty", titleProvenance: .native, providerName: "Claude",
            hostDisplayLabel: "Synthetic host", status: .working, lastActivity: .now, preview: "",
            availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        let registered = await runtime.snapshot(for: emptyID)
        let empty = try XCTUnwrap(registered)
        XCTAssertTrue(empty.messages.isEmpty)
        for state in ["preparing", "verifying"] {
            let progress = try status(state, "continue", "readPending")
            model.ingestionReadStatuses[shown.summary.id] = progress
            model.ingestionReadStatuses[emptyID] = progress
            XCTAssertNil(model.visibleReadStatus(for: shown), "\(state) over a shown transcript stays out of the detail")
            XCTAssertEqual(model.visibleReadStatus(for: empty), progress, "an empty transcript says what it waits for")
        }
        let failure = try status("failed", "manual", "sourceNotAuthorized")
        model.ingestionReadStatuses[shown.summary.id] = failure
        XCTAssertEqual(model.visibleReadStatus(for: shown), failure, "a failure always shows, with Retry")
        model.ingestionReadStatuses[shown.summary.id] = nil
        XCTAssertNil(model.visibleReadStatus(for: shown))
    }

    func testBackgroundEndsAbandonedPreparationAndKeepsReadFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-resume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        let thread = try XCTUnwrap(AgentCenterV2Fixture.makeModel(scene: .outgoing).selectedThread?.summary.id)
        let failed = try XCTUnwrap(AgentThreadID(hostID: thread.hostID, providerID: .claude, providerSessionID: "failed-reader"))
        let progress = try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("preparing"),
            "domain": .string("source"), "recovery": .string("continue"), "code": .string("readPending")]))
        let failure = try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("failed"),
            "domain": .string("source"), "recovery": .string("manual"), "code": .string("sourceNotAuthorized")]))
        coordinator.presentation.ingestionReadStatuses = [thread: progress, failed: failure]
        await coordinator.setApplicationActive(false)
        XCTAssertEqual(coordinator.presentation.ingestionReadStatuses, [failed: failure])
        await coordinator.setApplicationActive(true)
        XCTAssertEqual(coordinator.presentation.ingestionReadStatuses, [failed: failure])
        await coordinator.setExperimentEnabled(false)
    }

    func testComposerSendAcknowledgesSynchronouslyAndKeepsQueueExplicit() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        var sent: [AgentCenterV2PresentationModel.ComposerSend] = []
        model.onAction = { if case .send(let request) = $0 { sent.append(request) } }
        model.setDraft("next boundary", for: thread.summary.id)
        model.sendDraft(for: thread)
        XCTAssertNotNil(model.pendingSends[thread.summary.id])
        model.sendDraft(for: thread)
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(try XCTUnwrap(sent.first).queueWhenWorking)
        XCTAssertEqual(sent.first?.binding, thread.binding)
        model.finishSend(sent[0])
        XCTAssertNil(model.pendingSends[thread.summary.id])
        model.sendDraft(for: thread, queueWhenWorking: true)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[1].queueWhenWorking)
        model.finishSend(sent[0])
        XCTAssertEqual(model.pendingSends[thread.summary.id], sent[1].id, "old completion cannot clear a newer send")
        model.finishSend(sent[1])
        XCTAssertEqual(model.draftBinding(for: thread.summary.id), "next boundary", "only plan acceptance may clear a draft")
    }

    func testAttachmentsRetainPickerOriginAndConcurrentDraftEditsAcrossAllTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let original = try XCTUnwrap(model.selectedThread)
            let route = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("attachment")!, transport: transport,
                tmuxSession: "fixture", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadSnapshot(summary: original.summary, messages: [], cursor: nil, hasMore: false, binding: route)
            model.apply(thread: thread)
            let target = AgentComposerAttachments.Target(threadID: thread.summary.id, binding: route, registrationID: UUID(), generation: 1)
            var complete: CheckedContinuation<String, Error>?
            var stagedURL: URL?
            var sends = 0
            model.onAction = { if case .send = $0 { sends += 1 } }
            let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in true }, upload: { binding, url in
                XCTAssertEqual(binding, route)
                XCTAssertEqual(try Data(contentsOf: url), Data("fixture attachment".utf8))
                stagedURL = url
                return try await withCheckedThrowingContinuation { complete = $0 }
            })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-test-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory); service.cancelAll() }
            let file = directory.appendingPathComponent("test.txt")
            try Data("fixture attachment".utf8).write(to: file)
            model.setDraft("initial", for: thread.summary.id)
            model.prepareAttachments(for: thread)
            let request = try XCTUnwrap(model.attachmentPickerRequest)
            let otherID = AgentThreadID(hostID: thread.summary.id.hostID, providerID: .codex, providerSessionID: "other-thread")!
            model.selectedThreadID = otherID
            model.setDraft("other draft", for: otherID)
            model.completeAttachments(request, urls: [file])
            let started = await waitUntil { complete != nil }
            XCTAssertTrue(started)
            XCTAssertTrue(model.uploadingThreads.contains(thread.summary.id))
            model.setDraft("latest concurrent edit", for: thread.summary.id)
            model.sendDraft(for: thread)
            XCTAssertEqual(sends, 0, "send waits until selected attachments finish")
            complete?.resume(returning: "/home/fixture/.cache/tessera/quoted \"file\".txt")
            let finished = await waitUntil { model.uploadingThreads.isEmpty }
            XCTAssertTrue(finished)
            XCTAssertEqual(model.draftBinding(for: thread.summary.id), "latest concurrent edit\n\"/home/fixture/.cache/tessera/quoted \\\"file\\\".txt\"")
            XCTAssertEqual(model.draftBinding(for: otherID), "other draft")
            XCTAssertNil(model.composerFocusRequest, "an upload must not focus a different selected thread")
            XCTAssertEqual(sends, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedURL).path))
        }
    }

    func testAttachmentUploadRequestsFocusAfterUpdatingTheSelectedMountedComposer() async throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let target = AgentComposerAttachments.Target(threadID: thread.summary.id,
            binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
        var completion: CheckedContinuation<String, Error>?
        let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in true }, upload: { _, _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-focus-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); service.cancelAll() }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        model.setComposerMounted(true, for: thread.summary.id)
        model.prepareAttachments(for: thread, composerWasFocused: true)
        let request = try XCTUnwrap(model.attachmentPickerRequest)
        model.completeAttachments(request, urls: [file])
        let started = await waitUntil { completion != nil }
        XCTAssertTrue(started)
        model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
        let dismissalFocus = try XCTUnwrap(model.composerFocusRequest)
        model.keyboardFocus = .none
        completion?.resume(returning: "/tmp/fixture.txt")
        let finished = await waitUntil { model.uploadingThreads.isEmpty }
        XCTAssertTrue(finished)
        XCTAssertTrue(model.draftBinding(for: thread.summary.id).contains("/tmp/fixture.txt"))
        XCTAssertEqual(model.composerFocusRequest?.threadID, thread.summary.id)
        XCTAssertNotEqual(model.composerFocusRequest?.id, dismissalFocus.id)
    }

    func testComposerFocusRequestsRequireTheSelectedMountedThreadAndRestoreAfterPickerCancel() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let otherID = makeThreadID()
        model.requestComposerFocus(for: thread.summary.id)
        XCTAssertNil(model.composerFocusRequest, "an unmounted composer must not retain a focus request")
        model.setComposerMounted(true, for: thread.summary.id)
        model.requestComposerFocus(for: otherID)
        XCTAssertNil(model.composerFocusRequest)

        let request = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        model.onPrepareAttachments = { _ in request }
        model.prepareAttachments(for: thread, composerWasFocused: true)
        model.completeAttachments(request, urls: [])
        XCTAssertNil(model.composerFocusRequest, "wait for dismissal before restoring first responder")
        model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
        let first = try XCTUnwrap(model.composerFocusRequest)
        XCTAssertEqual(first.threadID, thread.summary.id)
        XCTAssertTrue(model.consumeComposerFocusRequest(first))
        XCTAssertFalse(model.consumeComposerFocusRequest(first), "each focus request is consumed once")
        model.requestComposerFocus(for: thread.summary.id)
        XCTAssertNotEqual(model.composerFocusRequest?.id, first.id)
        let staleSelection = try XCTUnwrap(model.composerFocusRequest)

        model.prepareAttachments(for: thread, composerWasFocused: true)
        model.select(otherID)
        XCTAssertNil(model.composerFocusRequest)
        XCTAssertFalse(model.consumeComposerFocusRequest(staleSelection))
        model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
        XCTAssertNil(model.composerFocusRequest, "dismissing a picker for another thread cannot steal focus")
        model.select(thread.summary.id)
        model.requestComposerFocus(for: thread.summary.id)
        let staleMount = try XCTUnwrap(model.composerFocusRequest)
        model.setComposerMounted(false, for: thread.summary.id)
        XCTAssertFalse(model.consumeComposerFocusRequest(staleMount))
        model.requestComposerFocus(for: thread.summary.id)
        XCTAssertNil(model.composerFocusRequest)
    }

    func testUploadCompletionPreservesOtherTextInputsAndListFocus() async throws {
        for focus in [AgentCenterV2PresentationModel.KeyboardFocus.search, .promptAnswer, .list] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let thread = try XCTUnwrap(model.selectedThread)
            let target = AgentComposerAttachments.Target(threadID: thread.summary.id,
                binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
            var completion: CheckedContinuation<String, Error>?
            let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in true }, upload: { _, _ in
                try await withCheckedThrowingContinuation { completion = $0 }
            })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("upload-search-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { service.cancelAll(); try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("file.txt")
            try Data("attachment".utf8).write(to: file)
            model.setComposerMounted(true, for: thread.summary.id)
            model.prepareAttachments(for: thread, composerWasFocused: true)
            let request = try XCTUnwrap(model.attachmentPickerRequest)
            model.completeAttachments(request, urls: [file])
            let started = await waitUntil { completion != nil }
            XCTAssertTrue(started)
            model.attachmentPickerDidDismiss(hardwareKeyboardConnected: true)
            let dismissalFocus = try XCTUnwrap(model.composerFocusRequest)
            XCTAssertTrue(model.consumeComposerFocusRequest(dismissalFocus))
            // The search field reports its focus the way the list view does.
            if focus == .search { model.requestSearchFocus() }
            model.keyboardFocus = focus
            completion?.resume(returning: "/tmp/file.txt")
            let finished = await waitUntil { model.uploadingThreads.isEmpty }
            XCTAssertTrue(finished)
            XCTAssertEqual(model.keyboardFocus, focus)
            XCTAssertNil(model.composerFocusRequest)
            XCTAssertTrue(model.draftBinding(for: thread.summary.id).contains("/tmp/file.txt"))
        }
    }

    func testSearchRevokesAnUnconsumedComposerFocusRequest() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        model.setComposerMounted(true, for: thread.summary.id)
        model.requestComposerFocus(for: thread.summary.id)
        let pending = try XCTUnwrap(model.composerFocusRequest)
        model.requestSearchFocus()
        XCTAssertNotEqual(model.keyboardFocus, .search, "only the mounted field reports search focus")
        XCTAssertNil(model.composerFocusRequest)
        XCTAssertFalse(model.consumeComposerFocusRequest(pending))
    }

    func testAttachmentFocusRestorationUsesCapturedFocusOrCurrentHardwareKeyboard() throws {
        for source in [AgentCenterV2PresentationModel.AttachmentPickerRequest.Source.file, .photo] {
            for focused in [false, true] {
                for hardware in [false, true] {
                    let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
                    let thread = try XCTUnwrap(model.selectedThread)
                    model.setComposerMounted(true, for: thread.summary.id)
                    model.keyboardFocus = focused ? .composer : .none
                    model.onPrepareAttachments = { _ in .init(id: UUID(), threadID: thread.summary.id) }
                    model.prepareAttachments(for: thread, source: source)
                    let request = try XCTUnwrap(model.attachmentPickerRequest)
                    XCTAssertEqual(request.source, source)
                    XCTAssertEqual(request.composerWasFocused, focused)
                    model.keyboardFocus = .none
                    model.completeAttachments(request, urls: [])
                    XCTAssertNil(model.composerFocusRequest)
                    model.attachmentPickerDidDismiss(hardwareKeyboardConnected: hardware)
                    XCTAssertEqual(model.composerFocusRequest != nil, focused || hardware)
                    if let focus = model.composerFocusRequest { XCTAssertTrue(model.consumeComposerFocusRequest(focus)) }
                    // The upload completion uses the same captured rule after dismissal.
                    model.restoreComposerFocus(after: request, hardwareKeyboardConnected: hardware)
                    XCTAssertEqual(model.composerFocusRequest != nil, focused || hardware)
                }
            }
        }
    }

    func testPhotoLoadFailureReportsNoticeCleansPartialCopiesAndIgnoresFailureAfterReset() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let target = AgentComposerAttachments.Target(threadID: thread.summary.id,
            binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
        let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in true }, upload: { _, _ in
            XCTFail("failed photo loads must not upload a partial selection")
            return "/tmp/unexpected"
        })
        defer { service.cancelAll() }
        model.prepareAttachments(for: thread, source: .photo)
        let failed = try XCTUnwrap(model.attachmentPickerRequest)
        try FileManager.default.createDirectory(at: failed.photoDirectory, withIntermediateDirectories: true)
        try Data("partial copy".utf8).write(to: failed.photoDirectory.appendingPathComponent("photo.png"))
        XCTAssertTrue(model.beginLoadingAttachmentPhotos(failed))
        model.failPhotoAttachments(failed, error: AgentAttachmentPhotos.failure())
        XCTAssertTrue(model.capabilityNotice?.contains("Photo attachment failed") == true)
        XCTAssertFalse(model.loadingAttachmentPhotos)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.photoDirectory.path))
        model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)

        model.prepareAttachments(for: thread, source: .photo)
        let stale = try XCTUnwrap(model.attachmentPickerRequest)
        model.clearForExperimentDisable()
        XCTAssertFalse(model.beginLoadingAttachmentPhotos(stale))
        model.failPhotoAttachments(stale, error: AgentAttachmentPhotos.failure())
        XCTAssertNil(model.capabilityNotice)
        model.prepareAttachments(for: thread, source: .photo)
        let current = try XCTUnwrap(model.attachmentPickerRequest)
        model.failPhotoAttachments(stale, error: AgentAttachmentPhotos.failure())
        XCTAssertEqual(model.attachmentPickerRequest?.id, current.id)
        XCTAssertNil(model.capabilityNotice)
    }

    func testPhotoCopiesPreserveSupportedBytesAndTranscodeTIFFWithOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-conversion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for type in [UTType.png, .jpeg, .gif, .tiff] {
            let fileExtension = try XCTUnwrap(type.preferredFilenameExtension)
            let input = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            let copy = try AgentAttachmentPhotos.copyImage(at: input, suggestedName: "Screenshot.heic", to: directory.appendingPathComponent("copies"))
            XCTAssertEqual(copy.deletingPathExtension().lastPathComponent, "Screenshot")
            if type == .tiff {
                XCTAssertEqual(copy.pathExtension, "jpg")
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
            } else {
                XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: input))
                XCTAssertEqual(copy.pathExtension, type == .jpeg ? "jpg" : fileExtension)
            }
        }
        let invalid = directory.appendingPathComponent("invalid.heic")
        try Data("invalid image".utf8).write(to: invalid)
        XCTAssertThrowsError(try AgentAttachmentPhotos.copyImage(at: invalid, suggestedName: nil, to: directory.appendingPathComponent("invalid")))
    }

    private final class PhotoProviderProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: AgentAttachmentPhotoLoad.Completion?
        let progress = Progress(totalUnitCount: 1)

        var started: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completion != nil
        }

        func start(_ completion: @escaping AgentAttachmentPhotoLoad.Completion) -> Progress {
            lock.lock()
            self.completion = completion
            lock.unlock()
            return progress
        }

        func finish(url: URL) {
            lock.lock()
            let callback = completion
            lock.unlock()
            callback?(url, nil)
        }
    }

    func testPhotoLoadingCancelDismissAndResetCancelProgressAndRejectLateCopies() async throws {
        for exit in ["cancel", "swipe", "reset"] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let thread = try XCTUnwrap(model.selectedThread)
            model.setComposerMounted(true, for: thread.summary.id)
            model.onPrepareAttachments = { _ in .init(id: UUID(), threadID: thread.summary.id) }
            var completedURLs: [URL]?
            model.onCompleteAttachments = { _, urls in completedURLs = urls }
            model.prepareAttachments(for: thread, source: .photo, composerWasFocused: true)
            let request = try XCTUnwrap(model.attachmentPickerRequest)
            let load = AgentAttachmentPhotoLoad(directory: request.photoDirectory)
            let provider = PhotoProviderProbe()
            var finished = false
            let task = Task { @MainActor in
                defer { finished = true }
                do {
                    _ = try await load.loadFile(suggestedName: "late.png", start: provider.start)
                    XCTFail("cancelled provider must not return an attachment")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
            defer { task.cancel(); load.cancel() }
            XCTAssertTrue(model.beginLoadingAttachmentPhotos(request, onCancel: { task.cancel(); load.cancel() }))
            let started = await waitUntil { provider.started }
            XCTAssertTrue(started)
            // Simulate a previously loaded photo in the same multi-selection.
            try FileManager.default.createDirectory(at: request.photoDirectory, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: request.photoDirectory.appendingPathComponent("first.png"))
            switch exit {
            case "cancel": model.cancelLoadingAttachmentPhotos()
            case "swipe": model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
            default: model.clearForExperimentDisable()
            }
            let cancelled = await waitUntil { finished && provider.progress.isCancelled }
            XCTAssertTrue(cancelled, "cancellation must finish even if the provider never calls back")
            XCTAssertTrue(provider.progress.isCancelled)
            XCTAssertNil(model.attachmentPickerRequest)
            XCTAssertFalse(model.loadingAttachmentPhotos)
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.photoDirectory.path))
            if exit != "reset" {
                XCTAssertEqual(completedURLs, [])
                model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
                XCTAssertEqual(model.composerFocusRequest?.threadID, thread.summary.id)
            }
            XCTAssertNil(model.capabilityNotice)
            // A valid late photo would recreate its copy directory without the fence.
            let input = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID()).png")
            defer { try? FileManager.default.removeItem(at: input) }
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            provider.finish(url: input)
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.photoDirectory.path))
            XCTAssertNil(model.capabilityNotice)
        }
    }

    func testPhotoTaskCancellationBeforeProviderReturnsProgressCancelsThatProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-progress-\(UUID())")
        let load = AgentAttachmentPhotoLoad(directory: directory)
        defer { load.cancel() }
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            try await load.loadFile(suggestedName: nil) { _ in
                // Cancellation can race with loadFileRepresentation returning its handle.
                load.cancel()
                return progress
            }
        }
        do { _ = try await task.value; XCTFail("cancelled load must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(progress.isCancelled)
    }

    func testPhotoCopiesAreRemovedAfterUploadSuccessFailureAndStaleSelection() async throws {
        for outcome in ["success", "failure", "stale", "cancelled"] {
            let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
            let thread = try XCTUnwrap(model.selectedThread)
            let target = AgentComposerAttachments.Target(threadID: thread.summary.id,
                binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
            var current = true
            var completion: CheckedContinuation<String, Error>?
            let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in current }, upload: { _, _ in
                try await withCheckedThrowingContinuation { completion = $0 }
            })
            defer { service.cancelAll() }
            model.prepareAttachments(for: thread, source: .photo, composerWasFocused: false)
            let request = try XCTUnwrap(model.attachmentPickerRequest)
            defer { try? FileManager.default.removeItem(at: request.photoDirectory) }
            try FileManager.default.createDirectory(at: request.photoDirectory, withIntermediateDirectories: true)
            let file = request.photoDirectory.appendingPathComponent("photo.png")
            try Data("photo fixture".utf8).write(to: file)
            if outcome == "stale" { current = false }
            model.completeAttachments(request, urls: [file])
            if outcome != "stale" {
                let started = await waitUntil { completion != nil }
                XCTAssertTrue(started)
                model.attachmentPickerDidDismiss(hardwareKeyboardConnected: false)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "dismissal must not remove an active upload's source")
                if outcome == "cancelled" { service.cancelAll() }
                if outcome == "failure" {
                    completion?.resume(throwing: AgentAttachmentPhotos.failure())
                } else { completion?.resume(returning: "/tmp/photo.png") }
                let cleaned = await waitUntil { !FileManager.default.fileExists(atPath: request.photoDirectory.path) }
                XCTAssertTrue(cleaned)
                XCTAssertEqual(model.draftBinding(for: thread.summary.id).contains("/tmp/photo.png"), outcome == "success")
                if outcome == "failure" { XCTAssertTrue(model.capabilityNotice?.contains("File upload failed") == true) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.photoDirectory.path))
        }
    }

    func testAttachmentsRejectStalePickerAndUploadCompletionsAndCleanUpOnDisable() async throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let target = AgentComposerAttachments.Target(threadID: thread.summary.id, binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
        var current = true
        var complete: CheckedContinuation<String, Error>?
        var stagedURL: URL?
        let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in current }, upload: { _, url in
            stagedURL = url
            return try await withCheckedThrowingContinuation { complete = $0 }
        })
        defer { service.cancelAll() }
        model.setDraft("preserve", for: thread.summary.id)
        model.prepareAttachments(for: thread)
        let stalePicker = try XCTUnwrap(model.attachmentPickerRequest)
        current = false
        model.completeAttachments(stalePicker, urls: [URL(fileURLWithPath: "/does-not-exist")])
        XCTAssertNil(stagedURL, "stale picker must be rejected before opening the local file")
        XCTAssertEqual(model.draftBinding(for: thread.summary.id), "preserve")
        current = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.txt")
        try Data("fixture".utf8).write(to: file)
        model.prepareAttachments(for: thread)
        model.completeAttachments(try XCTUnwrap(model.attachmentPickerRequest), urls: [file])
        let started = await waitUntil { complete != nil }
        XCTAssertTrue(started)
        current = false
        complete?.resume(returning: "/home/fixture/.cache/tessera/fixture.txt")
        let finished = await waitUntil { model.uploadingThreads.isEmpty }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.draftBinding(for: thread.summary.id), "preserve")
        XCTAssertTrue(model.capabilityNotice?.contains("no draft was changed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedURL).path))

        current = true
        complete = nil
        model.prepareAttachments(for: thread)
        let disabledPicker = try XCTUnwrap(model.attachmentPickerRequest)
        service.cancelAll()
        model.completeAttachments(disabledPicker, urls: [file])
        XCTAssertTrue(model.uploadingThreads.isEmpty)
        XCTAssertNil(complete, "a stale picker cannot resume after disable/re-enable")
    }

    func testDisabledAttachmentFailureCannotOverwriteNewPresentationNotice() async throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let target = AgentComposerAttachments.Target(threadID: thread.summary.id, binding: try XCTUnwrap(thread.binding), registrationID: UUID(), generation: 1)
        var current = true
        var completion: CheckedContinuation<String, Error>?
        var staged: URL?
        let service = AgentComposerAttachments(model: model, targetFor: { _ in target }, isCurrent: { _ in current }, upload: { _, url in
            staged = url
            return try await withCheckedThrowingContinuation { completion = $0 }
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); service.cancelAll() }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        model.prepareAttachments(for: thread)
        model.completeAttachments(try XCTUnwrap(model.attachmentPickerRequest), urls: [file])
        let started = await waitUntil { completion != nil }
        XCTAssertTrue(started)
        current = false
        service.cancelAll()
        model.capabilityNotice = "new generation notice"
        completion?.resume(throwing: CocoaError(.fileWriteUnknown))
        let cleaned = await waitUntil { staged.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(model.capabilityNotice, "new generation notice")
    }

    func testHelperUpdateCopyAndLiveReadinessDoNotRequireRelaunch() {
        let location = location(sessionID: UUID(), paneID: 7)
        let active = AgentCurrentIntegrationTarget(location: location, foreground: .agent,
            processIDs: [42], shellIntegrationActive: false, agentIntegrationActive: true,
            agentRequiresLifecycleHook: true)
        let updated = AgentIntegrationWarningState.resolved(installation: .outdated(version: 8), target: active)
        XCTAssertTrue(String(localized: updated.message).contains("without interrupting this agent"))
        XCTAssertTrue(String(localized: updated.message).contains("If lifecycle status remains unavailable"))
        let ready = AgentIntegrationWarningState.resolved(installation: .current, target: active)
        XCTAssertEqual(ready.kind, .ready)
        XCTAssertFalse(ready.showsWarning)
        let pending = AgentCurrentIntegrationTarget(location: location, foreground: .agent,
            processIDs: [42], shellIntegrationActive: false, agentIntegrationActive: false,
            agentRequiresLifecycleHook: true)
        let warning = AgentIntegrationWarningState.resolved(installation: .current, target: pending)
        XCTAssertEqual(String(localized: warning.title), "Agent lifecycle not yet confirmed")
        XCTAssertTrue(String(localized: warning.message).contains("If status remains unavailable"))
        let pendingUpdate = AgentIntegrationWarningState.resolved(installation: .outdated(version: 8), target: pending)
        XCTAssertTrue(String(localized: pendingUpdate.message).contains("If lifecycle status remains unavailable"))
    }

    func testSessionIntegrationForegroundUsesSharedKimiAndShellClassification() {
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "kimi",
                processNames: ["/usr/local/bin/kimi"]
            ),
            .agent
        )
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "pwsh",
                processNames: ["/opt/homebrew/bin/pwsh"]
            ),
            .unsupportedShell
        )
        XCTAssertEqual(
            AgentSessionSourceFactory.currentIntegrationForeground(
                currentCommand: "opencode",
                processNames: ["/usr/local/bin/opencode"]
            ),
            .agent
        )
        XCTAssertFalse(
            AgentIntegrationForegroundClassifier.classify(
                executables: ["/usr/local/bin/opencode"]
            ).requiresLifecycleHook,
            "Tier-C inventory providers must not produce lifecycle-hook repair warnings"
        )
    }

    func testRawSwipePadFocusIsRetainedAsARealLocation() {
        var focusBySession: [UUID: AgentCenterV2SwipePadFocus] = [:]
        let sessionID = UUID()

        focusBySession[sessionID] = .init(paneID: nil)

        XCTAssertEqual(focusBySession[sessionID], .raw)
        XCTAssertNil(focusBySession[sessionID]?.paneID)
        XCTAssertEqual(
            focusBySession[sessionID],
            AgentCenterV2SwipePadFocus(paneID: nil),
            "raw SSH/mosh focus must not be encoded as a Dictionary-removing nil"
        )
    }

    func testScopedDiscoveryRetiresOnlyAbsentRoutesInItsPane() {
        let sessionID = UUID()
        let scope = AgentCenterV2DiscoveryScope(sessionID: sessionID, paneID: 4)
        let locations = [
            "raw": location(sessionID: sessionID, paneID: nil),
            "pane-4": location(sessionID: sessionID, paneID: 4),
            "pane-5": location(sessionID: sessionID, paneID: 5),
            "other-session": location(sessionID: UUID(), paneID: 4),
        ]

        XCTAssertEqual(
            scope.absentRouteIDs(locations: locations, seenIDs: []),
            Set(["pane-4"]),
            "a pane refresh must never evict raw or sibling-pane routes"
        )
        XCTAssertTrue(
            scope.absentRouteIDs(locations: locations, seenIDs: ["pane-4"]).isEmpty
        )
    }

    func testReadPolicyAndTaskOwnershipFailClosedAcrossLifecycleChanges() {
        let activeTask = UUID()

        XCTAssertTrue(AgentCenterV2TaskOwnership.owns(
            currentTaskID: activeTask,
            taskID: activeTask
        ))
        XCTAssertFalse(AgentCenterV2TaskOwnership.owns(
            currentTaskID: UUID(),
            taskID: activeTask
        ))
        XCTAssertFalse(AgentCenterV2TaskOwnership.owns(
            currentTaskID: nil,
            taskID: activeTask
        ))
        XCTAssertTrue(AgentCenterV2ReadPolicy.allows(
            isEnabled: true,
            applicationActive: true,
            hasSurfaceDemand: true
        ))
        XCTAssertFalse(AgentCenterV2ReadPolicy.allows(
            isEnabled: true,
            applicationActive: false,
            hasSurfaceDemand: true
        ))
        XCTAssertFalse(AgentCenterV2ReadPolicy.allows(
            isEnabled: true,
            applicationActive: true,
            hasSurfaceDemand: false
        ))
    }

    func testExplicitLatestIntentWaitsForRefreshAndSupersedesHistory() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        coordinator.setSurfaceDemand(true)
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "latest-during-refresh")!
        coordinator.projectionTasks[id] = Task { try? await Task.sleep(for: .seconds(30)) }
        coordinator.pendingHistoryRequests.insert(id)
        coordinator.pendingProjectionRefreshes.insert(id)
        coordinator.requestNewerPage(id, latest: true)
        XCTAssertEqual(coordinator.pendingLatestRequests, [id])
        XCTAssertTrue(coordinator.pendingHistoryRequests.isEmpty)
        XCTAssertTrue(coordinator.pendingProjectionRefreshes.isEmpty)
        coordinator.requestNewerPage(id, latest: true)
        XCTAssertEqual(coordinator.pendingLatestRequests, [id], "Repeated taps coalesce, not extra remote reads")
        coordinator.setSurfaceDemand(false)
        XCTAssertTrue(coordinator.pendingLatestRequests.isEmpty)
    }

    func testCoalescedProjectionRefreshesAreClearedAtSurfaceBackgroundAndDisableBoundaries() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "pending-refresh")!
        coordinator.setSurfaceDemand(true)
        coordinator.pendingProjectionRefreshes.insert(id)
        coordinator.pendingLatestRequests.insert(id)
        coordinator.presentation.loadingTranscriptThreads.insert(id)
        coordinator.setSurfaceDemand(false)
        XCTAssertTrue(coordinator.pendingProjectionRefreshes.isEmpty)
        XCTAssertTrue(coordinator.pendingLatestRequests.isEmpty)
        XCTAssertTrue(coordinator.presentation.loadingTranscriptThreads.isEmpty)
        coordinator.pendingProjectionRefreshes.insert(id)
        coordinator.pendingLatestRequests.insert(id)
        coordinator.presentation.loadingTranscriptThreads.insert(id)
        await coordinator.setApplicationActive(false)
        XCTAssertTrue(coordinator.pendingProjectionRefreshes.isEmpty)
        XCTAssertTrue(coordinator.pendingLatestRequests.isEmpty)
        XCTAssertTrue(coordinator.presentation.loadingTranscriptThreads.isEmpty)
        coordinator.pendingProjectionRefreshes.insert(id)
        coordinator.pendingLatestRequests.insert(id)
        coordinator.presentation.loadingTranscriptThreads.insert(id)
        await coordinator.setExperimentEnabled(false)
        XCTAssertTrue(coordinator.pendingProjectionRefreshes.isEmpty)
        XCTAssertTrue(coordinator.pendingLatestRequests.isEmpty)
        XCTAssertTrue(coordinator.presentation.loadingTranscriptThreads.isEmpty)
    }

    func testRefreshQueueCoalescesGenericOutputAndKeepsNewestLifecyclePerPane() {
        var queue = AgentCenterV2SessionRefreshQueue()
        let older = lifecycleEvent(turnID: "older", timestampNanoseconds: 10)
        let newer = lifecycleEvent(turnID: "newer", timestampNanoseconds: 20)

        queue.enqueue(paneID: nil, lifecycle: nil)
        queue.enqueue(paneID: nil, lifecycle: nil)
        queue.enqueue(paneID: 4, lifecycle: older)
        queue.enqueue(paneID: 4, lifecycle: newer)
        queue.enqueue(paneID: 9, lifecycle: older)

        XCTAssertEqual(queue.dequeue()?.lifecycle, nil)
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "newer")
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "older")
        XCTAssertNil(queue.dequeue())
    }

    func testRefreshQueueRemainsFairAndBoundedUnderContinuousOutput() {
        var queue = AgentCenterV2SessionRefreshQueue()
        let event = lifecycleEvent(turnID: "latest", timestampNanoseconds: 20)
        queue.enqueue(paneID: nil, lifecycle: nil)
        for pane in 0..<200 { queue.enqueue(paneID: pane, lifecycle: event) }
        XCTAssertNil(queue.dequeue()?.lifecycle)
        queue.enqueue(paneID: nil, lifecycle: nil)
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "latest", "output must not starve lifecycle")
        XCTAssertNil(queue.dequeue()?.lifecycle, "lifecycle must not starve generic discovery")
        var remaining = 0
        while queue.dequeue() != nil { remaining += 1 }
        XCTAssertEqual(remaining, AgentCenterV2SessionRefreshQueue.maximumLifecycleScopes - 1)

        queue.enqueue(paneID: 4, lifecycle: event)
        queue.enqueue(paneID: 4, lifecycle: lifecycleEvent(turnID: "older", timestampNanoseconds: 10))
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "latest")
    }

    func testCodexStartedInANewQuietPaneAppearsAfterAnInitialOrFreshReadMiss() async {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            for missesReread in [false, true] {
                let harness = await ConversationPaneHarness(provider: "codex", transport: transport, pane: 7)
                harness.hidesPane = true
                let startupInspected = await waitUntil { harness.discoveries.count == 1 }
                XCTAssertTrue(startupInspected)
                XCTAssertTrue(harness.listedSessions.isEmpty)
                harness.hidesPane = false
                if missesReread {
                    harness.staleProcessIDs = [7]
                    harness.failNextProcessReadDiscovery = true
                } else {
                    harness.failNextDiscovery = true
                }
                // No more output or hooks follow this one announcement.
                harness.publish(event("codex", "SessionStart", .idle, session: "late", at: 100))
                let appeared = await waitUntil(attempts: 300) {
                    harness.coordinator.presentation.threadSnapshots[harness.threadID("late")]?.binding?.agentPID == 42
                }
                XCTAssertTrue(appeared, "\(transport), freshRead=\(missesReread)")
                await harness.close()
            }
        }
    }

    func testQuietSessionRetriesUnavailableDiscoveryWithoutAnotherOutputPulse() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        let registrationID = UUID()
        var discoveries = 0
        let source = AgentSessionSource(
            registrationID: registrationID, sessionID: sessionID,
            discover: {
                discoveries += 1
                return discoveries == 1 ? .unavailable : .success([])
            },
            observe: { _ in nil }, inspect: { _ in nil },
            send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let recovered = await waitUntil { discoveries == 2 }
        XCTAssertTrue(recovered, "A quiet newly-created pane must recover without another hook")
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: registrationID)
    }

    func testDiscoveryRetryDoesNotReplaceANewerQueuedLifecycle() {
        var queue = AgentCenterV2SessionRefreshQueue()
        let missed = lifecycleEvent(turnID: "missed", timestampNanoseconds: 20)
        queue.enqueue(paneID: 7, lifecycle: missed)
        let retry = queue.dequeue()!
        queue.enqueue(paneID: 7, lifecycle: lifecycleEvent(turnID: "new", timestampNanoseconds: 20))
        queue.requeueIfAbsent(retry)
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "new")
        XCTAssertTrue(queue.isEmpty)
    }

    func testRepeatedOutputDoesNotCancelSuspendedSessionDiscovery() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        let registrationID = UUID()
        var discoverCount = 0
        var firstDiscovery: CheckedContinuation<AgentDiscoveryResult, Never>?
        var firstDiscoveryWasCancelled = false
        let source = AgentSessionSource(
            registrationID: registrationID,
            sessionID: sessionID,
            discover: {
                discoverCount += 1
                guard discoverCount == 1 else { return .success([]) }
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<AgentDiscoveryResult, Never>) in
                    firstDiscovery = continuation
                }
                firstDiscoveryWasCancelled = Task.isCancelled
                return result
            },
            observe: { _ in nil },
            inspect: { _ in nil },
            send: { _, _ in false },
            jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let firstDiscoveryStarted = await waitUntil { firstDiscovery != nil }
        XCTAssertTrue(firstDiscoveryStarted)

        for _ in 0..<8 {
            coordinator.noteOutput(
                sessionID: sessionID,
                paneID: nil,
                registrationID: registrationID,
                data: Array("output".utf8)[...]
            )
        }
        firstDiscovery?.resume(returning: .success([]))
        firstDiscovery = nil

        // Generic output discovers on a floor, and with no surface open that
        // floor is a minute (`AgentCenterV2DiscoveryPolicy`). What this case is
        // about is that the burst left the queued work intact and the worker
        // alive — not how long the worker then waits — so spend the cooldown
        // rather than sleeping through it.
        XCTAssertNotNil(coordinator.sessionDiscoveryAfter[sessionID])
        coordinator.sessionDiscoveryAfter[sessionID] = .distantPast

        let followUpDiscoveryStarted = await waitUntil { discoverCount >= 2 }
        XCTAssertTrue(followUpDiscoveryStarted)
        XCTAssertFalse(firstDiscoveryWasCancelled)
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: registrationID)
    }

    /// Discovery keeps running with no surface open — that is how a background
    /// agent's waiting/finished transition is noticed, and why the mosh side
    /// channel is held for a connected tmux session. What must not keep running
    /// at surface rates is the cost: a pass is four remote commands and, on the
    /// reporter's device, 813 ms. V1 said so with a 2 s / 60 s `minimumInterval`
    /// (`AgentCenter.noteOutput`, `b0da44df^`); the V2 rewrite kept the
    /// unconditional discovery and dropped the rate half.
    func testAnUnattendedSessionDiscoversOnTheSlowFloorUntilASurfaceOpens() async throws {
        XCTAssertEqual(
            AgentCenterV2DiscoveryPolicy.genericDiscoveryInterval(hasSurfaceDemand: false),
            AgentCenterV2DiscoveryPolicy.unattendedInterval
        )
        XCTAssertEqual(
            AgentCenterV2DiscoveryPolicy.genericDiscoveryInterval(hasSurfaceDemand: true),
            AgentCenterV2DiscoveryPolicy.attendedInterval
        )
        XCTAssertGreaterThan(
            AgentCenterV2DiscoveryPolicy.unattendedInterval,
            AgentCenterV2DiscoveryPolicy.attendedInterval
        )

        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        let sessionID = UUID()
        let registrationID = UUID()
        var discoveries = 0
        let source = AgentSessionSource(
            registrationID: registrationID,
            sessionID: sessionID,
            discover: { discoveries += 1; return .success([]) },
            observe: { _ in nil }, inspect: { _ in nil },
            send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let firstDiscoveryRan = await waitUntil { discoveries >= 1 }
        XCTAssertTrue(firstDiscoveryRan)

        // Output keeps arriving with no surface open: the queue stays warm, the
        // remote bill does not repeat.
        for _ in 0..<20 {
            coordinator.noteOutput(
                sessionID: sessionID,
                paneID: nil,
                registrationID: registrationID,
                data: Array("output".utf8)[...]
            )
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(discoveries, 1, "a closed surface must not pay a discovery per second")
        let cooldown = try XCTUnwrap(coordinator.sessionDiscoveryAfter[sessionID])
        XCTAssertGreaterThan(
            cooldown.timeIntervalSinceNow,
            AgentCenterV2DiscoveryPolicy.attendedInterval,
            "the stored wait must be the unattended floor, not the surface one"
        )

        // Opening a surface is the moment that floor stops applying. Inheriting
        // its remainder would show the user a list up to a minute out of date.
        coordinator.setSurfaceDemand(true)
        XCTAssertNil(coordinator.sessionDiscoveryAfter[sessionID])
        let attendedDiscoveryRan = await waitUntil { discoveries >= 2 }
        XCTAssertTrue(attendedDiscoveryRan)

        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: registrationID)
        await coordinator.setExperimentEnabled(false)
    }

    func testInventoryRouteIdentityIsIndependentOfSharedHistoryCursor() {
        let carrier = binding(capabilities: [], agentPID: nil)
        let source = AgentSessionSource(
            registrationID: UUID(), sessionID: carrier.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil },
            inspect: { _ in nil }, send: { _, _ in false }, jump: { _ in }
        )
        let route = AppleAgentProjectionRoute(
            transcriptRef: "verified-source", providerID: .pi,
            binding: carrier, source: source
        )
        XCTAssertTrue(route.matchesInventorySource(transcriptRef: "verified-source", binding: carrier, registrationID: source.registrationID))
        XCTAssertFalse(route.matchesInventorySource(transcriptRef: "replacement", binding: carrier, registrationID: source.registrationID))
        XCTAssertFalse(route.matchesInventorySource(transcriptRef: "verified-source", binding: carrier, registrationID: UUID()))
        XCTAssertFalse(route.matchesInventorySource(transcriptRef: "verified-source", binding: binding(capabilities: [], agentPID: nil), registrationID: source.registrationID))
    }

    func testDisableUnregisterAndReplacementInvalidateSuspendedRefreshWorker() async {
        let coordinator = AgentCenterV2Coordinator()
        await coordinator.setExperimentEnabled(true)

        let disabledSession = UUID()
        let disabledRegistration = UUID()
        var disabledWait: CheckedContinuation<AgentDiscoveryResult, Never>?
        var disabledWasCancelled = false
        let disabledSource = AgentSessionSource(
            registrationID: disabledRegistration,
            sessionID: disabledSession,
            discover: {
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<AgentDiscoveryResult, Never>) in
                    disabledWait = continuation
                }
                disabledWasCancelled = Task.isCancelled
                return result
            },
            observe: { _ in nil }, inspect: { _ in nil }, send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(disabledSource, hostID: UUID(), profiles: { [] })
        let disabledDiscoveryStarted = await waitUntil { disabledWait != nil }
        XCTAssertTrue(disabledDiscoveryStarted)
        await coordinator.setExperimentEnabled(false)
        disabledWait?.resume(returning: .success([]))
        disabledWait = nil
        let disabledWorkerCancelled = await waitUntil { disabledWasCancelled }
        XCTAssertTrue(disabledWorkerCancelled)
        XCTAssertNil(coordinator.sessionRefreshTasks[disabledSession])
        XCTAssertNil(coordinator.sessionRefreshQueues[disabledSession])

        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        let firstRegistration = UUID()
        var firstWait: CheckedContinuation<AgentDiscoveryResult, Never>?
        var firstWasCancelled = false
        let firstSource = AgentSessionSource(
            registrationID: firstRegistration,
            sessionID: sessionID,
            discover: {
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<AgentDiscoveryResult, Never>) in
                    firstWait = continuation
                }
                firstWasCancelled = Task.isCancelled
                return result
            },
            observe: { _ in nil }, inspect: { _ in nil }, send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(firstSource, hostID: UUID(), profiles: { [] })
        let unregisterDiscoveryStarted = await waitUntil { firstWait != nil }
        XCTAssertTrue(unregisterDiscoveryStarted)
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: firstRegistration)
        firstWait?.resume(returning: .success([]))
        firstWait = nil
        let unregisterWorkerCancelled = await waitUntil { firstWasCancelled }
        XCTAssertTrue(unregisterWorkerCancelled)
        XCTAssertNil(coordinator.sessionRefreshTasks[sessionID])

        let oldRegistration = UUID()
        var oldWait: CheckedContinuation<AgentDiscoveryResult, Never>?
        var oldWasCancelled = false
        let oldSource = AgentSessionSource(
            registrationID: oldRegistration,
            sessionID: sessionID,
            discover: {
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<AgentDiscoveryResult, Never>) in
                    oldWait = continuation
                }
                oldWasCancelled = Task.isCancelled
                return result
            },
            observe: { _ in nil }, inspect: { _ in nil }, send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(oldSource, hostID: UUID(), profiles: { [] })
        let replacementDiscoveryStarted = await waitUntil { oldWait != nil }
        XCTAssertTrue(replacementDiscoveryStarted)
        let replacement = AgentSessionSource(
            registrationID: UUID(),
            sessionID: sessionID,
            discover: { .success([]) },
            observe: { _ in nil }, inspect: { _ in nil }, send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(replacement, hostID: UUID(), profiles: { [] })
        oldWait?.resume(returning: .success([]))
        oldWait = nil
        let replacementWorkerCancelled = await waitUntil { oldWasCancelled }
        XCTAssertTrue(replacementWorkerCancelled)
        let replacementWorkerFinished = await waitUntil { coordinator.sessionRefreshIsIdle(sessionID) }
        XCTAssertTrue(replacementWorkerFinished)
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: replacement.registrationID)
    }

    func testCandidateAnswerRequiresPIDProvenPromptCapability() {
        let noPID = binding(capabilities: [.observe, .promptAnswer], agentPID: nil)
        let noCapability = binding(capabilities: [.observe], agentPID: 31)
        let actionable = binding(capabilities: [.observe, .promptAnswer], agentPID: 31)

        XCTAssertFalse(AgentCenterV2CandidateActionPolicy.canAnswer(noPID))
        XCTAssertFalse(AgentCenterV2CandidateActionPolicy.canAnswer(noCapability))
        XCTAssertTrue(AgentCenterV2CandidateActionPolicy.canAnswer(actionable))
    }

    func testPostGateKimiOSCLifecycleUsesSharedHookCapabilityAndExactProof() throws {
        let json = #"{"version":9,"provider":"kimi","event":"PreToolUse","state":"working","timestampNs":"1000000000","sessionId":"kimi-session","turnId":"kimi-turn","agentPid":4242,"transcriptRef":"b3BhcXVlX3JlZg"}"#
        let osc = "\u{1B}]1337;TesseraAgentState=\(Data(json.utf8).base64EncodedString())\u{07}"
        var scanner = AgentLifecycleOSCScanner()

        let events = scanner.feed(Array(osc.utf8)[...])
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.provider, "kimi")
        XCTAssertEqual(event.version, 9)
        XCTAssertEqual(event.state, .working)

        let conformance = try XCTUnwrap(AgentKimiWireAdapter.liveConformance(
            sessionIndexPassed: true,
            hookConfigurationPassed: true
        ))
        let registry = AgentProviderCapabilityGate().hardenedRegistry(
            requested: AgentProviderRegistry.builtIn.allManifests,
            conformances: [conformance]
        )
        XCTAssertEqual(registry.manifest(for: .kimi)?.lifecycle, .hooks(version: 9))

        let sessionID = UUID()
        let binding = AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("kimi-lifecycle-test")!,
            transport: .ssh,
            agentPID: 4242,
            capabilities: [.observe, .send, .interrupt]
        )
        let envelope = try XCTUnwrap(AgentLifecycleEnvelope(
            version: event.version,
            providerID: .kimi,
            event: .preToolUse,
            status: .working,
            providerSessionID: event.providerSessionID,
            agentPID: event.agentPID,
            transcriptRef: event.transcriptRef
        ))
        let proof = AgentLifecycleBindingProof(
            hostID: UUID(),
            binding: binding,
            sourceIdentity: "kimi-live-source",
            processIDs: [4242]
        )
        let validator = AgentLifecycleValidator(registry: registry)
        XCTAssertEqual(
            validator.validate(
                envelope,
                proof: proof,
                expectedBinding: binding,
                expectedSourceIdentity: "kimi-live-source"
            ),
            .accepted(threadID: AgentThreadID(
                hostID: proof.hostID,
                providerID: .kimi,
                providerSessionID: "kimi-session"
            ))
        )

        let wrongPID = try XCTUnwrap(AgentLifecycleEnvelope(
            version: 9,
            providerID: .kimi,
            event: .preToolUse,
            status: .working,
            providerSessionID: "kimi-session",
            agentPID: 9999,
            transcriptRef: "b3BhcXVlX3JlZg"
        ))
        XCTAssertEqual(
            validator.validate(
                wrongPID,
                proof: proof,
                expectedBinding: binding,
                expectedSourceIdentity: "kimi-live-source"
            ),
            .rejected(.pidMismatch)
        )
    }

    func testReadCarrierPreservesAllFourTransportKinds() {
        XCTAssertEqual(AgentSessionSourceFactory.readCarrierTransport(baseTransportLabel: "ssh", usesTmux: false), .ssh)
        XCTAssertEqual(AgentSessionSourceFactory.readCarrierTransport(baseTransportLabel: "ssh", usesTmux: true), .sshTmux)
        XCTAssertEqual(AgentSessionSourceFactory.readCarrierTransport(baseTransportLabel: "mosh", usesTmux: false), .mosh)
        XCTAssertEqual(AgentSessionSourceFactory.readCarrierTransport(baseTransportLabel: "mosh", usesTmux: true), .moshTmux)
    }

    func testVerifiedNarrowNotificationNavigationIsConsumedOnlyByThatThread() {
        let model = AgentCenterV2PresentationModel()
        let target = makeThreadID()
        model.requestNarrowThreadNavigation(target)

        model.consumeNarrowThreadNavigation(AgentThreadID(
            hostID: UUID(), providerID: .claude, providerSessionID: "other"
        )!)
        XCTAssertEqual(model.pendingNarrowThreadNavigation, target)
        model.consumeNarrowThreadNavigation(target)
        XCTAssertNil(model.pendingNarrowThreadNavigation)
        XCTAssertEqual(model.selectedThreadID, target)
    }

    func testActivitySystemEventVisibilityIsQuietByDefaultAndRestorable() {
        let system = AgentActivityEvent(
            id: "system",
            sequence: 1,
            kind: .system,
            title: "background synchronization"
        )
        let message = AgentActivityEvent(
            id: "message",
            sequence: 2,
            kind: .message,
            title: "checked"
        )
        let model = AgentCenterV2PresentationModel()

        XCTAssertEqual(model.displayedActivityEvents(from: [system, message]), [message])
        model.setShowSystemEvents(true)
        XCTAssertEqual(model.displayedActivityEvents(from: [system, message]), [system, message])
    }

    func testSearchFocusNeverEnablesListNavigationShortcuts() {
        let model = AgentCenterV2PresentationModel()

        model.keyboardFocus = .search
        XCTAssertFalse(model.allowsListNavigationShortcuts)

        model.keyboardFocus = .list
        XCTAssertTrue(model.allowsListNavigationShortcuts)
    }

    func testCompactPopDisablesPromptDigitsAndActionFocusDespiteRetainedSelection() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .primary)
        let waiting = try XCTUnwrap(model.selectedThread)
        var answers = 0
        model.onAction = { if case .answer = $0 { answers += 1 } }
        model.keyboardFocus = .none
        XCTAssertFalse(model.allowsPromptDigitShortcuts, "an unmounted detail is not visible")
        model.setThreadDetailVisible(true) // Compact push or a wide detail.
        XCTAssertEqual(model.keyboardFocus, .action)
        XCTAssertTrue(model.allowsPromptDigitShortcuts)
        model.setThreadDetailVisible(false) // Compact Back; selection remains.
        XCTAssertEqual(model.selectedThreadID, waiting.summary.id)
        XCTAssertEqual(model.keyboardFocus, .none)
        model.apply(thread: waiting) // A publish must not re-arm Escape.
        XCTAssertEqual(model.keyboardFocus, .none)
        XCTAssertFalse(model.allowsPromptDigitShortcuts)
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 0)
        model.keyboardFocus = .list
        XCTAssertTrue(model.allowsListNavigationShortcuts)
        XCTAssertFalse(model.allowsPromptDigitShortcuts)
        model.setThreadDetailVisible(true)
        XCTAssertEqual(model.keyboardFocus, .list)
        XCTAssertTrue(model.allowsListNavigationShortcuts)
        XCTAssertTrue(model.allowsPromptDigitShortcuts)
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 1)
    }

    func testPromptShortcutsRequireTheSameAttentionAsRenderedInlineOptions() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .primary)
        let waiting = try XCTUnwrap(model.selectedThread)
        model.setThreadDetailVisible(true)
        var answers = 0
        model.onAction = { if case .answer = $0 { answers += 1 } }
        for attention in [AgentAttention.none, .unreadCompletion] {
            var summary = waiting.summary
            summary.attention = attention
            model.apply(thread: .init(summary: summary, messages: waiting.messages, cursor: nil, hasMore: false, binding: waiting.binding))
            XCTAssertFalse(AgentCenterV2PresentationModel.rendersInlinePromptOptions(for: summary))
            XCTAssertFalse(model.allowsPromptDigitShortcuts)
            XCTAssertEqual(model.keyboardFocus, .none)
            model.answerPromptOption(0)
        }
        XCTAssertEqual(answers, 0)
        model.apply(thread: waiting)
        XCTAssertTrue(model.allowsPromptDigitShortcuts)
        XCTAssertEqual(model.keyboardFocus, .action)
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 1)
    }

    func testPromptDigitsRemainAvailableAfterListSelectionAndStopWhenPromptResolves() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .primary)
        model.setThreadDetailVisible(true)
        let waiting = try XCTUnwrap(model.selectedThread)
        let other = try XCTUnwrap(model.listSnapshot.threads.first { $0.id != waiting.summary.id })
        model.select(other.id)
        model.keyboardFocus = .list
        model.select(waiting.summary.id)
        XCTAssertEqual(model.keyboardFocus, .list)
        XCTAssertTrue(model.allowsListNavigationShortcuts)
        XCTAssertTrue(model.allowsPromptDigitShortcuts)
        var answers = 0
        model.onAction = { if case .answer(let id, _, _) = $0 { XCTAssertEqual(id, waiting.summary.id); answers += 1 } }
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 1)

        model.apply(thread: .init(summary: waiting.summary, messages: [], cursor: nil, hasMore: false, binding: waiting.binding))
        XCTAssertFalse(model.allowsPromptDigitShortcuts)
        XCTAssertTrue(model.allowsListNavigationShortcuts)
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 1)
    }

    func testArrivingAndChangingPromptsUpdateFocusWithoutStealingTextOrListFocus() throws {
        for focus in [AgentCenterV2PresentationModel.KeyboardFocus.none, .list, .composer, .search, .promptAnswer] {
            let model = AgentCenterV2Fixture.makeModel(scene: .primary)
            model.setThreadDetailVisible(true)
            let waiting = try XCTUnwrap(model.selectedThread)
            let empty = AgentThreadSnapshot(summary: waiting.summary, messages: [], cursor: nil, hasMore: false, binding: waiting.binding)
            model.apply(thread: empty)
            model.keyboardFocus = focus
            XCTAssertFalse(model.allowsPromptDigitShortcuts)
            model.apply(thread: waiting)
            let expected: AgentCenterV2PresentationModel.KeyboardFocus = focus == .none ? .action : focus
            XCTAssertEqual(model.keyboardFocus, expected)
            let textInput = focus == .composer || focus == .search || focus == .promptAnswer
            XCTAssertEqual(model.allowsPromptDigitShortcuts, !textInput)

            let prompt = AgentCenterV2Fixture.PromptVariant.review.prompt
            model.apply(thread: .init(summary: waiting.summary, messages: [
                .init(recordID: "replacement-prompt", role: .assistant, displayTime: nil, blocks: [.actionPrompt(prompt)])
            ], cursor: nil, hasMore: false, binding: waiting.binding))
            XCTAssertEqual(model.keyboardFocus, expected)
            var answeredToken: AgentActionToken?
            model.onAction = { if case .answer(_, let token, _) = $0 { answeredToken = token } }
            if model.allowsPromptDigitShortcuts { model.answerPromptOption(0) }
            XCTAssertEqual(answeredToken, textInput ? nil : prompt.token)
            model.apply(thread: empty)
            XCTAssertFalse(model.allowsPromptDigitShortcuts)
            XCTAssertEqual(model.keyboardFocus, focus)
        }
    }

    func testPromptDigitsRequireActionAvailabilityPromptCapabilityAndNoAnswerInFlight() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .primary)
        model.setThreadDetailVisible(true)
        let waiting = try XCTUnwrap(model.selectedThread)
        model.keyboardFocus = .list
        var answers = 0
        model.onAction = { if case .answer = $0 { answers += 1 } }
        var unavailable = waiting.summary
        unavailable.availability.actions = false
        let observeOnly = binding(capabilities: [.observe], agentPID: 42)
        for thread in [
            AgentThreadSnapshot(summary: unavailable, messages: waiting.messages, cursor: nil, hasMore: false, binding: waiting.binding),
            AgentThreadSnapshot(summary: waiting.summary, messages: waiting.messages, cursor: nil, hasMore: false, binding: nil),
            AgentThreadSnapshot(summary: waiting.summary, messages: waiting.messages, cursor: nil, hasMore: false, binding: observeOnly),
        ] {
            model.apply(thread: thread)
            XCTAssertFalse(model.allowsPromptDigitShortcuts)
            model.answerPromptOption(0)
        }
        model.apply(thread: waiting)
        model.answeringPromptThreads.insert(waiting.summary.id)
        XCTAssertFalse(model.allowsPromptDigitShortcuts)
        model.answerPromptOption(0)
        XCTAssertEqual(answers, 0)
        model.answeringPromptThreads.remove(waiting.summary.id)
        XCTAssertTrue(model.allowsPromptDigitShortcuts)
    }

    /// A reader on the conversation `/clear` replaced follows its pane to the
    /// conversation Core names as its successor, not to whichever row happens
    /// to be first: whether or not the replaced one could still show content,
    /// and whether the successor's snapshot and row have landed yet (a list
    /// read before the removal, or a search that hides the new row).
    func testReaderOfAReplacedConversationFollowsItsPane() {
        for content in [true, false] {
            for successorLanded in [true, false] {
                let label = "content \(content), successor landed \(successorLanded)"
                let model = AgentCenterV2PresentationModel()
                let hostID = UUID()
                func id(_ session: String) -> AgentThreadID {
                    AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: session)!
                }
                func pane(_ paneID: String, pid: Int) -> AgentTerminalBinding {
                    AgentTerminalBinding(liveSessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, carrierGeneration: 1,
                        incarnation: AgentIncarnationToken("pane-\(paneID)")!, transport: .sshTmux, tmuxSession: "work",
                        windowID: "@1", paneID: paneID, agentPID: pid, capabilities: [.observe, .send, .tmux])
                }
                func snapshot(_ session: String, _ binding: AgentTerminalBinding) -> AgentThreadSnapshot {
                    .init(summary: AgentThreadSummary(id: id(session), providerName: "Claude Code",
                        availability: .init(content: content, status: true, actions: true, spawn: false, fork: false, search: true)),
                        messages: [], cursor: nil, hasMore: false, binding: binding)
                }
                let old = snapshot("old", pane("%2", pid: 42)), other = snapshot("other", pane("%3", pid: 43))
                model.apply(list: .init(threads: [other.summary, old.summary]), changed: [other, old], removed: [])
                model.select(id("old"))
                // Core lists the other pane's conversation first.
                let new = snapshot("new", pane("%2", pid: 42))
                model.apply(list: .init(threads: successorLanded ? [other.summary, new.summary] : [other.summary, old.summary]),
                            changed: successorLanded ? [new] : [], removed: [id("old")], successors: [id("old"): id("new")])
                XCTAssertEqual(model.selectedThreadID, id("new"), label)
                XCTAssertNil(model.threadSnapshots[id("old")], label)
                model.apply(list: .init(threads: [other.summary, new.summary]), changed: [new], removed: [])
                XCTAssertEqual(model.selectedThreadID, id("new"), label)
                // `/clear` twice between publishes.
                model.apply(list: .init(threads: [other.summary]), changed: [], removed: [id("new")],
                            successors: [id("new"): id("newer"), id("newer"): id("newest")])
                XCTAssertEqual(model.selectedThreadID, id("newest"), label)
                // A conversation dropped with no successor leaves its reader on
                // the first row that remains.
                let last = snapshot("newest", pane("%2", pid: 42))
                model.apply(list: .init(threads: [last.summary, other.summary]), changed: [last], removed: [])
                model.apply(list: .init(threads: [last.summary, other.summary]), changed: [], removed: [id("newest")])
                XCTAssertEqual(model.selectedThreadID, id("other"), label)
                // A reader of another conversation stays where they are.
                model.apply(list: .init(threads: [other.summary, new.summary]), changed: [new], removed: [])
                model.select(id("other"))
                model.apply(list: .init(threads: [other.summary]), changed: [], removed: [id("new")],
                            successors: [id("new"): id("newer")])
                XCTAssertEqual(model.selectedThreadID, id("other"), label)
            }
        }
    }

    func testHistoricalSearchSelectionSurvivesLiveOnlyListRefresh() {
        let model = AgentCenterV2PresentationModel()
        let historical = makeThreadID()
        let summary = AgentThreadSummary(
            id: historical, providerName: "Claude Code",
            availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: true)
        )
        model.apply(thread: .init(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil))
        model.select(historical)
        model.apply(list: .init(threads: []))
        XCTAssertEqual(model.selectedThreadID, historical)

        var revoked = summary
        revoked.availability.content = false
        model.apply(thread: .init(summary: revoked, messages: [], cursor: nil, hasMore: false, binding: nil))
        model.apply(list: .init(threads: []))
        XCTAssertNil(model.selectedThreadID)
    }

    func testColdNotificationRetryPausesWhileInactiveButKeepsRouteEligibleForForeground() async {
        XCTAssertFalse(
            AgentCenterV2NotificationRetryPolicy.shouldRun(
                isEnabled: true,
                applicationActive: false,
                hasPendingRoute: true,
                hasSessionSource: true
            )
        )
        XCTAssertTrue(
            AgentCenterV2NotificationRetryPolicy.shouldRun(
                isEnabled: true,
                applicationActive: true,
                hasPendingRoute: true,
                hasSessionSource: true
            )
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCenterV2NotificationRetryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(
            metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json"))
        )
        let route = AppleAgentNotificationRoute(
            token: .init(rawValue: UUID()),
            generation: 7
        )
        coordinator.pendingNotificationRoutes = [route]
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(false)
        XCTAssertEqual(
            coordinator.pendingNotificationRoutes,
            [route],
            "backgrounding must pause work without dropping the opaque cold route"
        )
    }

    func testDisablePurgesDurableMetadataAndPresentationState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCenterV2CoordinatorTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("metadata.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadata = AppleAgentMetadataRepository(fileURL: fileURL)
        let coordinator = AgentCenterV2Coordinator(metadata: metadata)
        let threadID = makeThreadID()
        try await metadata.save(.init(threadID: threadID, pinnedTitle: "metadata only"))

        await coordinator.setExperimentEnabled(true)
        coordinator.presentation.setDraft("never durable", for: threadID)
        coordinator.presentation.capabilityNotice = "unavailable"
        await coordinator.setExperimentEnabled(false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(coordinator.presentation.drafts.isEmpty)
        XCTAssertNil(coordinator.presentation.capabilityNotice)
        XCTAssertNil(coordinator.presentation.selectedThreadID)
    }

    func testIntegrationActionsKeepTemporaryAndPersistentShellActivationDistinct() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCenterV2IntegrationTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(
            metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json"))
        )
        await coordinator.setExperimentEnabled(true)

        let sessionID = UUID()
        let registrationID = UUID()
        let initialTarget = AgentCurrentIntegrationTarget(
            location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell,
            processIDs: [42],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        )
        var applyCount = 0
        var persistCount = 0
        var currentTarget = initialTarget
        var holdInspection = false
        var heldInspection: CheckedContinuation<Void, Never>?
        let source = AgentSessionSource(
            registrationID: registrationID,
            sessionID: sessionID,
            discover: { .success([]) },
            observe: { _ in nil },
            inspect: { _ in nil },
            lifecycleIntegrationCacheKey: "integration-test-host",
            automaticallyProbeLifecycleIntegration: true,
            probeLifecycleIntegration: { .current },
            inspectCurrentIntegration: {
                let captured = currentTarget
                if holdInspection {
                    await withCheckedContinuation { heldInspection = $0 }
                }
                return captured
            },
            applyLifecycleIntegrationToCurrentShell: { received in
                XCTAssertEqual(received, currentTarget)
                applyCount += 1
                return true
            },
            persistLifecycleIntegrationInCurrentShell: { received in
                XCTAssertEqual(received, currentTarget)
                persistCount += 1
                return true
            },
            send: { _, _ in false },
            jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })

        let initialStateResolved = await waitUntil {
            coordinator.presentation.integrationNotice?.state.kind == .inactiveShell
        }
        XCTAssertTrue(initialStateResolved)
        XCTAssertEqual(coordinator.presentation.integrationNotice?.state.action, .apply)
        XCTAssertEqual(coordinator.presentation.integrationNotice?.state.secondaryAction, .persistAndApply)

        coordinator.presentation.onAction?(.fixIntegration(sessionID: sessionID, action: .apply))
        let temporaryApplyFinished = await waitUntil { applyCount == 1 && coordinator.integrationTasks[sessionID] == nil }
        XCTAssertTrue(temporaryApplyFinished)
        XCTAssertEqual(persistCount, 0, "one-shell activation must never write a shell startup file")

        coordinator.presentation.onAction?(.fixIntegration(sessionID: sessionID, action: .persistAndApply))
        let persistentApplyFinished = await waitUntil { persistCount == 1 && coordinator.integrationTasks[sessionID] == nil }
        XCTAssertTrue(persistentApplyFinished)
        XCTAssertEqual(applyCount, 1)

        currentTarget = AgentCurrentIntegrationTarget(
            location: initialTarget.location,
            foreground: .other,
            processIDs: [73],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        )
        holdInspection = true
        coordinator.scheduleIntegrationRefresh(sessionID: sessionID)
        let slowInspectionStarted = await waitUntil { heldInspection != nil }
        XCTAssertTrue(slowInspectionStarted)
        currentTarget = AgentCurrentIntegrationTarget(
            location: initialTarget.location,
            foreground: .shell,
            processIDs: [74],
            shellIntegrationActive: true,
            agentIntegrationActive: false
        )
        coordinator.noteOutput(
            sessionID: sessionID,
            paneID: nil,
            registrationID: registrationID,
            data: Array("shell prompt".utf8)[...]
        )
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertNotNil(
            coordinator.pendingIntegrationActivityRegistrations[sessionID],
            "activity arriving during a slow probe must remain pending"
        )
        holdInspection = false
        heldInspection?.resume()
        heldInspection = nil
        let readyStateResolved = await waitUntil {
            coordinator.presentation.integrationNotice?.state.kind == .ready
        }
        XCTAssertTrue(readyStateResolved)

        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: registrationID)
        XCTAssertNil(coordinator.presentation.integrationNotice)
    }

    func testBackgroundIntegrationCheckDoesNotBlinkExistingWarning() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-warning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: true, agentIntegrationActive: false)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { .unavailable }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: true,
            probeLifecycleIntegration: { .current }, inspectCurrentIntegration: { target },
            send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [.builtInCodexCLI] })
        coordinator.integrationStates[sessionID] = .unavailable()
        coordinator.scheduleIntegrationRefresh(sessionID: sessionID, forceHostProbe: true)
        XCTAssertEqual(coordinator.integrationState(sessionID: sessionID)?.kind, .unavailable)
        XCTAssertTrue(coordinator.integrationState(sessionID: sessionID)?.showsWarning == true)
        let refreshed = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .ready }
        XCTAssertTrue(refreshed, "A fresh successful check must still clear a resolved warning")
        coordinator.scheduleIntegrationRefresh(sessionID: sessionID, manual: true)
        XCTAssertEqual(coordinator.integrationState(sessionID: sessionID)?.kind, .repairing)
        await coordinator.setExperimentEnabled(false)
    }

    func testManualMoshIntegrationProbeNeverRunsUntilRequested() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCenterV2ManualIntegrationTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(
            metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json"))
        )
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        var probeCount = 0
        let source = AgentSessionSource(
            registrationID: UUID(),
            sessionID: sessionID,
            discover: { .success([]) },
            observe: { _ in nil },
            inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: false,
            probeLifecycleIntegration: {
                probeCount += 1
                return .current
            },
            inspectCurrentIntegration: {
                AgentCurrentIntegrationTarget(
                    location: self.location(sessionID: sessionID, paneID: nil),
                    foreground: .shell,
                    processIDs: [81],
                    shellIntegrationActive: true,
                    agentIntegrationActive: false
                )
            },
            send: { _, _ in false },
            jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })

        XCTAssertEqual(probeCount, 0)
        XCTAssertEqual(coordinator.presentation.integrationNotice?.state.kind, .manualCheckRequired)
        coordinator.presentation.onAction?(.fixIntegration(sessionID: sessionID, action: .check))
        let manualProbeFinished = await waitUntil {
            probeCount == 1 && coordinator.presentation.integrationNotice?.state.kind == .ready
        }
        XCTAssertTrue(manualProbeFinished)
        coordinator.scheduleIntegrationActivityRefresh(sessionID: sessionID, delay: .milliseconds(100))
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: source.registrationID)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(probeCount, 1, "a retired carrier must not run its queued integration refresh")
    }

    func testIntegrationRecoversOnQuietHostAndExpiresMissingInstallation() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        var probeCount = 0
        var installation: AgentLifecycleHostInstallation = .missing
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: true, agentIntegrationActive: false)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { .unavailable }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: true,
            probeLifecycleIntegration: {
                probeCount += 1
                if probeCount == 1 { throw NSError(domain: "lost-side-channel", code: 1) }
                return installation
            }, inspectCurrentIntegration: { target }, send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let integrationCondition1 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .unavailable }
        XCTAssertTrue(integrationCondition1)
        // No output, lifecycle frame, user retry or re-registration arrives.
        try? await Task.sleep(for: .milliseconds(2_100))
        let integrationCondition2 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .notInstalled }
        XCTAssertTrue(integrationCondition2)
        XCTAssertEqual(probeCount, 2)
        installation = .current
        coordinator.integrationInstallationDates[source.lifecycleIntegrationCacheKey] = .distantPast
        coordinator.scheduleIntegrationRefresh(sessionID: sessionID)
        let integrationCondition3 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .ready }
        XCTAssertTrue(integrationCondition3)
        XCTAssertEqual(probeCount, 3, "A previous missing result must not be cached for the entire app run")
        await coordinator.setExperimentEnabled(false)
    }

    func testSessionChromeObservesItsIntegrationCheckSettling() async {
        // A quiet terminal re-renders nothing else, so the chrome's delayed
        // warning can only start (or clear) if the state itself is observed.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-observe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        var releaseProbe: CheckedContinuation<Void, Never>?
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: true, agentIntegrationActive: false)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { .unavailable }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: true,
            probeLifecycleIntegration: {
                await withCheckedContinuation { releaseProbe = $0 }
                return .missing
            }, inspectCurrentIntegration: { target }, send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let probing = await waitUntil { releaseProbe != nil }
        XCTAssertTrue(probing)

        var settled = false
        withObservationTracking {
            _ = coordinator.integrationState(sessionID: sessionID)
        } onChange: { settled = true }
        releaseProbe?.resume()
        let resolved = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .notInstalled }
        XCTAssertTrue(resolved)
        XCTAssertTrue(settled, "session chrome must re-render when its integration check settles")

        var cleared = false
        withObservationTracking {
            _ = coordinator.integrationState(sessionID: sessionID)
        } onChange: { cleared = true }
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: source.registrationID)
        XCTAssertNil(coordinator.integrationState(sessionID: sessionID))
        XCTAssertTrue(cleared, "a retired session's warning must clear from its chrome")
        await coordinator.setExperimentEnabled(false)
    }

    func testInstallationTooNewForThisAppAsksOnlyForAnAppUpdate() {
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: UUID(), paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: false, agentIntegrationActive: false)
        let state = AgentIntegrationWarningState.resolved(installation: .requiresAppUpdate(version: 12), target: target)
        XCTAssertEqual(state.kind, .appUpdateRequired)
        XCTAssertTrue(state.showsWarning)
        XCTAssertNil(state.action, "an older app must never offer to replace a newer integration")
        XCTAssertNil(state.actionLabel)
    }

    func testPaneMarkerAcceptsAnyReleaseSinceTheShellFloor() {
        let ours = RemoteAgentLifecycleIntegrationInstaller.integrationVersion
        let floor = RemoteAgentLifecycleIntegrationInstaller.shellIntegrationCompatibleFrom
        XCTAssertEqual(AgentSessionSourceFactory.shellMarkerPID("\(ours):4242:\(ours)"), 4242)
        XCTAssertEqual(AgentSessionSourceFactory.shellMarkerPID("\(ours + 1):4242:\(ours + 1)"), 4242)
        // A shell loaded before the last update holds the same shell state.
        XCTAssertEqual(AgentSessionSourceFactory.shellMarkerPID("\(floor):4242:\(floor)"), 4242)
        for marker in ["\(floor - 1):4242:\(floor - 1)", "+\(ours + 1):4242:+\(ours + 1)", "\(ours):4242:\(ours + 1)",
                       "\(ours):1:\(ours)", "123456:4242:123456", ":4242:", "\(ours):4242", "\(ours):4242:\(ours):1"] {
            XCTAssertNil(AgentSessionSourceFactory.shellMarkerPID(marker), marker)
        }
    }

    func testContinuousOutputCoalescesWithoutCancellingIntegrationCheck() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-stream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        var inspections = 0
        var releaseInspection: CheckedContinuation<Void, Never>?
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: true, agentIntegrationActive: false)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { .unavailable }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: true, probeLifecycleIntegration: { .current },
            inspectCurrentIntegration: {
                inspections += 1
                if inspections == 1 { await withCheckedContinuation { releaseInspection = $0 } }
                return target
            }, send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let integrationCondition4 = await waitUntil { releaseInspection != nil }
        XCTAssertTrue(integrationCondition4)
        for _ in 0..<10 { coordinator.scheduleIntegrationRefresh(sessionID: sessionID) }
        XCTAssertEqual(inspections, 1)
        releaseInspection?.resume()
        let integrationCondition5 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .ready }
        XCTAssertTrue(integrationCondition5)
        coordinator.integrationRefreshNotBefore[sessionID] = .distantPast
        // Output arrives faster than the activity delay. The first deadline
        // must survive; a trailing debounce would never inspect here.
        for _ in 0..<12 {
            coordinator.scheduleIntegrationActivityRefresh(sessionID: sessionID, delay: .milliseconds(100))
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(inspections, 1)
        await coordinator.setExperimentEnabled(false)
    }

    func testMoshAutomaticProbeNeverUsesManualConnectionFallbackAndRefreshesAfterForeground() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-mosh-carrier-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        var connected = false
        var connectedProbeCount = 0
        var manualProbeCount = 0
        let target = AgentCurrentIntegrationTarget(location: location(sessionID: sessionID, paneID: nil),
            foreground: .shell, processIDs: [42], shellIntegrationActive: true, agentIntegrationActive: false)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { .unavailable }, observe: { _ in nil }, inspect: { _ in nil },
            probeLifecycleIntegrationOnCurrentCarrier: {
                connectedProbeCount += 1
                return connected ? .current : nil
            },
            probeLifecycleIntegration: { manualProbeCount += 1; return .current },
            automaticallyInspectCurrentIntegration: { connected },
            inspectCurrentIntegration: { target }, send: { _, _ in false }, jump: { _ in })
        coordinator.registerSessionSource(source, hostID: UUID(), profiles: { [] })
        let integrationCondition6 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .manualCheckRequired }
        XCTAssertTrue(integrationCondition6)
        XCTAssertEqual(manualProbeCount, 0)
        XCTAssertEqual(connectedProbeCount, 0)
        connected = true
        try? await Task.sleep(for: .milliseconds(2_100))
        let integrationCondition7 = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .ready }
        XCTAssertTrue(integrationCondition7, "A quiet restored carrier must be retried without terminal output")
        XCTAssertEqual(connectedProbeCount, 1)
        await coordinator.setApplicationActive(false)
        coordinator.integrationInstallationDates[source.lifecycleIntegrationCacheKey] = .distantPast
        await coordinator.setApplicationActive(true)
        let resumed = await waitUntil { connectedProbeCount == 2 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(connectedProbeCount, 2)
        XCTAssertEqual(manualProbeCount, 0)
        await coordinator.setExperimentEnabled(false)
    }

    func testFactoryForwardsOwnedCarrierProbeWithoutUsingManualFallback() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-factory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        let sessionID = UUID()
        let host = Host(name: "fixture", address: "192.0.2.1", port: 22, user: "fixture")
        // The facade is never connected or sent input. Only the injected read
        // callback is exercised through the real production source factory.
        let session = SSHSession(host: host)
        var automaticProbes = 0
        var manualProbes = 0
        let source = AgentSessionSourceFactory.make(
            sessionID: sessionID, hostName: "fixture", baseTransportLabel: "mosh",
            tmux: TmuxController(controlPath: .sideChannel),
            terminalBox: TerminalBox(traceLabel: "integration-factory-test"),
            tmuxSessionName: { nil }, profiles: { [] }, rawProcessProvider: { nil },
            probeLifecycleIntegrationOnCurrentCarrier: { automaticProbes += 1; return .current },
            probeLifecycleIntegration: { manualProbes += 1; return .current },
            sessionCommands: AppleSessionCommandFacade(session: session), rawSend: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: host.id, profiles: { [] })
        let probed = await waitUntil { automaticProbes == 1 }
        XCTAssertTrue(probed)
        XCTAssertEqual(manualProbes, 0)
        await coordinator.setExperimentEnabled(false)
    }

    /// `/clear` (and Codex `/new`) keeps the provider process and pane but
    /// starts another conversation: the pane's next frame names a new session.
    /// The old conversation must leave the list instead of lingering as an
    /// open agent no frame will ever update, on every transport.
    func testClearedConversationLeavesTheListOnAllFourTransports() async throws {
        for provider in ["claude", "codex"] {
            for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
                let label = "\(provider) \(transport)"
                let pane: Int? = transport.contains("tmux") ? 2 : nil
                let harness = await ConversationPaneHarness(provider: provider, transport: transport, pane: pane)
                // Another pane's agent waiting on the user lists first, so a
                // reader who fell back to the first row would land there.
                let neighbour = pane.map { _ in event("claude", "PermissionRequest", .waitingForInput, session: "neighbour", at: 50, pid: 43) }
                if let neighbour {
                    harness.publishNeighbour(neighbour)
                    let listed = await waitUntil { harness.listedSessions == ["neighbour"] }
                    XCTAssertTrue(listed, label)
                }
                let others = neighbour == nil ? [] : ["neighbour"]
                harness.publish(event(provider, "UserPromptSubmit", .working, session: "before-clear", at: 100))
                let oldID = harness.threadID("before-clear")
                let working = await waitUntil { harness.listedSessions == ["before-clear"] + others }
                XCTAssertTrue(working, label)
                if neighbour != nil {
                    XCTAssertEqual(harness.coordinator.presentation.listSnapshot.threads.first?.id.providerSessionID, "neighbour", label)
                }
                harness.coordinator.presentation.select(oldID)

                harness.publish(event(provider, "SessionEnd", .unavailable, session: "before-clear", at: 200))
                // One frame per pass: a refresh coalesces to the latest.
                let ended = await waitUntil { harness.applied("SessionEnd", session: "before-clear") }
                XCTAssertTrue(ended, label)
                harness.publish(event(provider, "SessionStart", .idle, session: "after-clear", at: 201))
                let replaced = await waitUntil { harness.listedSessions == ["after-clear"] + others }
                XCTAssertTrue(replaced, "\(label): \(harness.listedSessions)")
                // A stale copy would still claim the pane for SwipePad and sends.
                let dropped = await waitUntil { harness.coordinator.presentation.threadSnapshots[oldID] == nil }
                XCTAssertTrue(dropped, label)
                XCTAssertEqual(harness.coordinator.presentation.selectedThreadID, harness.threadID("after-clear"), label)
                await harness.close()
            }
        }
    }

    /// Claude runs `/clear`'s SessionEnd and SessionStart hooks back to back,
    /// so the old conversation's end can land after the new one started, and
    /// tmux then keeps that end for later passes. Neither may retire the
    /// conversation that holds the pane now, or list the old one again.
    func testLateSessionEndOfTheClearedConversationKeepsTheNewOne() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let oldID = harness.threadID("before-clear"), newID = harness.threadID("after-clear")
            harness.publish(event("claude", "UserPromptSubmit", .working, session: "before-clear", at: 100))
            let working = await waitUntil { harness.listedSessions == ["before-clear"] }
            XCTAssertTrue(working, transport)
            harness.coordinator.presentation.select(oldID)
            harness.publish(event("claude", "SessionStart", .idle, session: "after-clear", at: 201))
            let replaced = await waitUntil { harness.listedSessions == ["after-clear"] }
            XCTAssertTrue(replaced, "\(transport): \(harness.listedSessions)")
            let binding = harness.coordinator.presentation.threadSnapshots[newID]?.binding
            XCTAssertNotNil(binding?.agentPID, transport)

            // tmux renames the window after its active command.
            harness.windowName = "renamed"
            let passes = harness.discoveries.count
            let lateEnd = event("claude", "SessionEnd", .unavailable, session: "before-clear", at: 200)
            harness.publish(lateEnd)
            let ended = await waitUntil { harness.discoveries.count > passes }
            XCTAssertTrue(ended, transport)
            // Later passes meet it again: tmux retains the last hook for every
            // pass, and a pass reads it as it reads a delivered one.
            harness.publish(lateEnd)
            let again = await waitUntil { harness.discoveries.count > passes + 1 }
            XCTAssertTrue(again, transport)
            harness.publish(event("claude", "Stop", .idle, session: "after-clear", at: 300))
            let stopped = await waitUntil { harness.applied("Stop", session: "after-clear") }
            XCTAssertTrue(stopped, transport)
            // Each pass reads what the previous one left.
            for state in harness.discoveries.dropFirst(passes + 1) {
                XCTAssertEqual(state.listed, ["after-clear"], transport)
                XCTAssertEqual(state.bindings[newID], binding, "\(transport): the pane's conversation kept its route")
                XCTAssertNil(state.bindings[oldID], transport)
                XCTAssertEqual(state.selected, newID, transport)
            }
            XCTAssertEqual(harness.discoveries.count, passes + 3, transport)
            await harness.close()
        }
    }

    /// A working agent starts and ends tool and hook processes under its pane
    /// all the time. They are not a new agent: the thread keeps one binding
    /// (so a send in flight keeps its lease and receipt) and still accepts the
    /// agent's later frames.
    func testChildProcessesComingAndGoingKeepTheBindingAndTheStatus() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let id = harness.threadID("session")
            harness.publish(event("claude", "UserPromptSubmit", .working, session: "session", at: 100))
            let working = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.summary.status == .working }
            XCTAssertTrue(working, transport)
            let binding = harness.coordinator.presentation.threadSnapshots[id]?.binding
            XCTAssertNotNil(binding?.agentPID, transport)

            // A tool shell and the Stop hook run beside the agent.
            harness.processIDs = [42, 4_242, 4_243]
            harness.publish(event("claude", "PreToolUse", .working, session: "session", at: 200))
            let tool = await waitUntil { harness.applied("PreToolUse", session: "session") }
            XCTAssertTrue(tool, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding, binding, transport)
            harness.processIDs = [42, 4_250]
            harness.publish(event("claude", "Stop", .idle, session: "session", at: 300))
            let finished = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.summary.attention == .unreadCompletion }
            XCTAssertTrue(finished, "\(transport): \(String(describing: harness.coordinator.presentation.threadSnapshots[id]?.summary))")
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding, binding, transport)
            await harness.close()
        }
    }

    /// Codex's wrapper reports SessionStart before Codex names a session, so
    /// the pane lists as a candidate, parsed on the main actor, while Codex's
    /// fresh screen is still mostly width-padded blank rows. That parse once
    /// backtracked for about a minute per refresh and froze the app.
    func testCodexCandidateOnAFreshScreenListsWithoutStallingTheMainActorOnAllFourTransports() async throws {
        let width = 166
        let rows = ["╭─────────────────────────────────────────────────╮",
                    "│ >_ OpenAI Codex (v0.157.1)                      │",
                    "╰─────────────────────────────────────────────────╯"]
            + Array(repeating: "", count: 50) + ["› Implement {feature}"]
        let screen = rows.map { $0 + String(repeating: " ", count: width - $0.count) }.joined(separator: "\n")
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "codex", transport: transport, pane: pane)
            harness.visibleText = screen
            let started = ContinuousClock.now
            harness.publish(event("codex", "SessionStart", .idle, session: "", at: 100))
            // `waitUntil` counts polls, so a blocked main actor would still
            // pass it; bound the wall-clock time instead.
            let listed = await waitUntil { harness.coordinator.presentation.listSnapshot.candidates.count == 1 }
            XCTAssertTrue(listed, transport)
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), transport)
            await harness.close()
        }
    }

    /// Claude starts Codex agents in the background. They inherit Claude's
    /// pane, so their hooks write the pane's lifecycle, naming processes the
    /// pane's foreground does not contain. Claude keeps the pane: its row is
    /// neither replaced by an unproven Codex row nor unbound until its own
    /// next hook, on every transport.
    func testBackgroundAgentsHooksLeaveThePaneWithItsForegroundAgentOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let id = harness.threadID("holder")
            harness.publish(event("claude", "UserPromptSubmit", .working, session: "holder", at: 100))
            let working = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.summary.status == .working }
            XCTAssertTrue(working, transport)
            let binding = harness.coordinator.presentation.threadSnapshots[id]?.binding
            XCTAssertEqual(binding?.agentPID, 42, transport)

            let passes = harness.discoveries.count
            harness.publish(event("codex", "SessionStart", .idle, session: "child", at: 200, pid: 5_000))
            let started = await waitUntil { harness.discoveries.count > passes }
            XCTAssertTrue(started, transport)
            harness.publish(event("codex", "UserPromptSubmit", .working, session: "child", at: 300, pid: 5_000))
            let prompted = await waitUntil { harness.discoveries.count > passes + 1 }
            XCTAssertTrue(prompted, transport)
            harness.publish(event("claude", "PreToolUse", .working, session: "holder", at: 400))
            let tool = await waitUntil { harness.applied("PreToolUse", session: "holder") }
            XCTAssertTrue(tool, transport)
            // Each pass reads what the previous one left.
            for state in harness.discoveries.dropFirst(passes + 1) {
                XCTAssertEqual(state.listed, ["holder"], transport)
                XCTAssertEqual(state.bindings[id], binding, transport)
            }
            XCTAssertEqual(harness.listedSessions, ["holder"], transport)
            XCTAssertTrue(harness.coordinator.presentation.listSnapshot.candidates.isEmpty, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.summary.status, .working, transport)

            // The agent's frame still queued when a background agent's newer
            // one arrives is applied, not replaced.
            harness.publish(event("claude", "Stop", .idle, session: "holder", at: 500))
            harness.publish(event("codex", "PreToolUse", .working, session: "child", at: 600, pid: 5_001))
            let finished = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.summary.attention == .unreadCompletion }
            XCTAssertTrue(finished, "\(transport): \(String(describing: harness.coordinator.presentation.threadSnapshots[id]?.summary))")
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding, binding, transport)
            XCTAssertEqual(harness.invalidations, 0, transport)
            await harness.close()
        }
    }

    func testTmuxReplacementRestoresClaudeBeforeItsNextHookWithRunningBackgroundCodex() async throws {
        try await assertTmuxReplacementRestoresClaude(backgroundIsRunning: true)
    }

    func testTmuxReplacementRestoresClaudeBeforeItsNextHookWithExitedForeignPID() async throws {
        try await assertTmuxReplacementRestoresClaude(backgroundIsRunning: false)
    }

    private func assertTmuxReplacementRestoresClaude(backgroundIsRunning: Bool) async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let id = harness.threadID("holder")
            let oldBinding = try await proveHolderBeforeReplacement(harness)
            if backgroundIsRunning {
                // The nested process is still alive, but outside Claude's
                // foreground set; a neighbouring pane independently sees it.
                harness.publishNeighbour(event("codex", "SessionStart", .idle, session: "background", at: 210, pid: 5_000))
                let backgroundListed = await waitUntil {
                    harness.listedSessions.contains("background") && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
                }
                XCTAssertTrue(backgroundListed, transport)
            }

            let oldSession = harness.sessionID
            let oldRegistration = try XCTUnwrap(harness.coordinator.threadRoutes[id]?.registrationID)
            harness.replaceSource()
            XCTAssertNotEqual(harness.sessionID, oldSession, transport)
            let restored = await waitUntil {
                harness.coordinator.threadRoutes[id]?.binding.liveSessionID == harness.sessionID
                    && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(restored, "\(transport): \(harness.listedSessions)")
            let route = try XCTUnwrap(harness.coordinator.threadRoutes[id], transport)
            let binding = try XCTUnwrap(harness.coordinator.presentation.threadSnapshots[id]?.binding, transport)
            XCTAssertNotEqual(route.registrationID, oldRegistration, transport)
            XCTAssertEqual(route.registrationID, harness.coordinator.sessionRoutes[harness.sessionID]?.source.registrationID, transport)
            XCTAssertEqual(binding.liveSessionID, harness.sessionID, transport)
            XCTAssertNotEqual(binding.carrierGeneration, oldBinding.carrierGeneration, transport)
            XCTAssertNotEqual(binding.incarnation, oldBinding.incarnation, transport)
            XCTAssertEqual(binding.tmuxSession, "restored-view", transport)
            XCTAssertEqual(binding.agentPID, 42, transport)
            // The read proves the process, not that it still runs this
            // conversation: no input until Claude's own frame.
            XCTAssertTrue(binding.capabilities.contains(.observe), transport)
            XCTAssertFalse(binding.capabilities.contains(.send), transport)
            XCTAssertFalse(binding.capabilities.contains(.promptAnswer), transport)
            XCTAssertEqual(harness.listedSessions, backgroundIsRunning ? ["background", "holder"] : ["holder"], transport)
            XCTAssertFalse(harness.coordinator.threadRoutes.contains {
                $0.key.providerID == .codex && $0.value.location.paneID == 2
            }, transport)
            XCTAssertTrue(harness.coordinator.presentation.listSnapshot.candidates.isEmpty, transport)

            // The recovered route now protects later passes on this carrier.
            harness.publish(event("codex", "PreToolUse", .working, session: "child", at: 300, pid: 5_000))
            let foreignRead = await waitUntil { harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
            XCTAssertTrue(foreignRead, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding, binding, transport)
            let listed = harness.listedSessions
            harness.publish(event("claude", "PreToolUse", .working, session: "holder", at: 400))
            let hooked = await waitUntil {
                harness.applied("PreToolUse", session: "holder") && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(hooked, transport)
            XCTAssertEqual(harness.listedSessions, listed, transport)
            let confirmed = try XCTUnwrap(harness.coordinator.presentation.threadSnapshots[id]?.binding, transport)
            XCTAssertEqual(confirmed.agentPID, 42, transport)
            XCTAssertEqual(confirmed.liveSessionID, harness.sessionID, transport)
            XCTAssertTrue(confirmed.capabilities.contains(.send), transport)
            await harness.close()
        }
    }

    func testTmuxReplacementDoesNotRestoreClaudeAfterItsForegroundProcessExits() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let id = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.processIDs = [77]
            let passes = harness.discoveries.count
            harness.replaceSource()
            let discovered = await replacementPassed(harness, after: passes)
            XCTAssertTrue(discovered, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            XCTAssertNil(harness.coordinator.presentation.threadSnapshots[id]?.binding, transport)
            let foreignID = AgentThreadID(hostID: harness.hostID, providerID: .codex, providerSessionID: "child")!
            XCTAssertNil(harness.coordinator.presentation.threadSnapshots[foreignID]?.binding?.agentPID, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[foreignID], transport)
            XCTAssertFalse(harness.coordinator.presentation.listSnapshot.candidates.isEmpty, transport)

            // A later read containing the retired PID cannot resurrect a memo
            // the first fresh replacement read already disproved.
            harness.processIDs = [42]
            let later = harness.discoveries.count
            harness.publish(event("codex", "PreToolUse", .working, session: "child", at: 300, pid: 5_000))
            let completed = await replacementPassed(harness, after: later)
            XCTAssertTrue(completed, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            XCTAssertFalse(harness.listedSessions.contains("holder"), transport)
            await harness.close()
        }
    }

    func testTmuxReplacementDoesNotRestoreClaudeOnAnotherHostWithTheSamePaneID() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let id = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            let passes = harness.discoveries.count
            harness.replaceSource(hostID: UUID())
            let discovered = await replacementPassed(harness, after: passes)
            XCTAssertTrue(discovered, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            XCTAssertNil(harness.coordinator.presentation.threadSnapshots[id]?.binding, transport)
            XCTAssertFalse(harness.coordinator.threadRoutes.values.contains { $0.binding.agentPID == 42 }, transport)
            XCTAssertFalse(harness.listedSessions.contains("holder"), transport)
            await harness.close()
        }
    }

    func testRawReplacementDoesNotRestoreClaudeWithoutANewHook() async throws {
        for transport in ["ssh", "mosh"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: nil)
            let id = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.replaceSource()
            let discovered = await waitUntil {
                harness.listedSessions.isEmpty && harness.coordinator.presentation.listSnapshot.candidates.count == 1
                    && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(discovered, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            XCTAssertNil(harness.coordinator.presentation.threadSnapshots[id]?.binding, transport)
            harness.publish(event("claude", "PreToolUse", .working, session: "holder", at: 400))
            let hooked = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.binding?.liveSessionID == harness.sessionID }
            XCTAssertTrue(hooked, transport)
            await harness.close()
        }
    }

    /// `/clear` before the suspension: tmux keeps the replaced conversation's
    /// late SessionEnd, naming Claude's own PID. The replacement restores the
    /// conversation that held the pane, not the ended one.
    func testTmuxReplacementRestoresTheSuccessorOverARetainedLateSessionEnd() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let oldID = harness.threadID("holder"), newID = harness.threadID("after-clear")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.publish(event("claude", "SessionStart", .idle, session: "after-clear", at: 301))
            let cleared = await waitUntil {
                harness.listedSessions == ["after-clear"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(cleared, transport)
            harness.publish(event("claude", "SessionEnd", .unavailable, session: "holder", at: 300))
            let ended = await waitUntil { harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
            XCTAssertTrue(ended, transport)
            XCTAssertEqual(harness.listedSessions, ["after-clear"], transport)

            let passes = harness.discoveries.count
            harness.replaceSource()
            let restored = await waitUntil {
                harness.coordinator.threadRoutes[newID]?.binding.liveSessionID == harness.sessionID
                    && harness.discoveries.count > passes
                    && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(restored, "\(transport): \(harness.listedSessions)")
            XCTAssertEqual(harness.listedSessions, ["after-clear"], transport)
            XCTAssertNil(harness.coordinator.threadRoutes[oldID], transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[newID]?.binding?.agentPID, 42, transport)
            await harness.close()
        }
    }

    func testTmuxReplacementRestoredClaudeKeepsClearAndLateEndHandling() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let oldID = harness.threadID("holder"), newID = harness.threadID("after-clear")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.replaceSource()
            let restored = await waitUntil {
                harness.coordinator.threadRoutes[oldID]?.binding.liveSessionID == harness.sessionID
                    && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(restored, transport)
            XCTAssertEqual(harness.listedSessions, ["holder"], transport)
            harness.coordinator.presentation.select(oldID)
            harness.publish(event("claude", "SessionStart", .idle, session: "after-clear", at: 401))
            let cleared = await waitUntil {
                harness.listedSessions == ["after-clear"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(cleared, transport)
            XCTAssertNil(harness.coordinator.presentation.threadSnapshots[oldID], transport)
            XCTAssertEqual(harness.coordinator.presentation.selectedThreadID, newID, transport)
            let binding = harness.coordinator.presentation.threadSnapshots[newID]?.binding
            harness.publish(event("claude", "SessionEnd", .unavailable, session: "holder", at: 400))
            let ended = await waitUntil { harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
            XCTAssertTrue(ended, transport)
            XCTAssertEqual(harness.listedSessions, ["after-clear"], transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[newID]?.binding, binding, transport)
            await harness.close()
        }
    }

    func testTmuxReplacementRequiresAFreshProcessReadToRestoreClaude() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let id = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.processSnapshotTakenAtOverride = .distantPast
            let passes = harness.discoveries.count
            harness.replaceSource()
            let unread = await replacementPassed(harness, after: passes)
            XCTAssertTrue(unread, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            harness.processSnapshotTakenAtOverride = nil
            // A read that cannot answer for the incoming PID is not reused.
            harness.staleProcessIDs = [42]
            harness.publish(event("codex", "PreToolUse", .working, session: "child", at: 300, pid: 5_000))
            let restored = await waitUntil {
                harness.listedSessions == ["holder"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(restored, transport)
            XCTAssertEqual(harness.invalidations, 0, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID, 42, transport)
            await harness.close()
        }
    }

    func testTmuxReplacementPrefersAProvenCurrentEventOverRememberedClaude() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let oldID = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.processIDs = [42, 77]
            harness.retain(event("codex", "SessionStart", .idle, session: "foreground-codex", at: 300, pid: 77))
            harness.replaceSource()
            // Even a queued foreign hook cannot displace the retained event
            // this pass independently proves in the pane's foreground. Make
            // the first read hook-driven, before a generic pass uses the memo.
            harness.coordinator.sessionRefreshQueues[harness.sessionID] = .init()
            harness.coordinator.scheduleSessionRefresh(sessionID: harness.sessionID, paneID: 2,
                lifecycle: event("codex", "PreToolUse", .working, session: "child", at: 400, pid: 5_000))
            let current = await waitUntil {
                harness.listedSessions == ["foreground-codex", "holder"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(current, transport)
            XCTAssertEqual(harness.coordinator.threadRoutes[oldID]?.restoredFromRetiredConnection, true, transport)
            let newID = AgentThreadID(hostID: harness.hostID, providerID: .codex, providerSessionID: "foreground-codex")!
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[newID]?.binding?.agentPID, 77, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[newID]?.binding?.capabilities.contains(.send), true, transport)
            await harness.close()
        }
    }

    func testTmuxReplacementDoesNotRestoreAHolderRetiredByAuthoritativeAbsence() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            let id = harness.threadID("holder")
            _ = try await proveHolderBeforeReplacement(harness)
            harness.hidesPane = true
            harness.occupancyPaneExists = false
            harness.coordinator.scheduleLivenessSweep(sessionID: harness.sessionID)
            harness.publish(event("codex", "PreToolUse", .working, session: "child", at: 300, pid: 5_000))
            let absent = await waitUntil {
                harness.coordinator.threadRoutes[id] == nil && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(absent, transport)
            harness.hidesPane = false
            harness.occupancyPaneExists = true
            let passes = harness.discoveries.count
            harness.replaceSource()
            let discovered = await replacementPassed(harness, after: passes)
            XCTAssertTrue(discovered, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[id], transport)
            XCTAssertFalse(harness.listedSessions.contains("holder"), transport)
            await harness.close()
        }
    }

    func testDisablingAgentCenterDiscardsRetiredPaneHoldersBeforeReplacement() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: 2)
            _ = try await proveHolderBeforeReplacement(harness)
            harness.unregisterSource()
            await harness.coordinator.setExperimentEnabled(false)
            await harness.coordinator.setExperimentEnabled(true)
            let passes = harness.discoveries.count
            harness.replaceSource()
            let discovered = await replacementPassed(harness, after: passes)
            XCTAssertTrue(discovered, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("holder")], transport)
            XCTAssertFalse(harness.coordinator.threadRoutes.values.contains { $0.binding.agentPID == 42 }, transport)
            await harness.close()
        }
    }

    /// The replacement's discovery ran a pass after `passes` and settled.
    /// Without a restored holder the pane's foreign frame lists no row, so a
    /// test that expects none must wait on the pass, not on the list.
    private func replacementPassed(_ harness: ConversationPaneHarness, after passes: Int) async -> Bool {
        await waitUntil {
            harness.discoveries.count > passes && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
        }
    }

    private func proveHolderBeforeReplacement(_ harness: ConversationPaneHarness) async throws -> AgentTerminalBinding {
        let id = harness.threadID("holder")
        harness.publish(event("claude", "UserPromptSubmit", .working, session: "holder", at: 100))
        let proven = await waitUntil {
            harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID == 42
                && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
        }
        XCTAssertTrue(proven)
        let binding = try XCTUnwrap(harness.coordinator.presentation.threadSnapshots[id]?.binding)
        harness.publish(event("codex", "SessionStart", .idle, session: "child", at: 200, pid: 5_000))
        let judged = await waitUntil { harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
        XCTAssertTrue(judged)
        XCTAssertEqual(harness.listedSessions, ["holder"])
        XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding, binding)
        return binding
    }

    /// The same frame from a process a reused read never saw can be a new
    /// foreground agent: the pass reads the host again before it keeps the
    /// pane with the agent the old read showed.
    func testANewForegroundAgentTakesThePaneDespiteAReusedProcessReadOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let oldID = harness.threadID("before"), newID = harness.threadID("after")
            harness.publish(event("claude", "UserPromptSubmit", .working, session: "before", at: 100))
            let working = await waitUntil { harness.coordinator.presentation.threadSnapshots[oldID]?.binding?.agentPID == 42 }
            XCTAssertTrue(working, transport)

            harness.processIDs = [77]
            harness.staleProcessIDs = [42]
            harness.publish(event("claude", "SessionStart", .idle, session: "after", at: 200, pid: 77))
            let adopted = await waitUntil { harness.coordinator.presentation.threadSnapshots[newID]?.binding?.agentPID == 77 }
            XCTAssertTrue(adopted, "\(transport): \(harness.listedSessions)")
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[oldID]?.binding?.agentPID, 42, transport)
            harness.coordinator.scheduleLivenessSweep(sessionID: harness.sessionID)
            let retired = await waitUntil { harness.coordinator.presentation.threadSnapshots[oldID]?.binding == nil }
            XCTAssertTrue(retired, transport)
            XCTAssertEqual(harness.invalidations, 1, transport)
            await harness.close()
        }
    }

    /// An agent starting where a shell just ran: its first frame names a PID
    /// the reused read predates. The pass reads again and proves it at once,
    /// instead of leaving an unproven row until a generic pass (a minute with
    /// Agent Center closed). Later occupancy passes read once, without a
    /// second read for an already judged foreign PID.
    func testAStartingAgentIsProvenDespiteAReusedProcessReadOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let id = harness.threadID("fresh")
            harness.staleProcessIDs = [7]
            harness.publish(event("claude", "SessionStart", .idle, session: "fresh", at: 100))
            let proven = await waitUntil {
                harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID == 42
                    && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
            }
            XCTAssertTrue(proven, "\(transport): \(harness.listedSessions)")
            XCTAssertEqual(harness.invalidations, 0, transport)
            let initialInvalidations = harness.invalidations

            for timestamp in [200, 300] as [UInt64] {
                let passes = harness.discoveries.count
                harness.staleProcessIDs = [42]
                harness.publish(event("codex", "Stop", .idle, session: "gone", at: timestamp, pid: 999))
                let read = await waitUntil { harness.discoveries.count > passes }
                XCTAssertTrue(read, transport)
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(harness.invalidations, initialInvalidations, transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID, 42, transport)
            await harness.close()
        }
    }

    /// tmux announces a pane's option again with every change to the pane's
    /// metadata, so an agent's title spinner repeats its last frame many times
    /// a second, and a background agent's hooks keep arriving. Each discovery
    /// pass costs the host a process read and tmux commands the user's typing
    /// waits behind; only a new frame from the pane's agent may start one.
    func testRepeatedAndBackgroundAgentFramesDoNotStartDiscoveryOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let id = harness.threadID("holder")
            let registered = await waitUntil { harness.discoveries.count == 1 }
            XCTAssertTrue(registered, transport)

            // Repeats of a frame start no pass until the window passes, even
            // when the pass it bought failed: discovery fails most on a
            // loaded host. Then a repeat looks again, e.g. for a prompt drawn
            // after its hook.
            let holder = lifecycleJSON("claude", "UserPromptSubmit", "working", session: "holder", at: 100)
            let place = AgentInstanceID(sessionID: harness.sessionID, paneID: pane)
            harness.failNextDiscovery = true
            harness.deliver(holder)
            let failed = await waitUntil { harness.discoveries.count == 2 }
            XCTAssertTrue(failed, transport)
            for _ in 0..<5 { harness.deliver(holder) }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(harness.discoveries.count, 2, "\(transport): repeats started passes")
            let admitted = try XCTUnwrap(harness.coordinator.lastLifecycleDeliveries[place], transport)
            harness.coordinator.lastLifecycleDeliveries[place] = (admitted.event, admitted.admittedAt
                .addingTimeInterval(-AgentCenterV2DiscoveryPolicy.lifecycleRepeatInterval))
            harness.deliver(holder)
            harness.deliver(holder)
            let working = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID == 42 }
            XCTAssertTrue(working, transport)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(harness.discoveries.count, 3, transport)
            var passes = harness.discoveries.count

            // A background agent's first hook costs one pass; later ones none.
            harness.deliver(lifecycleJSON("codex", "SessionStart", "idle", session: "child", at: 200, pid: 5_000))
            let judged = await waitUntil { harness.discoveries.count == passes + 1 }
            XCTAssertTrue(judged, transport)
            passes = harness.discoveries.count
            harness.deliver(lifecycleJSON("codex", "UserPromptSubmit", "working", session: "child", at: 300, pid: 5_000))
            harness.deliver(lifecycleJSON("codex", "PreToolUse", "working", session: "child", at: 400, pid: 5_000))
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(harness.discoveries.count, passes, "\(transport): background hooks started passes")
            XCTAssertEqual(harness.listedSessions, ["holder"], transport)
            XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID, 42, transport)
            // A session boundary always looks: it may be that process taking
            // the pane after all.
            harness.deliver(lifecycleJSON("codex", "SessionStart", "idle", session: "child-2", at: 450, pid: 5_000))
            let boundary = await waitUntil { harness.discoveries.count == passes + 1 }
            XCTAssertTrue(boundary, transport)
            XCTAssertEqual(harness.listedSessions, ["holder"], transport)
            passes = harness.discoveries.count

            // The foreground agent's next frame still gets its pass.
            let stop = lifecycleJSON("claude", "Stop", "idle", session: "holder", at: 500)
            harness.deliver(stop)
            let stopped = await waitUntil { harness.applied("Stop", session: "holder") }
            XCTAssertTrue(stopped, transport)
            XCTAssertEqual(harness.discoveries.count, passes + 1, transport)

            // A complete inventory proves absence; when the process returns,
            // tmux announces the same frame.
            harness.hidesPane = true
            harness.occupancyProcesses = []
            harness.coordinator.scheduleLivenessSweep(sessionID: harness.sessionID)
            harness.publish(event("claude", "Stop", .idle, session: "holder", at: 500))
            let retired = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.binding == nil }
            XCTAssertTrue(retired, transport)
            XCTAssertNil(harness.coordinator.foreignLifecyclePIDs[place], "\(transport): verdicts judged against the retired agent")
            harness.hidesPane = false
            harness.occupancyProcesses = nil
            harness.deliver(stop)
            let returned = await waitUntil { harness.coordinator.presentation.threadSnapshots[id]?.binding?.agentPID == 42 }
            XCTAssertTrue(returned, transport)
            await harness.close()
        }
    }

    /// A current host integration check has no fresh lifecycle event for a
    /// quiet agent. Discovery's proven route keeps that foreground agent
    /// confirmed on both raw and tmux transports until its process leaves.
    func testIntegrationCheckKeepsTheProvenForegroundAgentConfirmedOnEveryTransport() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane, checksIntegration: true)
            let coordinator = harness.coordinator, sessionID = harness.sessionID
            let unconfirmed = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .insideAgent }
            XCTAssertTrue(unconfirmed, "\(transport): \(String(describing: coordinator.integrationState(sessionID: sessionID)?.kind))")
            harness.publish(event("claude", "UserPromptSubmit", .working, session: "holder", at: 100))
            let proven = await waitUntil { coordinator.presentation.threadSnapshots[harness.threadID("holder")]?.binding?.agentPID == 42 }
            XCTAssertTrue(proven, transport)
            coordinator.scheduleIntegrationRefresh(sessionID: sessionID, forceHostProbe: true)
            let confirmed = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .ready }
            XCTAssertTrue(confirmed, "\(transport): \(String(describing: coordinator.integrationState(sessionID: sessionID)?.kind))")

            harness.processIDs = [77]
            coordinator.scheduleIntegrationRefresh(sessionID: sessionID, forceHostProbe: true)
            let dropped = await waitUntil { coordinator.integrationState(sessionID: sessionID)?.kind == .insideAgent }
            XCTAssertTrue(dropped, transport)
            await harness.close()
        }
    }

    /// Discovery reuses a pane's process read briefly, but never one that
    /// predates the agent the pane's lifecycle names: that read would hide
    /// the agent, or leave its pane out of discovery.
    func testDiscoveryReusesAProcessReadOnlyIfItCanAnswerForThePanesAgent() {
        typealias Reads = AgentSessionSourceFactory.DiscoveryProcessReads
        var reads = Reads()
        let start = Date()
        let shell = SwipePadPlainSSHProcessProbe.Snapshot(processNames: ["zsh"], processIDs: [7])
        reads.store(.init(snapshot: shell, requestedAt: start, completedAt: start, lookedFor: nil), panePID: 5)
        XCTAssertNotNil(reads.reusable(panePID: 5, expectedPID: nil, now: start.addingTimeInterval(1)))
        XCTAssertNotNil(reads.reusable(panePID: 5, expectedPID: 7, now: start.addingTimeInterval(1)))
        XCTAssertNil(reads.reusable(panePID: 5, expectedPID: 42, now: start.addingTimeInterval(1)))
        XCTAssertNil(reads.reusable(panePID: 6, expectedPID: nil, now: start.addingTimeInterval(1)))
        XCTAssertNil(reads.reusable(panePID: 5, expectedPID: nil, now: start.addingTimeInterval(Reads.reuseInterval)))

        // A read taken for a background agent's PID answers for it.
        reads.store(.init(snapshot: shell, requestedAt: start, completedAt: start, lookedFor: 5_000), panePID: 5)
        XCTAssertNotNil(reads.reusable(panePID: 5, expectedPID: 5_000, now: start.addingTimeInterval(1)))
        XCTAssertNil(reads.reusable(panePID: 5, expectedPID: 5_001, now: start.addingTimeInterval(1)))
        reads.removeAll()
        XCTAssertNil(reads.reusable(panePID: 5, expectedPID: nil, now: start))
    }

    func testRefreshQueueKeepsEachAgentsNewestFrameOnASharedPane() {
        var queue = AgentCenterV2SessionRefreshQueue()
        queue.enqueue(paneID: 4, lifecycle: lifecycleEvent(turnID: "holder", timestampNanoseconds: 10))
        queue.enqueue(paneID: 4, lifecycle: event("codex", "SessionStart", .idle, session: "child", at: 20, pid: 5_000))
        queue.enqueue(paneID: 4, lifecycle: event("codex", "UserPromptSubmit", .working, session: "child", at: 30, pid: 5_000))
        XCTAssertEqual(queue.dequeue()?.lifecycle?.turnID, "holder")
        XCTAssertEqual(queue.dequeue()?.lifecycle?.event, "UserPromptSubmit")
        XCTAssertNil(queue.dequeue())
    }

    private func lifecycleJSON(_ provider: String, _ name: String, _ state: String, session: String,
                               at timestamp: UInt64, pid: Int = 42) -> String {
        #"{"version":9,"provider":"\#(provider)","event":"\#(name)","state":"\#(state)","reason":"fixture","timestampNs":"\#(timestamp)","sessionId":"\#(session)","turnId":"turn","agentPid":\#(pid),"transcriptRef":"c2Vzc2lvbg"}"#
    }

    /// Hooks from before integration v21 announce no question, and a dialog
    /// raised before the app connected announces nothing. The conversation
    /// on screen still reads its terminal and shows the dialog as a card;
    /// one that is not on screen is not read.
    func testTheConversationOnScreenShowsAnUnannouncedQuestionOnEveryTransport() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let coordinator = harness.coordinator
            harness.publish(event("claude", "PreToolUse", .working, session: "asking", at: 100))
            let id = harness.threadID("asking")
            let listed = await waitUntil { harness.listedSessions == ["asking"] }
            XCTAssertTrue(listed, transport)
            harness.visibleText = Self.claudeQuestionScreen
            coordinator.setSurfaceDemand(true)
            try await Task.sleep(for: .milliseconds(2_500))
            // The narrow list keeps a selection behind it: selected is not on screen.
            XCTAssertEqual(coordinator.presentation.selectedThreadID, id, transport)
            XCTAssertNil(liveCard(coordinator, id), "\(transport): a conversation that is not on screen is not read")

            coordinator.presentation.onAction?(.detailVisibility(id, true))
            let shown = await waitUntil(attempts: 300) { self.liveCard(coordinator, id)?.kind == .question }
            XCTAssertTrue(shown, transport)
            XCTAssertEqual(liveCard(coordinator, id)?.question, "Which database should the service use for the new ledger?", transport)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.attention, .needsYou, transport)

            // Answered in the terminal: the screen raised the card, so it goes.
            harness.visibleText = "❯ "
            let gone = await waitUntil(attempts: 300) { self.liveCard(coordinator, id) == nil }
            XCTAssertTrue(gone, transport)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.attention, TesseraCore.AgentAttention.none, transport)

            // Closed again, the conversation is no longer read.
            coordinator.presentation.onAction?(.detailVisibility(id, false))
            try await Task.sleep(for: .milliseconds(1_500))
            harness.visibleText = Self.claudeQuestionScreen
            try await Task.sleep(for: .milliseconds(2_500))
            XCTAssertNil(liveCard(coordinator, id), "\(transport): a closed conversation is not read")
            await harness.close()
        }
    }

    /// A phone sizes the tmux window to its 56 columns, where Claude wraps the
    /// dialog's key hints, and a tmux pane is captured with its styles
    /// (`capture-pane -e -N`). The hook announced the dialog; the card must
    /// still come from the screen on every transport.
    func testAPhoneWidthQuestionShowsItsCardOnEveryTransport() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane: Int? = transport.contains("tmux") ? 2 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            let coordinator = harness.coordinator
            harness.publish(event("claude", "PreToolUse", .working, session: "asking", at: 100))
            let id = harness.threadID("asking")
            let listed = await waitUntil { harness.listedSessions == ["asking"] }
            XCTAssertTrue(listed, transport)
            harness.visibleText = pane == nil ? Self.claudePhoneQuestionScreen : Self.claudePhoneQuestionCapture
            harness.publish(event("claude", "Notification", .waitingForInput, session: "asking", at: 200))
            coordinator.setSurfaceDemand(true)
            coordinator.presentation.onAction?(.detailVisibility(id, true))
            let shown = await waitUntil(attempts: 300) { self.liveCard(coordinator, id)?.kind == .question }
            XCTAssertTrue(shown, transport)
            let card = liveCard(coordinator, id)
            XCTAssertEqual(card?.question?.hasPrefix("Which plan should the next run use? The last run of the ledger import"), true, transport)
            XCTAssertEqual(card?.options.map(\.label), ["Keep the current plan (safe)", "Switch to the fast path", "Stop and report",
                                                        "Type something.", "Chat about this"], transport)
            XCTAssertEqual(card?.progress, "☐ Run plan ☐ Report ✔ Submit", transport)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.status, .waitingForInput, transport)
            await harness.close()
        }
    }

    func testAConversationClosedDuringItsCaptureRaisesNoCard() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 2)
        let coordinator = harness.coordinator
        harness.publish(event("claude", "PreToolUse", .working, session: "asking", at: 100))
        let id = harness.threadID("asking")
        let listed = await waitUntil { harness.listedSessions == ["asking"] }
        XCTAssertTrue(listed)
        coordinator.setSurfaceDemand(true)
        // Past the frame's own watch, only the screen reads the conversation.
        try await Task.sleep(for: .milliseconds(2_000))
        var held: CheckedContinuation<Void, Never>?
        harness.inspectionHold = { await withCheckedContinuation { held = $0 } }
        harness.visibleText = Self.claudeQuestionScreen
        coordinator.presentation.onAction?(.detailVisibility(id, true))
        let capturing = await waitUntil(attempts: 300) { held != nil }
        XCTAssertTrue(capturing)
        coordinator.presentation.onAction?(.detailVisibility(id, false))
        harness.inspectionHold = nil
        held?.resume()
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertNil(liveCard(coordinator, id), "a capture that outlived the conversation on screen raises nothing")
        XCTAssertEqual(coordinator.presentation.threadSnapshots[id]?.summary.attention, TesseraCore.AgentAttention.none)
        await harness.close()
    }

    /// An end accepted while a send awaits its inspection revokes the send:
    /// the process may already show the next conversation's composer.
    func testAcceptedEndRevokesASendAwaitingInspection() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 2 : nil)
            let coordinator = harness.coordinator, presentation = coordinator.presentation
            harness.publish(event("claude", "SessionStart", .idle, session: "A", at: 100))
            let id = harness.threadID("A")
            let listed = await waitUntil { harness.listedSessions == ["A"] }
            XCTAssertTrue(listed, transport)
            coordinator.setSurfaceDemand(true)
            var held: CheckedContinuation<Void, Never>?
            harness.inspectionHold = { await withCheckedContinuation { held = $0 } }
            let thread = try XCTUnwrap(presentation.threadSnapshots[id])
            presentation.setDraft("hello", for: id)
            presentation.sendDraft(for: thread)
            let inspecting = await waitUntil(attempts: 300) { held != nil }
            XCTAssertTrue(inspecting, transport)
            harness.inspectionHold = nil
            harness.publish(event("claude", "SessionEnd", .unavailable, session: "A", at: 200))
            let ended = await waitUntil { coordinator.threadRoutes[id]?.lifecycleEvent?.event == "SessionEnd" || coordinator.threadRoutes[id] == nil }
            XCTAssertTrue(ended, transport)
            held?.resume()
            let settled = await waitUntil { presentation.pendingSends[id] == nil }
            XCTAssertTrue(settled, transport)
            XCTAssertTrue(harness.sentBytes.isEmpty, "\(transport): \(harness.sentBytes)")
            XCTAssertEqual(presentation.draftBinding(for: id), "hello", transport)
            await harness.close()
        }
    }

    private func liveCard(_ coordinator: AgentCenterV2Coordinator, _ id: AgentThreadID) -> AgentActionPrompt? {
        for message in coordinator.presentation.threadSnapshots[id]?.messages ?? [] where message.recordID.hasPrefix("live-prompt-") {
            for case .actionPrompt(let prompt) in message.blocks { return prompt }
        }
        return nil
    }

    /// Claude Code 2.1.285's AskUserQuestion dialog, as the shared-core fixtures captured it.
    private static let claudeQuestionScreen = #"""
✻ Churned for 0s · done 7:21 PM

❯ SCRIPT:ask1
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Database

Which database should the service use for the new ledger?

❯ 1. Postgres (Recommended)
     Mature, transactional, already deployed.
  2. SQLite
     Embedded file, zero operations.
  3. DynamoDB
     Managed key-value store.
  4. Type something.
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""#

    /// The long question on a 56-column phone pane (Claude Code 2.1.285), as
    /// the tmux side channel captures it: `capture-pane -e -N`, styles kept.
    private static let claudePhoneQuestionCapture = #"""
← \#u{1B}[38;5;16m\#u{1B}[48;5;153m ☐ Run plan \#u{1B}[39m\#u{1B}[49m ☐ Report  ✔ Submit  →                    

\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich plan should the next run use? The last run of \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mthe ledger import (src/…/import/batch_job.py, 120 rows
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mper batch) finished in 244 s against a 164–190 s \#u{1B}[0m     
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mbudget, and the retry pass after it took 62.6 s for \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231m33,945 rows. The fast path is about 1.7× quicker than 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mthe current one, but it skips the checksum pass, so a 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mcorrupt batch would only show up in the nightly audit.
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich trade-off do you want?\#u{1B}[0m                          

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1.\#u{1B}[39m \#u{1B}[38;5;153mKeep the current plan (safe)\#u{1B}[39m                       
     \#u{1B}[38;5;246mRun the same batches with the checksum pass on \#u{1B}[39m    
     \#u{1B}[38;5;246mevery batch, and report the timing against the \#u{1B}[39m    
     \#u{1B}[38;5;246m164–190 s budget again so the regression is \#u{1B}[39m       
     \#u{1B}[38;5;246mvisible: −23.63% → about −13%.\#u{1B}[39m                     
  \#u{1B}[38;5;246m2.\#u{1B}[39m Switch to the fast path
     \#u{1B}[38;5;246mSkip the checksum pass for this run, keep a copy of
\#u{1B}[39m     \#u{1B}[38;5;246mevery batch, and rely on the nightly audit to \#u{1B}[39m     
     \#u{1B}[38;5;246mcatch a corrupt one.\#u{1B}[39m   
  \#u{1B}[38;5;246m3.\#u{1B}[39m Stop and report        
     \#u{1B}[38;5;246mStop now and report the partial timings.\#u{1B}[39m           
  \#u{1B}[38;5;246m4. Type something.\#u{1B}[39m        
\#u{1B}[38;5;246m────────────────────────────────────────────────────────
\#u{1B}[39m  5. Chat about this        

\#u{1B}[38;5;246mEnter to select · Tab/Arrow keys to navigate · Esc to \#u{1B}[39m  
\#u{1B}[38;5;246mcancel\#u{1B}[39m        












"""#

    /// The same screen as a raw SSH or mosh terminal grid reads it.
    private static let claudePhoneQuestionScreen = #"""
←  ☐ Run plan  ☐ Report  ✔ Submit  →

│ Which plan should the next run use? The last run of
│ the ledger import (src/…/import/batch_job.py, 120 rows
│ per batch) finished in 244 s against a 164–190 s
│ budget, and the retry pass after it took 62.6 s for
│ 33,945 rows. The fast path is about 1.7× quicker than
│ the current one, but it skips the checksum pass, so a
│ corrupt batch would only show up in the nightly audit.
│ Which trade-off do you want?

❯ 1. Keep the current plan (safe)
     Run the same batches with the checksum pass on
     every batch, and report the timing against the
     164–190 s budget again so the regression is
     visible: −23.63% → about −13%.
  2. Switch to the fast path
     Skip the checksum pass for this run, keep a copy of
     every batch, and rely on the nightly audit to
     catch a corrupt one.
  3. Stop and report
     Stop now and report the partial timings.
  4. Type something.
────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to
cancel












"""#


    func testQuietSweepRetiresRefusedEndBeforeReplacementOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            harness.processIDs = [95_076]
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100, pid: 95_076), in: harness)
            XCTAssertEqual(harness.listedSessions, ["A"], transport)
            // Neither the refused End nor the wrapper's blank exit is delivered.
            harness.processIDs = []
            harness.processNames = ["zsh"]
            harness.retain(event("claude", "WrapperExit", .unavailable, session: "", at: 200, pid: 99))
            let retired = await waitUntil(attempts: 400) { harness.listedSessions.isEmpty }
            XCTAssertTrue(retired, transport)
            let old = harness.threadID("A")
            XCTAssertNil(harness.coordinator.threadRoutes[old], transport)
            XCTAssertNil(harness.coordinator.terminalAdapters[old], transport)
            XCTAssertNil(harness.coordinator.projectionRoutes[old], transport)
            XCTAssertTrue(harness.coordinator.inventoryTasks.isEmpty, transport)
            harness.processIDs = [77]
            harness.processNames = ["claude"]
            await pass(event("claude", "SessionStart", .idle, session: "B", at: 300, pid: 77), in: harness)
            XCTAssertEqual(harness.listedSessions, ["B"], transport)
            await harness.close()
        }
    }

    func testQuietSweepPausesUntilTheAppIsActive() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        await harness.coordinator.setApplicationActive(false)
        let reads = harness.occupancyReads
        harness.hidesPane = true
        harness.occupancyPaneExists = false
        try await Task.sleep(for: .milliseconds(5_200))
        XCTAssertEqual(harness.occupancyReads, reads)
        XCTAssertEqual(harness.listedSessions, ["A"])
        await harness.coordinator.setApplicationActive(true)
        let retired = await waitUntil { harness.listedSessions.isEmpty }
        XCTAssertTrue(retired)
        await harness.close()
    }

    func testRootAndCodexChildSurviveEveryDiscoveryPass() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "codex", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("codex", "SessionStart", .idle, session: "R", at: 100), in: harness)
            XCTAssertEqual(harness.listedSessions, ["R"], transport)
            for frame in [event("codex", "PreToolUse", .working, session: "C", at: 200, agentID: "child-agent"),
                          event("codex", "PreToolUse", .working, session: "R", at: 300),
                          event("codex", "UserPromptSubmit", .working, session: "C", at: 400, agentID: "child-agent")] {
                await pass(frame, in: harness)
                XCTAssertEqual(harness.listedSessions, ["C", "R"], transport)
                XCTAssertNotNil(harness.coordinator.threadRoutes[harness.threadID("R")], transport)
                XCTAssertNotNil(harness.coordinator.threadRoutes[harness.threadID("C")], transport)
            }
            await harness.close()
        }
    }

    func testQuietSweepIsNotPostponedByAnotherPanesFrames() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        harness.processIDs = []
        harness.processNames = ["zsh"]
        for timestamp: UInt64 in 200..<224 {
            harness.publishNeighbour(event("claude", "PreToolUse", .working, session: "B", at: timestamp, pid: 77))
            try await Task.sleep(for: .milliseconds(250))
        }
        let retired = await waitUntil { harness.listedSessions == ["B"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
        XCTAssertTrue(retired)
        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
        await harness.close()
    }

    func testRestoredRootAndCodexChildSurviveEveryDiscoveryPass() async throws {
        for transport in ["ssh+tmux", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "codex", transport: transport, pane: 75)
            await pass(event("codex", "SessionStart", .idle, session: "R", at: 100), in: harness)
            await pass(event("codex", "PreToolUse", .working, session: "C", at: 200, agentID: "child-agent"), in: harness)
            harness.retain(event("codex", "PreToolUse", .working, session: "foreign", at: 300, pid: 999))
            let reads = harness.discoveries.count
            harness.replaceSource()
            let restored = await replacementPassed(harness, after: reads)
            XCTAssertTrue(restored, transport)
            XCTAssertEqual(harness.listedSessions, ["C", "R"], transport)
            for session in ["R", "C"] {
                XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID(session)]?.restoredFromRetiredConnection, true)
                XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID(session)]?.binding.capabilities.contains(.send), false)
            }
            await pass(event("codex", "PreToolUse", .working, session: "R", at: 400), in: harness)
            XCTAssertEqual(harness.listedSessions, ["C", "R"], transport)
            await pass(event("codex", "PreToolUse", .working, session: "C", at: 500, agentID: "child-agent"), in: harness)
            XCTAssertEqual(harness.listedSessions, ["C", "R"], transport)
            await harness.close()
        }
    }

    func testStaleRetainedEventDoesNotKeepItsDeadProcessSeen() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        harness.processIDs = [77]
        let reads = harness.discoveries.count
        harness.coordinator.sessionDiscoveryAfter[harness.sessionID] = .distantPast
        harness.coordinator.scheduleSessionRefresh(sessionID: harness.sessionID)
        let refreshed = await replacementPassed(harness, after: reads)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(harness.listedSessions.isEmpty)
        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
        XCTAssertEqual(harness.coordinator.presentation.listSnapshot.candidates.count, 1)
        await harness.close()
    }

    func testIncompleteProcessReadRetiresNothing() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        let binding = harness.coordinator.threadRoutes[harness.threadID("A")]?.binding
        harness.processIDs = []
        harness.processNames = ["zsh"]
        harness.processSnapshotTakenAtOverride = .distantPast
        harness.occupancyComplete = false
        await pass(event("claude", "WrapperExit", .unavailable, session: "", at: 200), in: harness)
        XCTAssertEqual(harness.listedSessions, ["A"])
        XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID("A")]?.binding, binding)
        await harness.close()
    }

    func testSuspendedAndEditorAgentsSurviveOccupancySweepsOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            let id = harness.threadID("A")
            let binding = harness.coordinator.threadRoutes[id]?.binding
            harness.occupancyProcesses = [.init(pid: 42, providerID: .claude)]
            for foreground in ["zsh", "vim"] {
                harness.processIDs = [99]
                harness.processNames = [foreground]
                let reads = harness.discoveries.count
                harness.coordinator.sessionDiscoveryAfter[harness.sessionID] = .distantPast
                harness.coordinator.scheduleSessionRefresh(sessionID: harness.sessionID)
                let refreshed = await replacementPassed(harness, after: reads)
                XCTAssertTrue(refreshed, "\(transport): \(foreground)")
                await sweep(harness)
                XCTAssertEqual(harness.listedSessions, ["A"], "\(transport): \(foreground)")
                XCTAssertEqual(harness.coordinator.threadRoutes[id]?.binding, binding)
                XCTAssertNotNil(harness.coordinator.terminalAdapters[id])
            }
            await harness.close()
        }
    }

    func testTruncatedOccupancyInventoryRetiresNothingOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane = transport.contains("tmux") ? 75 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            let binding = harness.coordinator.threadRoutes[harness.threadID("A")]?.binding
            harness.occupancySnapshotOverride = .init(panes: [
                .init(paneID: pane.map(String.init), exists: true, complete: false, processes: [])
            ], allPaneIDs: pane.map { [String($0)] })
            let discoveries = harness.discoveries.count
            await sweep(harness)
            XCTAssertEqual(harness.listedSessions, ["A"], transport)
            XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID("A")]?.binding, binding)
            XCTAssertEqual(harness.discoveries.count, discoveries, "\(transport): a sweep must not discover or capture")
            await harness.close()
        }
    }

    func testFailedPaneInventoryDoesNotBlockAnotherPanesRetirement() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        harness.publishNeighbour(event("claude", "SessionStart", .idle, session: "B", at: 200, pid: 77))
        let listed = await waitUntil { harness.listedSessions == ["A", "B"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
        XCTAssertTrue(listed)
        let binding = harness.coordinator.threadRoutes[harness.threadID("B")]?.binding
        harness.processIDs = []
        harness.failedOccupancyPanes = [76]
        harness.failNextDiscovery = true
        await sweep(harness)
        XCTAssertEqual(harness.listedSessions, ["B"])
        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
        XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID("B")]?.binding, binding)
        XCTAssertTrue(harness.failNextDiscovery, "occupancy must not depend on an unrelated capture failure")
        await harness.close()
    }

    func testReusedPIDByAnotherProviderRetiresTheOldConversationOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            harness.occupancyProcesses = [.init(pid: 42, providerID: .codex), .init(pid: 77, providerID: .claude)]
            await sweep(harness)
            XCTAssertTrue(harness.listedSessions.isEmpty, transport)
            XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
            await harness.close()
        }
    }

    func testMissingPaneRetiresOnlyAfterACompletePaneList() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        harness.occupancySnapshotOverride = .init(panes: [])
        await sweep(harness)
        XCTAssertEqual(harness.listedSessions, ["A"])
        harness.occupancySnapshotOverride = .init(panes: [], allPaneIDs: [])
        await sweep(harness)
        XCTAssertTrue(harness.listedSessions.isEmpty)
        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
        await harness.close()
    }

    func testActivationSweepsWithoutAcknowledgingTheFocusedCompletion() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let pane = transport.contains("tmux") ? 75 : nil
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport, pane: pane)
            await pass(event("claude", "Stop", .idle, session: "A", at: 100), in: harness)
            let id = harness.threadID("A")
            XCTAssertEqual(harness.coordinator.attentionEntries().map(\.threadID), [id], transport)
            await harness.coordinator.setApplicationActive(false)
            harness.coordinator.setSwipePadFocus(sessionID: harness.sessionID, paneID: pane)
            let reads = harness.occupancyReads, discoveries = harness.discoveries.count
            await harness.coordinator.setApplicationActive(true)
            let swept = await waitUntil { harness.occupancyReads > reads && harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
            XCTAssertTrue(swept, transport)
            XCTAssertEqual(harness.discoveries.count, discoveries, transport)
            XCTAssertEqual(harness.coordinator.attentionEntries().map(\.threadID), [id], transport)
            await harness.close()
        }
    }

    func testUnlocatableSuccessorRevokesPredecessorWithoutAnActionableRouteOnAllFourTransports() async throws {
        for provider in ["claude", "codex", "kimi"] {
            for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
                for locator in [nil, "/invalid/path"] as [String?] {
                    let harness = await ConversationPaneHarness(provider: provider, transport: transport,
                        pane: transport.contains("tmux") ? 75 : nil)
                    await pass(event(provider, "SessionStart", .idle, session: "A", at: 100), in: harness)
                    let id = harness.threadID("A")
                    let binding = try XCTUnwrap(harness.coordinator.threadRoutes[id]?.binding)
                    let lease = try await harness.coordinator.runtime.acquireLease(threadID: id, action: .send, binding: binding)
                    await pass(event(provider, "SessionStart", .idle, session: "B", at: 200, transcriptRef: locator), in: harness)
                    XCTAssertTrue(harness.listedSessions.isEmpty, "\(provider) \(transport)")
                    for session in ["A", "B"] {
                        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID(session)])
                        XCTAssertNil(harness.coordinator.terminalAdapters[harness.threadID(session)])
                    }
                    let successor = await harness.coordinator.runtime.snapshot(for: harness.threadID("B"))
                    XCTAssertNil(successor, "an envelope is required before registering the successor")
                    do {
                        _ = try await harness.coordinator.runtime.acquireLease(threadID: id, action: .send, binding: binding)
                        XCTFail("\(provider) \(transport): predecessor acquired a send lease")
                    } catch {
                        XCTAssertTrue(error as? AgentActionError == .staleBinding || error as? AgentActionError == .unavailable)
                    }
                    do {
                        try await harness.coordinator.runtime.markOutgoingDispatched(lease)
                        XCTFail("\(provider) \(transport): predecessor's old lease survived")
                    } catch { XCTAssertEqual(error as? AgentActionError, .staleBinding) }
                    await harness.close()
                }
            }
        }
    }

    func testLateOrSameConversationWithoutALocatorDoesNotClearTheHeldRoot() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 200), in: harness)
        let binding = harness.coordinator.threadRoutes[harness.threadID("A")]?.binding
        for (session, timestamp): (String, UInt64) in [("B", 150), ("A", 300)] {
            await pass(event("claude", "SessionStart", .idle, session: session, at: timestamp, transcriptRef: nil), in: harness)
            XCTAssertEqual(harness.listedSessions, ["A"])
            XCTAssertEqual(harness.coordinator.threadRoutes[harness.threadID("A")]?.binding, binding)
        }
        await harness.close()
    }

    func testLateFramesCannotRestoreConversationsClearedByAnUnlocatableSuccessor() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        await pass(event("claude", "SessionStart", .idle, session: "B", at: 200, transcriptRef: nil), in: harness)
        await pass(event("claude", "Stop", .idle, session: "A", at: 150), in: harness)
        XCTAssertTrue(harness.listedSessions.isEmpty)
        XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID("A")])
        await pass(event("claude", "SessionStart", .idle, session: "C", at: 300), in: harness)
        XCTAssertEqual(harness.listedSessions, ["C"])
        await harness.close()
    }

    func testBlankWrapperExitRequestsAnImmediateOccupancySweepOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            harness.processIDs = []
            harness.processNames = ["zsh"]
            let started = ContinuousClock.now
            await pass(event("claude", "WrapperExit", .unavailable, session: "", at: 200, pid: 99), in: harness)
            XCTAssertTrue(harness.listedSessions.isEmpty, transport)
            XCTAssertGreaterThan(harness.occupancyReads, 0, transport)
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), transport)
            await harness.close()
        }
    }

    func testRefusedLifecycleProofRequestsAnImmediateOccupancySweepOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            harness.processIDs = []
            await pass(event("claude", "PreToolUse", .working, session: "A", at: 200), in: harness)
            XCTAssertTrue(harness.listedSessions.isEmpty, transport)
            XCTAssertGreaterThan(harness.occupancyReads, 0, transport)
            await harness.close()
        }
    }

    func testCodexBlankRootRetiresItsRootAndChildOnly() async throws {
        let harness = await ConversationPaneHarness(provider: "codex", transport: "ssh+tmux", pane: 75)
        await pass(event("codex", "SessionStart", .idle, session: "R", at: 100), in: harness)
        await pass(event("codex", "PreToolUse", .working, session: "C", at: 200, agentID: "child-agent"), in: harness)
        harness.publishNeighbour(event("claude", "SessionStart", .idle, session: "other", at: 250, pid: 77))
        let other = await waitUntil { harness.listedSessions == ["C", "R", "other"] && harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
        XCTAssertTrue(other)
        await pass(event("codex", "SessionStart", .idle, session: "", at: 300), in: harness)
        XCTAssertEqual(harness.listedSessions, ["other"])
        for session in ["R", "C"] {
            XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID(session)])
            XCTAssertNil(harness.coordinator.terminalAdapters[harness.threadID(session)])
        }
        await harness.close()
    }

    func testLateCodexBlankRootCannotClearANewerConversation() async throws {
        let harness = await ConversationPaneHarness(provider: "codex", transport: "ssh+tmux", pane: 75)
        await pass(event("codex", "SessionStart", .idle, session: "R", at: 300), in: harness)
        await pass(event("codex", "SessionStart", .idle, session: "", at: 200), in: harness)
        XCTAssertEqual(harness.listedSessions, ["R"])
        XCTAssertTrue(harness.coordinator.presentation.listSnapshot.candidates.isEmpty)
        await harness.close()
    }

    func testResumeIntoAnotherPaneKeepsOrTransfersTheWholeRoute() async throws {
        for oldProcessAlive in [true, false] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
            await pass(event("claude", "SessionStart", .idle, session: "B", at: 100), in: harness)
            let id = harness.threadID("B")
            let oldRoute = try XCTUnwrap(harness.coordinator.threadRoutes[id])
            let oldAdapter = try XCTUnwrap(harness.coordinator.terminalAdapters[id])
            if !oldProcessAlive { harness.processIDs = []; harness.processNames = ["zsh"] }
            for timestamp: UInt64 in [200, 300, 400] {
                let reads = harness.discoveries.count
                harness.publishNeighbour(event("claude", "SessionStart", .idle, session: "B", at: timestamp, pid: 77))
                let refreshed = await replacementPassed(harness, after: reads)
                XCTAssertTrue(refreshed)
                XCTAssertEqual(harness.listedSessions, ["B"])
                if oldProcessAlive {
                    XCTAssertEqual(harness.coordinator.threadRoutes[id]?.binding, oldRoute.binding)
                    XCTAssertTrue(harness.coordinator.terminalAdapters[id] === oldAdapter)
                } else {
                    XCTAssertEqual(harness.coordinator.threadRoutes[id]?.binding.paneID, "76")
                    XCTAssertEqual(harness.coordinator.threadRoutes[id]?.binding.agentPID, 77)
                    XCTAssertFalse(harness.coordinator.terminalAdapters[id] === oldAdapter)
                }
            }
            await harness.close()
        }
    }

    func testLateFramesCannotResurrectReplacedConversationTenures() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        for (session, timestamp): (String, UInt64) in [("A", 100), ("B", 200), ("C", 300)] {
            await pass(event("claude", "SessionStart", .idle, session: session, at: timestamp), in: harness)
            XCTAssertEqual(harness.listedSessions, [session])
        }
        for frame in [event("claude", "Stop", .idle, session: "A", at: 150),
                      event("claude", "SessionStart", .idle, session: "B", at: 250)] {
            await pass(frame, in: harness)
            XCTAssertEqual(harness.listedSessions, ["C"])
            XCTAssertNil(harness.coordinator.threadRoutes[harness.threadID(frame.providerSessionID)])
        }
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 400), in: harness)
        await pass(event("claude", "SessionEnd", .unavailable, session: "A", at: 175), in: harness)
        XCTAssertEqual(harness.listedSessions, ["A"])
        XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[harness.threadID("A")]?.conversationEnded, false)
        await harness.close()
    }

    func testRefreshQueuePreservesConversationFramesAndTheirNewestTimestamps() {
        var queue = AgentCenterV2SessionRefreshQueue()
        queue.enqueue(paneID: 75, lifecycle: event("claude", "SessionStart", .idle, session: "B", at: 300))
        queue.enqueue(paneID: 75, lifecycle: event("claude", "Stop", .idle, session: "A", at: 100))
        queue.enqueue(paneID: 75, lifecycle: event("claude", "SessionEnd", .unavailable, session: "B", at: 200))
        XCTAssertEqual(queue.dequeue()?.lifecycle?.providerSessionID, "B")
        XCTAssertEqual(queue.dequeue()?.lifecycle?.providerSessionID, "A")
        XCTAssertTrue(queue.isEmpty)
    }

    func testRestoredResumedConversationIgnoresItsOldTenuresEnd() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        await pass(event("claude", "SessionStart", .idle, session: "B", at: 200), in: harness)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 300), in: harness)
        harness.retain(event("claude", "SessionEnd", .unavailable, session: "A", at: 150))
        let reads = harness.discoveries.count
        harness.replaceSource()
        let restored = await replacementPassed(harness, after: reads)
        XCTAssertTrue(restored)
        XCTAssertEqual(harness.listedSessions, ["A"])
        XCTAssertEqual(harness.coordinator.presentation.threadSnapshots[harness.threadID("A")]?.conversationEnded, false)
        await harness.close()
    }

    func testEndedConversationKeepsComposerDraftWithoutDispatch() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        await pass(event("claude", "SessionEnd", .unavailable, session: "A", at: 200), in: harness)
        let id = harness.threadID("A")
        let snapshot = try XCTUnwrap(harness.coordinator.presentation.threadSnapshots[id])
        XCTAssertEqual(snapshot.conversationEnded, true)
        let model = harness.coordinator.presentation
        var sends = 0
        model.onAction = { if case .send = $0 { sends += 1 } }
        model.setDraft("keep this draft", for: id)
        model.sendDraft(for: snapshot)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(model.draftBinding(for: id), "keep this draft")
        XCTAssertTrue(model.capabilityNotice?.contains("conversation has ended") == true)
        await harness.close()
    }

    func testTerminalOpenPropagatesInputNotReady() async throws {
        let harness = await ConversationPaneHarness(provider: "claude", transport: "ssh+tmux", pane: 75)
        await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
        harness.inspectionUnavailable = true
        let presentation = harness.coordinator.presentation
        presentation.onAction?(.openTerminal(harness.threadID("A")))
        let reported = await waitUntil { presentation.capabilityNotice != nil }
        XCTAssertTrue(reported)
        XCTAssertEqual(presentation.capabilityNotice,
            "The agent's input wasn't ready, so nothing was typed into the terminal.")
        await harness.close()
    }

    func testSecondTerminalOpenInspectionExhaustionReportsInputNotReadyOnAllFourTransports() async throws {
        for transport in ["ssh", "ssh+tmux", "mosh", "mosh+tmux"] {
            let harness = await ConversationPaneHarness(provider: "claude", transport: transport,
                pane: transport.contains("tmux") ? 75 : nil)
            await pass(event("claude", "SessionStart", .idle, session: "A", at: 100), in: harness)
            harness.inspectionUnavailableAfter = 1
            let presentation = harness.coordinator.presentation
            presentation.onAction?(.openTerminal(harness.threadID("A")))
            let reported = await waitUntil { presentation.capabilityNotice != nil }
            XCTAssertTrue(reported, transport)
            XCTAssertEqual(presentation.capabilityNotice,
                "The agent's input wasn't ready, so nothing was typed into the terminal.", transport)
            await harness.close()
        }
    }

    private func sweep(_ harness: ConversationPaneHarness) async {
        let reads = harness.occupancyReads
        harness.coordinator.scheduleLivenessSweep(sessionID: harness.sessionID)
        let swept = await waitUntil { harness.occupancyReads > reads && harness.coordinator.sessionRefreshIsIdle(harness.sessionID) }
        XCTAssertTrue(swept)
    }

    private func pass(_ frame: AgentLifecycleEvent, in harness: ConversationPaneHarness) async {
        let reads = harness.discoveries.count
        harness.publish(frame)
        let refreshed = await waitUntil(attempts: 200) {
            harness.discoveries.count > reads && harness.coordinator.sessionRefreshIsIdle(harness.sessionID)
        }
        XCTAssertTrue(refreshed)
    }

    private func event(_ provider: String, _ name: String, _ state: Tessera.AgentStatus, session: String, at timestamp: UInt64,
                       pid: Int = 42, agentID: String? = nil, transcriptRef: String? = "c2Vzc2lvbg") -> AgentLifecycleEvent {
        .init(version: 9, provider: provider, event: name, state: state, reason: "fixture",
              timestampNanoseconds: timestamp, providerSessionID: session, turnID: "", notificationType: "",
              permissionMode: "", agentPID: pid, transcriptRef: transcriptRef, agentID: agentID,
              rootAgentID: nil)
    }

    private func lifecycleEvent(turnID: String, timestampNanoseconds: UInt64) -> AgentLifecycleEvent {
        .init(
            version: 9,
            provider: "codex",
            event: "Stop",
            state: .idle,
            reason: "turn-stopped",
            timestampNanoseconds: timestampNanoseconds,
            providerSessionID: "session",
            turnID: turnID,
            notificationType: "",
            permissionMode: "",
            agentPID: 42,
            transcriptRef: "c2Vzc2lvbg"
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeThreadID() -> AgentThreadID {
        AgentThreadID(
            hostID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000099")!,
            providerID: .claude,
            providerSessionID: "coordinator-test"
        )!
    }

    private func location(sessionID: UUID, paneID: Int?) -> AgentLocation {
        AgentLocation(
            sessionID: sessionID,
            hostName: "test host",
            transportLabel: paneID == nil ? "ssh" : "ssh+tmux",
            tmuxSessionName: paneID == nil ? nil : "test",
            windowID: paneID == nil ? nil : 1,
            windowName: paneID == nil ? nil : "window",
            paneID: paneID
        )
    }

    private func binding(
        capabilities: AgentTerminalCapabilities,
        agentPID: Int?
    ) -> AgentTerminalBinding {
        AgentTerminalBinding(
            liveSessionID: UUID(),
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("candidate-test")!,
            transport: .ssh,
            agentPID: agentPID,
            capabilities: capabilities
        )
    }
}

/// One pane running one provider process, whose conversation and child
/// processes the test changes between discovery passes.
@MainActor
private final class ConversationPaneHarness {
    let coordinator: AgentCenterV2Coordinator
    private(set) var sessionID = UUID(), hostID = UUID()
    let provider: String
    let pane: Int?
    private let transport: String
    private let checksIntegration: Bool
    var processIDs: Set<Int> = [42]
    var processNames: [String]?
    /// A process read discovery kept from before `processIDs` changed; it
    /// serves this until the source is told to read the host again.
    var staleProcessIDs: Set<Int>? {
        didSet { staleReadAt = Date() }
    }
    private var staleReadAt = Date()
    private(set) var invalidations = 0
    var failNextDiscovery = false
    var failNextProcessReadDiscovery = false
    /// Discovery finds no agent on the pane (tmux detached, job stopped).
    var hidesPane = false
    var windowName = "fixture"
    var tmuxSessionName = "fixture"
    /// An unread pane has no timestamped process proof for recovery.
    var processSnapshotTakenAtOverride: Date?
    var occupancyProcesses: [AgentOccupancyObservation.Process]?
    var occupancyComplete = true
    var occupancyPaneExists = true
    var occupancySnapshotOverride: AgentSessionOccupancySnapshot?
    var failedOccupancyPanes = Set<Int?>()
    private(set) var occupancyReads = 0
    var visibleText = "❯ "
    /// While set, a capture waits here before it reads the screen.
    var inspectionHold: (@MainActor () async -> Void)?
    private(set) var sentBytes: [[UInt8]] = []
    var inspectionUnavailable = false
    var inspectionUnavailableAfter: Int?
    private var inspections = 0
    /// A Claude agent on the next pane (tmux only), when published.
    private var neighbour: AgentLifecycleEvent?
    /// What each discovery pass found when it started: the state the
    /// previous pass left.
    private(set) var discoveries: [(listed: [String], bindings: [AgentThreadID: AgentTerminalBinding], selected: AgentThreadID?)] = []
    private var current: AgentLifecycleEvent?
    private var source: AgentSessionSource!
    private let directory: URL

    /// `checksIntegration` adds the top bar's check. Its target is the
    /// foreground agent, whose process snapshot alone cannot confirm its
    /// lifecycle without the separately proven route.
    init(provider: String, transport: String, pane: Int?, checksIntegration: Bool = false) async {
        self.provider = provider
        self.pane = pane
        self.transport = transport
        self.checksIntegration = checksIntegration
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-\(UUID())")
        coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        registerSource()
        if provider == "kimi" {
            coordinator.sessionConformingProviders[sessionID] = [.kimi]
            await coordinator.configureRegistryForLiveGates()
        }
    }

    private func registerSource() {
        let location: @MainActor (Int?) -> AgentLocation = { [unowned self] pane in
            AgentLocation(sessionID: sessionID, hostName: "fixture", transportLabel: transport,
                tmuxSessionName: pane == nil ? nil : tmuxSessionName, windowID: pane == nil ? nil : 1,
                windowName: pane == nil ? nil : windowName, paneID: pane)
        }
        let targets: @MainActor () -> [AgentProbeTarget] = { [unowned self] in
            // Raw SSH and mosh deliver hooks only as OSC frames; tmux panes
            // also retain the last one.
            let names = processNames ?? ([provider] + (current.flatMap { event in
                event.agentPID.map(processIDs.contains) == true ? [event.provider] : nil
            } ?? []))
            return [AgentProbeTarget(location: location(pane), processNames: names, processIDs: staleProcessIDs ?? processIDs,
                visibleText: visibleText, lifecycleEvent: pane == nil ? nil : current, bracketedPasteEnabled: false,
                processSnapshotTakenAt: processSnapshotTakenAtOverride ?? (staleProcessIDs == nil ? Date() : staleReadAt))]
            + (pane.flatMap { pane in neighbour.map { event in
                AgentProbeTarget(location: location(pane + 1), processNames: [event.provider], processIDs: event.agentPID.map { [$0] } ?? [43],
                    visibleText: "❯ ", lifecycleEvent: event, bracketedPasteEnabled: false)
            } }.map { [$0] } ?? [])
        }
        let discover: @MainActor (Int?) async -> AgentDiscoveryResult = { [unowned self] expectedPID in
            discoveries.append((listedSessions, coordinator.presentation.threadSnapshots.compactMapValues(\.binding),
                                coordinator.presentation.selectedThreadID))
            if failNextDiscovery {
                failNextDiscovery = false
                return .unavailable
            }
            if let expectedPID = expectedPID ?? (pane == nil ? nil : current?.agentPID),
               let staleProcessIDs, !staleProcessIDs.contains(expectedPID) {
                self.staleProcessIDs = nil
                if failNextProcessReadDiscovery {
                    failNextProcessReadDiscovery = false
                    return .unavailable
                }
            }
            return .success(hidesPane ? [] : targets())
        }
        source = AgentSessionSource(registrationID: UUID(), sessionID: sessionID,
            discover: { await discover(nil) }, discoverForLifecycle: discover,
            observeOccupancy: { [unowned self] bindings in
                occupancyReads += 1
                if let occupancySnapshotOverride { return occupancySnapshotOverride }
                let paneIDs = Set(bindings.map { $0.paneID.flatMap(Int.init) })
                let panes = paneIDs.compactMap { id -> AgentOccupancyObservation.Pane? in
                    guard !failedOccupancyPanes.contains(id) else { return nil }
                    if id == pane {
                        return .init(paneID: id.map(String.init), exists: occupancyPaneExists, complete: occupancyComplete,
                            processes: occupancyProcesses ?? processIDs.map { pid in
                                .init(pid: pid, providerID: AgentProviderID(rawValue: current?.agentPID == pid ? current!.provider : provider)!)
                            })
                    }
                    if let pane, id == pane + 1, let neighbour {
                        return .init(paneID: id.map(String.init), exists: true, complete: true,
                            processes: neighbour.agentPID.map { [.init(pid: $0, providerID: AgentProviderID(rawValue: neighbour.provider)!)] } ?? [])
                    }
                    return nil
                }
                let allPaneIDs = pane.map { pane in
                    (occupancyPaneExists ? [String(pane)] : []) + (neighbour == nil ? [] : [String(pane + 1)])
                }
                return .init(panes: panes, allPaneIDs: allPaneIDs)
            }, observe: { _ in nil },
            inspect: { [unowned self] location in
                inspections += 1
                if let hold = inspectionHold { await hold() }
                if inspectionUnavailable || inspectionUnavailableAfter.map({ inspections > $0 }) == true { return nil }
                return targets().first { $0.location.paneID == location.paneID } ?? targets()[0]
            },
            automaticallyProbeLifecycleIntegration: checksIntegration,
            probeLifecycleIntegration: checksIntegration ? { .current } : nil,
            inspectCurrentIntegration: checksIntegration ? { [unowned self] in
                AgentCurrentIntegrationTarget(location: location(pane), foreground: .agent, processIDs: processIDs,
                    shellIntegrationActive: false, agentIntegrationActive: false, agentRequiresLifecycleHook: true)
            } : nil,
            send: { [unowned self] _, bytes in sentBytes.append(bytes); return false }, jump: { _ in },
            invalidateProcessSnapshots: { [unowned self] in
                staleProcessIDs = nil
                invalidations += 1
            })
        coordinator.registerSessionSource(source, hostID: hostID, profiles: { [.builtInClaudeCode, .builtInCodexCLI, .builtInKimi] })
    }

    /// Foreground restore retires the old carrier, then attaches a new live
    /// session through its own tmux view session. The pane keeps its option.
    func replaceSource(hostID: UUID? = nil) {
        unregisterSource()
        sessionID = UUID()
        if let hostID { self.hostID = hostID }
        tmuxSessionName = "restored-view"
        registerSource()
    }

    func retain(_ event: AgentLifecycleEvent?) {
        current = event
    }

    func unregisterSource() {
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: source.registrationID)
    }

    func threadID(_ session: String) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: AgentProviderID(rawValue: provider)!, providerSessionID: session)!
    }

    var listedSessions: [String] {
        coordinator.presentation.listSnapshot.threads.map(\.id.providerSessionID).sorted()
    }

    func applied(_ event: String, session: String) -> Bool {
        coordinator.presentation.threadSnapshots[threadID(session)]?.activity.contains { $0.title == event } == true
    }

    func publish(_ event: AgentLifecycleEvent) {
        current = event
        coordinator.scheduleSessionRefresh(sessionID: sessionID, paneID: pane, lifecycle: event)
    }

    /// Delivers a hook's frame as the transport does: tmux announces the
    /// pane's option, and raw SSH and mosh carry the hook's OSC in the output.
    func deliver(_ json: String) {
        if let pane {
            current = AgentLifecycleEvent.decode(json: json)
            coordinator.noteLifecyclePayload(sessionID: sessionID, paneID: pane, registrationID: source.registrationID, json: json)
        } else {
            let osc = "\u{1B}]1337;TesseraAgentState=\(Data(json.utf8).base64EncodedString())\u{07}"
            coordinator.noteOutput(sessionID: sessionID, paneID: nil, registrationID: source.registrationID, data: Array(osc.utf8)[...])
        }
    }

    func publishNeighbour(_ event: AgentLifecycleEvent) {
        guard let pane else { return }
        neighbour = event
        coordinator.scheduleSessionRefresh(sessionID: sessionID, paneID: pane + 1, lifecycle: event)
    }

    func close() async {
        coordinator.unregisterSessionSource(sessionID: sessionID, registrationID: source.registrationID)
        await coordinator.setExperimentEnabled(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class AgentThreadListSectionTests: XCTestCase {
    private func summary(_ session: String, status: TesseraCore.AgentStatus, attention: TesseraCore.AgentAttention) -> AgentThreadSummary {
        AgentThreadSummary(id: AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: session)!,
            providerName: "Claude", status: status, attention: attention,
            availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false))
    }

    func testAttentionSectionsHoldEachThreadOnceAndKeepTheirIdentity() throws {
        let rows = [
            summary("waiting", status: .waitingForInput, attention: .needsYou),
            summary("busy", status: .working, attention: .none),
            summary("busy-unread", status: .working, attention: .unreadCompletion),
            summary("done", status: .finished, attention: .unreadCompletion),
            summary("idle", status: .idle, attention: .none),
        ]
        let sections = AgentThreadListSection.sections(for: rows, grouping: .attention)
        XCTAssertEqual(sections.map(\.id), ["needs you", "working", "finished", "recent"])
        XCTAssertEqual(sections.map { $0.rows.map(\.id.providerSessionID) },
                       [["waiting"], ["busy", "busy-unread"], ["done"], ["idle"]])
        let placed = sections.flatMap(\.rows).map(\.id)
        XCTAssertEqual(Set(placed).count, placed.count, "a thread renders in one section only")
        XCTAssertEqual(placed.count, rows.count)

        // A section keeps its identity when the sections before it vanish:
        // the lazy list must not reuse "needs you" for another category.
        let later = AgentThreadListSection.sections(for: [rows[0]], grouping: .attention)
        XCTAssertEqual(later.map(\.id), ["needs you"])
        let without = AgentThreadListSection.sections(for: Array(rows.dropFirst()), grouping: .attention)
        XCTAssertEqual(without.first?.id, "working")

        // A row is keyed by its section too: a thread moving from working to
        // needs you gets a new row rather than the one the list drew before.
        var asked = rows[1]
        asked.status = .waitingForInput
        asked.attention = .needsYou
        let before = try XCTUnwrap(sections[1].keyedRows.first?.id)
        let after = try XCTUnwrap(AgentThreadListSection.sections(for: [asked], grouping: .attention).first?.keyedRows.first?.id)
        XCTAssertEqual(before.thread, after.thread)
        XCTAssertNotEqual(before, after)
    }

    func testSectionMoveKeepsACardVisibleInEitherCallbackOrder() throws {
        let thread = summary("moving", status: .working, attention: .none)
        let old = try XCTUnwrap(AgentThreadListSection.sections(for: [thread], grouping: .attention).first?.keyedRows.first?.id)
        var asked = thread
        asked.status = .waitingForInput
        asked.attention = .needsYou
        let new = try XCTUnwrap(AgentThreadListSection.sections(for: [asked], grouping: .attention).first?.keyedRows.first?.id)

        // The new row appears before the old one goes: nothing changes.
        var visibility = AgentThreadListSection.Visibility()
        XCTAssertEqual(visibility.set(old, visible: true), true)
        XCTAssertNil(visibility.set(new, visible: true))
        XCTAssertNil(visibility.set(old, visible: false))
        XCTAssertEqual(visibility.set(new, visible: false), false)

        // The old row goes first: the card leaves and comes back, in order.
        visibility = AgentThreadListSection.Visibility()
        XCTAssertEqual(visibility.set(old, visible: true), true)
        XCTAssertEqual(visibility.set(old, visible: false), false)
        XCTAssertEqual(visibility.set(new, visible: true), true)
        XCTAssertEqual(visibility.keys, [new])
    }
}
