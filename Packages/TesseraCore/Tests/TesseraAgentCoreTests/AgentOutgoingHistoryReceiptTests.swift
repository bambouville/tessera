import XCTest
@testable import TesseraAgentCore

/// Returning from background replaces the live head. A sent prompt can then
/// be visible only in a canonical history page, with its own physical proof.
final class AgentOutgoingHistoryReceiptTests: XCTestCase {
    private struct Fixture {
        let core: AgentCenterRuntime
        let id: AgentThreadID
        let binding: AgentTerminalBinding
    }

    private func fixture(provider: AgentProviderID = .claude, transport: AgentTransportKind = .sshTmux,
                         windowed: Bool = true) async throws -> Fixture {
        let id = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "history-receipt")!
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("history-receipt")!, transport: transport,
            tmuxSession: "fixture", windowID: "@1", paneID: "%1", agentPID: 42,
            capabilities: [.observe, .send, .tmux])
        let core = AgentCenterRuntime()
        await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true,
            actions: true, spawn: false, fork: false, search: true)), binding: binding)
        let result = Fixture(core: core, id: id, binding: binding)
        if windowed {
            try await accept(result, page(.bootstrap, 1, "boot", records: [record(10, "anchor", role: "assistant", offset: 50)]))
        } else {
            try await accept(result, XCTUnwrap(AgentProjectionPage(sourceIdentity: "legacy", records: [record(1, "anchor", role: "assistant", offset: 50)], cursor: nil, hasMore: false)))
        }
        return result
    }

    private func record(_ sequence: UInt64, _ text: String, role: String = "user", offset: UInt64,
                        physical: String? = "jsonl:1:2", id: String? = nil, revision: UInt64 = 1) -> AgentProjectionRecord {
        .init(sequence: sequence, recordID: id ?? "r-\(sequence)",
            record: .object(["type": .string(role), "text": .string(text)]), sourceOffset: offset, revision: revision,
            receiptSourceIdentity: physical, receiptSourceOffset: physical == nil ? nil : offset)!
    }

    private func page(_ lane: AgentIngestionWindowTransaction.Lane, _ version: UInt64, _ name: String,
                      from: String? = nil, epoch: String = "before", records: [AgentProjectionRecord]) throws -> AgentProjectionPage {
        let history = lane == .before || lane == .after
        let transaction = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: name,
            before: name + "-before", after: name + "-after", hasOlder: true)
        return try XCTUnwrap(AgentProjectionPage(sourceIdentity: "claude-chain:\(epoch)", from: from, records: records,
            cursor: name + "-before", hasMore: true,
            ingestion: .init(epoch: epoch, requestID: name,
                operation: lane == .bootstrap ? .bootstrap : history ? .history : .updates,
                liveCursor: history ? nil : name, sourceEnd: history ? nil : 10_000, window: transaction)))
    }

    private func accept(_ fixture: Fixture, _ page: AgentProjectionPage,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await fixture.core.apply(page: page, to: fixture.id)
        XCTAssertTrue(result.accepted, "page rejected: \(result)", file: file, line: line)
    }

    @discardableResult
    private func send(_ fixture: Fixture, text: String = "same", end: UInt64 = 100,
                      unavailable: Bool = false, dispatched: Bool = true,
                      result: AgentActionResultStatus? = .verified, legacy: Bool = false) async throws -> AgentActionLease {
        let lease = try await fixture.core.acquireLease(threadID: fixture.id, action: .send, binding: fixture.binding,
            textRequest: AgentTextSendRequest(threadID: fixture.id, binding: fixture.binding,
                text: text, queueWhenWorking: false)!)
        let frontier = unavailable ? AgentOutgoingFrontier.unavailable(for: lease) :
            AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "before", provider: fixture.id.providerID,
                providerSessionID: fixture.id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: end,
                consistency: .observedPrefix)!
        if legacy {
            let boundary = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "claude-chain:before",
                records: [record(10, "anchor", role: "assistant", offset: 50)], cursor: nil, hasMore: false,
                summary: .object(["nativeReceiptEpoch": .string("before"), "nativeReceiptSourceEnd": .string("100")])))
            try await fixture.core.armOutgoing(lease, freshPage: boundary)
        } else { try await fixture.core.armOutgoing(lease, frontier: frontier) }
        if dispatched { try await fixture.core.markOutgoingDispatched(lease) }
        if let result { await fixture.core.releaseLease(lease, result: result) }
        return lease
    }

    private func resume(_ fixture: Fixture, epoch: String = "after") async throws {
        try await accept(fixture, page(.bootstrap, 1, "resume-\(epoch)", epoch: epoch,
            records: [record(30, "later agent activity", role: "assistant", offset: 400)]))
    }

    private func statuses(_ fixture: Fixture) async -> [AgentOutgoingMessage.Status] {
        await fixture.core.snapshot(for: fixture.id)?.outgoingMessages?.map(\.status) ?? []
    }

    func testBackgroundResumeSettlesAReceiptInAnOlderCanonicalPage() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        try await resume(fixture)
        let before = await statuses(fixture)
        XCTAssertEqual(before, [.awaitingReceipt])

        try await accept(fixture, page(.before, 2, "older", from: "resume-after-before", epoch: "after",
            records: [record(20, "same", offset: 150)]))

        let snapshot = await fixture.core.snapshot(for: fixture.id)
        // Feed the existing connection-free transcript scene for before/after
        // simulator captures of the exact state returned by the shared core.
        if let path = ProcessInfo.processInfo.environment["TESSERA_AGENT_RECEIPT_CAPTURE_PATH"], let snapshot {
            struct Capture: Encodable { let thread: AgentThreadSnapshot }
            try JSONEncoder().encode(Capture(thread: snapshot)).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertTrue(snapshot?.messages.contains { $0.role == .user && $0.recordID == "r-20" } == true)
        XCTAssertEqual(snapshot?.outgoingMessages?.map(\.status), [.observed],
            "the parsed prompt still has a duplicate waiting bubble after resume")
    }

    func testForwardHistoryNavigationAlsoSettlesItsOwnPhysicalReceipt() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        await fixture.core.setIngestionViewportAnchor("r-10", for: fixture.id)
        try await accept(fixture, page(.head, 2, "head", from: "boot",
            records: [record(30, "later agent activity", role: "assistant", offset: 400)]))
        let currentWindow = await fixture.core.ingestionWindowSnapshot(for: fixture.id)
        let window = try XCTUnwrap(currentWindow)
        try await accept(fixture, page(.after, 3, "forward", from: window.after,
            records: [record(20, "same", offset: 150), record(30, "later agent activity", role: "assistant", offset: 400)]))
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.observed])
    }

    func testAnOlderPhysicalReceiptStillSettlesAfterANewerSendAdvancedTheSequenceFence() async throws {
        let fixture = try await fixture()
        try await send(fixture, text: "first")
        try await resume(fixture)
        // The unavailable frontier keeps the legacy sequence watermark in
        // play, independently of the first send's physical frontier.
        try await send(fixture, text: "second", unavailable: true)
        try await accept(fixture, page(.head, 2, "newer-send", from: "resume-after", epoch: "after",
            records: [record(31, "second", offset: 500)]))
        let newer = await statuses(fixture)
        XCTAssertEqual(newer, [.awaitingReceipt, .observed])
        let currentWindow = await fixture.core.ingestionWindowSnapshot(for: fixture.id)
        let window = try XCTUnwrap(currentWindow)
        try await accept(fixture, page(.before, 3, "older-send", from: window.before, epoch: "after",
            records: [record(20, "first", offset: 150)]))
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.observed, .observed])
    }

    func testHistoricalPhysicalRecordCanSettleOnlyOneSendAcrossReaderRestarts() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        try await send(fixture)
        try await resume(fixture)
        try await accept(fixture, page(.before, 2, "first", from: "resume-after-before", epoch: "after",
            records: [record(20, "same", offset: 150)]))
        let first = await statuses(fixture)
        XCTAssertEqual(first, [.observed, .awaitingReceipt])

        try await resume(fixture, epoch: "replay")
        try await accept(fixture, page(.before, 2, "replayed", from: "resume-replay-before", epoch: "replay",
            records: [record(20, "same", offset: 150, id: "new-reader-id")]))
        let replayed = await statuses(fixture)
        XCTAssertEqual(replayed, [.observed, .awaitingReceipt])

        try await resume(fixture, epoch: "second")
        try await accept(fixture, page(.before, 2, "second", from: "resume-second-before", epoch: "second",
            records: [record(20, "same", offset: 150), record(21, "same", offset: 200)]))
        let second = await statuses(fixture)
        XCTAssertEqual(second, [.observed, .observed])
    }

    func testHistoryNeedsItsOwnMatchingPhysicalSourceAndPostFrontierOffset() async throws {
        for (identity, offset) in [("jsonl:9:9", UInt64(150)), ("jsonl:1:2", UInt64(99))] {
            let fixture = try await fixture()
            try await send(fixture)
            try await resume(fixture)
            try await accept(fixture, page(.before, 2, "unsafe", from: "resume-after-before", epoch: "after",
                records: [record(20, "same", offset: offset, physical: identity)]))
            let result = await statuses(fixture)
            XCTAssertEqual(result, [.awaitingReceipt])
        }
    }

    func testHistoryWithoutPhysicalProvenanceCannotSettleAFrontierSend() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        try await resume(fixture)
        try await accept(fixture, page(.before, 2, "legacy", from: "resume-after-before", epoch: "after",
            records: [record(20, "same", offset: 150, physical: nil)]))
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.awaitingReceipt])
    }

    func testHistoryDoesNotBroadenTheUnavailableFrontierFallback() async throws {
        let fixture = try await fixture()
        try await send(fixture, unavailable: true)
        try await resume(fixture)
        try await accept(fixture, page(.before, 2, "history", from: "resume-after-before", epoch: "after",
            records: [record(20, "same", offset: 150)]))
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.sentUnconfirmed])
    }

    func testHistoryReceiptWorksAcrossAllTransportsAndBothFileProviders() async throws {
        for provider in [AgentProviderID.claude, .codex] {
            for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
                let fixture = try await fixture(provider: provider, transport: transport)
                try await send(fixture)
                try await resume(fixture)
                try await accept(fixture, page(.before, 2, "receipt", from: "resume-after-before", epoch: "after",
                    records: [record(20, "same", offset: 150)]))
                let result = await statuses(fixture)
                XCTAssertEqual(result, [.observed], "\(provider) / \(transport)")
            }
        }
    }

    func testDifferentHeadAndHistoryRevisionsCannotExchangeTheirPhysicalProof() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        await fixture.core.setIngestionViewportAnchor("r-10", for: fixture.id)
        try await accept(fixture, page(.head, 2, "head", from: "boot",
            records: [record(20, "different text", offset: 150)]))
        let current = await fixture.core.ingestionWindowSnapshot(for: fixture.id)
        try await accept(fixture, page(.after, 3, "history", from: current?.after,
            records: [record(20, "same", offset: 150, physical: "jsonl:9:9", revision: 2)]))
        let rejected = await fixture.core.apply(page: try page(.head, 4, "head-again", from: "head",
            records: [record(20, "same", offset: 150)]), to: fixture.id)
        XCTAssertEqual(rejected, .resyncRequired, "the stale head revision must be rejected before receipt matching")
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.awaitingReceipt], "history text must not borrow the head's physical source")
    }

    func testIgnoredLegacyDuplicateCannotSupplyANewReceiptBody() async throws {
        let fixture = try await fixture(windowed: false)
        try await send(fixture)
        for revision in [UInt64(1), 2] {
            let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "legacy",
                records: [record(2, revision == 1 ? "different text" : "same", offset: 150, revision: revision)],
                cursor: nil, hasMore: false))
            try await accept(fixture, page)
        }
        let snapshot = await fixture.core.snapshot(for: fixture.id)
        XCTAssertEqual(snapshot?.outgoingMessages?.map(\.status), [.awaitingReceipt])
        XCTAssertTrue(snapshot?.messages.contains { $0.blocks == [.text("different text")] } == true)
    }

    func testHistoricalReceiptDoesNotSettleAnUndispatchedOrUnacknowledgedSend() async throws {
        for dispatched in [false, true] {
            let fixture = try await fixture()
            try await send(fixture, dispatched: dispatched, result: dispatched ? .failed : .verified)
            try await resume(fixture)
            try await accept(fixture, page(.before, 2, "not-sent", from: "resume-after-before", epoch: "after",
                records: [record(20, "same", offset: 150)]))
            let result = await statuses(fixture)
            XCTAssertEqual(result, [dispatched ? .unconfirmed : .awaitingReceipt])
        }
    }

    func testHistoryObservedBeforeDispatchOrAcknowledgmentCannotBeReplayedAsANewReceipt() async throws {
        for beforeDispatch in [true, false] {
            let fixture = try await fixture()
            let lease = beforeDispatch ? nil : try await send(fixture, result: nil)
            // Reader sequence and physical file offset are independent. Keep
            // the higher physical offset in history, outside the live head.
            try await accept(fixture, page(.before, 2, "pre-ack", from: "boot-before",
                records: [record(5, "same", offset: 150)]))
            if let lease { await fixture.core.releaseLease(lease, result: .verified) }
            else { try await send(fixture) }
            try await accept(fixture, page(.bootstrap, 1, "resume", epoch: "after",
                records: [record(30, "new head", role: "assistant", offset: 60)]))
            try await accept(fixture, page(.before, 2, "replayed", from: "resume-before", epoch: "after",
                records: [record(20, "same", offset: 150)]))
            let result = await statuses(fixture)
            XCTAssertEqual(result, [.awaitingReceipt])
        }
    }

    func testHistoryFenceSurvivesWindowReplacementBeforeDispatchOrAcknowledgment() async throws {
        for beforeDispatch in [true, false] {
            let fixture = try await fixture()
            let lease = try await send(fixture, dispatched: !beforeDispatch, result: nil)
            try await accept(fixture, page(.before, 2, "pre-ack", from: "boot-before",
                records: [record(5, "same", offset: 150)]))
            // Replace the window before either dispatch or its final ACK.
            // The offset already observed must outlive the evicted page.
            try await accept(fixture, page(.bootstrap, 1, "resume", epoch: "after",
                records: [record(30, "new head", role: "assistant", offset: 60)]))
            if beforeDispatch { try await fixture.core.markOutgoingDispatched(lease) }
            await fixture.core.releaseLease(lease, result: .verified)
            try await accept(fixture, page(.before, 2, "replayed", from: "resume-before", epoch: "after",
                records: [record(20, "same", offset: 150)]))
            let replayed = await statuses(fixture)
            XCTAssertEqual(replayed, [.awaitingReceipt], "an evicted pre-ACK record must remain fenced")

            try await accept(fixture, page(.bootstrap, 1, "own", epoch: "own",
                records: [record(30, "new head", role: "assistant", offset: 60)]))
            try await accept(fixture, page(.before, 2, "own-receipt", from: "own-before", epoch: "own",
                records: [record(21, "same", offset: 200)]))
            let own = await statuses(fixture)
            XCTAssertEqual(own, [.observed], "a newer receipt must still settle the send")
        }
    }

    func testVeryLongConversationKeepsOnlyTheBoundedWindowWhileWaitingForHistory() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        // The source has advanced by a million records. Only accepted pages
        // enter Core; resolving the send must not need the intervening log.
        for pass in 0..<80 {
            let start = UInt64(1_000_000 + pass * 100)
            let records = (0..<100).map { record(start + UInt64($0), "continued work", role: "assistant", offset: start + UInt64($0)) }
            try await accept(fixture, page(.bootstrap, 1, "long-\(pass)", epoch: "long-\(pass)", records: records))
            let snapshot = await fixture.core.snapshot(for: fixture.id)
            XCTAssertEqual(snapshot?.messages.count, 100)
            XCTAssertEqual(snapshot?.outgoingMessages?.map(\.status), [.awaitingReceipt])
            XCTAssertEqual(snapshot?.ingestionWindow?.viewportSegmentIDs.count, 1)
        }
        try await accept(fixture, page(.before, 2, "receipt", from: "long-79-before", epoch: "long-79",
            records: [record(20, "same", offset: 150)]))
        let snapshot = await fixture.core.snapshot(for: fixture.id)
        XCTAssertEqual(snapshot?.messages.count, 101)
        XCTAssertEqual(snapshot?.outgoingMessages?.map(\.status), [.observed])
        XCTAssertEqual(snapshot?.ingestionWindow?.viewportSegmentIDs.count, 2)
    }

    func testMixedLegacyAndPhysicalSendsClaimEachHeadRecordOnlyOnceInSendOrder() async throws {
        for legacyFirst in [true, false] {
            let fixture = try await fixture()
            try await send(fixture, legacy: legacyFirst)
            try await send(fixture, legacy: !legacyFirst)
            let records = [record(10, "anchor", role: "assistant", offset: 50), record(20, "same", offset: 150)]
            try await accept(fixture, page(.head, 2, "receipt", from: "boot", records: records))
            let first = await statuses(fixture)
            XCTAssertEqual(first, legacyFirst ? [.awaitingReceipt] : [.observed, .awaitingReceipt])
            try await accept(fixture, page(.head, 3, "replay", from: "receipt", records: records))
            let replay = await statuses(fixture)
            XCTAssertEqual(replay, first, "a held head replay must not settle the other identical send")
            if legacyFirst {
                try await resume(fixture)
                try await accept(fixture, page(.before, 2, "history-replay", from: "resume-after-before", epoch: "after",
                    records: [record(20, "same", offset: 150)]))
                let restarted = await statuses(fixture)
                XCTAssertEqual(restarted, [.awaitingReceipt], "a removed legacy receipt must remain claimed across restart")
            }
        }
    }

    func testReceiptClaimSurvivesEvictionOfItsObservedOutgoingBubble() async throws {
        let fixture = try await fixture()
        try await send(fixture)
        try await send(fixture)
        let anchor = record(10, "anchor", role: "assistant", offset: 50)
        let claimed = record(20, "same", offset: 150)
        try await accept(fixture, page(.head, 2, "receipt", from: "boot", records: [anchor, claimed]))
        for index in 0..<31 { try await send(fixture, text: "filler \(index)", end: 500) }
        let before = await statuses(fixture)
        XCTAssertEqual(before.count, 32)
        XCTAssertEqual(before.first, .awaitingReceipt)
        try await accept(fixture, page(.head, 3, "replay", from: "receipt",
            records: [anchor, claimed, record(30, "more work", role: "assistant", offset: 400)]))
        let replayed = await statuses(fixture)
        XCTAssertEqual(replayed.first, .awaitingReceipt, "evicting its claimant must not reuse a receipt")
        try await accept(fixture, page(.head, 4, "own-receipt", from: "replay",
            records: [anchor, claimed, record(21, "same", offset: 200), record(30, "more work", role: "assistant", offset: 400)]))
        let own = await statuses(fixture)
        XCTAssertEqual(own.first, .observed)
    }

    func testThirtyTwoIdenticalSendsKeepTheMaximumReceiptExclusionsBoundedAndExclusive() async throws {
        let fixture = try await fixture()
        for _ in 0..<32 { try await send(fixture) }
        let anchor = record(10, "anchor", role: "assistant", offset: 50)
        let receipts: [AgentProjectionRecord] = (0..<31).map { (index: Int) in
            let sequence = UInt64(20 + index)
            let offset = UInt64(150 + index * 10)
            return record(sequence, "same", offset: offset)
        }
        try await accept(fixture, page(.head, 2, "receipts", from: "boot", records: [anchor] + receipts))
        let first = await statuses(fixture)
        XCTAssertEqual(first, Array(repeating: .observed, count: 31) + [.awaitingReceipt])
        // The last waiting send now owns all 31 possible predecessor claims.
        // Drop every predecessor bubble, then replay the same physical rows.
        for index in 0..<31 { try await send(fixture, text: "different \(index)", end: 1_000) }
        let tail = record(1_000, "continued work", role: "assistant", offset: 2_000)
        try await accept(fixture, page(.head, 3, "replay", from: "receipts", records: [anchor] + receipts + [tail]))
        let replay = await statuses(fixture)
        XCTAssertEqual(replay.count, 32)
        XCTAssertEqual(replay.first, .awaitingReceipt)
        try await accept(fixture, page(.head, 4, "own", from: "replay",
            records: [anchor] + receipts + [record(60, "same", offset: 500), tail]))
        let own = await statuses(fixture)
        XCTAssertEqual(own.first, .observed)
    }

    func testLegacyReceiptCannotBeReclaimedByAnImageSendDuringItsDepartureCheck() async throws {
        for unavailable in [false, true] {
            for physical in [false, true] {
                let fixture = try await fixture()
                let text = "Describe\n\"/tmp/a.png\""
                try await send(fixture, text: text, legacy: true)
                let active = try await send(fixture, text: text, unavailable: unavailable, result: nil)
                let image = AgentProjectionRecord(sequence: 20, recordID: "image", record: .object([
                    "type": .string("message"), "provider": .string("claude"), "role": .string("user"), "blocks": .array([
                        .object(["type": .string("text"), "text": .string("Describe\n[Image #42]")]),
                        .object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")])
                    ])]), sourceOffset: 150, receiptSourceIdentity: physical ? "jsonl:1:2" : nil, receiptSourceOffset: physical ? 150 : nil)!
                try await accept(fixture, page(.head, 2, "image", from: "boot",
                    records: [record(10, "anchor", role: "assistant", offset: 50), image]))
                await fixture.core.releaseLease(active, result: .verified)
                let result = await statuses(fixture)
                XCTAssertEqual(result, [unavailable ? .sentUnconfirmed : .awaitingReceipt], "the departure check must not reuse the removed legacy send's image receipt")
            }
        }
    }

    func testHistoryCannotRewriteABridgedRecordAndBorrowItsCachedText() async throws {
        let fixture = try await fixture()
        func records(_ range: Range<Int>) -> [AgentProjectionRecord] {
            range.map { record(UInt64($0), $0 == 10 ? "same" : "work", role: $0 == 10 ? "user" : "assistant", offset: $0 == 10 ? 50 : UInt64($0 + 10)) }
        }
        try await accept(fixture, page(.bootstrap, 1, "bridge-0", records: records(0..<10)))
        for roll in 1...3 {
            try await accept(fixture, page(.head, UInt64(roll + 1), "bridge-\(roll)", from: "bridge-\(roll - 1)",
                records: records((roll * 5)..<(roll * 5 + 10))))
        }
        let before = await fixture.core.ingestionWindowSnapshot(for: fixture.id)
        XCTAssertEqual(before?.bridgesToHead, true)
        try await send(fixture)
        let rejected = await fixture.core.apply(page: try page(.after, 5, "unsafe", from: before?.after,
            records: [record(10, "different text", offset: 150)]), to: fixture.id)
        XCTAssertEqual(rejected, .resyncRequired)
        let result = await statuses(fixture)
        XCTAssertEqual(result, [.awaitingReceipt])
    }
}
