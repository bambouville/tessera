import XCTest
import TesseraCore
import TmuxControl
import SwiftTerm
@testable import Tessera

final class AppleAgentServicesTests: XCTestCase {
    func testSendAnywayEligibilityExcludesIdentityAndAmbiguousFailures() {
        let reasons = ["capture-unavailable", "composer-occupied", "composer-unrecognized",
                       "composer-blocked", "cursor-hidden", "prompt-visible"]
        for reason in reasons {
            XCTAssertTrue(AppleAgentSendNotWritten(error: .inputNotReady, reason: reason, attempts: 1, shape: nil).allowsSendAnyway)
        }
        for reason in ["receipt", "route", "conversation-ended", "inspect", "fence", "dispatch", "cancelled",
                       "queue-unsupported", "target-unproven", "input-policy", "transport-not-admitted"] {
            XCTAssertFalse(AppleAgentSendNotWritten(error: .inputNotReady, reason: reason, attempts: 1, shape: nil).allowsSendAnyway, reason)
        }
        for error in [AgentActionError.staleBinding, .cancelled, .unavailable, .verificationFailed] {
            XCTAssertFalse(AppleAgentSendNotWritten(error: error, reason: "composer-unrecognized", attempts: 1, shape: nil).allowsSendAnyway)
        }
    }

    @MainActor
    func testSendAnywayBypassesComposerChecksAndSubmitsOneSemanticKeyOnEveryTransport() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for provider in [AgentProviderID.codex, .claude] {
                for queue in [false, true] {
                    let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                        incarnation: AgentIncarnationToken("override")!, transport: transport,
                        tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                    let thread = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "override")!
                    let normal = AgentTextSendRequest(threadID: thread, binding: binding, text: "first\nsecond", queueWhenWorking: queue)!
                    let override = AgentTextSendRequest(threadID: thread, binding: binding, text: normal.text,
                        queueWhenWorking: queue, composerVerification: .userOverride)!
                    var writes: [Data] = [], keys: [AppleAgentTerminalKey] = []
                    var inspections = 0, dispatched = 0
                    let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                        inspect: { _ in
                            inspections += 1
                            // Identity is authoritative while the UI is a
                            // future, unrecognized provider composer.
                            return .init(observation: .init(binding: binding, liveTail: "future composer"), queueSupported: true,
                                composerRow: 0, composerColumn: 0, composerCursorVisible: false, bracketedPasteEnabled: true)
                        }, sendText: { bytes, purpose, expected, inspection in
                            XCTAssertEqual(expected, binding)
                            XCTAssertNotNil(AppleAgentTerminalInputPolicy.bytes(bytes, purpose: purpose,
                                provider: provider.rawValue, bracketedPasteEnabled: inspection.bracketedPasteEnabled))
                            writes.append(bytes); return true
                        }, sendKey: { key, expected, _ in
                            XCTAssertEqual(expected, binding); keys.append(key); return true
                        }, verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .staleBinding }
                    ), readinessWindow: .zero)
                    do { try await adapter.sendText(normal); XCTFail("normal send bypassed composer checks") }
                    catch { XCTAssertTrue(try XCTUnwrap(error as? AppleAgentSendNotWritten).allowsSendAnyway) }
                    XCTAssertTrue(writes.isEmpty)
                    try await adapter.sendText(override, beforeWrite: { await MainActor.run { dispatched += 1 } })
                    try await adapter.sendReturn(binding: binding)
                    do { try await adapter.sendReturn(binding: binding); XCTFail("the submission key was repeated") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                    try await adapter.verifySubmission(threadID: thread, binding: binding)
                    XCTAssertEqual(writes, [Data(normal.text.utf8)])
                    XCTAssertEqual(keys, [provider == .codex && queue ? .tab : .return])
                    XCTAssertEqual(dispatched, 1)
                    XCTAssertGreaterThanOrEqual(inspections, 3, "ordinary refusal, override text proof, override key proof")
                }
            }
        }
    }

    @MainActor
    func testSendAnywayStillWaitsForClaudeToAttachAnImage() async throws {
        for attaches in [true, false] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("override-image")!, transport: .moshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "override-image")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "\"/tmp/a.png\"\nReply with one word: ok",
                queueWhenWorking: false, composerVerification: .userOverride)!
            var writes = 0, afterCaptures = 0
            var capturesAtKey: Int?
            let footer = "\n──────────────────────────────\n? for shortcuts"
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    if writes > 0 {
                        afterCaptures += 1
                        // A slow link: every check would add up to seconds.
                        if !attaches { try await Task.sleep(for: .milliseconds(150)) }
                    }
                    let rows = writes == 0 ? ["❯ "]
                        : [attaches && afterCaptures > 3 ? "❯ [Image #1]" : "❯ \"/tmp/a.png\"", "  Reply with one word: ok"]
                    let visible = rows.joined(separator: "\n") + footer
                    return .init(observation: .init(binding: binding, liveTail: visible), composerText: rows.last,
                        composerRow: rows.count - 1, composerVisibleText: visible, composerCursorVisible: true)
                }, sendText: { _, _, _, _ in writes += 1; return true },
                sendKey: { _, _, _ in capturesAtKey = afterCaptures; return true },
                verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .staleBinding }
            ), readinessWindow: .zero)
            let started = ContinuousClock.now
            try await adapter.sendText(request)
            try await adapter.sendReturn(binding: binding)
            let captures = try XCTUnwrap(capturesAtKey, "an approved send still submits")
            // Return waits for the marker, or for a bounded moment when the
            // composer never reads as attached, not for all 40 checks.
            if attaches {
                XCTAssertGreaterThan(captures, 3)
            } else {
                XCTAssertGreaterThan(captures, 5)
                XCTAssertLessThan(captures, 25)
                XCTAssertLessThan(started.duration(to: .now), AppleAgentTerminalAdapter.overrideImageWait + .seconds(1))
            }
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testSendAnywayStillRefusesStaleIdentityAndCancelledDispatch() async throws {
        for stale in [false, true] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("override-fence")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "override-fence")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false,
                composerVerification: .userOverride)!
            var writes = 0
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    if stale { throw AgentActionError.staleBinding }
                    return .init(observation: .init(binding: binding, liveTail: "unknown composer"))
                }, sendText: { _, _, _, _ in writes += 1; return true }, sendKey: { _, _, _ in true },
                verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .staleBinding }
            ), readinessWindow: .zero)
            do {
                try await adapter.sendText(request, beforeWrite: { throw CancellationError() })
                XCTFail("override ignored identity or cancellation")
            } catch {
                let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten)
                XCTAssertEqual(refusal.error, stale ? .staleBinding : .cancelled)
                XCTAssertFalse(refusal.allowsSendAnyway)
            }
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testConcurrentSendAnywaySubmissionConsumesTheKeyBeforeInspection() async throws {
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("override-once")!, transport: .sshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
        let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "override-once")!
        let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false,
            composerVerification: .userOverride)!
        var keys: [AppleAgentTerminalKey] = []
        let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
            inspect: { _ in await Task.yield(); return .init(observation: .init(binding: binding, liveTail: "unknown composer")) },
            sendText: { _, _, _, _ in true }, sendKey: { key, _, _ in keys.append(key); return true },
            verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .staleBinding }
        ), readinessWindow: .zero)
        try await adapter.sendText(request)
        let first = Task { () -> Bool in do { try await adapter.sendReturn(binding: binding); return true } catch { return false } }
        let second = Task { () -> Bool in do { try await adapter.sendReturn(binding: binding); return true } catch { return false } }
        let results = await [first.value, second.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(keys, [.return])
    }

    func testProjectionFailureReasonNamesTheHostCodeWithoutContent() {
        // A failed native read used to log only "transport"; the host's
        // allowlisted classifier token is the diagnosable part.
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentIngestionError.remote("codexOrdinalDiscontinuity")),
                       "ingestion/remote/codexOrdinalDiscontinuity")
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentIngestionError.capacityExceeded), "ingestion/capacityExceeded")
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentProjectionError.sourceChanged), "sourceChanged")
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentActionError.staleBinding), "action/staleBinding")
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(CancellationError()), "transport")
        // An old host without read statuses sends its raw error text as the code.
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentIngestionError.remote("open /home/x/.codex: denied")),
                       "ingestion/remote/unclassified")
        XCTAssertEqual(AgentCenterV2Coordinator.projectionFailureReason(AgentIngestionError.remote("")), "ingestion/remote/unclassified")
        // Eight host codes are exactly 22 characters, the mosh key width the
        // diagnostics sanitizer redacts; the slash-joined tokens survive it.
        for line in ["v2-read-status provider=codex status=failed/source/manual/subscriptionAckExpired",
                     "v2-project result=failed provider=codex older=false reason=ingestion/remote/codexMissingLiveAnchor",
                     "v2-summary provider=codex metadata=issue/codexTitleUnavailable",
                     "v2-summary provider=codex metadata=issue/codexTitleUnavailable/opencodeDatabaseUnavailable"] {
            XCTAssertEqual(DiagnosticLogStore.sanitizedMessageForTesting(line), line)
        }
        XCTAssertEqual(DiagnosticLogStore.sanitizedMessageForTesting("code=subscriptionAckExpired"), "code=<redacted-key>")
        // A joined token that lands on exactly 22 characters is padded past
        // the sanitizer; the real formatter is what the log line carries.
        let padded = AgentCenterV2Coordinator.diagnosticToken(["issue", "titleUnavailable"])
        XCTAssertEqual(padded, "issue/titleUnavailable/padded")
        let summaryLine = "v2-summary provider=codex metadata=\(padded)"
        XCTAssertEqual(DiagnosticLogStore.sanitizedMessageForTesting(summaryLine), summaryLine)
        XCTAssertEqual(DiagnosticLogStore.sanitizedMessageForTesting("metadata=issue/titleUnavailable"), "metadata=<redacted-key>")
        XCTAssertEqual(AgentCenterV2Coordinator.diagnosticToken(["failed", "host", "manual", "abc"]), "failed/host/manual/abc/padded")
        XCTAssertEqual(AgentCenterV2Coordinator.diagnosticToken(["ingestion", "capacityExceeded"]), "ingestion/capacityExceeded")
    }

    /// An unproven live Codex terminal used to be titled with the composer's
    /// placeholder. Only typed input names the row or previews a thread;
    /// otherwise the provider does and the preview stays empty.
    func testCandidateTitleIgnoresComposerPlaceholders() throws {
        let codex = try XCTUnwrap(AgentProviderRegistry.builtIn.manifest(for: .codex))
        let claude = try XCTUnwrap(AgentProviderRegistry.builtIn.manifest(for: .claude))
        let location = AgentLocation(sessionID: UUID(), hostName: "fixture", transportLabel: "ssh",
            tmuxSessionName: nil, windowID: nil, windowName: nil, paneID: nil)
        func target(_ line: String?, visibleText: String? = nil, cursorRow: Int? = nil) -> AgentProbeTarget {
            AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42], visibleText: visibleText,
                currentInputLine: line, cursorRow: cursorRow, bracketedPasteEnabled: false)
        }
        for line in ["› Ask Codex to do anything", "› ", nil, ""] as [String?] {
            XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target(line), provider: codex), "Codex", line ?? "nil")
            XCTAssertNil(AgentCenterV2Coordinator.rowPreview(for: target(line), provider: codex), line ?? "nil")
        }
        for line in ["› Ask Codex to do anything now", "› fix the flaky test"] {
            XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target(line), provider: codex), line)
            XCTAssertEqual(AgentCenterV2Coordinator.rowPreview(for: target(line), provider: codex), line)
        }
        XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target("❯"), provider: claude), claude.displayName)
        XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target("❯ Try \"fix the bug\""), provider: claude), "❯ Try \"fix the bug\"")
        // A tmux capture keeps SGR, so a renamed DIM placeholder is recognized from its own row.
        let dim = "banner\n› \u{1b}[2mImplement {feature}\u{1b}[0m"
        XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target("› Implement {feature}", visibleText: dim, cursorRow: 1), provider: codex), "Codex")
        XCTAssertNil(AgentCenterV2Coordinator.rowPreview(for: target("› Implement {feature}", visibleText: dim, cursorRow: 1), provider: codex))
        XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target("› Implement {feature}", visibleText: "banner\n› Implement {feature}", cursorRow: 1), provider: codex), "› Implement {feature}")
        let long = String(repeating: "x", count: 600)
        XCTAssertEqual(AgentCenterV2Coordinator.candidateTitle(for: target(long), provider: codex).count, 512)
        XCTAssertEqual(AgentCenterV2Coordinator.rowPreview(for: target(long), provider: codex)?.count, 600)
    }

    @MainActor
    func testNativeReadCompletionClearsOnlyCurrentProgressAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let (coordinator, thread, binding, _) = try await makeInitialPrefetchFixture(transport: transport)
            let host = try XCTUnwrap(coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: binding.liveSessionID, binding: binding)])
            let connection = try XCTUnwrap(host.connection)
            let progress = try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("preparing"),
                "domain": .string("host"), "recovery": .string("continue"), "code": .string("fixtureProgress")]))
            let failure = try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("resourceLimited"),
                "domain": .string("host"), "recovery": .string("manual"), "code": .string("fixtureFailure")]))
            coordinator.ingestionReadFailureCounts[thread] = 4
            await connection.onReadStatus?("thread", progress)
            await connection.onReadComplete?("unrelated-thread")
            XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread], progress)
            await connection.onReadComplete?("thread")
            XCTAssertNil(coordinator.presentation.ingestionReadStatuses[thread], "An unchanged completed read must clear Preparing")
            XCTAssertEqual(coordinator.ingestionReadFailureCounts[thread], 4, "Completion alone cannot reset retry backoff")
            await connection.onReadStatus?("thread", progress)
            await connection.onReadStatus?("thread", failure)
            await connection.onReadComplete?("thread")
            XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread], failure, "Late completion cannot erase a newer manual failure")
            XCTAssertTrue(coordinator.ingestionManualReadThreads.contains(thread))
            XCTAssertEqual(coordinator.ingestionReadFailureCounts[thread], 4)
            coordinator.presentation.ingestionReadStatuses[thread] = progress
            host.connection = nil
            await connection.onReadComplete?("thread")
            XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread], progress, "A retired connection cannot clear current progress")
            host.connection = connection
            coordinator.sessionRoutes.removeValue(forKey: binding.liveSessionID)
            await connection.onReadComplete?("thread")
            XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread], progress, "A retired registration cannot clear current progress")
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testNativeReadStatusKeepsContentAndUsesClassifiedRecoveryAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let (coordinator, thread, binding, handle) = try await makeInitialPrefetchFixture(transport: transport)
            let firstHost = try XCTUnwrap(coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: binding.liveSessionID, binding: binding)])
            let failedInitial = try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("unsupported"),
                "domain": .string("provider"), "recovery": .string("manual"), "code": .string("fixtureInitialFailure")]))
            coordinator.handleNativeReadStatus(failedInitial, threadID: thread, host: firstHost)
            XCTAssertNil(coordinator.presentation.threadSnapshots[thread]?.ingestionWindow)
            coordinator.requestNewerPage(thread, latest: true)
            let initialRetried = await waitForInitialPrefetch {
                coordinator.projectionTasks[thread] == nil && coordinator.presentation.threadSnapshots[thread]?.messages.count == 1
            }
            XCTAssertTrue(initialRetried, "Explicit Retry must work before any window exists")
            coordinator.refreshVisibleTranscript(thread)
            let waiting = await waitForInitialPrefetch { await handle.heldHistoryCount == 1 }
            XCTAssertTrue(waiting)
            await coordinator.cancelInitialPrefetch(thread)?.value
            let host = try XCTUnwrap(coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: binding.liveSessionID, binding: binding)])
            func status(_ state: String, _ recovery: String) throws -> AgentIngestionReadStatus {
                try AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string(state),
                    "domain": .string("host"), "recovery": .string(recovery), "code": .string("fixtureStatus")]))
            }
            coordinator.handleNativeReadStatus(try status("preparing", "continue"), threadID: thread, host: host)
            XCTAssertTrue(host.bootstrapped.contains(thread), "Preparing is not a resync")
            XCTAssertNil(coordinator.ingestionReadRetryTasks[thread])
            XCTAssertFalse(coordinator.presentation.ingestionCapacityThreads.contains(thread))
            coordinator.handleNativeReadStatus(try status("retryable", "retryRead"), threadID: thread, host: host)
            coordinator.handleNativeReadStatus(try status("retryable", "retryRead"), threadID: thread, host: host)
            XCTAssertNotNil(coordinator.ingestionReadRetryTasks[thread])
            XCTAssertEqual(coordinator.ingestionReadFailureCounts[thread], 1, "Duplicate failure events share one retry timer")
            coordinator.handleNativeReadStatus(try status("resourceLimited", "manual"), threadID: thread, host: host)
            XCTAssertNil(coordinator.ingestionReadRetryTasks[thread])
            XCTAssertTrue(coordinator.ingestionManualReadThreads.contains(thread))
            coordinator.refreshVisibleTranscript(thread)
            XCTAssertNil(coordinator.projectionTasks[thread], "Manual recovery suppresses automatic refresh loops")
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), ["message-10"])
            coordinator.requestNewerPage(thread, latest: true)
            let refreshed = await waitForInitialPrefetch { coordinator.projectionTasks[thread] == nil }
            XCTAssertTrue(refreshed)
            XCTAssertNil(coordinator.presentation.ingestionReadStatuses[thread], "A successful explicit read clears status")
            XCTAssertFalse(coordinator.ingestionManualReadThreads.contains(thread))
            coordinator.handleNativeReadStatus(try status("retryable", "renewConnection"), threadID: thread, host: host)
            XCTAssertFalse(coordinator.ingestionHosts.values.contains { $0 === host })
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), ["message-10"])
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testInitialDetailPublishesNewestBeforeTwoCancelableOlderPagesAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
          for selectedBeforeBootstrap in [true, false] {
            let fixture = try await makeInitialPrefetchFixture(transport: transport)
            let (coordinator, thread, _, handle) = fixture
            if !selectedBeforeBootstrap {
                coordinator.presentation.selectedThreadID = nil
                coordinator.ingestionOpenDetails.remove(thread)
                let host = try XCTUnwrap(coordinator.ingestionHosts.values.first)
                let connection = try XCTUnwrap(host.connection)
                let reply = try await connection.request(["kind": .string("window.read"), "operation": .string("bootstrap"),
                    "thread": .string("thread"), "windowVersion": .number(0)])
                let page = try XCTUnwrap(reply.page)
                let applied = await coordinator.apply(page: page, to: thread)
                XCTAssertTrue(applied.accepted)
                let snapshot = await coordinator.runtime.ingestionWindowSnapshot(for: thread)
                try await connection.acknowledgeWindow(page, thread: "thread", snapshot: XCTUnwrap(snapshot))
                host.bootstrapped.insert(thread)
                XCTAssertNil(coordinator.initialPrefetchTasks[thread], "A hidden row needs no optional transcript history")
                coordinator.presentation.selectedThreadID = thread
                coordinator.ingestionOpenDetails.insert(thread)
            }
            coordinator.refreshVisibleTranscript(thread)
            let firstOlder = await waitForInitialPrefetch { await handle.heldHistoryCount == 1 }
            XCTAssertTrue(firstOlder, transport.rawValue)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), ["message-10"])
            XCTAssertNil(coordinator.projectionTasks[thread], "Optional history cannot own the foreground read gate")
            XCTAssertFalse(coordinator.presentation.loadingTranscriptThreads.contains(thread))
            for _ in 0..<10 { coordinator.refreshVisibleTranscript(thread) }
            XCTAssertFalse(coordinator.initialPrefetchTasks[thread]?.isCancelled ?? true, "Ordinary refreshes cannot starve optional older pages")
            let initialAcks = await handle.acknowledgedVersions
            XCTAssertEqual(initialAcks, [1], "Newest must be acknowledged before requesting older history")
            try await handle.releaseHistory()
            let secondOlder = await waitForInitialPrefetch { await handle.historyRequests == 2 }
            XCTAssertTrue(secondOlder)
            try await handle.releaseHistory()
            let finished = await waitForInitialPrefetch { coordinator.initialPrefetchTasks[thread] == nil }
            XCTAssertTrue(finished)
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), ["message-8", "message-9", "message-10"])
            let operations = await handle.operations
            XCTAssertEqual(operations, ["bootstrap", "before", "before"], "Initial load stays at three ordinary bounded pages")
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.ingestionWindow?.viewportSegmentIDs.count, 3)
            await coordinator.setExperimentEnabled(false)
          }
        }
    }

    @MainActor
    func testInitialHistoryYieldsToReceiptAndRejectsLatePageAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let (coordinator, thread, binding, handle) = try await makeInitialPrefetchFixture(transport: transport)
            coordinator.refreshVisibleTranscript(thread)
            let waiting = await waitForInitialPrefetch { await handle.heldHistoryCount == 1 }
            XCTAssertTrue(waiting)
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "send now", queueWhenWorking: false)!
            let lease = try await coordinator.runtime.acquireLease(threadID: thread, action: .send, binding: binding, textRequest: request)
            try await AppleAgentIngestionConnection.withSearchDeadline(.seconds(2)) {
                try await coordinator.prepareOutgoingReceipt(lease)
            }
            // Send never joins the prefetch's cleanup, so the cancelled task
            // may still be unwinding when the receipt is armed. It must then
            // finish while its history reply is still unanswered.
            XCTAssertTrue(coordinator.initialPrefetchTasks[thread]?.isCancelled ?? true, "Receipt cancels optional history")
            let unwound = await waitForInitialPrefetch { coordinator.initialPrefetchTasks[thread] == nil }
            XCTAssertTrue(unwound, "Receipt cancels optional history without waiting for its reply (\(transport.rawValue))")
            let stillHeld = await handle.heldHistoryCount
            XCTAssertEqual(stillHeld, 1, "the history reply was never answered")
            let beforeLate = coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID)
            try await handle.releaseHistory()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), beforeLate)
            let operations = await handle.operations
            XCTAssertEqual(operations, ["bootstrap", "before"])
            await coordinator.runtime.releaseLease(lease)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testInitialHistoryCancellationBoundariesKeepNewestAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for boundary in ["background", "surface", "manual", "selection", "capacity", "epoch"] {
                let (coordinator, thread, binding, handle) = try await makeInitialPrefetchFixture(transport: transport)
                coordinator.refreshVisibleTranscript(thread)
                let waiting = await waitForInitialPrefetch { await handle.heldHistoryCount == 1 }
                XCTAssertTrue(waiting)
                switch boundary {
                case "background": await coordinator.setApplicationActive(false)
                case "surface": coordinator.setSurfaceDemand(false)
                case "manual": coordinator.requestOlderPage(thread)
                case "capacity":
                    let host = coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: binding.liveSessionID, binding: binding)]
                    await host?.connection?.onCapacity?("thread")
                case "epoch":
                    let host = coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: binding.liveSessionID, binding: binding)]
                    await host?.connection?.close()
                default:
                    coordinator.presentation.selectedThreadID = nil
                    coordinator.cancelInitialPrefetches()
                }
                let stopped = await waitForInitialPrefetch { coordinator.initialPrefetchTasks[thread] == nil }
                XCTAssertTrue(stopped, "\(transport.rawValue) \(boundary)")
                XCTAssertEqual(coordinator.presentation.threadSnapshots[thread]?.messages.map(\.recordID), ["message-10"])
                if boundary == "capacity" {
                    XCTAssertTrue(coordinator.presentation.ingestionCapacityThreads.contains(thread), "Optional reads cannot clear durable capacity")
                }
                if boundary == "manual" {
                    let manualStarted = await waitForInitialPrefetch { await handle.historyRequests == 2 }
                    XCTAssertTrue(manualStarted, "Explicit navigation replaces the optional request")
                    try await handle.releaseHistory()
                    try await handle.releaseHistory()
                }
                await coordinator.setExperimentEnabled(false)
            }
        }
    }

    // O2: a live identity can precede the first transcript; only its lifecycle
    // frames renew an exhausted first-read budget.
    @MainActor
    func testMissingFirstTranscriptPresentationRequiresAnEmptyLiveThread() async throws {
        let (coordinator, thread, binding, _) = try await makeInitialPrefetchFixture(transport: .moshTmux, initialResolveFailures: 1)
        let summary = AgentThreadSummary(id: thread, providerName: "Claude",
            availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true))
        let missing = try AgentIngestionReadStatus.decode(.object([
            "v": .number(1), "state": .string("failed"), "domain": .string("source"),
            "recovery": .string("manual"), "code": .string("sourceMissing")]))
        coordinator.presentation.ingestionReadStatuses[thread] = missing
        let live = AgentThreadSnapshot(summary: summary, messages: [], cursor: nil, hasMore: false, binding: binding)
        XCTAssertNil(coordinator.presentation.visibleReadStatus(for: live))
        let historical = AgentThreadSnapshot(summary: summary, messages: [], cursor: nil, hasMore: false, binding: nil)
        XCTAssertEqual(coordinator.presentation.visibleReadStatus(for: historical), missing)
        let loaded = AgentThreadSnapshot(summary: summary,
            messages: [.init(recordID: "empty-blocks", role: .assistant, displayTime: nil, blocks: [])],
            cursor: nil, hasMore: false, binding: binding)
        XCTAssertEqual(coordinator.presentation.visibleReadStatus(for: loaded), missing)
        let ended = AgentThreadSnapshot(summary: summary, messages: [], cursor: nil, hasMore: false, binding: binding, conversationEnded: true)
        XCTAssertEqual(coordinator.presentation.visibleReadStatus(for: ended), missing)
        let other = try AgentIngestionReadStatus.decode(.object([
            "v": .number(1), "state": .string("failed"), "domain": .string("source"),
            "recovery": .string("manual"), "code": .string("sourceNotAuthorized")]))
        coordinator.presentation.ingestionReadStatuses[thread] = other
        XCTAssertEqual(coordinator.presentation.visibleReadStatus(for: live), other)
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    func testMissingFirstTranscriptLifecycleRestartsPendingAndExhaustedLadders() async throws {
        for exhausted in [false, true] {
            // Fail the renewed immediate attempt too: recovery must start a
            // fresh bounded ladder, rather than merely bypass the manual flag.
            let failures = exhausted ? 7 : 2
            let (coordinator, thread, handle) = try await makeMissingTranscriptLifecycleFixture(resolveFailures: failures)
            let waiting = await waitForInitialPrefetch(attempts: 4_000) {
                exhausted ? coordinator.ingestionManualReadThreads.contains(thread) && coordinator.projectionTasks[thread] == nil
                    : coordinator.ingestionReadRetryTasks[thread] != nil && coordinator.projectionTasks[thread] == nil
            }
            XCTAssertTrue(waiting, "exhausted=\(exhausted)")
            let bindingBefore = coordinator.threadRoutes[thread]?.binding
            let sourceBefore = coordinator.initialProjectionRoutes[thread]?.transcriptRef
            if exhausted { XCTAssertEqual(coordinator.ingestionReadFailureCounts[thread], 5) }
            coordinator.scheduleSessionRefresh(sessionID: try XCTUnwrap(bindingBefore).liveSessionID, paneID: 2,
                lifecycle: missingTranscriptLifecycleEvent("UserPromptSubmit", timestamp: 2_000_000_000))
            let recovered = await waitForInitialPrefetch(attempts: 1_000) {
                coordinator.presentation.threadSnapshots[thread]?.messages.count == 1 && coordinator.projectionTasks[thread] == nil
            }
            XCTAssertTrue(recovered, "exhausted=\(exhausted)")
            XCTAssertEqual(coordinator.threadRoutes[thread]?.binding, bindingBefore)
            XCTAssertEqual(coordinator.projectionRoutes[thread]?.transcriptRef, sourceBefore)
            let resolves = await handle.resolveRequests
            XCTAssertEqual(resolves, failures + 1)
            XCTAssertNil(coordinator.presentation.ingestionReadStatuses[thread])
            XCTAssertNil(coordinator.ingestionReadFailureCounts[thread])
            XCTAssertFalse(coordinator.ingestionManualReadThreads.contains(thread))
            XCTAssertNil(coordinator.ingestionReadRetryTasks[thread])
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testFirstTranscriptLifecyclePreservesOtherManualFailures() async throws {
        let (coordinator, thread, handle) = try await makeMissingTranscriptLifecycleFixture(resolveFailures: 1,
            resolveFailure: ("sourceNotAuthorized", "failed", "manual"))
        let failed = await waitForInitialPrefetch { coordinator.ingestionManualReadThreads.contains(thread) && coordinator.projectionTasks[thread] == nil }
        XCTAssertTrue(failed)
        let status = coordinator.presentation.ingestionReadStatuses[thread]
        let binding = try XCTUnwrap(coordinator.threadRoutes[thread]?.binding)
        coordinator.scheduleSessionRefresh(sessionID: binding.liveSessionID, paneID: 2,
            lifecycle: missingTranscriptLifecycleEvent("UserPromptSubmit", timestamp: 2_000_000_000))
        let applied = await waitForInitialPrefetch {
            coordinator.threadRoutes[thread]?.lifecycleEvent?.event == "UserPromptSubmit" && coordinator.sessionRefreshIsIdle(binding.liveSessionID)
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread], status)
        XCTAssertEqual(status?.code, "sourceNotAuthorized")
        XCTAssertTrue(coordinator.ingestionManualReadThreads.contains(thread))
        let resolves = await handle.resolveRequests
        XCTAssertEqual(resolves, 1)
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    private func missingTranscriptLifecycleEvent(_ event: String, timestamp: UInt64) -> AgentLifecycleEvent {
        .init(version: 9, provider: "claude", event: event, state: event == "UserPromptSubmit" ? .working : .idle,
            reason: "fixture", timestampNanoseconds: timestamp, providerSessionID: "initial-prefetch", turnID: "turn",
            notificationType: "", permissionMode: "", agentPID: 42, transcriptRef: "c2Vzc2lvbg", agentID: nil, rootAgentID: nil)
    }

    @MainActor
    private func makeMissingTranscriptLifecycleFixture(resolveFailures: Int,
        resolveFailure: (code: String, state: String, recovery: String) = ("sourceMissing", "failed", "manual")) async throws
        -> (AgentCenterV2Coordinator, AgentThreadID, AppleInitialPrefetchTestHandle) {
        let (coordinator, thread, carrier, handle) = try await makeInitialPrefetchFixture(transport: .moshTmux,
            initialResolveFailures: resolveFailures, resolveFailure: resolveFailure)
        let original = try XCTUnwrap(coordinator.sessionRoutes[carrier.liveSessionID])
        let location = AgentLocation(sessionID: carrier.liveSessionID, hostName: "fixture", transportLabel: "mosh",
            tmuxSessionName: "rig", windowID: 1, windowName: "rig", paneID: 2)
        let target = AgentProbeTarget(location: location, processNames: ["claude"], processIDs: [42], visibleText: "❯ ", bracketedPasteEnabled: false)
        let source = AgentSessionSource(registrationID: original.source.registrationID, sessionID: carrier.liveSessionID,
            discover: { .success([target]) }, observe: { _ in nil }, inspect: { _ in target },
            send: { _, _ in false }, jump: { _ in },
            // The fixture's one scripted stream is already open. A further
            // connection (the session inventory's default scope) gets its own
            // silent stream, as a separate remote exec would, rather than
            // racing the first connection's reader on the shared one.
            projectorExecAvailability: { _, _ in .available(.init { _ in AppleSilentTestHandle() }) }, readCarrier: { carrier })
        coordinator.sessionRoutes[carrier.liveSessionID] = .init(hostID: thread.hostID, hostDisplayLabel: "fixture",
            source: source, profiles: { [.builtInClaudeCode] }, carrierGeneration: carrier.carrierGeneration)
        // Reuse the fixture's already-open synthetic connection under the
        // lifecycle-derived process context, rather than opening its stream twice.
        let liveBinding = AgentTerminalBinding(liveSessionID: carrier.liveSessionID, carrierGeneration: carrier.carrierGeneration,
            incarnation: AgentIncarnationToken("\(source.registrationID.uuidString):claude:agent-42")!, transport: .moshTmux,
            tmuxSession: "rig", windowID: "1", paneID: "2", agentPID: 42, capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux])
        let host = try XCTUnwrap(coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: carrier.liveSessionID, binding: carrier)])
        coordinator.ingestionHosts[AppleAgentIngestionHostKey(sessionID: carrier.liveSessionID, binding: liveBinding)] = host
        coordinator.initialProjectionRoutes.removeValue(forKey: thread)
        await coordinator.runtime.replaceBinding(nil, for: thread)
        coordinator.scheduleSessionRefresh(sessionID: carrier.liveSessionID, paneID: 2,
            lifecycle: missingTranscriptLifecycleEvent("SessionStart", timestamp: 1_000_000_000))
        return (coordinator, thread, handle)
    }

    @MainActor
    func testFirstResolveSourceMissingRetriesSelectedAndUnselectedThreads() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for selected in [true, false] {
                let (coordinator, thread, _, handle) = try await makeInitialPrefetchFixture(transport: transport, initialResolveFailures: 1)
                if !selected {
                    coordinator.presentation.selectedThreadID = nil
                    coordinator.ingestionOpenDetails.remove(thread)
                }
                coordinator.requestNewerPage(thread, latest: true)
                let failed = await waitForInitialPrefetch {
                    coordinator.presentation.ingestionReadStatuses[thread]?.code == "sourceMissing"
                }
                XCTAssertTrue(failed, "\(transport) selected=\(selected)")
                XCTAssertNil(coordinator.projectionRoutes[thread])
                XCTAssertNotNil(coordinator.ingestionReadRetryTasks[thread])
                let recovered = await waitForInitialPrefetch(attempts: 1_000) {
                    coordinator.presentation.threadSnapshots[thread]?.messages.count == 1 && coordinator.projectionTasks[thread] == nil
                }
                XCTAssertTrue(recovered, "\(transport) selected=\(selected)")
                let resolves = await handle.resolveRequests
                XCTAssertEqual(resolves, 2)
                XCTAssertNotNil(coordinator.projectionRoutes[thread])
                XCTAssertNil(coordinator.initialProjectionRoutes[thread])
                XCTAssertNil(coordinator.presentation.ingestionReadStatuses[thread])
                await coordinator.setExperimentEnabled(false)
            }
        }
    }

    /// A first resolve that raced an atomic transcript replacement reports a
    /// typed recovery, not `sourceMissing`; it still retries before a handle exists.
    @MainActor
    func testFirstResolveWithTypedRecoveryRetriesBeforeAThreadHandleExists() async throws {
        for (code, state, recovery) in [("sourceChanged", "sourceChanged", "rebootstrap"), ("readInterrupted", "retryable", "retryRead")] {
            let (coordinator, thread, _, handle) = try await makeInitialPrefetchFixture(transport: .sshTmux, initialResolveFailures: 1,
                resolveFailure: (code, state, recovery))
            coordinator.presentation.selectedThreadID = nil
            coordinator.ingestionOpenDetails.remove(thread)
            coordinator.requestNewerPage(thread, latest: true)
            let recovered = await waitForInitialPrefetch(attempts: 1_000) {
                coordinator.presentation.threadSnapshots[thread]?.messages.count == 1 && coordinator.projectionTasks[thread] == nil
            }
            XCTAssertTrue(recovered, code)
            let resolves = await handle.resolveRequests
            XCTAssertEqual(resolves, 2, code)
            XCTAssertNotNil(coordinator.projectionRoutes[thread], code)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testFirstResolveRetryExhaustionKeepsFailureAndAllowsExplicitRetry() async throws {
        let (coordinator, thread, _, handle) = try await makeInitialPrefetchFixture(transport: .sshTmux, initialResolveFailures: 6)
        coordinator.requestNewerPage(thread, latest: true)
        let exhausted = await waitForInitialPrefetch(attempts: 4_000) {
            coordinator.ingestionManualReadThreads.contains(thread) && coordinator.projectionTasks[thread] == nil
        }
        XCTAssertTrue(exhausted)
        let resolves = await handle.resolveRequests
        XCTAssertEqual(resolves, 6, "One attempt and five bounded retries")
        XCTAssertEqual(coordinator.ingestionReadFailureCounts[thread], 5)
        XCTAssertEqual(coordinator.presentation.ingestionReadStatuses[thread]?.code, "sourceMissing")
        XCTAssertNil(coordinator.ingestionReadRetryTasks[thread])
        XCTAssertNotNil(coordinator.initialProjectionRoutes[thread])
        coordinator.refreshVisibleTranscript(thread)
        XCTAssertNil(coordinator.projectionTasks[thread], "Automatic refresh cannot restart an exhausted retry window")
        coordinator.requestNewerPage(thread, latest: true)
        let recovered = await waitForInitialPrefetch {
            coordinator.presentation.threadSnapshots[thread]?.messages.count == 1 && coordinator.projectionTasks[thread] == nil
        }
        XCTAssertTrue(recovered)
        XCTAssertNil(coordinator.presentation.ingestionReadStatuses[thread])
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    func testFirstResolveRetryStopsWhenItsRouteChanges() async throws {
        let (coordinator, thread, _, handle) = try await makeInitialPrefetchFixture(transport: .sshTmux, initialResolveFailures: 1)
        coordinator.requestNewerPage(thread, latest: true)
        let failed = await waitForInitialPrefetch { coordinator.ingestionReadRetryTasks[thread] != nil }
        XCTAssertTrue(failed)
        let route = try XCTUnwrap(coordinator.initialProjectionRoutes[thread])
        coordinator.initialProjectionRoutes[thread] = .init(transcriptRef: "replacement", providerID: route.providerID,
            binding: route.binding, source: route.source)
        try await Task.sleep(for: .milliseconds(700))
        let resolves = await handle.resolveRequests
        XCTAssertEqual(resolves, 1)
        XCTAssertNil(coordinator.ingestionReadRetryTasks[thread])
        XCTAssertNil(coordinator.projectionRoutes[thread])
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    private func waitForInitialPrefetch(attempts: Int = 200, _ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func makeInitialPrefetchFixture(transport: AgentTransportKind, initialResolveFailures: Int? = nil,
                                            resolveFailure: (code: String, state: String, recovery: String) = ("sourceMissing", "failed", "manual")) async throws
        -> (AgentCenterV2Coordinator, AgentThreadID, AgentTerminalBinding, AppleInitialPrefetchTestHandle) {
        let metadata = AppleAgentMetadataRepository(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-initial-prefetch-\(UUID()).json"))
        let coordinator = AgentCenterV2Coordinator(metadata: metadata)
        await coordinator.setExperimentEnabled(true)
        coordinator.setSurfaceDemand(true)
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
            incarnation: AgentIncarnationToken("initial-prefetch")!, transport: transport, agentPID: 42, capabilities: [.observe, .send])
        let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "initial-prefetch")!
        let handle = try AppleInitialPrefetchTestHandle(resolveFailures: initialResolveFailures ?? 0, resolveFailure: resolveFailure)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: binding.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
            send: { _, _ in false }, jump: { _ in },
            projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { binding })
        coordinator.sessionRoutes[binding.liveSessionID] = .init(hostID: thread.hostID, hostDisplayLabel: "fixture",
            source: source, profiles: { [] }, carrierGeneration: 4)
        let route = AppleAgentProjectionRoute(transcriptRef: "fixture", providerID: .claude, binding: binding, source: source)
        if initialResolveFailures == nil { coordinator.projectionRoutes[thread] = route }
        else { coordinator.initialProjectionRoutes[thread] = route }
        await coordinator.runtime.register(.init(id: thread, providerName: "Claude",
            availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding)
        coordinator.presentation.selectedThreadID = thread
        coordinator.ingestionOpenDetails.insert(thread)
        let (host, _) = try await coordinator.nativeHost(source: source, context: binding)
        if initialResolveFailures == nil { host.threads[thread] = "thread" }
        return (coordinator, thread, binding, handle)
    }

    @MainActor
    func testNativeReceiptDoesNotWaitForProjectionAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let (coordinator, thread, binding, handle) = try await makeInitialPrefetchFixture(transport: transport)
            let gate = AppleSearchTestGate()
            let projection = Task { await gate.wait() }
            coordinator.projectionTasks[thread] = projection
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "send during initial indexing", queueWhenWorking: false)!
            let lease = try await coordinator.runtime.acquireLease(threadID: thread, action: .send, binding: binding, textRequest: request)
            try await AppleAgentIngestionConnection.withSearchDeadline(.seconds(1)) {
                try await coordinator.prepareOutgoingReceipt(lease)
            }
            let operations = await handle.operations
            XCTAssertTrue(operations.isEmpty, "Receipt must not bootstrap or navigate any window")
            let window = await coordinator.runtime.ingestionWindowSnapshot(for: thread)
            XCTAssertNil(window, "A first Send needs no projected transcript")
            try await coordinator.runtime.markOutgoingDispatched(lease)
            await coordinator.runtime.releaseLease(lease, result: .verified)
            let sent = await coordinator.runtime.snapshot(for: thread)
            XCTAssertEqual(sent?.outgoingMessages?.first?.status, .awaitingReceipt)
            await gate.release()
            await projection.value
            coordinator.projectionTasks.removeValue(forKey: thread)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testSendUsesOneFreshInspectionPerWriteAcrossTransports() async throws {
        // These are deterministic delayed-carrier measurements, not VPS or
        // physical-device measurements. The legacy fixture adds the redundant
        // source inspection formerly performed by each write closure.
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            var latencies: [Int] = []
            for legacyDuplicate in [true, false] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-send-latency-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let runtime = AgentCenterRuntime()
                let coordinator = AgentCenterV2Coordinator(runtime: runtime,
                    metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
                await coordinator.setExperimentEnabled(true)
                let tmux = transport == .sshTmux || transport == .moshTmux
                let hostID = UUID(), registrationID = UUID()
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("latency-fixture")!, transport: transport,
                    tmuxSession: tmux ? "rig" : nil, windowID: tmux ? "1" : nil, paneID: tmux ? "2" : nil,
                    agentPID: 42, capabilities: [.observe, .send])
                let threadID = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "latency-fixture")!
                let location = AgentLocation(sessionID: binding.liveSessionID, hostName: "fixture", transportLabel: transport.rawValue,
                    tmuxSessionName: tmux ? "rig" : nil, windowID: tmux ? 1 : nil, windowName: tmux ? "rig" : nil,
                    paneID: tmux ? 2 : nil)
                var inspections = 0, inserted = false, writes = 0, keys = 0, directoryReads = 0
                var dispatchPreparations = 0, inspectionsBeforeDispatch = 0, dispatchRechecks = 0, writing = false
                var firstWriteAt: ContinuousClock.Instant?
                let delayedInspect: @MainActor (AgentLocation) async -> AgentProbeTarget? = { _ in
                    if dispatchPreparations == 0 { inspectionsBeforeDispatch += 1 }
                    if dispatchPreparations == 1, !writing { dispatchRechecks += 1 }
                    inspections += 1
                    try? await Task.sleep(for: .milliseconds(100))
                    let line = inserted ? "› hello" : "› "
                    return AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42],
                        visibleText: line + "\n\ngpt-5.4 default · /tmp", currentInputLine: line,
                        cursorRow: 0, cursorColumn: inserted ? 7 : 2, cursorVisible: true, bracketedPasteEnabled: true)
                }
                let source = AgentSessionSource(registrationID: registrationID, sessionID: binding.liveSessionID,
                    discover: { .success([]) }, observe: { _ in nil }, inspect: delayedInspect,
                    send: { target, bytes in
                        writing = true
                        if legacyDuplicate { _ = await delayedInspect(target) }
                        XCTAssertEqual(dispatchPreparations, 1, "Receipt bookkeeping precedes the write")
                        firstWriteAt = .now; writes += 1; inserted = true
                        XCTAssertEqual(Data(bytes), AgentTextInsertion.bytes(provider: "codex", text: "hello", bracketedPasteEnabled: true))
                        return true
                    }, sendKey: { target, _ in
                        if legacyDuplicate { _ = await delayedInspect(target) }
                        keys += 1; return true
                    }, jump: { _ in },
                    validatedRemoteDirectories: { _ in directoryReads += 1; return ["/tmp"] },
                    supportsTmuxLaunch: { tmux }, launchAgent: { _ in throw AgentActionError.unavailable })
                let session = AppleAgentSessionRoute(hostID: hostID, hostDisplayLabel: "fixture", source: source,
                    profiles: { [.builtInCodexCLI] }, carrierGeneration: 1)
                let thread = AppleAgentThreadRoute(registrationID: registrationID, location: location,
                    profile: .builtInCodexCLI, binding: binding, sourceIdentity: "fixture")
                coordinator.sessionRoutes[binding.liveSessionID] = session
                coordinator.threadRoutes[threadID] = thread
                let adapter = coordinator.makeTerminalAdapter(threadID: threadID, session: session, thread: thread)
                let request = AgentTextSendRequest(threadID: threadID, binding: binding, text: "hello", queueWhenWorking: false)!
                let requestedAt = ContinuousClock.now
                await coordinator.synchronizePresentation(refreshLaunchSuggestions: false)
                let hop = DispatchHop()
                try await adapter.sendText(request, beforeWrite: {
                    let started = ContinuousClock.now
                    await MainActor.run { dispatchPreparations += 1 }
                    hop.duration = started.duration(to: .now)
                })
                try await adapter.sendReturn(binding: binding)
                try await adapter.verifySubmission(threadID: threadID, binding: binding)
                XCTAssertEqual(inspectionsBeforeDispatch, 1, "Dispatch is marked once the composer is ready, not before the readiness wait")
                // A loaded machine can make the dispatch hop itself age the
                // composer proof (150 ms); only then is one recheck earned.
                XCTAssertLessThanOrEqual(dispatchRechecks, hop.duration >= .milliseconds(140) ? 1 : 0,
                                         "hop \(hop.duration) earned no fresh composer check")
                XCTAssertEqual(directoryReads, 0, "Optimistic send publication cannot issue unrelated launch suggestions")
                XCTAssertEqual(inspections, (legacyDuplicate ? 4 : 2) + dispatchRechecks, "Text and Enter each need one separate fresh inspection")
                XCTAssertEqual(writes, 1); XCTAssertEqual(keys, 1)
                let elapsed = requestedAt.duration(to: try XCTUnwrap(firstWriteAt)).components
                latencies.append(Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
                // Retiring the carrier must reject the retained adapter even
                // though its immediately preceding action was successful.
                coordinator.threadRoutes.removeValue(forKey: threadID)
                do { try await adapter.sendText(request); XCTFail("Retired carrier wrote text") }
                catch {
                    let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten, "a retired carrier is refused before any write")
                    XCTAssertEqual(refusal.error, .staleBinding)
                    XCTAssertEqual(refusal.attempts, 1, "a changed binding is final, not retried")
                }
                XCTAssertEqual(writes, 1)
                await coordinator.setExperimentEnabled(false)
            }
            NSLog("AGENT_SEND_LATENCY synthetic transport=%@ inspectDelayMs=100 legacyFirstWriteMs=%d currentFirstWriteMs=%d", transport.rawValue, latencies[0], latencies[1])
        }
    }

    @MainActor
    func testNativeInventoryResumesImmediatelyAfterForegroundAndSurfaceReturnAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-resume-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            coordinator.setSurfaceDemand(true)
            let carrier = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("inventory-recovery")!, transport: transport, capabilities: [.observe])
            let factory = AppleInventoryRecoveryTestFactory()
            let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                projectorExecAvailability: { _, _ in .available(.init { try await factory.open($0) }) }, readCarrier: { carrier })
            coordinator.sessionRoutes[source.sessionID] = .init(hostID: UUID(), hostDisplayLabel: "fixture",
                source: source, profiles: { [] }, carrierGeneration: 4)
            coordinator.startInventory(sessionID: source.sessionID)
            try await waitForInventory(factory, count: 1, coordinator: coordinator)
            XCTAssertGreaterThan(coordinator.inventoryRetryAfter["\(source.sessionID.uuidString):native"] ?? .distantPast, Date())
            await coordinator.setApplicationActive(false)
            XCTAssertTrue(coordinator.inventoryRetryTasks.isEmpty)
            // Production updates notification policy immediately before the
            // lifecycle entry point; this must not hide the foreground edge.
            await coordinator.configureNotificationDelivery(enabled: false, applicationActive: true)
            await coordinator.setApplicationActive(true)
            try await waitForInventory(factory, count: 2, coordinator: coordinator)
            coordinator.setSurfaceDemand(false)
            coordinator.setSurfaceDemand(true)
            try await waitForInventory(factory, count: 3, coordinator: coordinator)
            await coordinator.setExperimentEnabled(false)
            XCTAssertTrue(coordinator.inventoryRetryTasks.isEmpty)
        }
    }

    @MainActor
    func testQuietFailedInventoryRetriesWithoutTerminalOutputAndCancelsOnBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        coordinator.setSurfaceDemand(true)
        let carrier = makeBinding()
        let factory = AppleInventoryRecoveryTestFactory(failures: 1)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
            projectorExecAvailability: { _, _ in .available(.init { try await factory.open($0) }) }, readCarrier: { carrier })
        coordinator.sessionRoutes[source.sessionID] = .init(hostID: UUID(), hostDisplayLabel: "fixture",
            source: source, profiles: { [] }, carrierGeneration: 4)
        coordinator.startInventory(sessionID: source.sessionID)
        for _ in 0..<200 {
            if coordinator.inventoryRetryTasks[source.sessionID] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(coordinator.inventoryRetryTasks[source.sessionID], "failed inventory needs its own retry even when discovery finds no running agent")
        try await waitForInventory(factory, count: 2, coordinator: coordinator, timeout: .seconds(12))
        XCTAssertNil(coordinator.inventoryRetryTasks[source.sessionID], "a successful quiet inventory must not poll indefinitely")
        // A suppressed request owns a scheduled retry, never a silent return.
        coordinator.startInventory(sessionID: source.sessionID)
        XCTAssertNotNil(coordinator.inventoryRetryTasks[source.sessionID])
        await coordinator.setApplicationActive(false)
        XCTAssertTrue(coordinator.inventoryRetryTasks.isEmpty)
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    func testIngestionOpeningDeadlineAndCancellationCloseLateHandles() async throws {
        for cancel in [false, true] {
            let gate = AppleSearchTestGate()
            let handle = try AppleWindowTestHandle()
            let binding = makeBinding()
            let started = ContinuousClock.now
            let opening = Task {
                try await AppleAgentIngestionConnection.open(factory: .init { _ in
                    await gate.wait() // deliberately ignores cancellation
                    return handle
                }, binding: binding, openingDeadline: cancel ? .seconds(10) : .milliseconds(30))
            }
            for _ in 0..<100 {
                if await gate.isWaiting { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            if cancel { opening.cancel() }
            do { _ = try await opening.value; XCTFail("stalled opening unexpectedly completed") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? AgentIngestionError, .remote("deadlineExceeded")) }
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(2))
            await gate.release()
            for _ in 0..<100 {
                if await handle.isClosed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let closed = await handle.isClosed
            XCTAssertTrue(closed, "a factory that returns after ownership ends must not leak its SSH exec")
        }
    }

    @MainActor
    func testRetiredIngestionHostCannotPublishBootstrapAfterDelayedAcknowledgment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-ack-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        coordinator.setSurfaceDemand(true)
        let carrier = makeBinding()
        let gate = AppleSearchTestGate()
        let handle = try AppleWindowTestHandle(windowAckGate: gate, autoBootstrap: true)
        let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
            projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { carrier })
        let hostID = UUID()
        coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
            source: source, profiles: { [] }, carrierGeneration: 4)
        let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "delayed-ack")!
        await coordinator.register(summary: .init(id: thread, providerName: "Claude",
            availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: true)), binding: nil)
        let (host, _) = try await coordinator.nativeHost(source: source)
        host.threads[thread] = "thread"
        coordinator.historicalRoutes[thread] = .init(transcriptRef: "/fixture/session.jsonl", providerID: .claude,
            binding: carrier, source: source)
        coordinator.projectHistoricalIfNeeded(thread)
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting, "bootstrap must reach its wire acknowledgment")
        // Helper replacement retires the pooled host while SSH write
        // completion is delayed; this task itself may not yet be cancelled.
        coordinator.closeIngestionHosts()
        await gate.release()
        await coordinator.projectionTasks[thread]?.value
        XCTAssertNil(coordinator.projectionRoutes[thread], "old helper completion must not become the new read route")
        XCTAssertFalse(host.bootstrapped.contains(thread))
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    func testNativeContextPressureReclaimsRetiredIncarnationsAndPreservesReferencedScopes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-context-pressure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        coordinator.setSurfaceDemand(true)
        let original = makeBinding()
        func context(_ pid: Int?) -> AgentTerminalBinding {
            .init(liveSessionID: original.liveSessionID, carrierGeneration: 4,
                  incarnation: AgentIncarnationToken("context-\(pid ?? 0)")!, transport: .ssh,
                  agentPID: pid, capabilities: [.observe])
        }
        let carrier = context(nil)
        let factory = AppleContextTestFactory()
        let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
            projectorExecAvailability: { _, _ in .available(.init { try await factory.open($0) }) }, readCarrier: { carrier })
        let hostID = UUID()
        coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
            source: source, profiles: { [] }, carrierGeneration: 4)
        let (host, connection) = try await coordinator.nativeHost(source: source)
        for pid in 2...128 {
            let key = AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: context(pid))
            coordinator.ingestionHosts[key] = host
            coordinator.ingestionScopes[key] = "0000000000000001"
        }
        let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "retained")!
        coordinator.projectionRoutes[thread] = .init(transcriptRef: "/fixture/retained.jsonl", providerID: .claude,
            binding: context(2), source: source)
        let replacement = try await coordinator.nativeHost(source: source, context: context(300))
        XCTAssertFalse(replacement.0 === host)
        XCTAssertNotNil(coordinator.ingestionScopes[AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: context(2))])
        XCTAssertNil(coordinator.ingestionScopes[AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: context(3))])
        XCTAssertFalse(connection.isClosed, "retiring an alias must not close its retained sibling scope")
        XCTAssertLessThan(coordinator.ingestionHosts.count, 128)
        coordinator.unregisterSessionSource(sessionID: source.sessionID, registrationID: source.registrationID)
        XCTAssertTrue(coordinator.ingestionScopes.isEmpty)
        coordinator.ingestionScopes[AppleAgentIngestionHostKey(sessionID: source.sessionID)] = "0000000000000001"
        await coordinator.setExperimentEnabled(false)
        XCTAssertTrue(coordinator.ingestionScopes.isEmpty)
    }

    @MainActor
    private func waitForInventory(_ factory: AppleInventoryRecoveryTestFactory, count: Int,
                                  coordinator: AgentCenterV2Coordinator, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await factory.attempts >= count, coordinator.inventoryTasks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = await factory.attempts
        XCTAssertEqual(attempts, count)
        XCTAssertTrue(coordinator.inventoryTasks.isEmpty)
        let delivered = await factory.inventoryDelivered
        XCTAssertTrue(delivered, "quiet source must complete an inventory without terminal output")
    }

    @MainActor
    func testDeferredAnswerRetriesBusyCapturesAndShowsTheQuestionAcrossTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("deferred-answer")!, transport: transport,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .promptAnswer])
            let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "deferred")!
            let deferred = AgentPromptObservationResult(signature: "1 waiting", options: [], kind: .deferred,
                identity: "waiting", isBlocking: false, controls: [.init(kind: .open, label: "Answer")], pendingCount: 1)!
            let question = AgentPromptObservationResult(signature: "Which database?", options: [
                .init(id: "1", label: "Postgres", responseMacro: "1", isDefault: true)!,
                .init(id: "2", label: "SQLite", responseMacro: "2", isDefault: false)!
            ], kind: .question, identity: "database", question: "Which database?")!
            var captures = 0, written: [String] = [], lastKind: AgentPromptKind?
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    captures += 1
                    if captures <= 2 { throw AppleAgentInspectionUnavailable.capture }
                    let screen = written.isEmpty ? deferred : question
                    lastKind = screen.kind
                    return .init(observation: .init(binding: binding, liveTail: "Question"), promptScreen: screen)
                }, sendText: { data, purpose, target, inspection in
                    XCTAssertEqual(purpose, .promptAnswer)
                    XCTAssertEqual(target, binding)
                    XCTAssertEqual(inspection.promptScreen, deferred)
                    written.append(String(decoding: data, as: UTF8.self))
                    return true
                }, sendKey: { _, _, _ in false }, verifySubmission: { _, _, _ in false }, openExactBinding: { _ in .staleBinding }))
            let request = AgentPromptAnswerRequest(threadID: thread, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: deferred.signature), expectedSignature: deferred.signature,
                optionID: "open", control: .open)!
            try await adapter.answer(request, freshObservation: .init(binding: binding, liveTail: "Question"))
            XCTAssertEqual(written, ["\u{1b}[1;2D"], transport.rawValue)
            XCTAssertEqual(captures, 4, transport.rawValue)
            XCTAssertEqual(lastKind, .question)
        }
    }

    @MainActor
    func testPlannerAnswersUseExactBytesAndFreshScreens() async throws {
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("planner-answer")!, transport: .sshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42,
            capabilities: [.observe, .promptAnswer])
        let claude = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "ask")!
        let codex = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "async")!
        let choices = [
            AgentPromptMacroOption(id: "1", label: "Postgres", responseMacro: "1", isDefault: true)!,
            AgentPromptMacroOption(id: "2", label: "SQLite", responseMacro: "2", isDefault: false)!,
            AgentPromptMacroOption(id: "4", label: "Type something.", responseMacro: "4", isDefault: false,
                role: .freeform, acceptsText: true)!
        ]
        func question(entry: AgentPromptEntry? = nil) -> AgentPromptObservationResult {
            AgentPromptObservationResult(signature: "Which database?", options: choices, kind: .question,
                identity: "database", question: "Which database?", entry: entry, textFocus: .optionKey)!
        }
        func adapter(screen: @escaping (Int) -> AgentPromptObservationResult?,
                     writes: @escaping (String) -> Void, count: @escaping () -> Int) -> AppleAgentTerminalAdapter {
            AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    let prompt = screen(count())
                    return .init(observation: .init(binding: binding, liveTail: prompt == nil ? "› " : "Question"),
                        promptScreen: prompt)
                },
                sendText: { data, purpose, _, _ in
                    XCTAssertEqual(purpose, .promptAnswer)
                    writes(String(decoding: data, as: UTF8.self))
                    return true
                },
                sendKey: { _, _, _ in false }, verifySubmission: { _, _, _ in false },
                openExactBinding: { _ in .staleBinding }))
        }
        let fresh = AgentTerminalObservation(binding: binding, liveTail: "Question")

        do {
            var written: [String] = []
            let terminal = adapter(screen: { $0 == 0 ? question() : nil },
                writes: { written.append($0) }, count: { written.count })
            let request = AgentPromptAnswerRequest(threadID: claude, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: "Which database?"),
                expectedSignature: "Which database?", optionID: "2")!
            try await terminal.answer(request, freshObservation: fresh)
            XCTAssertEqual(written, ["2"])
        }
        do {
            var written: [String] = []
            let terminal = adapter(screen: { step in
                switch step {
                case 0: question()
                case 1: question(entry: .init(optionID: "4", text: ""))
                case 2: question(entry: .init(optionID: "4", text: "abc"))
                default: nil
                }
            }, writes: { written.append($0) }, count: { written.count })
            let request = AgentPromptAnswerRequest(threadID: claude, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: "Which database?"),
                expectedSignature: "Which database?", optionID: "4", text: "abc")!
            try await terminal.answer(request, freshObservation: fresh)
            XCTAssertEqual(written, ["4", "abc", "\r"])
        }
        do {
            var written: [String] = []
            let deferred = AgentPromptObservationResult(signature: "2 waiting", options: [], kind: .deferred,
                identity: "waiting", isBlocking: false, controls: [.init(kind: .open, label: "Answer")],
                pendingCount: 2)!
            let terminal = adapter(screen: { $0 == 0 ? deferred : nil },
                writes: { written.append($0) }, count: { written.count })
            let request = AgentPromptAnswerRequest(threadID: codex, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: deferred.signature),
                expectedSignature: deferred.signature, optionID: "open", control: .open)!
            try await terminal.answer(request, freshObservation: fresh)
            XCTAssertEqual(written, ["\u{1b}[1;2D"])
        }
        do {
            var written: [String] = []
            let terminal = adapter(screen: { _ in question() },
                writes: { written.append($0) }, count: { written.count })
            let request = AgentPromptAnswerRequest(threadID: claude, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: "old prompt"),
                expectedSignature: "Which database?", optionID: "2")!
            do { try await terminal.answer(request, freshObservation: fresh); XCTFail("accepted stale token") }
            catch { XCTAssertEqual(error as? AgentActionError, .stalePrompt) }
            XCTAssertTrue(written.isEmpty)
        }
        do {
            var written: [String] = []
            let terminal = adapter(screen: { _ in question(entry: .init(optionID: "4", text: "occupied")) },
                writes: { written.append($0) }, count: { written.count })
            let request = AgentPromptAnswerRequest(threadID: claude, binding: binding,
                actionToken: AgentPromptGrammar.actionToken(for: "Which database?"),
                expectedSignature: "Which database?", optionID: "4", text: "abc")!
            do { try await terminal.answer(request, freshObservation: fresh); XCTFail("typed into occupied field") }
            catch { XCTAssertEqual(error as? AgentActionError, .terminalDraft) }
            XCTAssertTrue(written.isEmpty)
        }
    }

    func testPromptCaptureKeepsBottomWholeUTF8Rows() {
        let rows = Array(repeating: "界" + String(repeating: "x", count: 1000), count: 20).joined(separator: "\n")
        let clipped = AppleAgentPromptCapture.bottomWholeRows(rows)
        XCTAssertEqual(clipped, Array(repeating: "界" + String(repeating: "x", count: 1000), count: 16).joined(separator: "\n"))
        XCTAssertLessThanOrEqual(clipped.utf8.count, 16_384)
        XCTAssertEqual(AppleAgentPromptCapture.utf8Prefix("ééé", limit: 5), "éé")
        // A tmux capture keeps its styles (`-e -N`); the bound counts cells.
        let cells = (1...40).map { "  \($0). " + String(repeating: "option", count: 12) }
        let styled = cells.map { $0.map { "\u{1B}[38;5;246m\($0)" }.joined() + "\u{1B}[39m" }.joined(separator: "\n")
        XCTAssertGreaterThan(styled.utf8.count, 16_384)
        XCTAssertEqual(AppleAgentPromptCapture.bottomWholeRows(styled), cells.joined(separator: "\n"))
    }

    /// Interrupt and open need only the pane's identity; a capture that raced
    /// a redraw is retried instead of reporting "the terminal changed".
    @MainActor
    func testObservationAndFirstAnswerCaptureExhaustionKeepAnHonestPreWriteOutcome() async throws {
        let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "capture-timeout")!
        let screen = AgentPromptObservationResult(signature: "Question", options: [
            .init(id: "1", label: "Yes", responseMacro: "1", isDefault: true)!
        ], kind: .question, identity: "question", question: "Continue?")!
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for throwsCapture in [false, true] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("capture-timeout")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .promptAnswer])
                var captures = 0, writes = 0
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        captures += 1
                        if throwsCapture { throw AppleAgentInspectionUnavailable.capture }
                        return .init(observation: .init(binding: binding, liveTail: " \n"))
                    }, sendText: { _, _, _, _ in writes += 1; return true }, sendKey: { _, _, _ in writes += 1; return true },
                    verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .opened }),
                    readinessWindow: .milliseconds(50), readinessInterval: .milliseconds(10))
                let request = AgentPromptAnswerRequest(threadID: thread, binding: binding,
                    actionToken: AgentPromptGrammar.actionToken(for: screen.signature), expectedSignature: screen.signature,
                    optionID: "1")!
                for answer in [false, true] {
                    captures = 0
                    do {
                        if answer { try await adapter.answer(request, freshObservation: .init(binding: binding, liveTail: "Question")) }
                        else { _ = try await adapter.observe(binding: binding) }
                        XCTFail("an unsettled capture authorized an action")
                    } catch { XCTAssertEqual(error as? AgentActionError, .inputNotReady, transport.rawValue) }
                    XCTAssertGreaterThan(captures, 1)
                    XCTAssertEqual(writes, 0)
                }
            }
        }
        let presentation = AgentCenterV2PresentationModel()
        presentation.reportActionError(.inputNotReady)
        XCTAssertEqual(presentation.capabilityNotice, "The agent's input wasn't ready, so nothing was typed into the terminal.")
    }

    @MainActor
    func testObservationStillRejectsARealBindingMismatchWithoutRetrying() async throws {
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("binding-mismatch")!, transport: .sshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe])
        let replacement = AgentTerminalBinding(liveSessionID: binding.liveSessionID, carrierGeneration: 2,
            incarnation: binding.incarnation, transport: binding.transport,
            tmuxSession: binding.tmuxSession, windowID: binding.windowID, paneID: binding.paneID,
            agentPID: 42, capabilities: binding.capabilities)
        var captures = 0
        let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
            inspect: { _ in captures += 1; return .init(observation: .init(binding: replacement, liveTail: "Question")) },
            sendText: { _, _, _, _ in false }, sendKey: { _, _, _ in false },
            verifySubmission: { _, _, _ in false }, openExactBinding: { _ in .staleBinding }))
        do { _ = try await adapter.observe(binding: binding); XCTFail("a replaced binding was observed") }
        catch { XCTAssertEqual(error as? AgentActionError, .staleBinding) }
        XCTAssertEqual(captures, 1)
    }

    @MainActor
    func testInterruptAndOpenRetryAnUnsettledCaptureAcrossTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("unsettled-interrupt")!, transport: transport,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .interrupt])
            for settlesAfter in [nil, 2] as [Int?] {
                var captures = 0, keys = 0, opened = 0
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        captures += 1
                        guard let settlesAfter, captures > settlesAfter else { throw AppleAgentInspectionUnavailable.capture }
                        return .init(observation: .init(binding: binding, liveTail: "working", prompt: nil))
                    },
                    sendText: { _, _, _, _ in false }, sendKey: { _, _, _ in keys += 1; return true },
                    verifySubmission: { _, _, _ in false },
                    openExactBinding: { _ in opened += 1; return .opened }),
                    readinessWindow: .milliseconds(400), readinessInterval: .milliseconds(50))
                for open in [false, true] {
                    captures = 0
                    do {
                        if open { try await adapter.openTerminal(binding: binding) } else { try await adapter.interrupt(binding: binding) }
                        XCTAssertNotNil(settlesAfter, "\(transport): an unsettled capture proved the pane")
                    } catch {
                        XCTAssertNil(settlesAfter, "\(transport): \(error)")
                        XCTAssertEqual(error as? AgentActionError, .inputNotReady, transport.rawValue)
                    }
                    XCTAssertGreaterThan(captures, 1, "\(transport): the capture is retried")
                }
                XCTAssertEqual(keys, settlesAfter == nil ? 0 : 1, transport.rawValue)
                XCTAssertEqual(opened, settlesAfter == nil ? 0 : 1, transport.rawValue)
            }
        }
    }

    @MainActor
    func testNativeInventoryPageFailureAndOwnershipLossDoNotSuppressRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-inventory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        coordinator.setSurfaceDemand(true)
        defer { coordinator.closeIngestionHosts() }
        let carrier = makeBinding()
        let factory = AppleContextTestFactory()
        let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
            discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
            automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
            projectorExecAvailability: { _, _ in .available(.init { try await factory.open($0) }) },
            readCarrier: { carrier })
        let session = AppleAgentSessionRoute(hostID: UUID(), hostDisplayLabel: "fixture", source: source,
            profiles: { [] }, carrierGeneration: carrier.carrierGeneration)
        coordinator.sessionRoutes[carrier.liveSessionID] = session
        let (host, _) = try await coordinator.nativeHost(source: source)
        func row(_ id: String) -> [String: AgentJSONValue] {
            ["provider": .string("claude"), "sessionID": .string(id), "thread": .string("handle_" + id),
             "transcriptRef": .string("/fixture/" + id + ".jsonl")]
        }
        let first = try XCTUnwrap(AgentThreadID(hostID: session.hostID, providerID: .claude, providerSessionID: "first"))
        let second = try XCTUnwrap(AgentThreadID(hostID: session.hostID, providerID: .claude, providerSessionID: "second"))
        for invalid in [[row("first"), [:]], [row("first"), row("first")], Array(repeating: row("first"), count: 501)] {
            do {
                _ = try await coordinator.applyNativeInventoryPage(invalid, host: host, session: session, isCurrent: { true })
                XCTFail("invalid page accepted")
            } catch { XCTAssertTrue(error is AgentIngestionError) }
            XCTAssertTrue(host.threads.isEmpty)
            XCTAssertTrue(host.claimedThreads.isEmpty)
            XCTAssertTrue(coordinator.historicalRoutes.isEmpty)
            XCTAssertNil(coordinator.bridge.threadSnapshots[first])
        }
        var alias = row("second")
        alias["thread"] = .string("handle_first")
        do {
            _ = try await coordinator.applyNativeInventoryPage([row("first"), alias], host: host, session: session, isCurrent: { true })
            XCTFail("duplicate routing handle accepted")
        } catch { XCTAssertTrue(error is AgentIngestionError) }
        XCTAssertTrue(host.threads.isEmpty)
        var checks = 0
        let stale = try await coordinator.applyNativeInventoryPage([row("first"), row("second")], host: host, session: session) {
            checks += 1; return checks == 1
        }
        XCTAssertFalse(stale)
        XCTAssertTrue(host.threads.isEmpty)
        XCTAssertTrue(coordinator.historicalRoutes.isEmpty, "a stale completion cannot install the retry-success marker")
        let repaired = try await coordinator.applyNativeInventoryPage([row("first"), row("second")], host: host, session: session, isCurrent: { true })
        XCTAssertTrue(repaired)
        for thread in [first, second] {
            XCTAssertNotNil(coordinator.bridge.threadSnapshots[thread])
            XCTAssertNotNil(coordinator.historicalRoutes[thread])
            XCTAssertNotNil(host.threads[thread])
        }
        let largePage = (0..<500).map { row("large-\($0)") }
        var largeChecks = 0
        let partial = try await coordinator.applyNativeInventoryPage(largePage, host: host, session: session) {
            largeChecks += 1; return largeChecks == 1
        }
        XCTAssertFalse(partial)
        XCTAssertEqual(host.threads.count, 2)
        XCTAssertEqual(coordinator.historicalRoutes.count, 2)
        XCTAssertEqual(coordinator.bridge.threadSnapshots.count, 102, "only the first bounded Core chunk was accepted")
        let largeApplied = try await coordinator.applyNativeInventoryPage(largePage, host: host, session: session, isCurrent: { true })
        XCTAssertTrue(largeApplied)
        XCTAssertEqual(host.threads.count, 502)
        XCTAssertEqual(coordinator.bridge.threadSnapshots.count, 502)
        XCTAssertTrue(coordinator.bridge.listSnapshot.threads.isEmpty)
        await coordinator.setExperimentEnabled(false)
    }

    @MainActor
    func testPublishTakesOnlySnapshotsThatChangedSinceTheLastPublish() async throws {
        // Inventory keeps a snapshot per stored session; a main-actor publish
        // several times a second must not compare every one of them.
        let bridge = AppleAgentCenterRuntimeBridge(runtime: .init(), titleGenerator: nil)
        let host = UUID()
        let availability = AgentAvailability(content: true, status: true, actions: false, spawn: false, fork: false, search: false)
        let threads = try (0..<3).map { try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "take-\($0)")) }
        for thread in threads { await bridge.register(AgentThreadSummary(id: thread, providerName: "Claude", availability: availability)) }
        XCTAssertEqual(Set(bridge.takePresentationChanges().map(\.summary.id)), Set(threads), "the first publish applies everything")
        XCTAssertTrue(bridge.takePresentationChanges().isEmpty, "an unchanged publish applies nothing")
        await bridge.register(AgentThreadSummary(id: threads[1], providerName: "Claude", status: .working, availability: availability))
        await bridge.refresh(threads[2])
        XCTAssertEqual(bridge.takePresentationChanges().map(\.summary.id), [threads[1]], "an unchanged re-read is not a change")
        bridge.invalidatePresentation()
        XCTAssertEqual(bridge.takePresentationChanges().count, 3, "a cleared presentation takes every snapshot again")
    }

    @MainActor
    func testNativeInventoryRegistrationCostAndHistoricalVisibility() async throws {
        let host = UUID()
        let summaries = try (0..<1239).map { index in
            let thread = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude,
                providerSessionID: "inventory-cost-\(index)"))
            return AgentThreadSummary(id: thread, providerName: "Claude",
                availability: .init(content: true, status: false, actions: false,
                    spawn: false, fork: false, search: false))
        }
        var baseline: [AgentThreadID: AgentThreadSnapshot] = [:]
        for mode in ["per-row", "per-page"] {
            let bridge = AppleAgentCenterRuntimeBridge(runtime: .init(), titleGenerator: nil)
            let started = ContinuousClock.now
            if mode == "per-row" {
                for summary in summaries { await bridge.register(summary) }
            } else {
                for offset in stride(from: 0, to: summaries.count, by: 100) {
                    try await bridge.registerInventoryPage(Array(summaries[offset..<min(offset + 100, summaries.count)]))
                }
            }
            let elapsed = started.duration(to: .now).components
            NSLog("[AgentInventoryCost] mode=%@ rows=1239 wallMS=%.3f", mode,
                Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(bridge.threadSnapshots.count, 1239)
            XCTAssertTrue(bridge.listSnapshot.threads.isEmpty, "historical inventory must not appear as live agents")
            if mode == "per-row" { baseline = bridge.threadSnapshots }
            else { XCTAssertEqual(bridge.threadSnapshots, baseline) }
        }
    }

    @MainActor
    func testInstallerRemoteFailureCodeSurvivesChannelTeardownWithoutLeakingTraceback() {
        let output = Data("Traceback: private fixture path\nRuntimeError: versionStorageBudget\n".utf8)
        let error = AppleAgentInstallationExec.classifiedFailure(CancellationError(), output: output)
        guard case AgentLifecycleIntegrationInstallError.verificationFailed(let reason) = error else {
            return XCTFail("known remote installation error was hidden by channel teardown")
        }
        XCTAssertEqual(reason, "artifact: versionStorageBudget")
        for text in ["RuntimeError: private unknown detail\n", "prefix RuntimeError: versionStorageBudget\n",
                     "RuntimeError: versionStorageBudget\ntrailing private output\n"] {
            XCTAssertTrue(AppleAgentInstallationExec.classifiedFailure(CancellationError(), output: Data(text.utf8)) is CancellationError)
        }
    }

    @MainActor
    func testInstallerCallerCancellationWinsQueuedSuccessAndRemoteFailure() async {
        let remote = AppleAgentInstallationExec.classifiedFailure(CancellationError(),
            output: Data("RuntimeError: versionStorageBudget\n".utf8))
        let results: [Result<String, Error>] = [.success("ready"), .failure(remote)]
        for result in results {
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try AppleAgentInstallationExec.completeForCaller(result)
            }
            do { _ = try await task.value; XCTFail("queued completion hid caller cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(try? AppleAgentInstallationExec.completeForCaller(.success("ready")), "ready")
    }

    @MainActor
    func testIntegrationReadDeadlineAndCancellationCloseChildAndRejectLateOutput() async throws {
        for cancel in [false, true] {
            for opensLate in [false, true] {
                let gate = AppleSearchTestGate()
                let closed = expectation(description: "owned child closed")
                closed.assertForOverFulfill = true
                let drained = expectation(description: "late producer drained")
                let read = Task {
                    try await AppleAgentBoundedCommandExec.run(timeout: cancel ? .seconds(10) : .milliseconds(30)) { operation in
                        if !opensLate {
                            let accepted = await operation.accept(close: { closed.fulfill() })
                            XCTAssertTrue(accepted)
                        }
                        await gate.wait() // deliberately ignores cancellation
                        if opensLate {
                            let accepted = await operation.accept(close: { closed.fulfill() })
                            XCTAssertFalse(accepted)
                        }
                        do { try await operation.append(Data("late frame".utf8)); XCTFail("late output accepted") }
                        catch { XCTAssertTrue(error is CancellationError) }
                        drained.fulfill()
                    }
                }
                for _ in 0..<100 {
                    if await gate.isWaiting { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                // The 10 s deadline also ends a cancelled read as CancellationError,
                // so only promptness shows that cancellation itself closed it.
                let cancelledAt = ContinuousClock.now
                if cancel { read.cancel() }
                do { _ = try await read.value; XCTFail("stalled probe completed") }
                catch {
                    if cancel {
                        XCTAssertTrue(error is CancellationError)
                        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(3))
                    }
                    else { XCTAssertEqual(error as? AgentProjectionError, .channelUnavailable) }
                }
                await gate.release()
                await fulfillment(of: [closed, drained], timeout: 2)
            }
        }
    }

    @MainActor
    func testIntegrationReadOutputBudgetAndSuccessfulCompletionCloseOnlyTheirChild() async throws {
        for overflow in [false, true] {
            let closed = expectation(description: "completed child closed")
            do {
                let output = try await AppleAgentBoundedCommandExec.run(timeout: .seconds(1)) { operation in
                    _ = await operation.accept(close: { closed.fulfill() })
                    try await operation.append(overflow ? Data(repeating: 65, count: 128 * 1024 + 1) : Data("ready".utf8))
                }
                XCTAssertFalse(overflow)
                XCTAssertEqual(output, "ready")
            } catch { XCTAssertEqual(error as? AppleAgentPlatformError, .boundedPayloadExceeded) }
            await fulfillment(of: [closed], timeout: 2)
        }
    }

    func testNativeHistoryPanAccumulatesSmallWheelMotionAndRearmsDirection() {
        var demand = AgentTranscriptPanDemand()
        XCTAssertNil(demand.update(state: .began, translation: 0))
        XCTAssertNil(demand.update(state: .changed, translation: 1))
        XCTAssertNil(demand.update(state: .changed, translation: 2))
        let older = demand.update(state: .changed, translation: 3)
        XCTAssertEqual(older?.direction, "before"); XCTAssertEqual(older?.began, true)
        let reversed = demand.update(state: .changed, translation: -1)
        XCTAssertEqual(reversed?.direction, "after"); XCTAssertEqual(reversed?.began, false)
        XCTAssertNil(demand.update(state: .cancelled, translation: -1))
        let next = demand.update(state: .began, translation: -3)
        XCTAssertEqual(next?.direction, "after"); XCTAssertEqual(next?.began, true)
        XCTAssertNil(demand.update(state: .ended, translation: -3))
        XCTAssertNil(demand.update(state: .possible, translation: 200))
    }

    func testTerminalInputPolicyPreservesPromptMacrosAndRejectsComposerControls() {
        for pasteEnabled in [false, true] {
            let macro = Data([0x31, 0x0D, 0x09, 0x1B])
            XCTAssertEqual(AppleAgentTerminalInputPolicy.bytes(macro, purpose: .promptAnswer,
                provider: "codex", bracketedPasteEnabled: pasteEnabled), macro)
            XCTAssertNil(AppleAgentTerminalInputPolicy.bytes(macro, purpose: .composer,
                provider: "codex", bracketedPasteEnabled: pasteEnabled))
            let text = Data("first\nsecond\n".utf8)
            XCTAssertEqual(AppleAgentTerminalInputPolicy.bytes(text, purpose: .composer,
                provider: "codex", bracketedPasteEnabled: pasteEnabled),
                AgentTextInsertion.bytes(provider: "codex", text: "first\nsecond\n", bracketedPasteEnabled: pasteEnabled))
        }
    }

    @MainActor
    func testCodexImagesWaitForCompleteDraftAndRecheckBeforeSubmissionOnEveryTransport() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for scenario in ["attached", "unreadable", "changed-before-submit"] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("image-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "image-test")!
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "Describe\n\"/tmp/a.png\"", queueWhenWorking: false)!
                var writes = 0
                var afterCaptures = 0
                var submitting = false
                var keys: [AppleAgentTerminalKey] = []
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        if writes > 0 { afterCaptures += 1 }
                        let ready = writes > 0 && afterCaptures > 1 && scenario != "unreadable" && !(submitting && scenario == "changed-before-submit")
                        let rows = writes == 0 ? ["› "] : ["› Describe", ready ? "  [Image #1] " : "  \"/tmp/a.png\""]
                        let visible = rows.joined(separator: "\n") + "\n\ngpt-5.4 default · /tmp"
                        return .init(observation: .init(binding: binding, liveTail: visible), composerText: rows.last,
                            composerRow: rows.count - 1, composerVisibleText: visible, composerCursorVisible: true)
                    }, sendText: { bytes, purpose, _, _ in
                        writes += 1
                        XCTAssertEqual(AppleAgentTerminalInputPolicy.bytes(bytes, purpose: purpose, provider: "codex", bracketedPasteEnabled: false),
                            Data("\u{1b}[200~Describe\n\u{1b}[201~\u{1b}[200~'/tmp/a.png'\u{1b}[201~".utf8))
                        return true
                    }, sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, _, _ in true },
                    openExactBinding: { _ in .staleBinding }
                ), readinessWindow: .milliseconds(200), readinessInterval: .milliseconds(20))
                if scenario == "unreadable" {
                    do { try await adapter.sendText(request); XCTFail("image path submitted as prose") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                } else {
                    try await adapter.sendText(request)
                    XCTAssertGreaterThanOrEqual(afterCaptures, 2)
                    submitting = true
                }
                if scenario == "attached" {
                    try await adapter.sendReturn(binding: binding)
                    XCTAssertEqual(keys, [.return])
                } else {
                    do { try await adapter.sendReturn(binding: binding); XCTFail("unverified image received Return") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                    XCTAssertTrue(keys.isEmpty)
                }
                XCTAssertEqual(writes, 1, "an image paste must never be replayed")
            }
        }
    }

    @MainActor
    func testClaudeImagesWaitForCompleteDraftAndRecheckBeforeSubmissionOnEveryTransport() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for scenario in ["attached", "slow-attached", "unreadable", "literal", "literal-changed-before-submit", "changed-before-submit", "swallowed-return"] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("claude-image-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "image-test")!
                let text = "\"/tmp/a.png\"\n\"/tmp/b.png\"\nReply with one word: ok"
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: text, queueWhenWorking: false)!
                var writes = 0
                var afterCaptures = 0
                var submitting = false
                var verifications = 0
                var keys: [AppleAgentTerminalKey] = []
                let footer = "\n──────────────────────────────\n? for shortcuts"
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        if writes > 0 { afterCaptures += 1 }
                        let ready = writes > 0 && afterCaptures > (scenario == "slow-attached" ? 24 : 1) && scenario != "unreadable" && !(submitting && scenario == "changed-before-submit")
                        var rows = writes == 0 ? ["❯ "] : ["❯ [Image #4]", ready ? "  [Image #5]" : "  \"/tmp/b.png\"", "  Reply with one word: ok"]
                        if writes > 0 && scenario.hasPrefix("literal") {
                            rows = ["❯ \"/tmp/a.png\"", "  \"/tmp/b.png\"", "  Reply with one word: ok"]
                            if submitting && scenario == "literal-changed-before-submit" { rows[0] = "❯ [Image #4]" }
                        }
                        let visible = rows.joined(separator: "\n") + footer
                        return .init(observation: .init(binding: binding, liveTail: visible), composerText: rows.last,
                            composerRow: rows.count - 1, composerVisibleText: visible, composerCursorVisible: true)
                    }, sendText: { bytes, purpose, _, _ in
                        writes += 1
                        XCTAssertEqual(AppleAgentTerminalInputPolicy.bytes(bytes, purpose: purpose, provider: "claude", bracketedPasteEnabled: false),
                            Data("\u{1b}[200~\"/tmp/a.png\"\u{1b}[201~\u{1b}[200~\n\u{1b}[201~\u{1b}[200~\"/tmp/b.png\"\u{1b}[201~\u{1b}[200~\n\u{1b}[201~\u{1b}[200~Reply with one word: ok\u{1b}[201~".utf8))
                        return true
                    }, sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, submitted, _ in
                        verifications += 1
                        let rows = scenario == "swallowed-return" ? ["❯ [Image #4]", "  [Image #5]", "  Reply with one word: ok"] : ["❯ "]
                        return AgentComposerEvidence.presence(provider: "claude", visibleText: rows.joined(separator: "\n") + footer,
                            cursorLine: rows.last, text: submitted, cursorRow: rows.count - 1) == .absent
                    }, openExactBinding: { _ in .staleBinding }
                ), readinessWindow: .milliseconds(200), readinessInterval: .milliseconds(20))
                if scenario == "unreadable" {
                    do { try await adapter.sendText(request); XCTFail("incomplete image draft submitted") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                } else {
                    try await adapter.sendText(request)
                    XCTAssertGreaterThanOrEqual(afterCaptures, 2)
                    submitting = true
                }
                if ["attached", "slow-attached", "literal", "swallowed-return"].contains(scenario) {
                    try await adapter.sendReturn(binding: binding)
                    XCTAssertEqual(keys, [.return])
                    if scenario == "swallowed-return" {
                        do { try await adapter.verifySubmission(threadID: thread, binding: binding); XCTFail("retained markers counted as submitted") }
                        catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                    } else {
                        try await adapter.verifySubmission(threadID: thread, binding: binding)
                    }
                    if scenario == "literal" { XCTAssertEqual(verifications, 0) }
                    else { XCTAssertGreaterThan(verifications, 0) }
                } else {
                    do { try await adapter.sendReturn(binding: binding); XCTFail("unverified image received Return") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                    XCTAssertTrue(keys.isEmpty)
                }
                XCTAssertEqual(writes, 1, "an image paste must never be replayed")
            }
        }
    }

    @MainActor
    func testClaudeSubmissionVerificationBudgetBoundsSlowAndUncooperativeCaptures() async throws {
        for stalled in [false, true] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("verification-budget")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "budget-test")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "\"/tmp/a.png\"", queueWhenWorking: false)!
            var written = false
            var reads = 0
            var release: CheckedContinuation<Bool, Never>?
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    let row = written ? "❯ [Image #4]" : "❯ "
                    let visible = row + "\n────\n? for shortcuts"
                    return .init(observation: .init(binding: binding, liveTail: visible), composerText: row,
                        composerRow: 0, composerVisibleText: visible, composerCursorVisible: true)
                }, sendText: { _, _, _, _ in written = true; return true }, sendKey: { _, _, _ in true },
                verifySubmission: { _, _, _ in
                    reads += 1
                    if stalled { return await withCheckedContinuation { release = $0 } }
                    try await Task.sleep(for: .milliseconds(15))
                    return false
                }, openExactBinding: { _ in .staleBinding }
            ), submissionVerificationWindow: .milliseconds(90))
            try await adapter.sendText(request)
            try await adapter.sendReturn(binding: binding)
            let started = ContinuousClock.now
            do {
                try await adapter.verifySubmission(threadID: thread, binding: binding)
                XCTFail("Retained or stalled capture confirmed departure")
            } catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
            let elapsed = started.duration(to: .now)
            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(80))
            XCTAssertLessThan(elapsed, .seconds(1))
            XCTAssertGreaterThan(reads, 0)
            XCTAssertLessThan(reads, 40)
            if stalled {
                XCTAssertEqual(reads, 1)
                release?.resume(returning: true)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(reads, 1)
            }
        }
    }

    @MainActor
    func testPaneCaptureUsesOneBodyAndRejectsCursorMovement() async throws {
        for finalCursor in ["1:6:1", "0:6:1", "1:2:1", "1:6:0"] {
            var calls: [String] = []
            let capture = await AgentSessionSourceFactory.capturePane(paneID: PaneId(2)) { command in
                calls.append(command)
                if command.hasPrefix("capture-pane") { return .success(["› first", "second", "", "95% context left"]) }
                XCTAssertTrue(command.contains("#{cursor_x}"))
                return .success([calls.count == 3 ? finalCursor : "1:6:1"])
            }
            XCTAssertEqual(calls.count, 3)
            if finalCursor != "1:6:1" { XCTAssertNil(capture) }
            else {
                XCTAssertEqual(capture?.cursorRow, 1)
                XCTAssertEqual(capture?.cursorColumn, 6)
                XCTAssertEqual(capture?.cursorVisible, true)
                XCTAssertEqual(capture?.currentInputLine, "second")
                XCTAssertEqual(capture?.text, "› first\nsecond\n\n95% context left")
            }
        }
    }

    @MainActor
    func testRawFactoryReportsDisconnectedAdmissionForTextAndKeys() async {
        let session = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let tmux = TmuxController(controlPath: .inline)
        var legacyWrites = 0
        let source = AgentSessionSourceFactory.make(sessionID: session.host.id, hostName: "fixture", baseTransportLabel: "ssh",
            tmux: tmux, terminalBox: TerminalBox(traceLabel: "raw-admission"), tmuxSessionName: { nil }, profiles: { [] },
            rawProcessProvider: { nil }, sessionCommands: AppleSessionCommandFacade(session: session, tmux: tmux),
            rawSend: { _ in legacyWrites += 1 })
        let location = AgentLocation(sessionID: session.host.id, hostName: "fixture", transportLabel: "ssh",
            tmuxSessionName: nil, windowID: nil, windowName: nil, paneID: nil)
        let admitted = await source.send(location, Array("hello".utf8))
        let keyAdmitted = await source.sendKey?(location, .enter)
        XCTAssertFalse(admitted)
        XCTAssertEqual(keyAdmitted, false)
        XCTAssertEqual(legacyWrites, 0)
    }

    @MainActor
    func testRawNonAdmissionIsNotWrittenWhileAmbiguousFailuresStayDistinct() async throws {
        let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "raw-admission")!
        for transport in [AgentTransportKind.ssh, .mosh, .sshTmux, .moshTmux] {
            for ambiguous in [false, true] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("raw-admission")!, transport: transport,
                    tmuxSession: nil, windowID: nil, paneID: nil, agentPID: 42, capabilities: [.observe, .send])
                let visible = "❯ \n────\nctx:6%  Fable 5.1"
                var writes = 0
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in .init(observation: .init(binding: binding, liveTail: visible), composerText: "❯ ",
                        composerRow: 0, composerColumn: 2, composerVisibleText: visible, composerCursorVisible: true) },
                    sendText: { _, _, _, _ in
                        writes += 1
                        if ambiguous { throw AgentActionError.unavailable }
                        return false
                    }, sendKey: { _, _, _ in XCTFail("a refused insertion must not send K"); return false },
                    verifySubmission: { _, _, _ in false }, openExactBinding: { _ in .staleBinding }))
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false)!
                do { try await adapter.sendText(request); XCTFail("a refused write succeeded") }
                catch {
                    if !ambiguous && (transport == .ssh || transport == .mosh) {
                        let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten)
                        XCTAssertEqual(refusal.error, .inputNotReady)
                        XCTAssertEqual(refusal.reason, "transport-not-admitted")
                    } else {
                        XCTAssertNil(error as? AppleAgentSendNotWritten)
                        XCTAssertEqual(error as? AgentActionError, .unavailable)
                    }
                }
                XCTAssertEqual(writes, 1)
            }
        }
    }

    @MainActor
    func testRawPromptAndInterruptRefusalsDoNotClaimAWriteWhileLaterFailuresStayAmbiguous() async throws {
        let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "raw-key-refusal")!
        for transport in [AgentTransportKind.ssh, .mosh] {
            for admitsFirstStep in [false, true] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("raw-key-refusal")!, transport: transport, agentPID: 42,
                    capabilities: [.observe, .promptAnswer, .interrupt])
                var writes = 0
                func screen(selected: Bool) -> AgentPromptObservationResult {
                    .init(signature: "Question", options: [
                        .init(id: "1", label: "Keep it", responseMacro: "1", isDefault: true, isChecked: false)!
                    ], kind: .multiSelect, identity: "question", question: "Continue?",
                        controls: [.init(kind: .next, label: "Next", isSelected: selected)])!
                }
                let initial = screen(selected: false)
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in .init(observation: .init(binding: binding, liveTail: "Question"), promptScreen: screen(selected: writes > 0)) },
                    sendText: { _, _, _, _ in writes += 1; return admitsFirstStep && writes == 1 },
                    sendKey: { _, _, _ in false }, verifySubmission: { _, _, _ in false }, openExactBinding: { _ in .staleBinding }))
                let request = AgentPromptAnswerRequest(threadID: thread, binding: binding,
                    actionToken: AgentPromptGrammar.actionToken(for: initial.signature), expectedSignature: initial.signature,
                    optionID: "next", control: .next)!
                do { try await adapter.answer(request, freshObservation: .init(binding: binding, liveTail: "Question")); XCTFail("a refused step succeeded") }
                catch { XCTAssertEqual(error as? AgentActionError, admitsFirstStep ? .unavailable : .inputNotReady) }
                XCTAssertEqual(writes, admitsFirstStep ? 2 : 1)
                do { try await adapter.interrupt(binding: binding); XCTFail("a refused interrupt succeeded") }
                catch { XCTAssertEqual(error as? AgentActionError, .inputNotReady) }
            }
        }
    }

    @MainActor
    func testOccupancySnapshotKeepsSuspendedAndEditorProcessesWithExactProviders() {
        let snapshot = SwipePadPlainSSHProcessProbe.snapshot(from: """
        100 1 Ss pts/1 zsh zsh
        42 100 T pts/1 claude /bin/claude
        77 100 S pts/1 node /bin/node /usr/bin/codex
        80 42 S+ pts/1 vim vim
        81 100 S pts/1 codex codex fix claude hooks
        82 100 S pts/1 less less claude.md codex
        83 100 S pts/1 2.0.14 /home/u/.local/share/claude/versions/2.0.14
        99 1 S ? claude claude
        """)
        XCTAssertEqual(snapshot.processIDs, [80], "SwipePad still follows the foreground editor")
        XCTAssertEqual(snapshot.processNames, ["vim"])
        XCTAssertEqual(Set(snapshot.attachedProcesses.map(\.pid)), [100, 42, 77, 80, 81, 82, 83])
        let pane = AgentSessionSourceFactory.occupancyPane(paneID: "75", snapshot: snapshot)
        // A prompt or file argument naming another agent names no executable.
        XCTAssertEqual(pane.processes, [.init(pid: 42, providerID: .claude), .init(pid: 77, providerID: .codex),
                                        .init(pid: 81, providerID: .codex)])
        // A versioned native binary names no provider but is still present.
        XCTAssertEqual(pane.unclassifiedPIDs, [80, 82, 83, 100])
        XCTAssertTrue(pane.complete)
    }

    @MainActor
    func testOccupancySnapshotMarksCappedAndMalformedReadsIncomplete() {
        let limit = AgentProcessSnapshotCommand.outputLineLimit
        for count in [limit - 1, limit, limit + 1] {
            let text = (0..<count).map { "\(100 + $0) 1 S+ pts/1 zsh zsh" }.joined(separator: "\n")
            let snapshot = SwipePadPlainSSHProcessProbe.snapshot(from: text)
            XCTAssertEqual(snapshot.truncated, count >= limit)
            XCTAssertEqual(snapshot.complete, count < limit)
            XCTAssertEqual(AgentSessionSourceFactory.occupancyPane(paneID: "75", snapshot: snapshot).complete, count < limit)
        }
        for text in ["", "42 1 S+ pts/1 claude claude\npartial"] {
            XCTAssertFalse(SwipePadPlainSSHProcessProbe.snapshot(from: text).complete)
        }
    }

    @MainActor
    func testOccupancyPaneListCompletenessRejectsMalformedAndCappedReplies() throws {
        let listed = try XCTUnwrap(AgentSessionSourceFactory.parseOccupancyPanes(["%75 100", "%76 200"]))
        XCTAssertEqual(listed.roots, [75: 100, 76: 200])
        XCTAssertTrue(listed.complete)
        for count in [AgentSessionSourceFactory.occupancyPaneLimit, AgentSessionSourceFactory.occupancyPaneLimit + 1] {
            let capped = try XCTUnwrap(AgentSessionSourceFactory.parseOccupancyPanes((0..<count).map { "%\($0) \(100 + $0)" }))
            XCTAssertFalse(capped.complete)
            XCTAssertEqual(capped.roots.count, AgentSessionSourceFactory.occupancyPaneLimit)
        }
        for lines in [[], ["%75 100", "partial"], ["%75 100", "%75 200"], ["75 100"], ["%75 0"]] {
            XCTAssertNil(AgentSessionSourceFactory.parseOccupancyPanes(lines))
        }
    }

    @MainActor
    func testTmuxOccupancyUsesOnePaneListAndIndependentProcessReadsWithoutCaptures() async throws {
        let session = SSHSession(host: Host(id: UUID(), transport: .ssh))
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        var entry = [UInt8](arrayLiteral: 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
        entry.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        tmux.ingest(entry)
        for number in 2...20 {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        var wire: [String] = [], reads: [(Int, Int?)] = []
        tmux.sendBytes = { wire.append(String(decoding: $0, as: UTF8.self)) }
        let source = AgentSessionSourceFactory.make(sessionID: session.host.id, hostName: "fixture", baseTransportLabel: "ssh",
            tmux: tmux, terminalBox: TerminalBox(traceLabel: "occupancy"), tmuxSessionName: { "rig" }, profiles: { [] },
            rawProcessProvider: { nil }, paneProcessProvider: { root, expected in
                reads.append((root, expected))
                guard root == 100 else { return nil }
                return SwipePadPlainSSHProcessProbe.snapshot(from: "100 1 Ss pts/1 zsh zsh\n42 100 T pts/1 claude claude\n80 42 S+ pts/1 vim vim")
            }, sessionCommands: AppleSessionCommandFacade(session: session, tmux: tmux), rawSend: { _ in })
        let observe = try XCTUnwrap(source.observeOccupancy)
        let bindings = [75, 76, 78].map { pane in
            AgentTerminalBinding(liveSessionID: session.host.id, carrierGeneration: 1,
                incarnation: AgentIncarnationToken("occupancy-\(pane)")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "1", paneID: String(pane), agentPID: pane == 75 ? 42 : 43, capabilities: [.observe])
        }
        let observing = Task { await observe(bindings) }
        for _ in 0..<100 where wire.isEmpty { await Task.yield() }
        XCTAssertEqual(wire, ["list-panes -a -F '#{pane_id} #{pane_pid}'\n"])
        tmux.ingest(Array("%begin 0 30 1\r\n%75 100\r\n%76 200\r\n%end 0 30 1\r\n".utf8))
        let result = await observing.value
        let observed = try XCTUnwrap(result)
        XCTAssertEqual(reads.map { $0.0 }, [100, 200])
        XCTAssertEqual(reads.map { $0.1 }, [42, 43])
        XCTAssertEqual(observed.allPaneIDs, ["75", "76"])
        XCTAssertEqual(observed.panes, [
            .init(paneID: "75", exists: true, complete: true, processes: [.init(pid: 42, providerID: .claude)],
                  unclassifiedPIDs: [80, 100]),
            .init(paneID: "78", exists: false, complete: true, processes: [])
        ])
        XCTAssertFalse(wire.contains { $0.contains("capture-pane") })
    }

    @MainActor
    func testRawOccupancyUsesOneBoundProcessSnapshotWithoutTerminalCapture() async throws {
        for transport in ["ssh", "mosh"] {
            let session = SSHSession(host: Host(id: UUID(), transport: .ssh))
            let tmux = TmuxController(controlPath: .sideChannel)
            var expectedPIDs: [Int?] = []
            let source = AgentSessionSourceFactory.make(sessionID: session.host.id, hostName: "fixture", baseTransportLabel: transport,
                tmux: tmux, terminalBox: TerminalBox(traceLabel: "raw-occupancy"), tmuxSessionName: { nil }, profiles: { [] },
                rawProcessProvider: { XCTFail("occupancy must preserve the bound PID in its read"); return nil },
                rawProcessProofProvider: { expected in
                    expectedPIDs.append(expected)
                    return SwipePadPlainSSHProcessProbe.snapshot(from: "100 1 Ss pts/1 zsh zsh\n42 100 T pts/1 claude claude\n80 42 S+ pts/1 vim vim")
                }, sessionCommands: AppleSessionCommandFacade(session: session, tmux: tmux), rawSend: { _ in })
            let binding = AgentTerminalBinding(liveSessionID: session.host.id, carrierGeneration: 1,
                incarnation: AgentIncarnationToken("raw-occupancy")!, transport: transport == "ssh" ? .ssh : .mosh,
                agentPID: 42, capabilities: [.observe])
            let observe = try XCTUnwrap(source.observeOccupancy)
            let result = await observe([binding])
            let observed = try XCTUnwrap(result)
            XCTAssertEqual(expectedPIDs, [42], transport)
            XCTAssertNil(observed.allPaneIDs)
            XCTAssertEqual(observed.panes, [.init(paneID: nil, exists: true, complete: true,
                processes: [.init(pid: 42, providerID: .claude)], unclassifiedPIDs: [80, 100])])
        }
    }

    @MainActor
    func testRawCaptureReprovesAfterFrameWaitAndCancellationProducesNoTarget() async throws {
        for transport in ["ssh", "mosh"] {
            for cancelled in [false, true] {
                let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
                let box = TerminalBox(traceLabel: "capture-proof-fixture")
                box.view = view
                view.getTerminal().feed(text: "\u{1b}[?2026h\u{1b}[H› ")
                let host = Host(name: "fixture", address: "192.0.2.1", port: 22, user: "fixture")
                let session = SSHSession(host: host) // never connected
                let id = UUID()
                var proofs = 0
                var writes = 0
                let profile = SwipePadProfile(id: UUID(), name: "Codex", matchProcess: "codex", bindings: [:], isBuiltIn: false)
                let source = AgentSessionSourceFactory.make(sessionID: id, hostName: "fixture", baseTransportLabel: transport,
                    tmux: TmuxController(controlPath: .sideChannel), terminalBox: box,
                    tmuxSessionName: { nil }, profiles: { [profile] }, rawProcessProvider: {
                        proofs += 1
                        return .init(processNames: ["codex"], processIDs: [proofs == 1 ? 42 : 43])
                    }, sessionCommands: AppleSessionCommandFacade(session: session), rawSend: { _ in writes += 1 })
                let location = AgentLocation(sessionID: id, hostName: "fixture", transportLabel: transport,
                    tmuxSessionName: nil, windowID: nil, windowName: nil, paneID: nil)
                let task = Task { @MainActor in await source.inspect(location) }
                for _ in 0..<100 where proofs == 0 { await Task.yield() }
                XCTAssertEqual(proofs, 1)
                if cancelled { task.cancel() }
                else { view.getTerminal().feed(text: "\u{1b}[?2026l") }
                let observed = await task.value
                if cancelled { XCTAssertNil(observed); XCTAssertEqual(proofs, 1) }
                else {
                    XCTAssertEqual(proofs, 2)
                    XCTAssertEqual(observed?.processIDs, [43], "The PID proved before waiting must never survive")
                    XCTAssertNotNil(observed?.screenEvidence)
                }
                XCTAssertEqual(writes, 0)
                withExtendedLifetime(view) {}
            }
        }
    }

    @MainActor
    func testRawComposerCapturePreservesStyleCursorAndPhysicalRowsWhileScrolledBack() throws {
        let delegate = AgentComposerTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 4, scrollback: 100))
        terminal.feed(text: String(repeating: "old output\r\n", count: 12))
        terminal.feed(text: "\u{1b}[2J\u{1b}[Habove\r\n❯\u{00a0}\u{1b}[2;38;5;244msuggestion\u{1b}[0m\r\n────────\r\nctx: 5%\u{1b}[2;3H")
        terminal.buffer.yDisp = 0 // user reading history must not change the live input evidence
        let capture = try XCTUnwrap(AgentSessionSourceFactory.terminalCapture(terminal))
        XCTAssertEqual(capture.cursorRow, 1)
        XCTAssertEqual(capture.cursorColumn, 2)
        XCTAssertEqual(capture.currentInputLine, "❯\u{00a0}suggestion")
        XCTAssertEqual(capture.text.components(separatedBy: "\n").count, 4)
        XCTAssertEqual(capture.screenEvidence?.cells[1][2].style, 32)
        XCTAssertFalse(capture.text.contains("\u{1b}"))
        XCTAssertEqual(AgentTerminalText.normalized(capture.text.components(separatedBy: "\n")[0]), "above")
        XCTAssertEqual(AgentTerminalText.normalized(capture.text.components(separatedBy: "\n")[3]), "ctx: 5%")
        // Claude's focused software cursor inverts the first suggestion
        // glyph, while the remaining placeholder is DIM.
        terminal.feed(text: "\u{1b}[2;1H\u{1b}[2K❯\u{00a0}\u{1b}[7ms\u{1b}[0;2muggestion\u{1b}[0m\u{1b}[2;3H")
        let focused = try XCTUnwrap(AgentSessionSourceFactory.terminalCapture(terminal))
        XCTAssertEqual(focused.cursorColumn, 2)
        XCTAssertEqual(focused.screenEvidence?.cells[1][2].style, 8)
        XCTAssertEqual(focused.screenEvidence?.cells[1][3].style, 32)
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: focused.text,
            cursorRow: focused.cursorRow, cursorColumn: focused.cursorColumn, cursorVisible: focused.cursorVisible,
            requireEmpty: true, queueWhenWorking: false, screen: focused.screenEvidence), .readyReturn)
        terminal.feed(text: "\u{1b}[2;1H\u{1b}[2K❯\u{00a0}typed")
        let typed = try XCTUnwrap(AgentSessionSourceFactory.terminalCapture(terminal))
        XCTAssertEqual(typed.cursorColumn, 7)
        XCTAssertEqual(typed.currentInputLine, "❯\u{00a0}typed")
        XCTAssertEqual(typed.screenEvidence?.cells[1][2].style, 0)
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: typed.text,
            cursorRow: typed.cursorRow, cursorColumn: typed.cursorColumn, cursorVisible: typed.cursorVisible,
            requireEmpty: true, queueWhenWorking: false, screen: typed.screenEvidence), .occupied)
        terminal.feed(text: "\u{1b}[?2026hpartial")
        XCTAssertNil(AgentSessionSourceFactory.terminalCapture(terminal))
        terminal.feed(text: "\u{1b}[?2026l\u{1b}[?1049hother\u{1b}[?25l")
        let alternate = try XCTUnwrap(AgentSessionSourceFactory.terminalCapture(terminal))
        XCTAssertEqual(alternate.screenEvidence?.isAlternate, true)
        XCTAssertEqual(alternate.cursorVisible, false)
    }

    @MainActor
    func testMultilineSendWaitsForPhysicalCursorThroughEveryTransport() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for provider in [AgentProviderID.codex, .claude] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("multiline-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "multiline-test")!
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "first\n\nsecond\n", queueWhenWorking: false)!
                let marker = provider == .claude ? "❯\u{00a0}" : "› "
                let footer = provider == .claude ? "────\nctx:6%" : "\n95% context left"
                var sent: [Data] = []
                var keys: [AppleAgentTerminalKey] = []
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        let text = sent.isEmpty ? marker : marker + request.text
                        let visible = text + "\n" + footer
                        return .init(observation: .init(binding: binding, liveTail: visible),
                            composerText: sent.isEmpty ? marker : "", composerRow: sent.isEmpty ? 0 : 3, composerVisibleText: visible, composerCursorVisible: true)
                    }, sendText: { bytes, _, _, _ in sent.append(bytes); return true },
                    sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, text, _ in
                        AgentComposerEvidence.presence(provider: provider.rawValue, visibleText: marker + "\n" + footer,
                            cursorLine: marker, text: text, cursorRow: 0) == .absent
                    }, openExactBinding: { _ in .staleBinding }
                ))
                try await adapter.sendText(request)
                try await adapter.sendReturn(binding: binding)
                try await adapter.verifySubmission(threadID: thread, binding: binding)
                XCTAssertEqual(sent, [Data(request.text.utf8)])
                XCTAssertEqual(keys, [.return])
            }
        }
    }

    @MainActor
    func testBridgePublishesPendingBeforePreparationAndDoesNotWriteOnPreparationFailure() async throws {
        for scenario in ["success", "failure", "cancelled"] {
            let core = AgentCenterRuntime()
            let bridge = AppleAgentCenterRuntimeBridge(runtime: core, titleGenerator: nil)
            let thread = makeThreadID()
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("pending")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            await core.register(.init(id: thread, providerName: "Claude", availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding)
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello pending", queueWhenWorking: false)!
            var accepted = false
            var prepared = false
            var writes = 0
            var notSent: [AgentActionError] = []
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    XCTAssertTrue(prepared)
                    let line = "❯ " + (writes > 0 ? request.text : "")
                    return .init(observation: .init(binding: binding, liveTail: line + "\n────\nctx:6%  Fable 5.1"), composerText: line, composerRow: 0, composerCursorVisible: true)
                }, sendText: { _, _, _, _ in writes += 1; return true }, sendKey: { _, _, _ in true },
                verifySubmission: { _, _, _ in true },
                openExactBinding: { _ in .staleBinding }
            ))
            let result = await bridge.submit(request, terminal: adapter, prepareReceipt: { lease in
                XCTAssertTrue(accepted)
                XCTAssertEqual(writes, 0)
                if scenario == "failure" { throw AgentActionError.unavailable }
                if scenario == "cancelled" { throw CancellationError() }
                prepared = true
                try await core.armOutgoing(lease, freshPage: AgentProjectionPage(sourceIdentity: "1:2:0:1", records: [], cursor: nil, hasMore: false)!)
            }, onAccepted: {
                accepted = true
                XCTAssertEqual(bridge.threadSnapshots[thread]?.outgoingMessages?.map(\.status), [.sending])
                XCTAssertEqual(writes, 0)
            }, onNotSent: { notSent.append($0.error) })
            XCTAssertTrue(accepted)
            if scenario == "success" {
                if case .failure(let error) = result { XCTFail("send failed: \(error)") }
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(bridge.threadSnapshots[thread]?.outgoingMessages?.map(\.status), [.awaitingReceipt])
            } else {
                if case .success = result { XCTFail("unprepared send succeeded") }
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(bridge.threadSnapshots[thread]?.outgoingMessages ?? [], [],
                    "nothing was written, so no bubble waits for a receipt")
                XCTAssertEqual(notSent, [scenario == "failure" ? .unavailable : .cancelled])
            }
        }
    }

    @MainActor
    func testBothProvidersSubmitDraftMarginsThroughEveryTransportAdapter() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for provider in [AgentProviderID.codex, .claude] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("margin-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "margin-test")!
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "  hello world  ", queueWhenWorking: false)!
                let marker = provider == .claude ? "❯\u{00a0}" : "› "
                let footer = provider == .claude ? "────\nctx:6%  Fable 5.1\n⏵⏵ auto mode on (shift+tab to cycle)" : "\ngpt-6-astra high · /repo"
                var inserted = false
                var departed = false
                var checks = 0
                var sent: [Data] = []
                var keys: [AppleAgentTerminalKey] = []
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        let line = marker + (inserted && !departed ? request.text : "")
                        return .init(observation: .init(binding: binding, liveTail: line + "\n" + footer), composerText: line, composerRow: 0, composerCursorVisible: true)
                    },
                    sendText: { bytes, _, _, _ in sent.append(bytes); inserted = true; return true },
                    sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, text, _ in
                        checks += 1
                        departed = checks >= 3
                        let line = marker + (departed ? "" : request.text)
                        return AgentComposerEvidence.presence(provider: provider.rawValue,
                            visibleText: line + "\n" + footer, cursorLine: line, text: text) == .absent
                    },
                    openExactBinding: { _ in .staleBinding }
                ))
                try await adapter.sendText(request)
                try await adapter.sendReturn(binding: binding)
                try await adapter.verifySubmission(threadID: thread, binding: binding)
                XCTAssertEqual(sent, [Data(request.text.utf8)], "comparison must not rewrite submitted text")
                XCTAssertEqual(keys, [.return])
                XCTAssertEqual(checks, 0, "delivery must not wait for rendered draft departure")
            }
        }
    }

    @MainActor
    func testBusySubmissionUsesSharedQueueKeyAndRechecksComposerBeforeSending() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for queue in [false, true] {
            for scenario in ["busy", "became-idle", "menu-opened"] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("queue-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "queue-test")!
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello world", queueWhenWorking: queue)!
                var inserted = false
                var submissionPhase = false
                var keys: [AppleAgentTerminalKey] = []
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        let draft = !inserted ? "" : "hello world"
                        let footer = submissionPhase && scenario == "became-idle" ? "gpt-5.6 low · /repo" : "tab to queue message 97% context left"
                        return .init(observation: .init(binding: binding, liveTail: "› \(draft)\n\n\(footer)"), composerText: "› \(draft)", queueSupported: true, composerRow: 0, composerCursorVisible: !(submissionPhase && scenario == "menu-opened"))
                    },
                    sendText: { _, _, _, _ in inserted = true; return true },
                    sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, _, _ in true }, openExactBinding: { _ in .staleBinding }
                ), readinessWindow: .milliseconds(200), readinessInterval: .milliseconds(20))
                try await adapter.sendText(request)
                submissionPhase = true
                if scenario == "menu-opened" {
                    do { try await adapter.sendReturn(binding: binding); XCTFail("menu received submit key") }
                    catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                    XCTAssertTrue(keys.isEmpty)
                } else {
                    try await adapter.sendReturn(binding: binding)
                    XCTAssertEqual(keys, [queue ? .tab : .return], "normal Send must steer; only explicit queue uses Tab")
                    try await adapter.verifySubmission(threadID: thread, binding: binding)
                }
            }
            }
        }
    }

    @MainActor
    func testTerminalSendUsesFreshInputGuardWithoutWaitingForDraftRendering() async throws {
        for scenario in ["already-present", "unchanged", "wrapped"] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("composer-test")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "composer-test")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello world", queueWhenWorking: false)!
            var inserted = false
            var writes = 0
            var returns = 0
            var completionChecks = 0
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    let rendered = scenario == "already-present" || (scenario == "wrapped" && inserted)
                    let screen = rendered ? "› hello\n  world\n\ngpt-5.6 low · /repo" : "› \n\ngpt-5.6 low · /repo"
                    return .init(observation: .init(binding: binding, liveTail: screen), composerText: rendered ? "world" : "› ", composerRow: rendered ? 1 : 0, composerCursorVisible: true)
                },
                sendText: { _, _, _, _ in writes += 1; inserted = true; return true },
                sendKey: { _, _, _ in returns += 1; return true },
                verifySubmission: { _, _, _ in completionChecks += 1; return completionChecks >= 3 },
                openExactBinding: { _ in .staleBinding }
            ), readinessWindow: .milliseconds(200), readinessInterval: .milliseconds(20))
            if scenario != "already-present" {
                try await adapter.sendText(request)
                try await adapter.sendReturn(binding: binding)
                try await adapter.verifySubmission(threadID: thread, binding: binding)
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(returns, 1)
                XCTAssertEqual(completionChecks, 0)
            } else {
                do { try await adapter.sendText(request); XCTFail("stale composer accepted") }
                catch {
                    XCTAssertEqual((error as? AppleAgentSendNotWritten)?.error, .terminalDraft)
                    XCTAssertEqual((error as? AppleAgentSendNotWritten)?.reason, "composer-occupied")
                }
                do { try await adapter.sendReturn(binding: binding); XCTFail("unverified Return accepted") }
                catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(returns, 0)
            }
        }
    }

    @MainActor
    func testSendWaitsOutAnUnsettledComposerThenWritesExactlyOnce() async throws {
        // A working Claude redraws its composer and tmux discards captures
        // whose cursor moved; neither may fail a send that is about to be ready.
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            for provider in [AgentProviderID.claude, .codex] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken("settle-test")!, transport: transport,
                    tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
                let thread = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "settle-test")!
                let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "ok close it?", queueWhenWorking: false)!
                let marker = provider == .claude ? "❯\u{00a0}" : "› "
                let footer = provider == .claude ? "────\nctx:6%  Fable 5.1" : "\ngpt-6-astra high · /repo"
                var inspections = 0, writes = 0
                var keys: [AppleAgentTerminalKey] = []
                let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                    inspect: { _ in
                        inspections += 1
                        // 1: capture discarded, 2: cursor hidden mid-redraw,
                        // 3: a blank capture as the endpoint builds it, then the
                        // settled empty composer.
                        if writes == 0 && inspections == 1 { throw AppleAgentInspectionUnavailable.capture }
                        let line = marker + (writes > 0 ? request.text : "")
                        let visible = line + "\n" + footer
                        if writes == 0 && inspections == 3 {
                            return .init(observation: .init(binding: binding, liveTail: "\n\n"), composerVisibleText: "\n\n", composerCursorVisible: true)
                        }
                        return .init(observation: .init(binding: binding, liveTail: visible), composerText: line, composerRow: 0,
                            composerColumn: 2, composerVisibleText: visible, composerCursorVisible: !(writes == 0 && inspections == 2))
                    }, sendText: { _, _, _, _ in writes += 1; return true },
                    sendKey: { key, _, _ in keys.append(key); return true },
                    verifySubmission: { _, _, _ in true },
                    openExactBinding: { _ in .staleBinding }
                ), readinessWindow: .seconds(2), readinessInterval: .milliseconds(10))
                try await adapter.sendText(request)
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(inspections, 4, "three unsettled frames, then one ready frame")
                try await adapter.sendReturn(binding: binding)
                try await adapter.verifySubmission(threadID: thread, binding: binding)
                XCTAssertEqual(writes, 1, "retries re-inspect; they never replay the text")
                XCTAssertEqual(keys, [.return])
            }
        }
    }

    @MainActor
    func testPersistentlyUnreadyComposerIsRefusedWithoutAnyWrite() async throws {
        for scenario in ["cursor-hidden", "capture-unavailable", "prompt-visible", "composer-occupied"] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("refuse-test")!, transport: .moshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "refuse-test")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false)!
            var inspections = 0, writes = 0
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    inspections += 1
                    if scenario == "capture-unavailable" { throw AppleAgentInspectionUnavailable.capture }
                    let line = scenario == "composer-occupied" ? "❯ typed in the terminal" : "❯ "
                    let visible = line + "\n────\nctx:6%  Fable 5.1"
                    let prompt = scenario == "prompt-visible"
                        ? AgentAuthoritativePrompt(signature: "sig", options: [], cursorOwned: true, visiblyBlocking: true) : nil
                    return .init(observation: .init(binding: binding, liveTail: visible, prompt: prompt), composerText: line,
                        composerRow: 0, composerColumn: 2, composerVisibleText: visible, composerCursorVisible: scenario != "cursor-hidden")
                }, sendText: { _, _, _, _ in writes += 1; return true },
                sendKey: { _, _, _ in true }, verifySubmission: { _, _, _ in true },
                openExactBinding: { _ in .staleBinding }
            ), readinessWindow: .milliseconds(300), readinessInterval: .milliseconds(50))
            let started = ContinuousClock.now
            do { try await adapter.sendText(request); XCTFail("\(scenario) was written") }
            catch {
                let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten, "\(scenario) must be reported as not written")
                XCTAssertEqual(refusal.reason, scenario == "capture-unavailable" ? "target-unproven" : scenario)
                if scenario == "capture-unavailable" { XCTAssertFalse(refusal.allowsSendAnyway) }
                XCTAssertEqual(refusal.error, scenario == "composer-occupied" ? .terminalDraft : .inputNotReady)
                XCTAssertEqual(refusal.attempts, inspections)
                XCTAssertGreaterThan(refusal.attempts, 1, "an unready surface is re-inspected before giving up")
                if let shape = refusal.shape { XCTAssertFalse(shape.contains("typed"), "diagnostics never carry cell text") }
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(2), "the window is bounded")
            XCTAssertEqual(writes, 0)
        }
    }

    func testBindingReplacedJustBeforeTheWriteIsReportedAsATerminalChange() async throws {
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("fence-test")!, transport: .moshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
        let replacement = AgentTerminalBinding(liveSessionID: binding.liveSessionID, carrierGeneration: 2,
            incarnation: AgentIncarnationToken("fence-test")!, transport: .moshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
        let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "fence-test")!
        let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false)!
        var writes = 0
        let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
            inspect: { _ in
                let visible = "❯ \n────\nctx:6%  Fable 5.1"
                return .init(observation: .init(binding: binding, liveTail: visible), composerText: "❯ ",
                    composerRow: 0, composerColumn: 2, composerVisibleText: visible, composerCursorVisible: true)
            }, sendText: { _, _, _, _ in writes += 1; return true },
            sendKey: { _, _, _ in true }, verifySubmission: { _, _, _ in true },
            openExactBinding: { _ in .staleBinding }
        ), readinessWindow: .milliseconds(300), readinessInterval: .milliseconds(50))
        do {
            try await adapter.sendText(request, beforeWrite: { await adapter.replaceBinding(replacement) })
            XCTFail("a send whose terminal was replaced was written")
        } catch {
            let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten, "refused before any byte, so not ambiguous")
            XCTAssertEqual(refusal.reason, "fence")
            XCTAssertEqual(refusal.error, .staleBinding, "a replaced terminal reads as changed, not as unable to take input")
        }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testSlowDispatchBookkeepingEarnsOneFreshComposerCheck() async throws {
        for slow in [false, true] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("dispatch-test")!, transport: .sshTmux,
                tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
            let thread = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "dispatch-test")!
            let request = AgentTextSendRequest(threadID: thread, binding: binding, text: "hello", queueWhenWorking: false)!
            var inspections = 0, writes = 0, typedInTerminal = false
            let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
                inspect: { _ in
                    inspections += 1
                    let line = typedInTerminal ? "❯ typed in the terminal" : "❯ "
                    let visible = line + "\n────\nctx:6%  Fable 5.1"
                    return .init(observation: .init(binding: binding, liveTail: visible), composerText: line,
                        composerRow: 0, composerColumn: 2, composerVisibleText: visible, composerCursorVisible: true)
                }, sendText: { _, _, _, _ in writes += 1; return true },
                sendKey: { _, _, _ in true }, verifySubmission: { _, _, _ in true },
                openExactBinding: { _ in .staleBinding }
            ), readinessWindow: .seconds(1), readinessInterval: .milliseconds(250))
            do {
                try await adapter.sendText(request, beforeWrite: {
                    guard slow else { return }
                    // A busy runtime actor (longer than one readiness interval);
                    // the user types in the terminal meanwhile.
                    try await Task.sleep(for: .milliseconds(400))
                    await MainActor.run { typedInTerminal = true }
                })
                XCTAssertFalse(slow, "a composer that changed during a slow dispatch was written")
                XCTAssertEqual(inspections, 1, "a prompt dispatch reuses the readiness proof")
                XCTAssertEqual(writes, 1)
            } catch {
                XCTAssertTrue(slow, "a prompt dispatch was refused: \(error)")
                let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten)
                XCTAssertEqual(refusal.reason, "composer-occupied")
                XCTAssertEqual(refusal.attempts, inspections - 1, "only the fresh check after dispatch refused")
                XCTAssertGreaterThan(refusal.attempts, 1, "one redraw frame after a slow dispatch is re-inspected")
                XCTAssertEqual(writes, 0)
            }
        }
    }

    @MainActor
    func testEndpointRefusesTextItCannotEncodeBeforeAnyWrite() async throws {
        // A binding without an agent process fails the route check; one with
        // it reaches the input policy.
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] { for agentPID: Int? in [42, nil] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-send-policy-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(runtime: AgentCenterRuntime(),
                metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            let tmux = transport == .sshTmux || transport == .moshTmux
            let hostID = UUID(), registrationID = UUID()
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("policy-fixture")!, transport: transport,
                tmuxSession: tmux ? "rig" : nil, windowID: tmux ? "1" : nil, paneID: tmux ? "2" : nil,
                agentPID: agentPID, capabilities: [.observe, .send])
            let threadID = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "policy-fixture")!
            let location = AgentLocation(sessionID: binding.liveSessionID, hostName: "fixture", transportLabel: transport.rawValue,
                tmuxSessionName: tmux ? "rig" : nil, windowID: tmux ? 1 : nil, windowName: tmux ? "rig" : nil,
                paneID: tmux ? 2 : nil)
            var writes = 0
            let source = AgentSessionSource(registrationID: registrationID, sessionID: binding.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in
                    AgentProbeTarget(location: location, processNames: ["codex"], processIDs: [42],
                        visibleText: "› \n\ngpt-5.4 default · /tmp", currentInputLine: "› ",
                        cursorRow: 0, cursorColumn: 2, cursorVisible: true, bracketedPasteEnabled: true)
                }, send: { _, _ in writes += 1; return true }, sendKey: { _, _ in true }, jump: { _ in },
                validatedRemoteDirectories: { _ in [] }, supportsTmuxLaunch: { tmux }, launchAgent: { _ in throw AgentActionError.unavailable })
            let session = AppleAgentSessionRoute(hostID: hostID, hostDisplayLabel: "fixture", source: source,
                profiles: { [.builtInCodexCLI] }, carrierGeneration: 1)
            let thread = AppleAgentThreadRoute(registrationID: registrationID, location: location,
                profile: .builtInCodexCLI, binding: binding, sourceIdentity: "fixture")
            coordinator.sessionRoutes[binding.liveSessionID] = session
            coordinator.threadRoutes[threadID] = thread
            let adapter = coordinator.makeTerminalAdapter(threadID: threadID, session: session, thread: thread)
            // Codex takes an image path as one paste event, capped at 1,000 scalars.
            let longImage = "\"/tmp/" + String(repeating: "a", count: 1_100) + ".png\""
            let request = AgentTextSendRequest(threadID: threadID, binding: binding, text: longImage, queueWhenWorking: false)!
            do { try await adapter.sendText(request); XCTFail("\(transport.rawValue): unencodable text was written") }
            catch {
                let refusal = try XCTUnwrap(error as? AppleAgentSendNotWritten, "\(transport.rawValue): refused before any byte, so not ambiguous")
                XCTAssertEqual(refusal.reason, agentPID == nil ? "route" : "input-policy", transport.rawValue)
                XCTAssertEqual(refusal.error, agentPID == nil ? .staleBinding : .unavailable, transport.rawValue)
            }
            XCTAssertEqual(writes, 0)
            await coordinator.setExperimentEnabled(false)
        } }
    }

    /// A source that refuses before its first byte (tmux left control mode)
    /// is not an unacknowledged write; open re-captures past a raced frame.
    @MainActor
    func testEndpointReportsTransportRefusalsAndRetriesOpenCaptures() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-send-transport-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(runtime: AgentCenterRuntime(),
                metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            let tmux = transport == .sshTmux || transport == .moshTmux
            let hostID = UUID(), registrationID = UUID()
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("transport-fixture")!, transport: transport,
                tmuxSession: tmux ? "rig" : nil, windowID: tmux ? "1" : nil, paneID: tmux ? "2" : nil,
                agentPID: 42, capabilities: [.observe, .send])
            let threadID = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "transport-fixture")!
            let location = AgentLocation(sessionID: binding.liveSessionID, hostName: "fixture", transportLabel: transport.rawValue,
                tmuxSessionName: tmux ? "rig" : nil, windowID: tmux ? 1 : nil, windowName: tmux ? "rig" : nil,
                paneID: tmux ? 2 : nil)
            var writes = 0, captures = 0, jumps = 0
            var unsettled: Set<Int> = []
            var mismatchedSecondInspection = false
            var refusal: String? = tmux ? "not-in-tmux" : transport == .mosh ? "empty" : "tmux-location-mismatch"
            let source = AgentSessionSource(registrationID: registrationID, sessionID: binding.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in
                    captures += 1
                    if unsettled.contains(captures) { return nil }
                    return AgentProbeTarget(location: location, processNames: ["codex"],
                        processIDs: mismatchedSecondInspection && captures > 1 ? [77] : [42],
                        visibleText: "› \n\ngpt-5.4 default · /tmp", currentInputLine: "› ",
                        cursorRow: 0, cursorColumn: 2, cursorVisible: true, bracketedPasteEnabled: true)
                }, send: { _, _ in writes += 1; return refusal == nil }, sendRefusal: { _, _ in refusal },
                sendKey: { _, _ in true }, jump: { _ in jumps += 1 },
                validatedRemoteDirectories: { _ in [] }, supportsTmuxLaunch: { tmux }, launchAgent: { _ in throw AgentActionError.unavailable })
            let session = AppleAgentSessionRoute(hostID: hostID, hostDisplayLabel: "fixture", source: source,
                profiles: { [.builtInCodexCLI] }, carrierGeneration: 1)
            let thread = AppleAgentThreadRoute(registrationID: registrationID, location: location,
                profile: .builtInCodexCLI, binding: binding, sourceIdentity: "fixture")
            coordinator.sessionRoutes[binding.liveSessionID] = session
            coordinator.threadRoutes[threadID] = thread
            let adapter = coordinator.makeTerminalAdapter(threadID: threadID, session: session, thread: thread)
            let request = AgentTextSendRequest(threadID: threadID, binding: binding, text: "hello", queueWhenWorking: false)!
            do { try await adapter.sendText(request); XCTFail("\(transport.rawValue): a refused transport reported a write") }
            catch {
                let notWritten = try XCTUnwrap(error as? AppleAgentSendNotWritten, "\(transport.rawValue): refused before any byte, so not ambiguous")
                XCTAssertEqual(notWritten.reason, "transport-\(refusal!)", transport.rawValue)
                XCTAssertEqual(notWritten.error, refusal == "empty" ? .unavailable : .staleBinding, transport.rawValue)
            }
            XCTAssertEqual(writes, 0, transport.rawValue)
            // Open: the adapter's own capture (1) settles, then the
            // endpoint's re-capture races a redraw twice (2, 3) before it
            // settles.
            captures = 0
            unsettled = [2, 3]
            do { try await adapter.openTerminal(binding: binding) }
            catch { XCTFail("\(transport.rawValue): open refused a pane whose capture only raced a redraw: \(error)") }
            XCTAssertEqual(jumps, 1, "\(transport.rawValue): a raced capture must not read as a changed pane")
            XCTAssertEqual(captures, 4, transport.rawValue)
            captures = 0
            unsettled = [2, 3, 4]
            do { try await adapter.openTerminal(binding: binding); XCTFail("an unavailable second inspection opened the pane") }
            catch { XCTAssertEqual(error as? AgentActionError, .inputNotReady, transport.rawValue) }
            XCTAssertEqual(captures, 4, transport.rawValue)
            XCTAssertEqual(jumps, 1, transport.rawValue)
            captures = 0
            unsettled = []
            mismatchedSecondInspection = true
            do { try await adapter.openTerminal(binding: binding); XCTFail("a mismatched second inspection opened the pane") }
            catch { XCTAssertEqual(error as? AgentActionError, .staleBinding, transport.rawValue) }
            XCTAssertEqual(captures, 2, transport.rawValue)
            XCTAssertEqual(jumps, 1, transport.rawValue)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testBridgeWithdrawsTheBubbleOfASendRefusedBeforeItsFirstByte() async throws {
        let core = AgentCenterRuntime()
        let bridge = AppleAgentCenterRuntimeBridge(runtime: core, titleGenerator: nil)
        let thread = makeThreadID()
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("withdraw")!, transport: .moshTmux,
            tmuxSession: "rig", windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send])
        await core.register(.init(id: thread, providerName: "Claude", availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding)
        var hidden = true
        var writes = 0
        var notSent: [AgentActionError] = []
        let adapter = AppleAgentTerminalAdapter(binding: binding, operations: .init(
            inspect: { _ in
                let line = "❯ " + (writes > 0 ? "second try" : "")
                return .init(observation: .init(binding: binding, liveTail: line + "\n────\nctx:6%  Fable 5.1"), composerText: line,
                    composerRow: 0, composerCursorVisible: !hidden)
            }, sendText: { _, _, _, _ in writes += 1; return true }, sendKey: { _, _, _ in true },
            verifySubmission: { _, _, _ in true },
            openExactBinding: { _ in .staleBinding }
        ), readinessWindow: .milliseconds(200), readinessInterval: .milliseconds(20))
        let arm: (AgentActionLease) async throws -> Void = { lease in
            try await core.armOutgoing(lease, freshPage: AgentProjectionPage(sourceIdentity: "1:2:0:1", records: [], cursor: nil, hasMore: false)!)
        }
        let first = AgentTextSendRequest(threadID: thread, binding: binding, text: "first try", queueWhenWorking: false)!
        let refused = await bridge.submit(first, terminal: adapter, prepareReceipt: arm, onNotSent: { notSent.append($0.error) })
        guard case .failure(.inputNotReady) = refused else { return XCTFail("expected a not-ready refusal, got \(refused)") }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(notSent, [.inputNotReady])
        XCTAssertEqual(bridge.threadSnapshots[thread]?.outgoingMessages ?? [], [], "no receipt-unconfirmed bubble for an unsent message")
        // The lease is free again and the next send goes through normally.
        hidden = false
        let second = AgentTextSendRequest(threadID: thread, binding: binding, text: "second try", queueWhenWorking: false)!
        let accepted = await bridge.submit(second, terminal: adapter, prepareReceipt: arm, onNotSent: { notSent.append($0.error) })
        if case .failure(let error) = accepted { XCTFail("retry failed: \(error)") }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(notSent, [.inputNotReady])
        XCTAssertEqual(bridge.threadSnapshots[thread]?.outgoingMessages?.map(\.status), [.awaitingReceipt])
    }

    @MainActor
    func testPresentationReturnsANotSentMessageWithoutLosingNewerText() {
        let model = AgentCenterV2PresentationModel()
        let thread = makeThreadID()
        XCTAssertEqual(model.returnUnsentText("first", for: thread), .restored)
        XCTAssertEqual(model.draftBinding(for: thread), "first")
        model.reportNotSent(.inputNotReady, reason: "cursor-hidden", providerName: "Claude", draft: .restored)
        XCTAssertEqual(model.capabilityNotice, "Not sent — Claude's input wasn't ready. Nothing was typed; your message is back in the box.")
        // The box already holds exactly the message: nothing is duplicated.
        XCTAssertEqual(model.returnUnsentText("first", for: thread), .restored)
        XCTAssertEqual(model.draftBinding(for: thread), "first")

        // Typed (or an attachment path appended) during the readiness wait.
        // A substring is not the message: "ok" inside newer text still returns.
        model.setDraft("looking good", for: thread)
        XCTAssertEqual(model.returnUnsentText("ok", for: thread), .merged)
        XCTAssertEqual(model.draftBinding(for: thread), "ok\n\nlooking good", "the unsent message returns above the newer text")
        model.reportNotSent(.terminalDraft, reason: "composer-occupied", providerName: nil, draft: .merged)
        XCTAssertEqual(model.capabilityNotice, "Not sent — the terminal already has unsent text in the agent's prompt. Nothing was typed; your message is back in the box above what you typed since.")

        // Whitespace alone is not a draft worth keeping.
        model.setDraft("  \n", for: thread)
        XCTAssertEqual(model.returnUnsentText("second", for: thread), .restored)
        XCTAssertEqual(model.draftBinding(for: thread), "second")

        // The send never cleared the box: typing that continued keeps the
        // message at its start, so nothing is duplicated; a box emptied or
        // replaced since still gets the message back.
        model.setDraft("second and more", for: thread)
        XCTAssertEqual(model.returnUnsentText("second", for: thread, boxWasCleared: false), .restored)
        XCTAssertEqual(model.draftBinding(for: thread), "second and more")
        model.setDraft("", for: thread)
        XCTAssertEqual(model.returnUnsentText("second", for: thread, boxWasCleared: false), .restored)
        XCTAssertEqual(model.draftBinding(for: thread), "second")
        model.setDraft("something else", for: thread)
        XCTAssertEqual(model.returnUnsentText("second", for: thread, boxWasCleared: false), .merged)
        XCTAssertEqual(model.draftBinding(for: thread), "second\n\nsomething else")

        // Wording shared with Android's agentNotSentNotice.
        model.reportNotSent(.unavailable, reason: "input-policy", providerName: "Codex", draft: .restored)
        XCTAssertEqual(model.capabilityNotice, "Not sent — this message can't be typed into Codex's prompt from here. Nothing was typed; your message is back in the box.")
        model.reportNotSent(.verificationFailed, reason: "receipt", providerName: "Claude", draft: .restored)
        XCTAssertEqual(model.capabilityNotice, "Not sent — delivery tracking couldn't start. Nothing was typed; your message is back in the box.")
        model.reportNotSent(.cancelled, reason: "receipt", providerName: "Claude", draft: .restored)
        XCTAssertEqual(model.capabilityNotice, "Not sent — the send was cancelled. Nothing was typed; your message is back in the box.")
        model.reportNotSent(.staleBinding, reason: "route", providerName: "Claude", draft: .restored)
        XCTAssertEqual(model.capabilityNotice, "Not sent — the terminal changed. Nothing was typed; your message is back in the box.")
    }

    func testContentFreeNotificationCarriesOnlyOpaqueRouteData() {
        let event = AgentAttentionEvent(
            threadID: makeThreadID(),
            routeToken: AgentRouteToken(rawValue: UUID(uuidString: "A11CE000-0000-4000-8000-000000000010")!),
            attention: .needsYou,
            deliveryGeneration: 7
        )

        let content = AppleAgentNotificationPolicy.content(for: event, presentation: .init())

        XCTAssertEqual(content.title, "agent needs input")
        XCTAssertEqual(content.body, "Open Tessera to continue.")
        XCTAssertEqual(content.userInfo[AppleAgentNotificationPolicy.kindKey], AppleAgentNotificationPolicy.kind)
        XCTAssertEqual(content.userInfo[AppleAgentNotificationPolicy.routeTokenKey], event.routeToken.rawValue.uuidString)
        XCTAssertNil(content.userInfo["transcript"])
        XCTAssertFalse(content.userInfo.values.joined().contains(event.threadID.providerSessionID))
        let payload = content.userInfo.reduce(into: [AnyHashable: Any]()) { values, pair in
            values[AnyHashable(pair.key)] = pair.value
        }
        let route = AppleAgentNotificationPolicy.route(from: payload)
        XCTAssertEqual(route?.token, event.routeToken)
        XCTAssertEqual(route?.generation, event.deliveryGeneration)
    }

    func testBoundedPreviewStripsControlsBidiAndCapsLength() {
        let preview = AppleAgentNotificationPolicy.boundedPreview(
            "one\n\u{202E}two\u{0000} three four five",
            maximumCharacters: 12
        )

        XCTAssertEqual(preview, "one two thr…")
        XCTAssertLessThanOrEqual(preview.count, 12)
        XCTAssertFalse(preview.unicodeScalars.contains { $0.value < 0x20 })
        XCTAssertFalse(preview.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
    }

    func testRouteParserRejectsLegacyAndRawThreadPayloads() {
        XCTAssertNil(AppleAgentNotificationPolicy.route(from: [
            "tessera.kind": "agent-needs-input",
            "tessera.session-id": UUID().uuidString,
        ]))
        XCTAssertNil(AppleAgentNotificationPolicy.route(from: [
            AppleAgentNotificationPolicy.kindKey: AppleAgentNotificationPolicy.kind,
            AppleAgentNotificationPolicy.routeTokenKey: "not-a-uuid",
        ]))
        XCTAssertNil(AppleAgentNotificationPolicy.route(from: [
            AppleAgentNotificationPolicy.kindKey: AppleAgentNotificationPolicy.kind,
            AppleAgentNotificationPolicy.routeTokenKey: UUID().uuidString,
        ]))
    }

    @MainActor
    func testColdStartInboxRetainsOnlyBoundedOpaqueRoutes() {
        let inbox = AppleAgentNotificationInbox.shared
        _ = inbox.consumeAll()
        let token = AgentRouteToken(rawValue: UUID())
        inbox.enqueue(.init(token: token, generation: 1))
        inbox.enqueue(.init(token: token, generation: 2))
        for generation in 3...12 {
            inbox.enqueue(.init(token: AgentRouteToken(rawValue: UUID()), generation: UInt64(generation)))
        }

        let routes = inbox.consumeAll()

        XCTAssertEqual(routes.count, 8)
        XCTAssertFalse(routes.contains { $0.token == token && $0.generation == 1 })
        XCTAssertTrue(routes.allSatisfy { $0.token.rawValue.uuidString.count == 36 })
    }

    func testMetadataSchemaRejectsTranscriptLikeFieldsAndRoundTripsOnlyAllowedFields() throws {
        let threadID = makeThreadID()
        let record = AppleAgentThreadMetadataRecord(
            threadID: threadID,
            lastReadRecordID: "record-9",
            routeToken: UUID(),
            pinnedTitle: "my review",
            lineage: .init(parentThreadID: makeThreadID(session: "parent"))
        )
        let data = try JSONEncoder().encode(AppleAgentMetadataRepository.Document(records: [record]))

        XCTAssertTrue(AppleAgentMetadataPersistencePolicy.allows(record))
        XCTAssertTrue(AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(data))
        XCTAssertFalse(AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(Data(#"{"transcriptPath":"/private/session.jsonl"}"#.utf8)))
    }

    func testMetadataRepositoryKeepsLineageAcrossReadAndRouteUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleAgentServicesTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("metadata.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AppleAgentMetadataRepository(fileURL: fileURL)
        let threadID = makeThreadID()
        let lineage = AgentThreadLineage(parentThreadID: makeThreadID(session: "parent"))

        try await repository.saveLineage(lineage, for: threadID)
        let routeToken = try await repository.routeToken(for: threadID)
        try await repository.save(.init(threadID: threadID, lastReadRecordID: "record-22", routeToken: routeToken.rawValue, pinnedTitle: "Pinned title"))

        let storedLineage = await repository.lineage(for: threadID)
        let resolvedThread = await repository.resolve(routeToken)
        XCTAssertEqual(storedLineage, lineage)
        XCTAssertEqual(resolvedThread, threadID)
        let metadata = await repository.metadata(for: threadID)
        XCTAssertEqual(metadata?.lastReadRecordID, "record-22")
        XCTAssertEqual(metadata?.pinnedTitle, "Pinned title")
        let stored = try Data(contentsOf: fileURL)
        XCTAssertTrue(AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(stored))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // CoreSimulator accepts the protection attribute but its host-backed
        // temporary filesystem does not consistently report it back.
        XCTAssertTrue(protection == nil || protection == .completeUntilFirstUserAuthentication)
        #else
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        #endif
    }

    func testMetadataPersistsOnlyContentFreeViewStateAndNotificationFence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleAgentViewMetadataTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("metadata.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AppleAgentMetadataRepository(fileURL: fileURL)
        let threadID = makeThreadID()

        try await repository.saveNotificationGeneration(42, for: threadID)
        try await repository.saveViewMetadata(.init(
            grouping: .host,
            providerIDs: [.claude],
            lastSelectedThreadID: threadID,
            showSystemEvents: true
        ))

        let generation = await repository.notificationGeneration(for: threadID)
        let view = await repository.viewMetadata()
        XCTAssertEqual(generation, 42)
        XCTAssertEqual(view, .init(
            grouping: .host,
            providerIDs: [.claude],
            lastSelectedThreadID: threadID,
            showSystemEvents: true
        ))
        let stored = try Data(contentsOf: fileURL)
        XCTAssertTrue(AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(stored))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).localizedCaseInsensitiveContains("query"))
    }

    func testMetadataCompletionKeysSurviveOtherSavesAndLegacyDocumentsDecode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleAgentCompletionMetadataTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("metadata.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AppleAgentMetadataRepository(fileURL: fileURL)
        let threadID = makeThreadID()

        try await repository.saveCompletion(unread: "c1:18d2c0189ee74548:2a", acknowledged: nil, for: threadID)
        try await repository.saveNotificationGeneration(3, for: threadID)
        _ = try await repository.routeToken(for: threadID)
        try await repository.saveLineage(.init(parentThreadID: makeThreadID(session: "parent")), for: threadID)
        // A read-modify-write of metadata loaded before the completion moved.
        try await repository.save(.init(threadID: threadID, lastReadRecordID: "record-1"))
        var metadata = await repository.metadata(for: threadID)
        XCTAssertEqual(metadata?.unreadCompletionKey, "c1:18d2c0189ee74548:2a")
        XCTAssertNil(metadata?.acknowledgedCompletionKey)
        XCTAssertEqual(metadata?.lastReadRecordID, "record-1")

        try await repository.saveCompletion(unread: nil, acknowledged: "c1:18d2c0189ee74548:2a", for: threadID)
        metadata = await repository.metadata(for: threadID)
        XCTAssertNil(metadata?.unreadCompletionKey)
        XCTAssertEqual(metadata?.acknowledgedCompletionKey, "c1:18d2c0189ee74548:2a")
        let stored = try Data(contentsOf: fileURL)
        XCTAssertTrue(AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(stored))
        let document = try JSONDecoder().decode(AppleAgentMetadataRepository.Document.self, from: stored)
        XCTAssertEqual(document.schemaVersion, 3, "additive optional fields need no schema bump")

        // A document written before the fields existed decodes with none.
        let legacy = AppleAgentThreadMetadataRecord(threadID: threadID, lastReadRecordID: "record-1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(object["unreadCompletionKey"])
        object.removeValue(forKey: "acknowledgedCompletionKey")
        let decoded = try JSONDecoder().decode(AppleAgentThreadMetadataRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, legacy)
    }

    func testViewMetadataDefaultsSystemEventVisibilityForLegacyDocuments() throws {
        let legacyView = #"{"grouping":"attention","providerIDs":[],"lastSelectedThreadID":null}"#

        let view = try JSONDecoder().decode(AppleAgentViewMetadata.self, from: Data(legacyView.utf8))

        XCTAssertFalse(view.showSystemEvents)
    }

    func testViewMetadataRetiredProjectGroupingFallsBackToAttention() throws {
        let threadID = makeThreadID()
        let saved = AppleAgentViewMetadata(grouping: .host, providerIDs: [.claude], lastSelectedThreadID: threadID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["grouping"] = "project"

        let view = try JSONDecoder().decode(AppleAgentViewMetadata.self,
            from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(view.grouping, .attention)
        XCTAssertEqual(view.providerIDs, [.claude])
        XCTAssertEqual(view.lastSelectedThreadID, threadID)
    }

    func testProjectorDecoderFramesSplitNDJSONAndPreservesBounds() async throws {
        let binding = makeBinding()
        let output = """
        {"v":1,"kind":"page","sourceIdentity":"dev:inode","from":null,"to":null}
        {"v":1,"kind":"record","sequence":1,"recordID":"r1","record":{"type":"assistant","text":"hello"}}
        {"v":1,"kind":"end","cursor":"cursor-1","hasMore":false,"warnings":[]}

        """.data(using: .utf8)!
        let split = output.count / 2
        let stream = AppleAgentTestExecStream(frames: [
            AgentExecFrame(carrierGeneration: 4, kind: .stdout(output.prefix(split)))!,
            AgentExecFrame(carrierGeneration: 4, kind: .stdout(output.suffix(from: split)))!,
            AgentExecFrame(carrierGeneration: 4, kind: .exit(status: 0))!,
        ])
        let endpoint = AppleAgentProjectionEndpoint.projector(
            exec: AppleAgentTestExecPort(stream: stream)
        )
        let request = AgentProjectionRequest(
            kind: .project,
            providerID: .claude,
            transcriptRef: "b3BhcXVl"
        )!

        let pages = try await endpoint.project(request, binding)
        var collected: [AgentProjectionPage] = []
        for try await page in pages { collected.append(page) }

        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected.first?.sourceIdentity, "dev:inode")
        XCTAssertEqual(collected.first?.records.first?.recordID, "r1")
        XCTAssertEqual(collected.first?.cursor, "cursor-1")
    }

    func testProjectorDecoderRejectsIncompleteAndDuplicateTerminalFrames() async throws {
        let binding = makeBinding()
        let request = AgentProjectionRequest(
            kind: .project,
            providerID: .claude,
            transcriptRef: "b3BhcXVl"
        )!
        for output in [
            """
            {"v":1,"kind":"page","sourceIdentity":"dev:inode","from":null,"to":null}
            {"v":1,"kind":"record","sequence":1,"recordID":"r1","record":{"type":"assistant"}}
            """,
            """
            {"v":1,"kind":"page","sourceIdentity":"dev:inode","from":null,"to":null}
            {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}
            {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}
            """,
        ] {
            let data = Data((output + "\n").utf8)
            let stream = AppleAgentTestExecStream(frames: [
                AgentExecFrame(carrierGeneration: 4, kind: .stdout(data))!,
                AgentExecFrame(carrierGeneration: 4, kind: .exit(status: 0))!,
            ])
            let endpoint = AppleAgentProjectionEndpoint.projector(
                exec: AppleAgentTestExecPort(stream: stream)
            )
            do {
                _ = try await endpoint.project(request, binding)
                XCTFail("Incomplete or duplicate terminal frames must fail closed")
            } catch let error as AppleAgentPlatformError {
                XCTAssertEqual(error, .malformedStreamFrame)
            }
        }
    }

    func testProjectorDecoderRejectsInventoryForDifferentProvider() async throws {
        let binding = makeBinding()
        let output = """
        {"v":1,"kind":"inventory","sequence":1,"provider":"pi","providerSessionID":"session-1","transcriptRef":"b3BhcXVl","lastActivityNs":1,"size":1}
        {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}

        """.data(using: .utf8)!
        let stream = AppleAgentTestExecStream(frames: [
            AgentExecFrame(carrierGeneration: 4, kind: .stdout(output))!,
            AgentExecFrame(carrierGeneration: 4, kind: .exit(status: 0))!,
        ])
        let endpoint = AppleAgentProjectionEndpoint.projector(
            exec: AppleAgentTestExecPort(stream: stream)
        )
        let request = AgentProjectionRequest(kind: .inventory, providerID: .opencode)!

        do {
            _ = try await endpoint.inventory(request, binding)
            XCTFail("Inventory frames must be bound to the requested provider")
        } catch let error as AppleAgentPlatformError {
            XCTAssertEqual(error, .malformedStreamFrame)
        }
    }

    @MainActor
    func testTmuxCurrentDirectoryRequiresExactBindingAndSafePath() {
        XCTAssertEqual(
            AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
                "@12\t%34\t/Users/agent/work/tessera",
                expectedWindowID: "12",
                expectedPaneID: "34"
            ),
            "/Users/agent/work/tessera"
        )
        XCTAssertEqual(
            AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
                "@12\t%34\t~/work/tessera",
                expectedWindowID: "@12",
                expectedPaneID: "%34"
            ),
            "~/work/tessera"
        )
        XCTAssertNil(AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
            "@12\t%35\t/Users/agent/work/tessera",
            expectedWindowID: "12",
            expectedPaneID: "34"
        ))
        XCTAssertNil(AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
            "@12\t%34\trelative/path",
            expectedWindowID: "12",
            expectedPaneID: "34"
        ))
        XCTAssertNil(AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
            "@12\t%34\t/Users/agent/../secret",
            expectedWindowID: "12",
            expectedPaneID: "34"
        ))
        XCTAssertNil(AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
            "@12\t%34\t/Users/agent\u{0007}",
            expectedWindowID: "12",
            expectedPaneID: "34"
        ))
        XCTAssertNil(AgentSessionSourceFactory.validatedTmuxCurrentDirectory(
            "@12\t%34\t/" + String(repeating: "a", count: 2_048),
            expectedWindowID: "12",
            expectedPaneID: "34"
        ))
    }

    private func makeThreadID(session: String = "thread") -> AgentThreadID {
        AgentThreadID(
            hostID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!,
            providerID: .claude,
            providerSessionID: session
        )!
    }

    func testHelloWindowCapacityGrowsOnlyForAWellFormedAdvertisement() {
        func segments(_ capabilities: [String], _ advertised: AgentJSONValue?) -> Int {
            var hello: [String: AgentJSONValue] = ["capabilities": .array(capabilities.map(AgentJSONValue.string))]
            hello["maxWindowSegments"] = advertised
            return AppleAgentIngestionConnection.helloMaxWindowSegments(hello)
        }
        let capacity = ["bounded.windows", "window.partitions", "window.capacity.v1"]
        XCTAssertEqual(segments(capacity, .number(64)), 64)
        XCTAssertEqual(segments(capacity, .number(32)), 32)
        XCTAssertEqual(segments(capacity, .number(4_096)), 64)
        XCTAssertEqual(segments(capacity, .number(Decimal(string: "1e30")!)), 64)
        XCTAssertEqual(segments(capacity, .number(1)), 4)
        XCTAssertEqual(segments(capacity, .number(-8)), 4)
        XCTAssertEqual(segments(capacity, .number(Decimal(string: "63.5")!)), 4, "a fraction reads as legacy")
        XCTAssertEqual(segments(capacity, .string("64")), 4)
        XCTAssertEqual(segments(capacity, nil), 4)
        XCTAssertEqual(segments(Array(capacity.dropLast()), .number(64)), 4, "no capability, no growth")
    }

    @MainActor
    func testReadProgressRenewsOnlyItsReadIdleDeadlineAcrossAllTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("progress")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle(readProgress: true, holdSummaries: true)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
            var statuses = 0
            connection.onReadStatus = { thread, status in
                XCTAssertEqual(thread, "thread"); XCTAssertTrue(status.isProgress); statuses += 1
            }
            let request = Task { try await connection.request(["kind": .string("summary"), "thread": .string("thread")], deadline: .milliseconds(400)) }
            for _ in 0..<200 {
                if await handle.summaryRequestID != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let sentRequest = await handle.lastRequest("summary")
            let sent = try XCTUnwrap(sentRequest)
            XCTAssertEqual(sent["readProgress"], .bool(true))
            for index in 1...3 {
                try await Task.sleep(for: .milliseconds(200))
                try await handle.readProgress(id: sent["id"]!, sequence: String(UInt64.max - UInt64(3 - index)), bytes: String(UInt64.max - UInt64(3 - index)))
                for _ in 0..<200 {
                    if statuses >= index { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertEqual(statuses, index)
            }
            try await handle.replyHeldSummary()
            _ = try await request.value
            XCTAssertEqual(statuses, 3)
            XCTAssertFalse(connection.isClosed)
            await connection.close()
        }
    }

    @MainActor
    func testDuplicateForeignAndControlProgressCannotRenewDeadline() async throws {
        for scenario in ["duplicate", "sameBytes", "sameSequence", "foreignThread", "foreignID", "heartbeat", "legacy", "cancelled"] {
            let handle = try AppleWindowTestHandle(readProgress: scenario != "legacy", holdSummaries: true,
                heldRequestKinds: scenario == "heartbeat" ? ["heartbeat"] : [])
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            let kind = scenario == "heartbeat" ? "heartbeat" : "summary"
            var statuses = 0
            connection.onReadStatus = { _, _ in statuses += 1 }
            let request = Task { try await connection.request(["kind": .string(kind), "thread": .string("thread")], deadline: .milliseconds(200)) }
            for _ in 0..<200 {
                if await handle.lastRequest(kind) != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let sentRequest = await handle.lastRequest(kind)
            let sent = try XCTUnwrap(sentRequest)
            if scenario == "cancelled" {
                request.cancel(); _ = await request.result
                try await handle.readProgress(id: sent["id"]!, sequence: "1", bytes: "100")
                try await handle.replyHeldSummary()
                _ = try await connection.request(["kind": .string("heartbeat")])
                XCTAssertEqual(statuses, 0); XCTAssertFalse(connection.isClosed)
                await connection.close()
                continue
            }
            if scenario == "legacy" {
                XCTAssertNil(sent["readProgress"])
            } else {
                for index in 1...4 {
                    try await Task.sleep(for: .milliseconds(80))
                    try await handle.readProgress(id: scenario == "foreignID" ? .string("other_request") : sent["id"]!,
                        thread: scenario == "foreignThread" ? "otherThread" : "thread",
                        sequence: scenario == "sameBytes" ? String(index) : "1",
                        bytes: scenario == "sameSequence" ? String(index * 100) : "100")
                    if ["duplicate", "sameBytes", "sameSequence"].contains(scenario) && index == 1 {
                        for _ in 0..<200 {
                            if statuses > 0 { break }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
            }
            do { _ = try await request.value; XCTFail("unrelated or replayed progress kept \(scenario) alive") }
            catch { XCTAssertEqual(error as? AgentIngestionError, .remote("deadlineExceeded")) }
            XCTAssertEqual(statuses, ["duplicate", "sameBytes", "sameSequence"].contains(scenario) ? 1 : 0)
            XCTAssertFalse(connection.isClosed)
            await connection.close()
        }
    }

    @MainActor
    func testHostReadStatusNeverUsesLocalRetentionCapacityCallback() async throws {
        let handle = try AppleWindowTestHandle()
        let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
        var codes: [String] = []
        var resets = 0
        connection.onCapacity = { _ in XCTFail("host failure is not local retained-memory pressure") }
        connection.onReadStatus = { _, status in codes.append(status.code) }
        connection.onResync = { _ in resets += 1 }
        try await handle.inject(["kind": .string("resyncRequired"), "thread": .string("thread"),
            "reason": .string("capacityExceeded"), "status": .object(["v": .number(1), "state": .string("resourceLimited"),
                "domain": .string("host"), "recovery": .string("manual"), "code": .string("codexIndexCapacity")])])
        try await handle.inject(["kind": .string("resyncRequired"), "thread": .string("thread"), "reason": .string("capacityExceeded")])
        _ = try await connection.request(["kind": .string("heartbeat")])
        XCTAssertEqual(codes, ["codexIndexCapacity"]); XCTAssertEqual(resets, 1)
        await connection.close()
    }

    @MainActor
    func testInventoryWireRowLimitDoesNotRaiseReceiveByteBudget() async throws {
        for (rows, padding, accepted) in [(500, 0, true), (501, 0, false), (500, 1000, false)] {
            let handle = try AppleWindowTestHandle(inventoryRows: rows, inventoryPadding: padding)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            do {
                let reply = try await connection.request(["kind": .string("inventory"), "limit": .number(500)])
                XCTAssertTrue(accepted, "row or byte overflow accepted")
                XCTAssertEqual(reply.inventory.count, rows)
            } catch { XCTAssertFalse(accepted, "valid bounded inventory rejected: \(type(of: error))") }
            await connection.close()
        }
        for (begins, endKind) in [(0, "inventory.end"), (2, "inventory.end"), (1, "inventory.unknown"), (1, "page.end")] {
            let handle = try AppleWindowTestHandle(inventoryRows: 2, inventoryBegins: begins, inventoryEndKind: endKind)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            do {
                _ = try await connection.request(["kind": .string("inventory"), "limit": .number(500)])
                XCTFail("malformed inventory transaction accepted")
            } catch { }
            await connection.close()
        }
    }

    @MainActor
    func testExplicitNativeSummaryCompletesAndUpdatesMetadataAcrossAllTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("summary-test")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle()
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
            var titles: [String] = []
            connection.onSummary = { thread, summary in
                XCTAssertEqual(thread, "thread")
                titles.append(summary.records[0].objectValue?["title"]?.stringValue ?? "")
                return true
            }
            let reply = try await AppleAgentIngestionConnection.withSearchDeadline(.seconds(2)) {
                try await connection.request(["kind": .string("summary"), "thread": .string("thread")])
            }
            XCTAssertEqual(reply.object["kind"]?.stringValue, "summary")
            XCTAssertEqual(titles, ["External Codex title"])
            XCTAssertFalse(connection.isClosed)
            await connection.close()
        }
    }

    @MainActor
    func testCancelledSummaryReplyIsDiscardedWithoutClosingSiblingRequests() async throws {
        let handle = try AppleWindowTestHandle(holdSummaries: true)
        let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
        connection.onSummary = { _, _ in XCTFail("cancelled metadata was applied"); return true }
        for _ in 0..<130 {
            let request = Task { try await connection.request(["kind": .string("summary"), "thread": .string("thread")]) }
            while await handle.summaryRequestID == nil { await Task.yield() }
            request.cancel(); _ = await request.result
            try await handle.replyHeldSummary()
            _ = try await connection.request(["kind": .string("heartbeat")])
            XCTAssertFalse(connection.isClosed)
        }
        await connection.close()
    }

    @MainActor
    func testUnselectedVisibleCardResyncRenewsSummaryInterestWithoutTerminalOutputAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-card-resync-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            coordinator.setSurfaceDemand(true)
            let carrier = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("card-resync")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle()
            let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { carrier })
            let hostID = UUID()
            coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
                source: source, profiles: { [] }, carrierGeneration: 4)
            let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "quiet-card")!
            let (host, connection) = try await coordinator.nativeHost(source: source)
            host.threads[thread] = "thread"
            coordinator.ingestionVisibleCards.insert(thread)
            XCTAssertNil(coordinator.presentation.selectedThreadID)
            coordinator.scheduleNativeInterests()
            await host.interestTask?.value
            let initialInterests = await handle.subscribeInterests
            XCTAssertEqual(initialInterests, ["slow"])
            try await handle.inject(["kind": .string("resyncRequired"), "thread": .string("thread"),
                "reason": .string("sourceChanged")])
            // No output packet, selection change, or explicit scheduler call:
            // the resync callback itself must restore this visible card.
            for _ in 0..<200 {
                if await handle.subscribeInterests.count == 2, host.interests[thread] == false { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let restoredInterests = await handle.subscribeInterests
            XCTAssertEqual(restoredInterests, ["slow", "slow"], "unselected card lost updates after resync on \(transport)")
            XCTAssertEqual(host.interests[thread], false)
            let startedTranscript = await handle.didRead
            XCTAssertFalse(startedTranscript, "summary-only card resync must not bootstrap an unopened transcript")
            XCTAssertFalse(connection.isClosed)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testVisibleCardResyncDuringSubscribeAcknowledgmentRenewsInterestAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-card-resync-ack-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            coordinator.setSurfaceDemand(true)
            let carrier = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("card-resync-ack")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle(holdSubscribeAcknowledgments: true)
            let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { carrier })
            let hostID = UUID()
            coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
                source: source, profiles: { [] }, carrierGeneration: 4)
            let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "quiet-card")!
            let (host, _) = try await coordinator.nativeHost(source: source)
            host.threads[thread] = "thread"
            coordinator.ingestionVisibleCards.insert(thread)
            coordinator.scheduleNativeInterests()
            for _ in 0..<200 {
                if await handle.subscribeInterests.count == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let revision = host.interestRevision
            try await handle.inject(["kind": .string("resyncRequired"), "thread": .string("thread"),
                "reason": .string("sourceChanged")])
            for _ in 0..<200 {
                if host.interestRevision > revision { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertGreaterThan(host.interestRevision, revision)
            try await handle.replyHeldSubscription()
            for _ in 0..<200 {
                if await handle.subscribeInterests.count == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let interests = await handle.subscribeInterests
            XCTAssertEqual(interests, ["slow", "slow"], "pre-resync ACK suppressed renewal on \(transport)")
            try await handle.replyHeldSubscription()
            await host.interestTask?.value
            XCTAssertEqual(host.interests[thread], false)
            await coordinator.setExperimentEnabled(false)
        }
    }

    @MainActor
    func testSubscribeAcknowledgmentAfterHidingOrCapacityUnsubscribesAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for capacityPause in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-card-hide-ack-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
                await coordinator.setExperimentEnabled(true)
                coordinator.setSurfaceDemand(true)
                let carrier = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                    incarnation: AgentIncarnationToken("card-hide-ack")!, transport: transport, capabilities: [.observe])
                let handle = try AppleWindowTestHandle(holdSubscribeAcknowledgments: true)
                let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                    discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                    automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                    projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { carrier })
                let hostID = UUID()
                coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
                    source: source, profiles: { [] }, carrierGeneration: 4)
                let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "quiet-card")!
                let (host, _) = try await coordinator.nativeHost(source: source)
                host.threads[thread] = "thread"
                coordinator.ingestionVisibleCards.insert(thread)
                coordinator.scheduleNativeInterests()
                for _ in 0..<200 {
                    if await handle.subscribeInterests.count == 1 { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let revision = host.interestRevision
                if capacityPause {
                    // This tests local Core retention pressure, not a host
                    // resource failure delivered through resyncRequired.
                    await host.connection?.onCapacity?("thread")
                    for _ in 0..<200 {
                        if host.pausedThreads.contains(thread) { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                } else {
                    coordinator.ingestionVisibleCards.remove(thread)
                    coordinator.scheduleNativeInterests()
                }
                XCTAssertGreaterThan(host.interestRevision, revision)
                try await handle.replyHeldSubscription()
                await host.interestTask?.value
                let kinds = await handle.sentKinds
                XCTAssertEqual(kinds.filter { $0 == "subscribe" }.count, 1)
                XCTAssertEqual(kinds.filter { $0 == "unsubscribe" }.count, 1,
                    "a successful obsolete subscribe must be torn down on \(transport)")
                XCTAssertNil(host.interests[thread])
                XCTAssertEqual(host.pausedThreads.contains(thread), capacityPause)
                XCTAssertEqual(coordinator.presentation.ingestionCapacityThreads.contains(thread), capacityPause)
                if capacityPause {
                    // Completing a scoped read releases its transient pause;
                    // it must not undo a capacity event that arrived meanwhile.
                    host.pausedThreads.remove(thread)
                    coordinator.scheduleNativeInterests()
                    await host.interestTask?.value
                    let interestsAfterReadCleanup = await handle.subscribeInterests
                    XCTAssertEqual(interestsAfterReadCleanup, ["slow"])
                    XCTAssertNil(host.interests[thread])
                    XCTAssertTrue(coordinator.presentation.ingestionCapacityThreads.contains(thread))
                }
                await coordinator.setExperimentEnabled(false)
            }
        }
    }

    @MainActor
    func testReleaseAcknowledgmentReconcilesCapacityPauseAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for capacityArrivesDuringRelease in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-release-ack-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let core = AgentCenterRuntime()
                let coordinator = AgentCenterV2Coordinator(runtime: core,
                    metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
                await coordinator.setExperimentEnabled(true)
                coordinator.setSurfaceDemand(true)
                let carrier = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                    incarnation: AgentIncarnationToken("release-ack")!, transport: transport, capabilities: [.observe])
                let handle = try AppleWindowTestHandle(autoBootstrap: true, holdWindowReleases: true)
                let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                    discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                    automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                    projectorExecAvailability: { _, _ in .available(.init { _ in handle }) }, readCarrier: { carrier })
                let hostID = UUID()
                coordinator.sessionRoutes[source.sessionID] = .init(hostID: hostID, hostDisplayLabel: "fixture",
                    source: source, profiles: { [] }, carrierGeneration: 4)
                let thread = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "quiet-card")!
                await core.register(.init(id: thread, providerName: "Claude",
                    availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false)), binding: carrier)
                let (host, connection) = try await coordinator.nativeHost(source: source)
                host.threads[thread] = "thread"
                let boot = try await connection.request(["kind": .string("window.read"), "operation": .string("bootstrap"),
                    "thread": .string("thread"), "windowVersion": .number(0)])
                let applied = await core.apply(page: try XCTUnwrap(boot.page), to: thread)
                XCTAssertTrue(applied.accepted)
                host.bootstrapped.insert(thread)
                coordinator.ingestionVisibleCards.insert(thread)
                if !capacityArrivesDuringRelease {
                    host.pausedThreads.insert(thread)
                    coordinator.presentation.ingestionCapacityThreads.insert(thread)
                }
                coordinator.scheduleNativeInterests()
                for _ in 0..<200 {
                    if await handle.sentKinds.contains("window.release") { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                if capacityArrivesDuringRelease {
                    let revision = host.interestRevision
                    await connection.onCapacity?("thread")
                    for _ in 0..<200 {
                        if host.pausedThreads.contains(thread) { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertGreaterThan(host.interestRevision, revision)
                }
                try await handle.replyHeldWindowRelease()
                await host.interestTask?.value
                XCTAssertEqual(host.pausedThreads.contains(thread), capacityArrivesDuringRelease,
                    "release must clear only the pause it began with on \(transport)")
                XCTAssertEqual(coordinator.presentation.ingestionCapacityThreads.contains(thread), capacityArrivesDuringRelease)
                XCTAssertFalse(host.bootstrapped.contains(thread), "confirmed remote release still retires its old window")
                let interests = await handle.subscribeInterests
                XCTAssertEqual(interests, capacityArrivesDuringRelease ? [] : ["slow"],
                    "visible card must resume only after its own old capacity pause is released")
                let window = await core.ingestionWindowSnapshot(for: thread)
                XCTAssertNil(window)
                await coordinator.setExperimentEnabled(false)
            }
        }
    }

    @MainActor
    func testLegacyHostCapacityResyncDoesNotClaimLocalRetentionPressure() async throws {
        let handle = try AppleWindowTestHandle()
        let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
        let paused = expectation(description: "legacy host status requests resync")
        connection.onResync = { thread in XCTAssertEqual(thread, "thread"); paused.fulfill() }
        connection.onCapacity = { _ in XCTFail("host status must not become local retention pressure") }
        try await handle.inject(["kind": .string("resyncRequired"), "thread": .string("thread"),
            "reason": .string("capacityExceeded"), "code": .string("windowCapacity")])
        await fulfillment(of: [paused], timeout: 2)
        let heartbeat = try await connection.request(["kind": .string("heartbeat")])
        XCTAssertEqual(heartbeat.object["kind"]?.stringValue, "ack")
        XCTAssertFalse(connection.isClosed)
        await connection.close()
    }

    @MainActor
    func testUnsubscribeWaitsForCommittedWatchAcknowledgmentAcrossTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("window-test")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle()
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
            let entered = expectation(description: "Core commit suspended")
            var release: CheckedContinuation<Void, Never>?
            let snapshot = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"{"version":1,"epoch":"fixture","viewportSegmentIDs":["head"],"headSegmentID":"head","hasOlder":false,"hasNewer":false,"atLiveHead":true,"liveCursor":"live","transition":"bootstrap","retainsOutgoing":false}"#.utf8))
            connection.onWindowPage = { _, _ in
                await withCheckedContinuation { release = $0; entered.fulfill() }
                return .init(snapshot: snapshot, accepted: true)
            }
            try await handle.watchWindow("watch_first")
            await fulfillment(of: [entered], timeout: 2)
            let stop = Task { try await connection.request(["kind": .string("unsubscribe"), "thread": .string("thread")]) }
            try await Task.sleep(for: .milliseconds(100))
            let premature = await handle.sentKinds.contains("unsubscribe")
            XCTAssertFalse(premature, "Unsubscribe overtook Core commit's ACK")
            do {
                _ = try await connection.request(["kind": .string("subscribe"), "thread": .string("thread")])
                XCTFail("Subscribe must not overtake pending unsubscribe")
            } catch { XCTAssertEqual(error as? AgentIngestionError, .remote("controlBusy")) }
            release?.resume(); release = nil
            _ = try await stop.value
            let kinds = await handle.sentKinds
            XCTAssertLessThan(try XCTUnwrap(kinds.firstIndex(of: "window.ack")), try XCTUnwrap(kinds.firstIndex(of: "unsubscribe")))
            connection.onWindowPage = { _, _ in XCTFail("Paused watch must not commit"); return nil }
            try await handle.watchWindow("watch_late")
            _ = try await connection.request(["kind": .string("heartbeat")])
            XCTAssertFalse(connection.isClosed)
            _ = try await connection.request(["kind": .string("subscribe"), "thread": .string("thread")])
            await handle.rejectReads(2)
            _ = try await connection.request(["kind": .string("summary"), "thread": .string("thread")])
            await handle.rejectReads(6)
            do {
                _ = try await connection.request(["kind": .string("summary"), "thread": .string("thread")])
                XCTFail("Busy retries must remain bounded")
            } catch { XCTAssertEqual(error as? AgentIngestionError, .remote("busy")) }
            let remaining = await handle.busyReads
            XCTAssertEqual(remaining, 1)
            await connection.close()
        }
    }

    @MainActor
    func testWindowUnsubscribeDrainCompletesWaiterAcrossAllTransports() async throws {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                incarnation: AgentIncarnationToken("window-test")!, transport: transport, capabilities: [.observe])
            let handle = try AppleWindowTestHandle()
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
            let finished = expectation(description: "unsubscribe drains one window")
            let request = Task {
                do {
                    let reply = try await connection.request(["kind": .string("unsubscribe"), "thread": .string("thread")])
                    XCTAssertEqual(reply.object["kind"]?.stringValue, "window.cancelled")
                } catch { XCTFail("Unsubscribe failed: \(error)") }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertFalse(connection.isClosed)
            await connection.close(); _ = await request.result
        }
    }

    @MainActor
    func testAmbiguousSentControlsCloseOnlyIngestionChildWhileReadAbandonmentPreservesItAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for kind in ["subscribe", "unsubscribe", "window.release", "window.read", "summary"] {
                for cancel in [false, true] {
                    let handle = try AppleWindowTestHandle(heldRequestKinds: [kind])
                    let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                        incarnation: AgentIncarnationToken("ambiguous-control")!, transport: transport, capabilities: [.observe])
                    let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
                    let siblingHandle = try AppleWindowTestHandle()
                    let siblingConnection = try await AppleAgentIngestionConnection.open(factory: .init { _ in siblingHandle }, binding: binding)
                    let request = Task {
                        try await connection.request(["kind": .string(kind), "thread": .string("thread"),
                            "interest": .string("slow"), "operation": .string("bootstrap"), "windowVersion": .number(0)],
                            deadline: cancel ? .seconds(2) : .milliseconds(40))
                    }
                    for _ in 0..<200 {
                        if await handle.sentKinds.contains(kind) { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let reachedWire = await handle.sentKinds.contains(kind)
                    XCTAssertTrue(reachedWire)
                    if cancel { request.cancel() }
                    do { _ = try await request.value; XCTFail("unanswered request succeeded") }
                    catch {
                        if cancel { XCTAssertTrue(error is CancellationError) }
                        else { XCTAssertEqual(error as? AgentIngestionError, .remote("deadlineExceeded")) }
                    }
                    let control = ["subscribe", "unsubscribe", "window.release"].contains(kind)
                    XCTAssertEqual(connection.isClosed, control, "ambiguous \(kind) must retire only its ingestion relay")
                    if control {
                        for _ in 0..<200 {
                            if await handle.isClosed { break }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        let childClosed = await handle.isClosed
                        XCTAssertTrue(childClosed)
                    } else {
                        let sibling = try await connection.request(["kind": .string("heartbeat")])
                        XCTAssertEqual(sibling.object["kind"]?.stringValue, "ack")
                        XCTAssertFalse(connection.isClosed)
                        await connection.close()
                    }
                    let otherChild = try await siblingConnection.request(["kind": .string("heartbeat")])
                    XCTAssertEqual(otherChild.object["kind"]?.stringValue, "ack", "closing one relay must preserve its sibling on the same carrier")
                    XCTAssertFalse(siblingConnection.isClosed)
                    await siblingConnection.close()
                }
            }
        }
    }

    @MainActor
    func testExplicitControlRejectionsPreserveSiblingRequestsAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for kind in ["subscribe", "unsubscribe", "window.release"] {
                for code in ["busy", "unknownThread"] {
                    let handle = try AppleWindowTestHandle(requestRejections: [kind: code])
                    let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                        incarnation: AgentIncarnationToken("rejected-control")!, transport: transport, capabilities: [.observe])
                    let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
                    do {
                        _ = try await connection.request(["kind": .string(kind), "thread": .string("thread"), "interest": .string("slow")])
                        XCTFail("remote rejection was discarded")
                    } catch { XCTAssertEqual(error as? AgentIngestionError, .remote(code)) }
                    XCTAssertFalse(connection.isClosed)
                    let sibling = try await connection.request(["kind": .string("heartbeat")])
                    XCTAssertEqual(sibling.object["kind"]?.stringValue, "ack")
                    let kinds = await handle.sentKinds
                    XCTAssertEqual(kinds.filter { $0 == kind }.count, 1, "controls are never replayed")
                    await connection.close()
                }
            }
        }
    }

    @MainActor
    func testUnsentControlAbandonmentDropsQueuedWritesAndRestoresWatchGateAcrossTransports() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            for kind in ["subscribe", "unsubscribe", "window.release"] {
                for cancel in [false, true] {
                    let gate = AppleSearchTestGate()
                    let handle = try AppleWindowTestHandle(windowAckGate: gate)
                    let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 4,
                        incarnation: AgentIncarnationToken("queued-control")!, transport: transport, capabilities: [.observe])
                    let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: binding)
                    let snapshot = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"{"version":1,"epoch":"fixture","viewportSegmentIDs":["head"],"headSegmentID":"head","hasOlder":false,"hasNewer":false,"atLiveHead":true,"liveCursor":"live","transition":"bootstrap","retainsOutgoing":false}"#.utf8))
                    var delivered = 0
                    connection.onWindowPage = { _, _ in delivered += 1; return .init(snapshot: snapshot, accepted: true) }
                    try await handle.watchWindow("watch_queued_control")
                    for _ in 0..<200 {
                        if await gate.isWaiting { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let blocked = await gate.isWaiting
                    XCTAssertTrue(blocked)
                    // Subscribe queues behind the blocked writer; teardown of
                    // this same thread waits for its committed watch to drain.
                    let request = Task {
                        try await connection.request(["kind": .string(kind),
                            "thread": .string(kind == "subscribe" ? "sibling" : "thread"), "interest": .string("slow")],
                            deadline: cancel ? .seconds(2) : .milliseconds(30))
                    }
                    if cancel { try await Task.sleep(for: .milliseconds(20)); request.cancel() }
                    do { _ = try await request.value; XCTFail("blocked control unexpectedly completed") }
                    catch {
                        if cancel { XCTAssertTrue(error is CancellationError) }
                        else { XCTAssertEqual(error as? AgentIngestionError, .remote("deadlineExceeded")) }
                    }
                    XCTAssertFalse(connection.isClosed, "known-unsent control can safely preserve siblings")
                    await gate.release()
                    _ = try await connection.request(["kind": .string("heartbeat")])
                    let sent = await handle.sentKinds
                    XCTAssertFalse(sent.contains(kind), "abandoned \(kind) escaped its writer/drain queue")
                    try await handle.watchWindow("watch_after_abandonment")
                    for _ in 0..<200 {
                        if delivered == 2, await gate.isWaiting { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertEqual(delivered, 2, "unsent teardown must restore the previous watch gate")
                    await gate.release()
                    _ = try await connection.request(["kind": .string("heartbeat")])
                    await connection.close()
                }
            }
        }
    }

    @MainActor
    func testWindowCancellationDoesNotCloseSiblingRequests() async throws {
        let handle = try AppleWindowTestHandle()
        let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
        let request = Task { try await connection.request(["kind": .string("window.read"), "thread": .string("thread"),
            "operation": .string("bootstrap"), "windowVersion": .number(0)]) }
        for _ in 0..<100 {
            if await handle.didRead { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let read = await handle.didRead
        XCTAssertTrue(read)
        request.cancel(); _ = await request.result
        let heartbeat = try await connection.request(["kind": .string("heartbeat")])
        XCTAssertEqual(heartbeat.object["kind"]?.stringValue, "ack")
        for _ in 0..<100 {
            if await handle.didCancel { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await handle.didCancel
        XCTAssertTrue(cancelled)
        XCTAssertFalse(connection.isClosed)
        await connection.close()
    }

    @MainActor
    func testWindowHandshakeRejectsOldVersionAndMissingPartitionCapability() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await AppleAgentIngestionConnection.withSearchDeadline(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
                return true
            }
            XCTFail("search deadline was ignored")
        } catch { XCTAssertLessThan(started.duration(to: .now), .seconds(1)) }
        let gate = AppleSearchTestGate()
        let blocked = ContinuousClock.now
        do {
            _ = try await AppleAgentIngestionConnection.withSearchDeadline(.milliseconds(20)) {
                await gate.wait(); return true
            }
            XCTFail("shared opening blocked search timeout")
        } catch { XCTAssertLessThan(blocked.duration(to: .now), .seconds(1)) }
        await gate.release()
        for piSessions in [false, true] {
            let handle = try AppleWindowTestHandle(piSessions: piSessions)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            XCTAssertEqual(connection.supportsPiSessions, piSessions)
            await connection.close()
        }
        for openCodeSessions in [false, true] {
            let handle = try AppleWindowTestHandle(openCodeSessions: openCodeSessions)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            XCTAssertEqual(connection.supportsOpenCodeSessions, openCodeSessions)
            XCTAssertFalse(connection.supportsPiSessions)
            await connection.close()
        }
        for kimiSessions in [false, true] {
            let handle = try AppleWindowTestHandle(kimiSessions: kimiSessions)
            let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
            XCTAssertEqual(connection.supportsKimiSessions, kimiSessions)
            XCTAssertFalse(connection.supportsPiSessions)
            XCTAssertFalse(connection.supportsOpenCodeSessions)
            await connection.close()
        }
        for (version, partitions) in [(2, true), (3, false)] {
            let handle = try AppleWindowTestHandle(version: version, partitions: partitions)
            do {
                let connection = try await AppleAgentIngestionConnection.open(factory: .init { _ in handle }, binding: makeBinding())
                await connection.close()
                XCTFail("Incompatible window protocol was accepted")
            } catch {
                let closed = await handle.isClosed
                XCTAssertTrue(closed)
            }
        }
    }

    private func makeBinding() -> AgentTerminalBinding {
        AgentTerminalBinding(
            liveSessionID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000004")!,
            carrierGeneration: 4,
            incarnation: AgentIncarnationToken("test-incarnation")!,
            transport: .ssh,
            capabilities: [.observe]
        )
    }

    @MainActor
    func testProcessContextsShareOnlyAdmittedServiceAndKeepSiblingWaiters() async throws {
        for transport: AgentTransportKind in [.ssh, .sshTmux, .mosh, .moshTmux] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-context-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = AgentCenterV2Coordinator(metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json")))
            await coordinator.setExperimentEnabled(true)
            await coordinator.setApplicationActive(true)
            coordinator.setSurfaceDemand(true)
            let original = makeBinding()
            func context(_ pid: Int?) -> AgentTerminalBinding {
                AgentTerminalBinding(liveSessionID: original.liveSessionID, carrierGeneration: 4,
                    incarnation: AgentIncarnationToken("context-\(pid ?? 0)")!, transport: transport,
                    agentPID: pid, capabilities: [.observe])
            }
            let carrier = context(nil)
            let factory = AppleContextTestFactory()
            let source = AgentSessionSource(registrationID: UUID(), sessionID: carrier.liveSessionID,
                discover: { .success([]) }, observe: { _ in nil }, inspect: { _ in nil },
                automaticallyProbeLifecycleIntegration: false, send: { _, _ in false }, jump: { _ in },
                projectorExecAvailability: { _, _ in .available(.init { try await factory.open($0) }) },
                readCarrier: { carrier })
            coordinator.sessionRoutes[carrier.liveSessionID] = AppleAgentSessionRoute(hostID: UUID(), hostDisplayLabel: "fixture",
                source: source, profiles: { [] }, carrierGeneration: 4)
            let baseline = try await coordinator.nativeHost(source: source)
            let first = Task { try await coordinator.nativeHost(source: source, context: context(42)) }
            let second = Task { try await coordinator.nativeHost(source: source, context: context(42)) }
            let cancelled = Task { try await coordinator.nativeHost(source: source, context: context(42)) }
            for _ in 0..<100 { if await factory.pending { break }; try await Task.sleep(for: .milliseconds(10)) }
            let pending = await factory.pending; XCTAssertTrue(pending)
            cancelled.cancel(); await factory.release()
            let a = try await first.value, b = try await second.value
            XCTAssertTrue(a.0 === baseline.0 && b.0 === baseline.0)
            do { _ = try await cancelled.value; XCTFail("Cancelled borrower succeeded") } catch { }
            let reused = try await coordinator.nativeHost(source: source, context: context(42))
            XCTAssertTrue(reused.0 === baseline.0)
            let other = try await coordinator.nativeHost(source: source, context: context(99))
            XCTAssertFalse(other.0 === baseline.0)
            let borrowedAgain = try await coordinator.nativeHost(source: source)
            XCTAssertTrue(borrowedAgain.0 === baseline.0, "An admitted connection must not be replaced by a new alias")
            let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "collision")!
            try coordinator.claimNativeThread(thread, host: baseline.0)
            XCTAssertThrowsError(try coordinator.claimNativeThread(thread, host: other.0))
            let otherSession = AppleAgentIngestionHostKey(sessionID: UUID())
            // Core thread identity spans terminal sessions; a separate session
            // must not bypass the cross-scope conflict fence.
            coordinator.ingestionHosts = coordinator.ingestionHosts.filter { $0.value !== other.0 }
            coordinator.ingestionHosts[otherSession] = other.0
            XCTAssertThrowsError(try coordinator.claimNativeThread(thread, host: other.0))
            _ = try await baseline.1.request(["kind": .string("heartbeat")])
            let requests = await factory.contexts
            XCTAssertEqual(requests, [0, 42, 99], "Only the initial context sends a PID; retained history reuses its connection")
            let abandoned = Task { try await coordinator.nativeHost(source: source, context: context(200)) }
            for _ in 0..<100 { if await factory.contexts.contains(200) { break }; try await Task.sleep(for: .milliseconds(10)) }
            abandoned.cancel()
            let abandonedKey = AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: context(200))
            for _ in 0..<100 { if coordinator.ingestionHosts[abandonedKey] == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(coordinator.ingestionHosts[abandonedKey], "Sole cancellation must retire a still-suspended opening")
            do { _ = try await abandoned.value; XCTFail("Abandoned opening succeeded") } catch { }
            coordinator.closeIngestionHosts()
            // Simulate background/foreground after the provider exited. The
            // fixture refuses any further PID-based bootstrap after this point.
            await factory.exited()
            let resumed = try await coordinator.nativeHost(source: source, context: context(42))
            XCTAssertEqual(resumed.1.contextScope, "0000000000000001")
            let reconnects = await factory.scopeRequests
            XCTAssertEqual(reconnects, ["0000000000000001"])
            // Foreground helper upgrade: EOF retires the old pooled host;
            // concurrent borrowers admit one new epoch in the retained scope.
            await factory.upgrade()
            for _ in 0..<100 { if resumed.1.isClosed { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(resumed.1.isClosed)
            let reconnectA = Task { try await coordinator.nativeHost(source: source, context: context(42)) }
            let reconnectB = Task { try await coordinator.nativeHost(source: source, context: context(42)) }
            let upgraded = try await reconnectA.value
            let upgradedSibling = try await reconnectB.value
            XCTAssertTrue(upgraded.0 === upgradedSibling.0)
            XCTAssertFalse(upgraded.0 === resumed.0)
            XCTAssertEqual(upgraded.1.epoch, "fixture_1")
            XCTAssertEqual(upgraded.1.contextScope, "0000000000000001")
            _ = try await upgraded.1.request(["kind": .string("heartbeat")])
            coordinator.closeIngestionHosts()
            await factory.allowProcesses()
            for pid in 100..<108 {
                _ = try await coordinator.nativeHost(source: source, context: context(pid))
            }
            for host in coordinator.ingestionHosts.values { if let connection = host.connection { await connection.close() } }
            let ninth = try await coordinator.nativeHost(source: source, context: context(108))
            XCTAssertFalse(ninth.1.isClosed, "Closed scopes must not consume all eight admission slots")
            coordinator.closeIngestionHosts()
            await coordinator.setExperimentEnabled(false)
            for _ in 0..<100 { if await factory.allClosed { break }; try await Task.sleep(for: .milliseconds(10)) }
            let closed = await factory.allClosed; XCTAssertTrue(closed)
        }
    }
}

private actor AppleContextTestFactory {
    private(set) var contexts: [Int] = []
    private var handles: [AppleWindowTestHandle] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var processExited = false
    private var serviceGeneration = 0
    private(set) var scopeRequests: [String] = []
    var pending: Bool { gate != nil }
    var allClosed: Bool { get async {
        for handle in handles { if !(await handle.isClosed) { return false } }
        return true
    } }
    func open(_ request: AgentExecRequest) async throws -> AppleWindowTestHandle {
        let hello = try JSONDecoder().decode(AgentJSONValue.self, from: request.stdin.dropFirst(4)).objectValue!
        let pid = hello["contextPID"]?.numberValue.map { NSDecimalNumber(decimal: $0).intValue } ?? 0
        if let scope = hello["contextScope"]?.stringValue {
            scopeRequests.append(scope)
        } else if processExited { throw AgentIngestionError.remote("contextProcessUnavailable") }
        contexts.append(pid)
        if pid == 200 { try await Task.sleep(for: .seconds(30)) }
        if pid == 42 { await withCheckedContinuation { gate = $0 } }
        let epoch = pid >= 99 ? "scope_\(pid)" : "fixture"
        let handle = try AppleWindowTestHandle(epoch: serviceGeneration == 0 ? epoch : "\(epoch)_\(serviceGeneration)",
            contextScope: pid >= 99 ? String(format: "%016x", pid) : "0000000000000001")
        handles.append(handle); return handle
    }
    func release() { gate?.resume(); gate = nil }
    func exited() { processExited = true }
    func allowProcesses() { processExited = false }
    func upgrade() async {
        serviceGeneration += 1
        for handle in handles { await handle.cancel() }
    }
}

private actor AppleInventoryRecoveryTestFactory {
    private var failures: Int
    private var handles: [AppleWindowTestHandle] = []
    private(set) var attempts = 0
    init(failures: Int = 0) { self.failures = failures }
    func open(_ request: AgentExecRequest) async throws -> any AppleAgentStreamingExecHandle {
        attempts += 1
        if failures > 0 { failures -= 1; throw AgentIngestionError.remote("disconnected") }
        let handle = try AppleWindowTestHandle()
        handles.append(handle)
        return handle
    }
    var inventoryDelivered: Bool {
        get async { guard let handle = handles.last else { return false }; return await handle.sentKinds.contains("inventory") }
    }
}

private actor AppleSearchTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor AppleWindowTestHandle: AppleAgentStreamingExecHandle {
    private let epoch: String
    private let inventoryRows: Int
    private let inventoryPadding: Int
    private let inventoryBegins: Int
    private let inventoryEndKind: String
    private let holdSummaries: Bool
    private let holdSubscribeAcknowledgments: Bool
    private var pendingSubscriptionIDs: [AgentJSONValue] = []
    private let holdWindowReleases: Bool
    private var pendingWindowReleaseIDs: [AgentJSONValue] = []
    private let heldRequestKinds: Set<String>
    private let requestRejections: [String: String]
    private let windowAckGate: AppleSearchTestGate?
    private let autoBootstrap: Bool
    private(set) var summaryRequestID: AgentJSONValue?
    private var frames: [AgentExecFrame]
    private var waiter: CheckedContinuation<AgentExecFrame?, Error>?
    private var closed = false
    private(set) var didRead = false
    private(set) var didCancel = false
    private(set) var sentKinds: [String] = []
    private var sentRequests: [[String: AgentJSONValue]] = []
    func lastRequest(_ kind: String) -> [String: AgentJSONValue]? { sentRequests.last { $0["kind"]?.stringValue == kind } }
    private(set) var subscribeInterests: [String] = []
    private(set) var busyReads = 0
    func rejectReads(_ count: Int) { busyReads = count }

    var isClosed: Bool { closed }

    init(version: Int = 3, partitions: Bool = true, piSessions: Bool = false, openCodeSessions: Bool = false, kimiSessions: Bool = false, readProgress: Bool = false, epoch: String = "fixture", contextScope: String = "",
         inventoryRows: Int = 0, inventoryPadding: Int = 0, inventoryBegins: Int = 1,
         inventoryEndKind: String = "inventory.end", holdSummaries: Bool = false,
         windowAckGate: AppleSearchTestGate? = nil, autoBootstrap: Bool = false,
         holdSubscribeAcknowledgments: Bool = false, holdWindowReleases: Bool = false,
         heldRequestKinds: Set<String> = [], requestRejections: [String: String] = [:]) throws {
        self.epoch = epoch
        self.inventoryRows = inventoryRows
        self.inventoryPadding = inventoryPadding
        self.inventoryBegins = inventoryBegins
        self.inventoryEndKind = inventoryEndKind
        self.holdSummaries = holdSummaries
        self.holdSubscribeAcknowledgments = holdSubscribeAcknowledgments
        self.holdWindowReleases = holdWindowReleases
        self.heldRequestKinds = heldRequestKinds
        self.requestRejections = requestRejections
        self.windowAckGate = windowAckGate
        self.autoBootstrap = autoBootstrap
        let hello = try AgentIngestionFramer.encode(.object(["kind": .string("hello"), "id": .string("hello"),
            "serviceEpoch": .string(epoch), "contextScope": .string(contextScope), "v": .number(Decimal(version)), "capabilities": .array(
                [.string("bounded.windows")] + (partitions ? [.string("window.partitions")] : []) +
                (piSessions ? [.string("pi.sessions.v1-v3")] : []) +
                (openCodeSessions ? [.string("opencode.sqlite.v1-v2")] : []) +
                (kimiSessions ? [.string("kimi.wire.v1.4-v1.5")] : []) +
                (readProgress ? [.string("read.progress.v1")] : []))]))
        frames = [AgentExecFrame(carrierGeneration: 4, kind: .stdout(hello))!]
    }

    func nextFrame() async throws -> AgentExecFrame? {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(_ bytes: Data) async throws {
        let value = try JSONDecoder().decode(AgentJSONValue.self, from: bytes.dropFirst(4)).objectValue!
        let kind = value["kind"]!.stringValue!
        sentKinds.append(kind)
        sentRequests.append(value)
        if let code = requestRejections[kind] {
            try inject(["kind": .string("error"), "id": value["id"]!, "code": .string(code)])
            return
        }
        if heldRequestKinds.contains(kind) { return }
        if kind == "subscribe", let interest = value["interest"]?.stringValue { subscribeInterests.append(interest) }
        if kind == "subscribe", holdSubscribeAcknowledgments {
            pendingSubscriptionIDs.append(value["id"]!)
            return
        }
        if kind == "window.release", holdWindowReleases {
            pendingWindowReleaseIDs.append(value["id"]!)
            return
        }
        if kind == "summary", busyReads > 0 {
            busyReads -= 1
            try inject(["kind": .string("error"), "code": .string("busy"), "id": value["id"]!])
            return
        }
        if kind == "inventory" {
            for _ in 0..<inventoryBegins { try inject(["kind": .string("inventory.begin"), "id": value["id"]!]) }
            for index in 0..<inventoryRows {
                try inject(["kind": .string("inventory.thread"), "id": value["id"]!,
                    "thread": .string("inventory_\(index)"), "padding": .string(String(repeating: "x", count: inventoryPadding))])
            }
            try inject(["kind": .string(inventoryEndKind), "id": value["id"]!, "hasMore": .bool(false)])
            return
        }
        if kind == "window.read" {
            didRead = true
            if autoBootstrap {
                if value["operation"]?.stringValue == "head" {
                    let version = value["windowVersion"]?.numberValue ?? 0
                    try inject(["kind": .string("page.begin"), "id": value["id"]!, "thread": .string("thread"),
                        "sourceIdentity": .string("fixture"), "operation": .string("updates"), "from": value["cursor"]!])
                    try inject(["kind": .string("page.end"), "id": value["id"]!, "thread": .string("thread"),
                        "records": .number(0), "hasNewer": .bool(false), "liveCursor": .string("receipt-live"),
                        "window": .object(["lane": .string("revisions"), "version": .number(version + 1)])])
                } else { try watchWindow(value["id"]!.stringValue!) }
            }
            return
        }
        if kind == "window.ack", let windowAckGate { await windowAckGate.wait() }
        if kind == "summary" {
            if holdSummaries { summaryRequestID = value["id"]; return }
            try inject(["kind": .string("summary"), "id": value["id"]!, "thread": .string("thread"),
                "revision": .string("metadata"), "modified": .number(1),
                "records": .array([.object(["type": .string("session-title"), "title": .string("External Codex title")])])])
            return
        }
        if kind == "window.cancel" { didCancel = true }
        var reply: [String: AgentJSONValue] = ["serviceEpoch": .string(epoch), "id": value["id"]!, "kind": .string("ack")]
        if kind == "unsubscribe" || kind == "window.cancel" {
            reply["kind"] = .string("window.cancelled"); reply["transaction"] = value["transaction"] ?? .string("watch_fixture")
        }
        let frame = AgentExecFrame(carrierGeneration: 4, kind: .stdout(try AgentIngestionFramer.encode(.object(reply))))!
        if let pending = waiter { waiter = nil; pending.resume(returning: frame) } else { frames.append(frame) }
    }

    func cancel() { closed = true; waiter?.resume(returning: nil); waiter = nil }

    func watchWindow(_ id: String) throws {
        try inject(["kind": .string("page.begin"), "id": .string(id), "thread": .string("thread"),
            "sourceIdentity": .string("fixture"), "operation": .string("bootstrap")])
        try inject(["kind": .string("page.end"), "id": .string(id), "thread": .string("thread"),
            "records": .number(0), "historyCursor": .null, "hasOlder": .bool(false), "hasNewer": .bool(false),
            "liveCursor": .string("live"), "window": .object([
                "lane": .string("bootstrap"), "version": .number(1), "segmentID": .string("head"),
                "before": .string("begin"), "after": .string("end"), "hasOlder": .bool(false), "hasNewer": .bool(false)])])
    }

    func replyHeldSubscription() throws {
        guard !pendingSubscriptionIDs.isEmpty else { return }
        try inject(["kind": .string("ack"), "id": pendingSubscriptionIDs.removeFirst()])
    }

    func replyHeldWindowRelease() throws {
        guard !pendingWindowReleaseIDs.isEmpty else { return }
        try inject(["kind": .string("ack"), "id": pendingWindowReleaseIDs.removeFirst()])
    }

    func replyHeldSummary() throws {
        guard let id = summaryRequestID else { return }
        summaryRequestID = nil
        try inject(["kind": .string("summary"), "id": id, "thread": .string("thread"),
            "revision": .string("metadata"), "modified": .number(1), "records": .array([])])
    }

    func readProgress(id: AgentJSONValue, thread: String = "thread", sequence: String, bytes: String) throws {
        try inject(["kind": .string("read.progress"), "id": id, "thread": .string(thread),
            "sequence": .string(sequence), "bytesRead": .string(bytes),
            "status": .object(["v": .number(1), "state": .string("preparing"), "domain": .string("source"),
                "recovery": .string("continue"), "code": .string("readPending")])])
    }

    func inject(_ fields: [String: AgentJSONValue]) throws {
        var value = fields; value["serviceEpoch"] = .string(epoch)
        let frame = AgentExecFrame(carrierGeneration: 4, kind: .stdout(try AgentIngestionFramer.encode(.object(value))))!
        if let pending = waiter { waiter = nil; pending.resume(returning: frame) } else { frames.append(frame) }
    }
}

private actor AppleAgentTestExecStream: AgentExecStream {
    private let frames: [AgentExecFrame]
    private var index = 0

    init(frames: [AgentExecFrame]) { self.frames = frames }

    func nextFrame() -> AgentExecFrame? {
        guard index < frames.count else { return nil }
        defer { index += 1 }
        return frames[index]
    }

    func cancel() {}
}

private actor AppleAgentTestExecPort: AgentRemoteExecPort {
    private let stream: AppleAgentTestExecStream
    init(stream: AppleAgentTestExecStream) { self.stream = stream }
    func execute(_ request: AgentExecRequest) -> AgentExecStream { stream }
}

private final class AgentComposerTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Holds only history responses, never the duplex writer. Receipt and cancel
/// frames can therefore prove they bypass an unanswered optional page.
/// A remote exec that never answers: its connection waits out its own opening deadline.
private actor AppleSilentTestHandle: AppleAgentStreamingExecHandle {
    private var waiter: CheckedContinuation<AgentExecFrame?, Error>?
    private var closed = false

    func nextFrame() async throws -> AgentExecFrame? {
        if closed { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(_ bytes: Data) throws {}

    func cancel() { closed = true; waiter?.resume(returning: nil); waiter = nil }
}

private actor AppleInitialPrefetchTestHandle: AppleAgentStreamingExecHandle {
    private var frames: [AgentExecFrame] = []
    private var waiter: CheckedContinuation<AgentExecFrame?, Error>?
    private var heldHistory: [[String: AgentJSONValue]] = []
    private var historyCancellations: [String: AgentJSONValue] = [:]
    private var closed = false
    private var resolveFailures: Int
    private(set) var resolveRequests = 0
    private(set) var operations: [String] = []
    private(set) var acknowledgedVersions: [Int] = []
    var historyRequests: Int { operations.filter { $0 == "before" }.count }
    var heldHistoryCount: Int { heldHistory.count }

    private let resolveFailure: (code: String, state: String, recovery: String)

    init(resolveFailures: Int = 0,
         resolveFailure: (code: String, state: String, recovery: String) = ("sourceMissing", "failed", "manual")) throws {
        self.resolveFailures = resolveFailures
        self.resolveFailure = resolveFailure
        let hello = try AgentIngestionFramer.encode(.object(["kind": .string("hello"), "id": .string("hello"),
            "serviceEpoch": .string("initial-epoch"), "contextScope": .string("0000000000000001"), "v": .number(3),
            "capabilities": .array([.string("bounded.windows"), .string("window.partitions")])]))
        frames.append(AgentExecFrame(carrierGeneration: 4, kind: .stdout(hello))!)
    }

    func nextFrame() async throws -> AgentExecFrame? {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(_ bytes: Data) throws {
        let value = try JSONDecoder().decode(AgentJSONValue.self, from: bytes.dropFirst(4)).objectValue!
        switch value["kind"]?.stringValue {
        case "resolve":
            resolveRequests += 1
            if resolveFailures > 0 {
                resolveFailures -= 1
                try inject(["kind": .string("error"), "id": value["id"]!, "code": .string(resolveFailure.code),
                    "status": .object(["v": .number(1), "state": .string(resolveFailure.state), "domain": .string("source"),
                        "recovery": .string(resolveFailure.recovery), "code": .string(resolveFailure.code)])])
            } else {
                try inject(["kind": .string("resolved"), "id": value["id"]!, "thread": .string("thread"),
                    "provider": .string("claude"), "sessionID": .string("initial-prefetch")])
            }
        case "receipt.frontier":
            try inject(["kind": .string("receipt.frontier"), "id": value["id"]!, "frontier": .object([
                "version": .number(1), "actionID": value["actionID"]!, "serviceEpoch": .string("initial-epoch"),
                "provider": .string("claude"), "providerSessionID": .string("initial-prefetch"),
                "sourceIdentity": .string("jsonl:1:2"), "sourceEnd": .string("123"), "consistency": .string("observedPrefix")])])
        case "window.read":
            let operation = value["operation"]!.stringValue!
            operations.append(operation)
            if operation == "before" { heldHistory.append(value) }
            else { try page(value) }
        case "window.ack":
            acknowledgedVersions.append(NSDecimalNumber(decimal: value["windowVersion"]!.numberValue!).intValue)
        case "window.cancel":
            historyCancellations[value["transaction"]!.stringValue!] = value["id"]!
        default:
            try inject(["kind": .string("ack"), "id": value["id"]!])
        }
    }

    func releaseHistory() throws {
        guard !heldHistory.isEmpty else { return }
        let request = heldHistory.removeFirst()
        try page(request)
        if let transaction = request["id"]?.stringValue, let id = historyCancellations.removeValue(forKey: transaction) {
            try inject(["kind": .string("window.cancelled"), "id": id, "transaction": .string(transaction)])
        }
    }

    private func page(_ request: [String: AgentJSONValue]) throws {
        let operation = request["operation"]!.stringValue!
        let version = (request["windowVersion"]?.numberValue ?? 0) + 1
        var begin: [String: AgentJSONValue] = ["kind": .string("page.begin"), "id": request["id"]!,
            "thread": .string("thread"), "sourceIdentity": .string("initial-fixture"),
            "operation": .string(operation == "bootstrap" ? "bootstrap" : operation == "head" ? "updates" : "history")]
        if let cursor = request["cursor"] { begin["from"] = cursor }
        try inject(begin)
        if operation == "head" {
            try inject(["kind": .string("page.end"), "id": request["id"]!, "thread": .string("thread"),
                "records": .number(0), "hasNewer": .bool(false), "liveCursor": .string("live-\(version)"),
                "window": .object(["lane": .string("revisions"), "version": .number(version)])])
            return
        }
        let number = operation == "bootstrap" ? 10 : Int(request["cursor"]!.stringValue!.dropFirst(7))! - 1
        try inject(["kind": .string("page.record"), "id": request["id"]!, "thread": .string("thread"),
            "recordID": .string("message-\(number)"), "order": .number(Decimal(number)), "revision": .number(1),
            "record": .object(["type": .string("message"), "role": .string("assistant"),
                "blocks": .array([.object(["type": .string("text"), "text": .string("Page \(number)")])])])])
        var end: [String: AgentJSONValue] = ["kind": .string("page.end"), "id": request["id"]!, "thread": .string("thread"),
            "records": .number(1), "historyCursor": .string("before-\(number)"), "hasOlder": .bool(true),
            "window": .object(["lane": .string(operation == "bootstrap" ? "bootstrap" : "before"), "version": .number(version),
                "segmentID": .string("segment-\(number)"), "before": .string("before-\(number)"), "after": .string("after-\(number)"),
                "hasOlder": .bool(true), "hasNewer": .bool(operation != "bootstrap")])]
        if operation == "bootstrap" { end["hasNewer"] = .bool(false); end["liveCursor"] = .string("live-1") }
        try inject(end)
    }

    private func inject(_ fields: [String: AgentJSONValue]) throws {
        var value = fields; value["serviceEpoch"] = .string("initial-epoch")
        let frame = AgentExecFrame(carrierGeneration: 4, kind: .stdout(try AgentIngestionFramer.encode(.object(value))))!
        if let pending = waiter { waiter = nil; pending.resume(returning: frame) } else { frames.append(frame) }
    }

    func cancel() { closed = true; waiter?.resume(returning: nil); waiter = nil }
}

/// The dispatch hook runs off the main actor; the test reads this after the
/// awaited send returns.
private final class DispatchHop: @unchecked Sendable {
    var duration: Duration = .zero
}
