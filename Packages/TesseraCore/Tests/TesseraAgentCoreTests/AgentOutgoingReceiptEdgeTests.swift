import XCTest
@testable import TesseraAgentCore

/// Receipt edges of sends without a usable frontier, and of frontier sends
/// across reader restarts: each once settled the wrong send or none.
final class AgentOutgoingReceiptEdgeTests: XCTestCase {
    private let hostID = UUID()
    private let sessionID = UUID()
    private func thread(_ provider: AgentProviderID = .claude) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: "receipt-edge")!
    }
    private func binding(_ generation: UInt64 = 1) -> AgentTerminalBinding {
        .init(liveSessionID: sessionID, carrierGeneration: generation, incarnation: AgentIncarnationToken("receipt-edge")!,
              transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
    }
    private func runtime(_ id: AgentThreadID) async -> AgentCenterRuntime {
        let core = AgentCenterRuntime()
        await core.register(.init(id: id, providerName: id.providerID.rawValue, availability: .init(content: true, status: true,
            actions: true, spawn: false, fork: false, search: true)), binding: binding())
        return core
    }
    private func record(_ sequence: UInt64, _ type: String, _ text: String, id: String? = nil,
                        offset: UInt64? = nil, receipt: String? = nil) -> AgentProjectionRecord {
        .init(sequence: sequence, recordID: id ?? "r-\(sequence)", record: .object(["type": .string(type), "text": .string(text)]),
              sourceOffset: offset, receiptSourceIdentity: offset == nil ? nil : receipt, receiptSourceOffset: offset == nil ? nil : offset)!
    }
    private func window(_ lane: AgentIngestionWindowTransaction.Lane, _ version: UInt64, _ name: String, from: String?,
                        live: String, _ records: [AgentProjectionRecord], epoch: String = "epoch",
                        source: String, hasOlder: Bool = false) throws -> AgentProjectionPage {
        let tx = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: name,
            before: name + "-before", after: name + "-after", hasOlder: hasOlder)
        return AgentProjectionPage(sourceIdentity: source, from: from, records: records,
            cursor: hasOlder ? name + "-before" : nil, hasMore: hasOlder,
            ingestion: .init(epoch: epoch, requestID: name, operation: lane == .bootstrap ? .bootstrap : .updates,
                liveCursor: live, sourceEnd: 10_000, window: tx))!
    }
    @discardableResult
    private func unavailableSend(_ core: AgentCenterRuntime, _ id: AgentThreadID, text: String = "same") async throws -> AgentActionLease {
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: text, queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        return lease
    }
    private func statuses(_ core: AgentCenterRuntime, _ id: AgentThreadID) async -> [AgentOutgoingMessage.Status]? {
        await core.snapshot(for: id)?.outgoingMessages?.map(\.status)
    }

    private func accept(_ core: AgentCenterRuntime, _ id: AgentThreadID, _ page: AgentProjectionPage,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await core.apply(page: page, to: id)
        XCTAssertTrue(result.accepted, "page rejected: \(result)", file: file, line: line)
    }

    /// A send before the thread loaded, then its first legacy page: the
    /// newest page of an existing transcript, which does not reach the start.
    /// Its only prompt predates the send. Reconciling before the page's
    /// `hasMore` landed read it as the whole transcript.
    func testLegacyNewestPageDoesNotCountAsHeldFromStart() async throws {
        let id = thread()
        let core = await runtime(id)
        try await unavailableSend(core, id)
        let newest = AgentProjectionPage(sourceIdentity: "1:2:a:1", records: [
            record(50, "user", "same"), record(51, "assistant", "reply to the OLD prompt"),
        ], cursor: "older", hasMore: true)!
        _ = await core.apply(page: newest, to: id)
        let result = await statuses(core, id)
        XCTAssertEqual(result, [.sentUnconfirmed], "an old prompt on a page that does not reach the start settled the send")
    }

    /// Two identical sends whose frontiers both precede record A; A settles
    /// the first. A restarted reader (new epoch and chain generation)
    /// delivers A again, and the sequence fence keyed by the old generation
    /// no longer applies. The physical record stays claimed.
    func testReaderRestartDoesNotLetOneRecordSettleTwoFrontierSends() async throws {
        let id = thread()
        let core = await runtime(id)
        func page(_ request: String, _ from: String?, _ records: [(UInt64, UInt64, String)], epoch: String, source: String) -> AgentProjectionPage {
            .init(sourceIdentity: source, from: from, records: records.map { order, offset, text in
                .init(sequence: order, recordID: "\(source)-\(order)", record: .object(["type": .string("user"), "text": .string(text)]),
                      sourceOffset: offset, receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: offset)!
            }, cursor: nil, hasMore: false, ingestion: .init(epoch: epoch, requestID: request,
                operation: from == nil ? .bootstrap : .updates, liveCursor: request, sourceEnd: 1_000))!
        }
        _ = await core.apply(page: page("old", nil, [(1, 0, "anchor")], epoch: "e1", source: "claude-chain:g1"), to: id)
        for _ in 0..<2 {
            let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
                textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
            try await core.armOutgoing(lease, frontier: AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "e1",
                provider: id.providerID, providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: 100,
                consistency: .observedPrefix)!)
            try await core.markOutgoingDispatched(lease)
            await core.releaseLease(lease, result: .verified)
        }
        _ = await core.apply(page: page("a", "old", [(2, 150, "same")], epoch: "e1", source: "claude-chain:g1"), to: id)
        let afterA = await statuses(core, id)
        XCTAssertEqual(afterA, [.observed, .awaitingReceipt])
        // Reader restart: same file, same physical record A, new epoch and generation.
        _ = await core.apply(page: page("restart", nil, [(1, 0, "anchor"), (2, 150, "same")], epoch: "e2", source: "claude-chain:g2"), to: id)
        let afterReplay = await statuses(core, id)
        XCTAssertEqual(afterReplay, [.observed, .awaitingReceipt], "a replayed record settled a second send")
    }

    /// A loaded transcript with no record yet (a new OpenCode session, whose
    /// frontier is always unavailable, or any empty one whose frontier timed
    /// out): every record is newer than the send's ACK.
    func testUnavailableSendIntoAnEmptyBootstrappedTranscriptSettles() async throws {
        for provider in [AgentProviderID.opencode, .claude] {
            let id = thread(provider)
            let core = await runtime(id)
            let source = provider == .opencode ? "opencode-sqlite:1:2:review:messages" : "claude-chain:g1"
            try await accept(core, id, window(.bootstrap, 1, "boot", from: nil, live: "c1", [], source: source))
            try await unavailableSend(core, id)
            try await accept(core, id, window(.head, 2, "head1", from: "c1", live: "c2",
                [record(1 << 52, "user", "same"), record((1 << 52) + 1, "assistant", "ok")], source: source))
            let result = await statuses(core, id)
            XCTAssertEqual(result, [.observed], "provider=\(provider.rawValue): own first record never settles a send into an empty transcript")
        }
    }

    /// A new conversation after `/clear`: no source at dispatch, and its
    /// first window, already holding this prompt, lands before the platform
    /// releases the lease (the terminal ACK is followed by submission
    /// verification and an actor hop). Fencing at that window at the ACK
    /// excluded the send's own prompt.
    func testFirstBootstrapLandingBeforeTheAckDoesNotStrandTheFirstPrompt() async throws {
        let id = thread()
        let core = await runtime(id)
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        try await accept(core, id, window(.bootstrap, 1, "boot", from: nil, live: "c1",
            [record(0, "user", "same"), record(1, "assistant", "on it")], source: "claude-chain:new"))
        await core.releaseLease(lease, result: .verified)
        try await accept(core, id, window(.head, 2, "head1", from: "c1", live: "c2",
            [record(0, "user", "same"), record(1, "assistant", "on it"), record(2, "assistant", "done")], source: "claude-chain:new"))
        let result = await statuses(core, id)
        XCTAssertEqual(result, [.observed], "the opening prompt that arrived before the ACK can never settle the send")
    }
}
