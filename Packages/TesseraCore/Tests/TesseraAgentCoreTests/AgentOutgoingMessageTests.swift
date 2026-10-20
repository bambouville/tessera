import XCTest
@testable import TesseraAgentCore

final class AgentOutgoingMessageTests: XCTestCase {
    func testSendAnywayKeepsTranscriptParsingAndRequiresANewReceipt() async throws {
        for provider in [AgentProviderID.codex, .claude] {
            for verification in [AgentComposerVerification.required, .userOverride] {
                let thread = AgentThreadID(hostID: id.hostID, providerID: provider, providerSessionID: "send-anyway-receipt")!
                let core = AgentCenterRuntime()
                await core.register(.init(id: thread, providerName: provider.rawValue,
                    availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding())
                _ = await core.apply(page: page([(1, "same")]), to: thread)
                let request = try XCTUnwrap(AgentTextSendRequest(threadID: thread, binding: binding(), text: "same",
                    queueWhenWorking: false, composerVerification: verification))
                let lease = try await core.acquireLease(threadID: thread, action: .send, binding: binding(), textRequest: request)
                try await core.armOutgoing(lease, freshPage: page([(1, "same")]))
                try await core.markOutgoingDispatched(lease)
                await core.releaseLease(lease, result: .verified)
                let pending = await core.snapshot(for: thread)
                XCTAssertEqual(pending?.outgoingMessages?.map(\.status), [.awaitingReceipt])
                _ = await core.apply(page: page([(1, "same")], source: "b"), to: thread)
                let unchanged = await core.snapshot(for: thread)
                XCTAssertEqual(unchanged?.outgoingMessages?.map(\.status), [.awaitingReceipt])
                _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "c"), to: thread)
                let snapshot = await core.snapshot(for: thread)
                XCTAssertEqual(snapshot?.outgoingMessages, [])
                XCTAssertEqual(snapshot?.messages.count, 2, "Transcript parsing continues for \(verification)")
            }
        }
    }

    func testArmedButUndispatchedIdenticalRecordCannotAcknowledgeSend() async throws {
        let core = await runtime()
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        try await core.armOutgoing(lease, freshPage: page([(1, "anchor")]))
        _ = await core.apply(page: page([(1, "anchor"), (2, "same")], source: "b"), to: id)
        await assertPending(core, [.sending])
    }
    func testMemoryWarningKeepsUnconfirmedIntentUntilExplicitDisable() async throws {
        let core = await runtime()
        _ = try await send(core)
        await core.memoryWarning()
        await assertPending(core, [.unconfirmed])
        await core.setEnabled(false)
        await assertPending(core, [])
    }
    func testNativeReceiptsExcludePartialPreSendLineAndAcceptRevisedStableAnchor() async throws {
        for source in ["jsonl:1:2", "claude-chain:test", "codex-history:test", "codex-appserver:test"] {
            let fileBacked = !source.hasPrefix("codex-appserver:")
            let core = await runtime()
            func native(_ operation: AgentIngestionRange.Operation, _ request: String, _ from: String?, _ live: String,
                        _ records: [(UInt64, UInt64, String)], end: UInt64 = 100) -> AgentProjectionPage {
                .init(sourceIdentity: source, from: from, records: records.map { order, revision, text in
                    .init(sequence: AgentIngestionSourceIdentity.indexedFile(source) ? order / 50 : order, recordID: "native-\(order)",
                          record: .object(["type": .string("user"), "text": .string(text)]),
                          sourceOffset: AgentIngestionSourceIdentity.indexedFile(source) ? order : nil, revision: revision)!
                }, cursor: nil, hasMore: false, ingestion: .init(epoch: "epoch", requestID: request,
                    operation: operation, liveCursor: live, sourceEnd: fileBacked ? end : nil))!
            }
            _ = await core.apply(page: native(.bootstrap, "boot", nil, "c1", [(0, 1, "anchor")]), to: id)
            let caughtUp = native(.updates, "fresh", "c1", "c2", [])
            _ = await core.apply(page: caughtUp, to: id)
            let boundary = try await core.nativeReceiptBoundary(for: id, after: caughtUp)
            let lease = try await send(core, boundary: boundary)
            if fileBacked {
                // Bytes 50..<100 existed before Send, but had no newline.
                _ = await core.apply(page: native(.updates, "partial", "c2", "c3", [(50, 1, "same")], end: 150), to: id)
                await assertPending(core, [.sending])
            }
            let from = fileBacked ? "c3" : "c2"
            _ = await core.apply(page: native(.updates, "new", from, "c4", [(0, 2, "revised anchor"), (150, 1, "same")], end: 200), to: id)
            await assertPending(core, [])
            await core.releaseLease(lease, result: .verified)
        }
    }

    func testNativeJSONLReceiptRequiresRawEOFAndCaughtUpUpdates() async throws {
        let core = await runtime()
        let boot = AgentProjectionPage(sourceIdentity: "jsonl:1:2", records: [], cursor: nil, hasMore: false,
            ingestion: .init(epoch: "epoch", requestID: "boot", operation: .bootstrap, liveCursor: "c1"))!
        _ = await core.apply(page: boot, to: id)
        for (index, hasNewer) in [false, true].enumerated() {
            let page = AgentProjectionPage(sourceIdentity: "jsonl:1:2", from: "c\(index + 1)", records: [], cursor: nil, hasMore: false,
                ingestion: .init(epoch: "epoch", requestID: "up\(index)", operation: .updates,
                    liveCursor: "c\(index + 2)", hasNewer: hasNewer, sourceEnd: hasNewer ? 100 : nil))!
            _ = await core.apply(page: page, to: id)
            do { _ = try await core.nativeReceiptBoundary(for: id, after: page); XCTFail("unsafe receipt") }
            catch { XCTAssertEqual(error as? AgentActionError, .verificationFailed) }
        }
    }

    func testHistoryCannotBorrowLiveHeadOffsetToAcknowledgeSend() async throws {
        let core = await runtime()
        func record(_ name: String, _ order: UInt64, _ offset: UInt64, _ revision: UInt64, _ text: String) -> AgentProjectionRecord {
            .init(sequence: order, recordID: name, record: .object(["type": .string("user"), "text": .string(text)]),
                sourceOffset: offset, revision: revision)!
        }
        func page(_ lane: AgentIngestionWindowTransaction.Lane, _ version: UInt64, _ name: String,
                  _ from: String?, _ live: String?, _ records: [AgentProjectionRecord], _ end: UInt64?) throws -> AgentProjectionPage {
            let history = lane == .before || lane == .after
            let tx = try AgentIngestionWindowTransaction(lane: lane, version: version,
                segmentID: lane == .revisions ? nil : name, before: lane == .revisions ? nil : name + "before",
                after: lane == .revisions ? nil : name + "after", hasOlder: lane != .revisions)
            return .init(sourceIdentity: "codex-history:fixture", from: from, records: records,
                cursor: history || lane == .bootstrap ? name + "before" : nil, hasMore: history || lane == .bootstrap,
                ingestion: .init(epoch: "epoch", requestID: name, operation: lane == .bootstrap ? .bootstrap : history ? .history : .updates,
                    liveCursor: live, sourceEnd: end, window: tx))!
        }
        let anchor = record("anchor", 10, 200, 1, "anchor")
        _ = await core.apply(page: try page(.bootstrap, 1, "head", nil, "c1",
            [record("prior", 9, 190, 1, "prior"), anchor], 300), to: id)
        _ = await core.apply(page: try page(.before, 2, "old", "headbefore", nil,
            [record("olditem", 1, 10, 1, "old")], nil), to: id)
        await core.setIngestionViewportAnchor("olditem", for: id)
        let fresh = try page(.revisions, 3, "fresh", "c1", "c2", [], 300)
        _ = await core.apply(page: fresh, to: id)
        let boundary = try await core.nativeReceiptBoundary(for: id, after: fresh)
        let lease = try await send(core, boundary: boundary)
        _ = await core.apply(page: try page(.head, 4, "newhead", "c2", "c3",
            [anchor, record("newitem", 11, 310, 2, "different")], 400), to: id)
        let before = await core.ingestionWindowSnapshot(for: id)!
        XCTAssertTrue(before.retainsOutgoing)
        let invalid = try page(.after, 5, "invalid", before.after, nil,
            [record("newitem", 11, 100, 3, "same")], nil)
        let rejected = await core.apply(page: invalid, to: id)
        XCTAssertEqual(rejected, .resyncRequired)
        let unchanged = await core.ingestionWindowSnapshot(for: id)
        XCTAssertEqual(unchanged, before)
        // Even a valid, newer history snapshot cannot supply a send receipt.
        let newerHistory = try page(.after, 5, "later", before.after, nil,
            [record("newitem", 11, 410, 3, "same")], nil)
        let accepted = await core.apply(page: newerHistory, to: id)
        XCTAssertTrue(accepted.accepted)
        let after = await core.ingestionWindowSnapshot(for: id)
        XCTAssertTrue(after!.retainsOutgoing)
        // Nor may an empty live tick combine that history body with the old head offset.
        _ = await core.apply(page: try page(.revisions, 6, "tick", "c3", "c4", [], 500), to: id)
        let tick = await core.ingestionWindowSnapshot(for: id)
        XCTAssertTrue(tick!.retainsOutgoing)
        _ = await core.apply(page: try page(.revisions, 7, "canonical", "c4", "c5",
            [record("newitem", 11, 410, 3, "same")], 500), to: id)
        let confirmed = await core.ingestionWindowSnapshot(for: id)
        XCTAssertFalse(confirmed!.retainsOutgoing)
        await core.releaseLease(lease, result: .verified)
    }

    func testByteBoundaryRequiresNewOffsetAndExactRawAnchorHash() async throws {
        let core = await runtime()
        let anchorHash = String(repeating: "a", count: 64)
        func record(_ sequence: UInt64, _ offset: UInt64, _ text: String, hash: String = String(repeating: "a", count: 64)) -> AgentProjectionRecord {
            .init(sequence: sequence, recordID: "r-\(sequence)-\(offset)-\(hash)", record: .object(["type": .string("user"), "text": .string(text)]), sourceOffset: offset, sourceHash: hash)!
        }
        let boundary = AgentProjectionPage(sourceIdentity: "1:2:64:1", records: [record(0, 50, "anchor")], cursor: nil, hasMore: false,
            summary: .object(["receiptByteOffset": .string("100")]))!
        _ = try await send(core, boundary: boundary)
        for (version, (hash, receiptOffset, expected)) in [(String(repeating: "b", count: 64), UInt64(100), 1), (anchorHash, UInt64(75), 1), (anchorHash, UInt64(100), 0)].enumerated() {
            let fresh = AgentProjectionPage(sourceIdentity: "1:2:c8:\(version + 2)", records: [record(1, 50, "anchor", hash: hash), record(2, receiptOffset, "same")], cursor: nil, hasMore: false)!
            _ = await core.apply(page: fresh, to: id)
            let snapshot = await core.snapshot(for: id)
            XCTAssertEqual(snapshot?.outgoingMessages?.count, expected)
        }
    }
    private func frontier(_ lease: AgentActionLease, end: UInt64 = 100, identity: String = "jsonl:1:2") -> AgentOutgoingFrontier {
        AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "epoch", provider: id.providerID,
            providerSessionID: id.providerSessionID, sourceIdentity: identity, sourceEnd: end, consistency: .observedPrefix)!
    }
    private func frontierPage(_ request: String, _ from: String?, _ records: [(UInt64, UInt64, String)],
                              identity: String = "jsonl:1:2", epoch: String = "epoch",
                              source: String = "claude-chain:generation") -> AgentProjectionPage {
        .init(sourceIdentity: source, from: from, records: records.map { order, offset, text in
            .init(sequence: order, recordID: "physical-\(order)", record: .object(["type": .string("user"), "text": .string(text)]),
                sourceOffset: offset, receiptSourceIdentity: identity, receiptSourceOffset: offset)!
        }, cursor: nil, hasMore: false, ingestion: .init(epoch: epoch, requestID: request,
            operation: from == nil ? .bootstrap : .updates, liveCursor: request, sourceEnd: 1_000))!
    }
    private func freshSend(_ core: AgentCenterRuntime, end: UInt64 = 100, dispatch: Bool = true) async throws -> AgentActionLease {
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: frontier(lease, end: end))
        if dispatch { try await core.markOutgoingDispatched(lease) }
        return lease
    }

    func testFreshFrontierArmsDuringRebuildWithoutAnyProjectionOrCursor() async throws {
        let core = AgentCenterRuntime()
        await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true,
            spawn: false, fork: false, search: true)), binding: binding())
        let lease = try await freshSend(core)
        let checkpoint = await awaitCheckpoint(core)
        XCTAssertNil(checkpoint)
        await core.releaseLease(lease, result: .verified)
        await assertPending(core, [.awaitingReceipt])
        _ = await core.apply(page: frontierPage("first-after-rebuild", nil, [(1, 150, "same")]), to: id)
        await assertPending(core, [.observed]) // Advisory only; never silently removed as confirmed.
    }

    private func awaitCheckpoint(_ core: AgentCenterRuntime) async -> String? {
        await core.ingestionCheckpoint(for: id)?.cursor
    }

    func testFreshEOFRejectsStaleIndexCutAndPartialTailCompletion() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
        let lease = try await freshSend(core, end: 500)
        await core.releaseLease(lease, result: .verified)
        // Both records began before the real EOF, though the old index only
        // knew bytes near zero and the second record was an incomplete tail.
        _ = await core.apply(page: frontierPage("partial", "old", [(2, 100, "same"), (3, 499, "same")]), to: id)
        await assertPending(core, [.awaitingReceipt])
        _ = await core.apply(page: frontierPage("new", "partial", [(4, 500, "same")]), to: id)
        await assertPending(core, [.observed])
    }

    func testIdenticalConcurrentRecordObservedBeforeDispatchCannotMatchLater() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
        let lease = try await freshSend(core, dispatch: false)
        _ = await core.apply(page: frontierPage("concurrent", "old", [(2, 150, "same")]), to: id)
        await assertPending(core, [.sending])
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: frontierPage("tick", "concurrent", []), to: id)
        await assertPending(core, [.awaitingReceipt])
        _ = await core.apply(page: frontierPage("own", "tick", [(3, 200, "same")]), to: id)
        await assertPending(core, [.observed])
    }

    func testTruncateRegrowMatchingOffsetNeverBecomesStrongReceipt() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
        let lease = try await freshSend(core)
        await core.releaseLease(lease, result: .verified)
        // An uncooperative writer can truncate and regrow this same inode.
        // Physical identity and text/offset cannot establish causal delivery.
        _ = await core.apply(page: frontierPage("rewritten", "old", [(2, 150, "same")]), to: id)
        await assertPending(core, [.observed])
        await core.releaseLease(lease, result: .failed) // Late callback cannot downgrade acknowledged delivery.
        await assertPending(core, [.observed])
    }

    func testUnavailableFrontierDoesNotBlockDeliveryOrBorrowARecord() async throws {
        let core = await runtime()
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: frontierPage("new", nil, [(2, 150, "same")]), to: id)
        await assertPending(core, [.sentUnconfirmed])
    }

    /// No frontier: the reader was unavailable, or (the reported case) the
    /// conversation `/clear` just started had no transcript for it. The
    /// acknowledged write still settles on the record its transcript gains.
    func testUnavailableFrontierSettlesOnARecordTheThreadDidNotHoldAtDispatch() async throws {
        for heldBefore in [false, true] {
            let core = AgentCenterRuntime()
            await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true,
                actions: true, spawn: false, fork: false, search: true)), binding: binding())
            if heldBefore { _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "same")]), to: id) }
            let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
                textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
            try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
            try await core.markOutgoingDispatched(lease)
            await core.releaseLease(lease, result: .verified)
            await assertPending(core, [.sentUnconfirmed])
            if heldBefore {
                // The identical record held at dispatch is not this send.
                _ = await core.apply(page: frontierPage("tick", "old", []), to: id)
                await assertPending(core, [.sentUnconfirmed])
                _ = await core.apply(page: frontierPage("own", "tick", [(2, 150, "same")]), to: id)
            } else {
                _ = await core.apply(page: frontierPage("first", nil, [(1, 0, "same")]), to: id)
            }
            await assertPending(core, [.observed])
        }
    }

    /// A reconnect or a re-proved route rebinds the thread after the terminal
    /// acknowledged the write. Its record still settles it, and a send the
    /// transcript already showed stays shown through later rebinds and
    /// evictions instead of reverting to "receipt unavailable".
    func testAcknowledgedSendSettlesAndStaysSettledAcrossRebinds() async throws {
        for rebindThroughDiscovery in [false, true] {
            let core = await runtime()
            _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
            let lease = try await freshSend(core)
            await core.releaseLease(lease, result: .verified)
            await assertPending(core, [.awaitingReceipt])
            if rebindThroughDiscovery {
                await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true,
                    actions: true, spawn: false, fork: false, search: true)), binding: binding(2))
            } else {
                await core.replaceBinding(binding(2), for: id)
            }
            await assertPending(core, [.sentUnconfirmed])
            _ = await core.apply(page: frontierPage("own", "old", [(2, 150, "same")]), to: id)
            await assertPending(core, [.observed])
            await core.replaceBinding(binding(3), for: id)
            await assertPending(core, [.observed])
            await core.memoryWarning()
            await assertPending(core, [.observed])
        }
    }

    /// A restarted reader starts another epoch and a Claude chain another
    /// generation. The frontier's EOF is the file's own offset, so it still
    /// orders the send against records the new reader delivers.
    func testFrontierFromAnEarlierReaderSettlesOnANewerRecord() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")], source: "claude-chain:gen-1"), to: id)
        let lease = try await freshSend(core)
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: frontierPage("restart", nil, [(1, 0, "anchor"), (2, 50, "same")],
            epoch: "epoch-2", source: "claude-chain:gen-2"), to: id)
        await assertPending(core, [.awaitingReceipt], "the line began before the send's EOF")
        _ = await core.apply(page: frontierPage("own", "restart", [(3, 150, "same")], epoch: "epoch-2", source: "claude-chain:gen-2"), to: id)
        await assertPending(core, [.observed])
    }

    /// The reported case: `/clear` started a conversation whose transcript
    /// did not exist yet, so the send had no frontier and the thread no
    /// source. The prompt that opens the transcript is the send; the first
    /// window can already hold the whole turn.
    func testFirstPromptOfANewTranscriptSettlesAnUnavailableFrontier() async throws {
        for fromStart in [true, false] {
            let core = AgentCenterRuntime()
            await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true,
                actions: true, spawn: false, fork: false, search: true)), binding: binding())
            let lease = try await unavailableSend(core, text: "Testing message from agent center")
            await assertPending(core, [.sentUnconfirmed])
            let records: [AgentProjectionRecord] = [
                .init(sequence: 1, recordID: "caveat", record: .object(["type": .string("user"), "isMeta": .bool(true),
                    "text": .string("Caveat: local commands")]))!,
                .init(sequence: 2, recordID: "clear", record: .object(["type": .string("user"), "role": .string("system"),
                    "text": .string("<command-name>/clear</command-name>")]))!,
                .init(sequence: 3, recordID: "prompt", record: .object(["type": .string("user"),
                    "text": .string("Testing message from agent center")]))!,
                .init(sequence: 4, recordID: "reply", record: .object(["type": .string("assistant"), "text": .string("Seen.")]))!,
            ]
            let window = try AgentIngestionWindowTransaction(lane: .bootstrap, version: 1, segmentID: "first",
                before: "first-before", after: "first-after", hasOlder: !fromStart)
            _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "claude-chain:new", records: records,
                cursor: fromStart ? nil : "first-before", hasMore: !fromStart, ingestion: .init(epoch: "epoch", requestID: "first",
                    operation: .bootstrap, liveCursor: "first", sourceEnd: 500, window: window))!, to: id)
            await assertPending(core, [fromStart ? .observed : .sentUnconfirmed],
                fromStart ? "" : "a page that does not reach the start cannot tell the opening prompt")
            _ = lease
        }
    }

    /// Sent before the thread's transcript loaded: that transcript's history
    /// may repeat the text, and nothing orders it against the write.
    func testUnavailableFrontierIgnoresHistoryLoadedAfterTheSend() async throws {
        for native in [false, true] {
            let core = AgentCenterRuntime()
            await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true,
                actions: true, spawn: false, fork: false, search: true)), binding: binding())
            _ = try await unavailableSend(core)
            if native {
                _ = await core.apply(page: frontierPage("boot", nil, [(1, 0, "same"), (2, 50, "later prompt")]), to: id)
            } else {
                _ = await core.apply(page: page([(1, "same"), (2, "reply"), (3, "later prompt")]), to: id)
            }
            await assertPending(core, [.sentUnconfirmed])
        }
    }

    /// Memory pressure dropped the records but kept the source: the send has
    /// no baseline, so a reload of the same history is not its receipt.
    func testUnavailableFrontierIgnoresHistoryReloadedAfterEviction() async throws {
        for native in [false, true] {
            let core = await runtime(loaded: false)
            if native {
                _ = await core.apply(page: frontierPage("boot", nil, [(1, 0, "same"), (2, 50, "reply")]), to: id)
            } else {
                _ = await core.apply(page: page([(1, "same"), (2, "reply")]), to: id)
            }
            await core.memoryWarning()
            _ = try await unavailableSend(core)
            if native {
                _ = await core.apply(page: frontierPage("boot2", nil, [(1, 0, "same"), (2, 50, "reply")]), to: id)
            } else {
                _ = await core.apply(page: page([(1, "same"), (2, "reply")], source: "b"), to: id)
            }
            await assertPending(core, [.sentUnconfirmed])
        }
    }

    /// Without a frontier the held records fence the write: one that landed
    /// during the final process proof, before the terminal ACK, is not it.
    func testUnavailableFrontierExcludesARecordHeldBeforeTheAcknowledgment() async throws {
        let core = await runtime(loaded: false)
        _ = await core.apply(page: page([(1, "anchor")]), to: id)
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        _ = await core.apply(page: page([(1, "anchor"), (2, "same")], source: "b"), to: id)
        await core.releaseLease(lease, result: .verified)
        await assertPending(core, [.sentUnconfirmed])
        _ = await core.apply(page: page([(1, "anchor"), (2, "same"), (3, "reply")], source: "c"), to: id)
        await assertPending(core, [.sentUnconfirmed])
        _ = await core.apply(page: page([(1, "anchor"), (2, "same"), (3, "reply"), (4, "same")], source: "d"), to: id)
        await assertPending(core, [.observed])
    }

    /// One record settles one of two identical sends.
    func testUnavailableFrontierSettlesOneSendPerRecord() async throws {
        let core = await runtime(loaded: false)
        _ = await core.apply(page: page([(1, "anchor")]), to: id)
        _ = try await unavailableSend(core)
        _ = try await unavailableSend(core)
        _ = await core.apply(page: page([(1, "anchor"), (2, "same")], source: "b"), to: id)
        await assertPending(core, [.observed, .sentUnconfirmed])
        _ = await core.apply(page: page([(1, "anchor"), (2, "same"), (3, "same")], source: "c"), to: id)
        await assertPending(core, [.observed, .observed])
    }

    private func unavailableSend(_ core: AgentCenterRuntime, text: String = "same") async throws -> AgentActionLease {
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: text, queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        return lease
    }

    func testRecordObservedDuringFinalProofCannotMatchAfterTerminalAcknowledgment() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
        let lease = try await freshSend(core)
        // Dispatch is armed, but the final process/composer proof has not yet
        // finished. Receipt interpretation must wait for the terminal ACK.
        _ = await core.apply(page: frontierPage("before-write", "old", [(2, 150, "same")]), to: id)
        await assertPending(core, [.sending])
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: frontierPage("tick", "before-write", []), to: id)
        await assertPending(core, [.awaitingReceipt])
    }

    func testMoreThanThirtyTwoAcknowledgedObservedSendsRemainAdmissible() async throws {
        let core = await runtime()
        _ = await core.apply(page: frontierPage("old", nil, [(1, 0, "anchor")]), to: id)
        var cursor = "old"
        for index in 0..<40 {
            let lease = try await freshSend(core, end: UInt64(100 + index * 10))
            await core.releaseLease(lease, result: .verified)
            let next = "send-\(index)"
            _ = await core.apply(page: frontierPage(next, cursor, [(UInt64(index + 2), UInt64(100 + index * 10), "same")]), to: id)
            cursor = next
        }
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.outgoingMessages?.count, 32)
        XCTAssertTrue(snapshot?.outgoingMessages?.allSatisfy { $0.status == .observed } == true)
    }

    func testMoreThanThirtyTwoAcknowledgedSendsDoNotWaitForUnavailableOrRebuildingHistory() async throws {
        for unavailable in [false, true] {
            let core = await runtime()
            for _ in 0..<40 {
                let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
                    textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
                try await core.armOutgoing(lease, frontier: unavailable ? .unavailable(for: lease) : frontier(lease))
                try await core.markOutgoingDispatched(lease)
                await core.releaseLease(lease, result: .verified)
            }
            let snapshot = await core.snapshot(for: id)
            XCTAssertEqual(snapshot?.outgoingMessages?.count, 32)
            let expected: AgentOutgoingMessage.Status = unavailable ? .sentUnconfirmed : .awaitingReceipt
            XCTAssertTrue(snapshot?.outgoingMessages?.allSatisfy { $0.status == expected } == true)
        }
    }

    func testUnknownDeliveryIntentCannotBeEvictedByNewSends() async throws {
        let core = await runtime()
        for _ in 0..<32 {
            let lease = try await freshSend(core)
            await core.releaseLease(lease, result: .cancelled)
        }
        do { _ = try await freshSend(core); XCTFail("unknown terminal delivery must stay visible") }
        catch { XCTAssertEqual(error as? AgentActionError, .actionInFlight) }
        await assertPending(core, Array(repeating: .unconfirmed, count: 32))
    }

    func testFreshFrontierRejectsOldActionLeaseAndRotationCannotMatch() async throws {
        let core = await runtime()
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        let stale = AgentOutgoingFrontier(actionID: UUID(), serviceEpoch: "epoch", provider: id.providerID,
            providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: 0, consistency: .observedPrefix)!
        do { try await core.armOutgoing(lease, frontier: stale); XCTFail("cached frontier from another action") }
        catch { XCTAssertEqual(error as? AgentActionError, .staleBinding) }
        try await core.armOutgoing(lease, frontier: frontier(lease))
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: frontierPage("rotated", nil, [(2, 150, "same")], identity: "jsonl:1:3"), to: id)
        await assertPending(core, [.awaitingReceipt])
    }

    private let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "outgoing")!
    private let sessionID = UUID()
    private func binding(_ generation: UInt64 = 1) -> AgentTerminalBinding {
        .init(liveSessionID: sessionID, carrierGeneration: generation, incarnation: AgentIncarnationToken("outgoing")!,
              transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
    }
    private func page(_ texts: [(UInt64, String)], source: String = "a") -> AgentProjectionPage {
        .init(sourceIdentity: source.contains(":") ? source : "1:2:\(source):1", records: texts.map { sequence, text in
            .init(sequence: sequence, recordID: "\(source)-\(sequence)", record: .object(["type": .string("user"), "text": .string(text)]))!
        }, cursor: nil, hasMore: false)!
    }
    private func runtime(loaded: Bool = true) async -> AgentCenterRuntime {
        let core = AgentCenterRuntime()
        await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding())
        if loaded { _ = await core.apply(page: page([(1, "same")]), to: id) }
        return core
    }
    private func send(_ core: AgentCenterRuntime, text: String = "same", queue: Bool = false, boundary: AgentProjectionPage? = nil) async throws -> AgentActionLease {
        let lease = try await core.acquireLease(threadID: id, action: queue ? .queue : .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: text, queueWhenWorking: queue)!)
        try await core.armOutgoing(lease, freshPage: boundary ?? page([(1, "same")]))
        try await core.markOutgoingDispatched(lease)
        return lease
    }
    private func assertPending(_ core: AgentCenterRuntime, _ statuses: [AgentOutgoingMessage.Status], _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) async {
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.outgoingMessages?.map(\.status), statuses, message, file: file, line: line)
    }

    func testNewTranscriptReceiptReplacesPendingAtomicallyAndLateFailureCannotResurrectIt() async throws {
        let core = await runtime()
        let lease = try await send(core, text: "  same  ")
        await assertPending(core, [.sending])
        _ = await core.apply(page: page([(1, "same")], source: "b"), to: id)
        await assertPending(core, [.sending]) // Source/record IDs changing is not a receipt.
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "c"), to: id)
        await assertPending(core, [])
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.messages.count, 2)
        await core.releaseLease(lease, result: .failed)
        await assertPending(core, [])
    }

    func testIdenticalQueuedMessagesRequireDistinctNewRecordsEvenAfterIDReplacement() async throws {
        let core = await runtime()
        let first = try await send(core, queue: true)
        await assertPending(core, [.queueing])
        await core.releaseLease(first, result: .verified)
        let second = try await send(core, queue: true)
        await core.releaseLease(second, result: .verified)
        await assertPending(core, [.awaitingReceipt, .awaitingReceipt])
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "b"), to: id)
        await assertPending(core, [.awaitingReceipt])
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "c"), to: id)
        await assertPending(core, [.awaitingReceipt])
        _ = await core.apply(page: page([(1, "same"), (2, "same"), (3, "same")], source: "d"), to: id)
        await assertPending(core, [])
    }

    func testFailedOrCancelledSendRemainsUnconfirmedUntilRealReceipt() async throws {
        for status in [AgentActionResultStatus.failed, .cancelled, .staleBinding] {
            let core = await runtime()
            let lease = try await send(core)
            await core.releaseLease(lease, result: status)
            await assertPending(core, [.unconfirmed])
            _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "b"), to: id)
            await assertPending(core, [])
        }
    }

    func testSendRefusedBeforeAnyWriteLeavesNoBubbleAndCannotClaimALaterRecord() async throws {
        let core = await runtime()
        let lease = try await send(core)
        await core.releaseLease(lease, result: .notSent)
        await assertPending(core, [])
        // The platform proved no byte reached the terminal, so a later record
        // with the same text is somebody else's input, not this intent.
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "b"), to: id)
        await assertPending(core, [])
        // The thread is free for the retry from the restored draft.
        let retry = try await send(core)
        await core.releaseLease(retry, result: .verified)
        await assertPending(core, [.awaitingReceipt])
    }

    func testRefusalAfterARebindStillWithdrawsOnlyAnUnwrittenBubble() async throws {
        let core = await runtime()
        let lease = try await send(core)
        // The route changed while the platform was still proving the composer.
        await core.replaceBinding(binding(2), for: id)
        await assertPending(core, [.unconfirmed])
        await core.releaseLease(lease, result: .notSent)
        await assertPending(core, [])

        // A revoked lease never withdraws a bubble the terminal acknowledged,
        // and an ambiguous result after the rebind changes nothing.
        let fresh = await runtime()
        let written = try await send(fresh, text: "written")
        await fresh.releaseLease(written, result: .verified)
        let other = try await send(fresh, text: "other")
        await fresh.replaceBinding(binding(3), for: id)
        await fresh.releaseLease(written, result: .notSent)
        await fresh.releaseLease(other, result: .failed)
        await assertPending(fresh, [.sentUnconfirmed, .unconfirmed])
    }

    func testNotSentOutcomeIsOnlyForTextInput() {
        XCTAssertNotNil(AgentActionResultOutcome(status: .notSent, action: .send))
        XCTAssertNotNil(AgentActionResultOutcome(status: .notSent, action: .queue))
        XCTAssertNil(AgentActionResultOutcome(status: .notSent, action: .interrupt))
        XCTAssertNil(AgentActionResultOutcome(status: .notSent, action: .send, verification: "fresh-terminal-postcondition"))
    }

    func testBindingChangeCannotAcknowledgeOldIntentAndDisablePurgesIt() async throws {
        let core = await runtime()
        let lease = try await send(core)
        await core.replaceBinding(binding(2), for: id)
        await core.releaseLease(lease, result: .verified)
        _ = await core.apply(page: page([(2, "same")], source: "b"), to: id)
        await assertPending(core, [.unconfirmed])
        await core.setEnabled(false)
        await assertPending(core, [])
    }

    func testOlderPagingAndDifferentTextDoNotAcknowledgeAndPendingIsBounded() async throws {
        let core = await runtime()
        _ = await core.apply(page: page([(10, "tail")], source: "b"), to: id)
        for _ in 0..<32 {
            let lease = try await send(core, boundary: page([(10, "tail")], source: "b"))
            await core.releaseLease(lease, result: .verified)
        }
        let next = try await send(core, boundary: page([(10, "tail")], source: "b"))
        await core.releaseLease(next, result: .verified)
        _ = await core.apply(page: page([(9, "same"), (10, "tail"), (11, "different")], source: "c"), to: id)
        await assertPending(core, Array(repeating: .awaitingReceipt, count: 32))
    }

    func testUnarmedAndFreshBoundaryRejectDelayedPreSendHistory() async throws {
        let core = await runtime()
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
            textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "same", queueWhenWorking: false)!)
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "b"), to: id)
        await assertPending(core, [.sending])
        try await core.armOutgoing(lease, freshPage: page([(1, "same"), (2, "same")], source: "b"))
        try await core.markOutgoingDispatched(lease)
        _ = await core.apply(page: page([(1, "same"), (2, "same")], source: "c"), to: id)
        await assertPending(core, [.sending])
        _ = await core.apply(page: page([(1, "same"), (2, "same"), (3, "same")], source: "d"), to: id)
        await assertPending(core, [])
    }

    func testEmptyFreshBoundaryAcknowledgesSequenceZeroAndDifferentFileCannotAcknowledge() async throws {
        let core = await runtime()
        let lease = try await send(core, boundary: page([], source: "2:3:0:1"))
        _ = await core.apply(page: page([(0, "same")], source: "9:9:1:2"), to: id)
        await assertPending(core, [.sending])
        _ = await core.apply(page: page([(0, "same")], source: "2:3:1:2"), to: id)
        await assertPending(core, [])
        await core.releaseLease(lease, result: .verified)
    }

    func testDirectReregistrationMarksPendingUnconfirmed() async throws {
        let core = await runtime()
        _ = try await send(core)
        await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding(2))
        await assertPending(core, [.unconfirmed])
    }

    func testForwardPagedProvidersRequireTailAndSQLiteWalAppendPreservesSourceFile() async throws {
        for provider in [AgentProviderID.pi, .opencode] {
            let core = AgentCenterRuntime()
            let thread = AgentThreadID(hostID: id.hostID, providerID: provider, providerSessionID: "forward")!
            await core.register(.init(id: thread, providerName: provider.rawValue, availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding())
            let lease = try await core.acquireLease(threadID: thread, action: .send, binding: binding(),
                textRequest: AgentTextSendRequest(threadID: thread, binding: binding(), text: "same", queueWhenWorking: false)!)
            let oldSource = provider == .pi ? "pi:1:2:a:1" : "opencode:db:1:2:a:1;wal:3:4:b:2"
            let newSource = provider == .pi ? "pi:1:2:b:2" : "opencode:db:1:2:c:3;wal:3:4:d:4"
            let records = page([(1, "anchor")]).records
            let firstPage = AgentProjectionPage(sourceIdentity: oldSource, from: "forward-start", records: records, cursor: "next", hasMore: true)!
            do { try await core.armOutgoing(lease, freshPage: firstPage); XCTFail("oldest page is not a receipt boundary") }
            catch { XCTAssertEqual(error as? AgentActionError, .staleBinding) }
            try await core.armOutgoing(lease, freshPage: AgentProjectionPage(sourceIdentity: oldSource, from: "tail", records: records, cursor: "end", hasMore: false)!)
            try await core.markOutgoingDispatched(lease)
            let newFirst = AgentProjectionPage(sourceIdentity: newSource, records: page([(0, "older")]).records,
                cursor: "next", hasMore: true)!
            _ = await core.apply(page: newFirst, to: thread)
            let beforeTail = await core.snapshot(for: thread)
            XCTAssertEqual(beforeTail?.outgoingMessages?.count, 1)
            let newTail = AgentProjectionPage(sourceIdentity: newSource, from: "next",
                records: page([(1, "anchor"), (2, "same")]).records, cursor: "end", hasMore: false)!
            let appliedTail = await core.apply(page: newTail, to: thread)
            XCTAssertNotEqual(appliedTail, .resyncRequired)
            let snapshot = await core.snapshot(for: thread)
            XCTAssertEqual(snapshot?.outgoingMessages, [])
        }
    }
}
