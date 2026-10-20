import XCTest
@testable import TesseraAgentCore

final class AgentAttentionTargetsTests: XCTestCase {
    private let hostID = UUID(uuidString: "A77E0000-0000-4000-8000-000000000001")!

    func testClassificationNeverCountsAWaitingThreadAsFinished() {
        XCTAssertEqual(AgentAttentionKind(summary("a", attention: .needsYou)), .needsInput)
        XCTAssertEqual(AgentAttentionKind(summary("b", status: .waitingForInput)), .needsInput)
        XCTAssertEqual(AgentAttentionKind(summary("c", status: .waitingForInput, attention: .unreadCompletion)), .needsInput)
        XCTAssertEqual(AgentAttentionKind(summary("d", status: .finished, attention: .unreadCompletion)), .finished)
        XCTAssertEqual(AgentAttentionKind(summary("e", status: .idle, attention: .unreadCompletion)), .finished)
        XCTAssertNil(AgentAttentionKind(summary("f", status: .finished)))
        XCTAssertNil(AgentAttentionKind(summary("g", status: .working)))

        let threads = [
            summary("a", attention: .needsYou),
            summary("c", status: .waitingForInput, attention: .unreadCompletion),
            summary("d", status: .finished, attention: .unreadCompletion),
            summary("e", status: .idle, attention: .unreadCompletion),
            summary("f", status: .finished),
        ]
        let counts = AgentAttentionCounts(threads: threads)
        XCTAssertEqual(counts, AgentAttentionCounts(needsInput: 2, finished: 2))
        XCTAssertEqual(counts.total, 4)

        // The chip's count and the rows behind it come from one classifier.
        let entries = AgentAttentionTargets.entries(threads: threads, binding: { _ in nil }, isLive: { _, _ in true })
        XCTAssertEqual(entries.count, counts.total)
        XCTAssertEqual(entries.filter { $0.kind == .needsInput }.count, counts.needsInput)
        XCTAssertEqual(entries.filter { $0.kind == .finished }.count, counts.finished)
    }

    func testNeedsInputListsFirstThenNewestWithinEachKind() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threads = [
            summary("finished-old", status: .finished, attention: .unreadCompletion, lastActivity: now.addingTimeInterval(-600)),
            summary("finished-new", status: .finished, attention: .unreadCompletion, lastActivity: now),
            summary("waiting-old", attention: .needsYou, lastActivity: now.addingTimeInterval(-900)),
            summary("finished-undated", status: .finished, attention: .unreadCompletion, lastActivity: nil),
            summary("finished-seq-low", status: .finished, attention: .unreadCompletion, lastActivity: now.addingTimeInterval(-60), sequence: 1),
            summary("finished-seq-high", status: .finished, attention: .unreadCompletion, lastActivity: now.addingTimeInterval(-60), sequence: 9),
            summary("idle", status: .idle, lastActivity: now.addingTimeInterval(60)),
        ]
        let order = AgentAttentionTargets.entries(threads: threads, binding: { _ in nil }, isLive: { _, _ in false })
            .map(\.threadID.providerSessionID)
        XCTAssertEqual(order, [
            "waiting-old",
            "finished-new",
            "finished-seq-high",
            "finished-seq-low",
            "finished-old",
            "finished-undated",
        ])
        // Input order must not leak into the result.
        let reversed = AgentAttentionTargets.entries(threads: threads.reversed(), binding: { _ in nil }, isLive: { _, _ in false })
            .map(\.threadID.providerSessionID)
        XCTAssertEqual(reversed, order)
    }

    func testLiveBindingTargetsTheExactTerminalOnAllFourTransports() {
        let sessionID = UUID()
        let cases: [(AgentTransportKind, String?, String?)] = [
            (.ssh, nil, nil),
            (.sshTmux, "3", "21"),
            (.mosh, nil, nil),
            (.moshTmux, "4", "7"),
        ]
        for (transport, windowID, paneID) in cases {
            let finished = summary("agent-\(transport.rawValue)", status: .finished, attention: .unreadCompletion)
            let binding = makeBinding(sessionID: sessionID, transport: transport, windowID: windowID, paneID: paneID)
            var consulted: [AgentThreadID] = []
            let entries = AgentAttentionTargets.entries(
                threads: [finished],
                binding: { $0 == finished.id ? binding : nil },
                isLive: { id, candidate in
                    consulted.append(id)
                    return candidate == binding
                }
            )
            XCTAssertEqual(entries.count, 1, transport.rawValue)
            let entry = entries[0]
            XCTAssertEqual(entry.kind, .finished, transport.rawValue)
            XCTAssertEqual(entry.destination, .terminal(binding), transport.rawValue)
            XCTAssertEqual(entry.terminalBinding?.liveSessionID, sessionID, transport.rawValue)
            XCTAssertEqual(entry.terminalBinding?.windowID, windowID, transport.rawValue)
            XCTAssertEqual(entry.terminalBinding?.paneID, paneID, transport.rawValue)
            XCTAssertEqual(entry.lastKnownBinding, binding, transport.rawValue)
            XCTAssertEqual(entry.title, finished.title, transport.rawValue)
            XCTAssertEqual(entry.providerName, finished.providerName, transport.rawValue)
            XCTAssertEqual(entry.hostDisplayLabel, finished.hostDisplayLabel, transport.rawValue)
            XCTAssertEqual(consulted, [finished.id], transport.rawValue)
        }
    }

    func testGoneOrDisconnectedTerminalFallsBackToAgentCenterWithoutLosingItsLocation() {
        let sessionID = UUID()
        let stale = summary("stale", status: .finished, attention: .unreadCompletion)
        let unbound = summary("unbound", status: .finished, attention: .unreadCompletion)
        let staleBinding = makeBinding(sessionID: sessionID, transport: .sshTmux, windowID: "2", paneID: "9")
        var consulted: [AgentThreadID] = []
        let entries = AgentAttentionTargets.entries(
            threads: [stale, unbound],
            binding: { $0 == stale.id ? staleBinding : nil },
            isLive: { id, _ in
                consulted.append(id)
                return false
            }
        )
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.threadID, $0) })
        XCTAssertEqual(byID[stale.id]?.destination, .agentCenter)
        XCTAssertNil(byID[stale.id]?.terminalBinding)
        XCTAssertEqual(byID[stale.id]?.lastKnownBinding, staleBinding)
        XCTAssertEqual(byID[unbound.id]?.destination, .agentCenter)
        XCTAssertNil(byID[unbound.id]?.lastKnownBinding)
        // Liveness is asked only about a binding that exists.
        XCTAssertEqual(consulted, [stale.id])
    }

    /// Opening a pane re-proves the agent's process there. A binding observed
    /// without a process ID can never pass that proof, so it must not be
    /// offered as a jump even while its route is live.
    func testBindingWithoutAProcessIDIsReviewableButNeverAJumpTarget() {
        let sessionID = UUID()
        let observed = summary("observed", status: .finished, attention: .unreadCompletion)
        let proven = summary("proven", status: .finished, attention: .unreadCompletion)
        let observedBinding = makeBinding(sessionID: sessionID, transport: .moshTmux, windowID: "1", paneID: "4", agentPID: nil)
        let provenBinding = makeBinding(sessionID: sessionID, transport: .moshTmux, windowID: "1", paneID: "5")
        let entries = AgentAttentionTargets.entries(
            threads: [observed, proven],
            binding: { $0 == observed.id ? observedBinding : provenBinding },
            isLive: { _, _ in true }
        )
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.threadID, $0) })
        XCTAssertEqual(byID[observed.id]?.destination, .agentCenter)
        XCTAssertEqual(byID[observed.id]?.lastKnownBinding, observedBinding)
        XCTAssertEqual(byID[proven.id]?.destination, .terminal(provenBinding))
    }

    func testNoAttentionMeansNoRows() {
        let entries = AgentAttentionTargets.entries(
            threads: [summary("idle", status: .idle), summary("working", status: .working)],
            binding: { _ in XCTFail("no row should look up a binding"); return nil },
            isLive: { _, _ in XCTFail("no row should check liveness"); return true }
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(AgentAttentionCounts(threads: []).total, 0)
    }

    private func summary(
        _ session: String,
        status: AgentStatus = .idle,
        attention: AgentAttention = .none,
        lastActivity: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        sequence: UInt64 = 0
    ) -> AgentThreadSummary {
        AgentThreadSummary(
            id: AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: session)!,
            title: "title \(session)",
            providerName: "Claude Code",
            hostDisplayLabel: "fixture host",
            status: status,
            attention: attention,
            lastActivitySequence: sequence,
            lastActivity: lastActivity,
            availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: false)
        )
    }

    private func makeBinding(
        sessionID: UUID,
        transport: AgentTransportKind,
        windowID: String?,
        paneID: String?,
        agentPID: Int? = 42
    ) -> AgentTerminalBinding {
        let tmux = windowID != nil || paneID != nil
        return AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("incarnation-\(transport.rawValue)")!,
            transport: transport,
            tmuxSession: tmux ? "fixture" : nil,
            windowID: windowID,
            paneID: paneID,
            agentPID: agentPID,
            capabilities: tmux ? [.observe, .send, .tmux] : [.observe, .send]
        )
    }
}
