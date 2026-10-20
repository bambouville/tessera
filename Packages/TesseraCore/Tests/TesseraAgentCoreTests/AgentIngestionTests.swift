import XCTest
@testable import TesseraAgentCore

final class AgentIngestionTests: XCTestCase {
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func begin(_ id: String = "read", operation: String = "bootstrap", from: String? = nil) throws -> Data {
        var value: [String: Any] = ["kind": "page.begin", "id": id, "thread": "thread", "serviceEpoch": "epoch",
                                   "sourceIdentity": "jsonl:1:2", "operation": operation]
        if let from { value["from"] = from }
        return try data(value)
    }
    private func record(_ id: String = "read", order: UInt64 = 900) throws -> Data {
        try data(["kind": "page.record", "id": id, "thread": "thread", "serviceEpoch": "epoch", "order": order,
                  "recordID": "record-\(order)", "revision": 1, "record": ["type": "assistant", "text": "Hello 🌍"]])
    }
    private func end(_ id: String = "read", count: Int = 1) throws -> Data {
        try data(["kind": "page.end", "id": id, "thread": "thread", "serviceEpoch": "epoch",
                  "records": count, "historyCursor": "older", "hasOlder": true, "liveCursor": "live", "hasNewer": false])
    }

    func testFramingEverySplitIncludingUnicodeAndConcatenatedFrames() throws {
        let value = AgentJSONValue.object(["text": .string("A🌍B")])
        let one = try AgentIngestionFramer.encode(value)
        let both = one + one
        for split in 0...both.count {
            var framer = AgentIngestionFramer(); var values: [AgentJSONValue] = []
            try framer.append(both.prefix(split)) { values.append(try JSONDecoder().decode(AgentJSONValue.self, from: $0)) }
            try framer.append(both.dropFirst(split)) { values.append(try JSONDecoder().decode(AgentJSONValue.self, from: $0)) }
            try framer.finish()
            XCTAssertEqual(values, [value, value])
        }
    }

    func testFrameLimitsAndPartialEOF() throws {
        for bytes in [Data([0, 0, 0, 0, 1]), Data([0, 1, 0, 1, 1])] {
            var framer = AgentIngestionFramer()
            XCTAssertThrowsError(try framer.append(bytes) { _ in XCTFail("invalid frame emitted") })
        }
        var framer = AgentIngestionFramer()
        try framer.append(Data([0, 0])) { _ in XCTFail("partial frame emitted") }
        XCTAssertThrowsError(try framer.finish())
    }

    func testPageCommitsAtEndNotEOFAndKeepsConnectionUsable() throws {
        var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
        XCTAssertNil(try decoder.accept(begin()))
        XCTAssertNil(try decoder.accept(record()))
        let complete = try XCTUnwrap(decoder.accept(end()))
        XCTAssertEqual(complete.page.records.count, 1)
        XCTAssertEqual(complete.page.records[0].sequence, 900)
        XCTAssertEqual(complete.page.cursor, "older")
        XCTAssertEqual(complete.page.ingestion?.liveCursor, "live")
        try decoder.finish()
        XCTAssertNil(try decoder.accept(begin("next")))
        XCTAssertThrowsError(try decoder.finish())
    }

    func testPageEndMetadataAcceptsOnlyBoundedStringsAndLeavesAbsentSummaryNil() throws {
        func decode(_ metadata: Any?) throws -> AgentProjectionPage {
            var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
            _ = try decoder.accept(begin())
            _ = try decoder.accept(record())
            var value = try JSONSerialization.jsonObject(with: end()) as! [String: Any]
            if let metadata { value["metadata"] = metadata }
            value["metadataIssue"] = "unavailable"
            value["metadataReason"] = "transient"
            return try XCTUnwrap(decoder.accept(data(value))?.page)
        }
        let absent = try decode(nil)
        XCTAssertNil(absent.summary)
        let valid = try decode(["nativeTitle": "Survey the build cache layout",
                                "openingPrompt": "Opening request", "futureKey": "ignored"])
        XCTAssertEqual(valid.summary, .object(["nativeTitle": .string("Survey the build cache layout"),
                                               "openingPrompt": .string("Opening request")]))
        XCTAssertEqual(try JSONDecoder().decode(AgentProjectionPage.self, from: JSONEncoder().encode(valid)), valid)
        let partial = try decode(["nativeTitle": 7, "openingPrompt": "Opening request"])
        XCTAssertEqual(partial.summary, .object(["openingPrompt": .string("Opening request")]))
        let escaped = try decode(["openingPrompt": String(repeating: "\u{0001}", count: 4_096)])
        XCTAssertNil(escaped.summary, "encoded summary overflow cannot reject the page")
        for bad: Any in [7, ["nativeTitle": 7, "openingPrompt": false],
                         ["nativeTitle": String(repeating: "é", count: 257),
                          "openingPrompt": String(repeating: "é", count: 2_049)],
                         ["futureKey": "ignored"]] {
            let page = try decode(bad)
            XCTAssertEqual(page.records, absent.records)
            XCTAssertNil(page.summary)
        }
    }

    func testIndexedCodexPageUsesByteOffsetsNotCanonicalOrderForSourceBounds() throws {
        for identity in ["codex-history:fixture", "claude-chain:fixture", "pi-chain:fixture", "kimi-history:fixture"] {
        for offset in [nil, 900, 1000] as [Int?] {
            var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
            _ = try decoder.accept(data(["kind": "page.begin", "id": "read", "thread": "thread", "serviceEpoch": "epoch",
                "sourceIdentity": identity, "operation": "bootstrap"]))
            var row: [String: Any] = ["kind": "page.record", "id": "read", "thread": "thread", "serviceEpoch": "epoch",
                "recordID": "item", "order": 2, "revision": 1, "record": ["type": "assistant", "text": "fixture"]]
            if let offset { row["sourceOffset"] = offset }
            if offset == nil { XCTAssertThrowsError(try decoder.accept(data(row))); continue }
            _ = try decoder.accept(data(row))
            let final = try data(["kind": "page.end", "id": "read", "thread": "thread", "serviceEpoch": "epoch",
                "records": 1, "hasOlder": false, "liveCursor": "live", "hasNewer": false, "sourceEnd": 1000])
            if offset == 1000 { XCTAssertThrowsError(try decoder.accept(final)) }
            else { XCTAssertEqual(try decoder.accept(final)?.page.records.first?.sourceOffset, 900) }
        }
        }
    }

    func testMalformedPageDiscardsAllPendingTransactions() throws {
        var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
        _ = try decoder.accept(begin("one")); _ = try decoder.accept(begin("two"))
        _ = try decoder.accept(record("one"))
        XCTAssertThrowsError(try decoder.accept(record("one")))
        XCTAssertThrowsError(try decoder.accept(end("two", count: 0)))
        try decoder.finish()
    }

    func testWrongEpochAndIncorrectCountFailClosed() throws {
        var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
        _ = try decoder.accept(begin())
        XCTAssertThrowsError(try decoder.accept(end(count: 10)))
        XCTAssertThrowsError(try decoder.accept(data(["kind": "ack", "serviceEpoch": "other"])))
    }

    /// A bootstrap page as the Agent Host (2026-09-23 build) sent it for a
    /// three-line Claude transcript on the jump fixture. Receipt offsets are
    /// decimal strings on the wire.
    func testHostBootstrapPageWithDecimalReceiptOffsetsDecodes() throws {
        let frames = [
            #"{"id":"W1","serviceEpoch":"303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343","kind":"page.begin","thread":"4cc30799ef8ea19cce9fc09d196f968a","sourceIdentity":"claude-chain:88768f3a963ada93d875693d629c8284","operation":"bootstrap"}"#,
            #"{"id":"W1","serviceEpoch":"303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343","kind":"page.record","thread":"4cc30799ef8ea19cce9fc09d196f968a","recordID":"claude-chain:88768f3a963ada93d875693d629c8284:0","order":0,"revision":1,"record":{"provider":"claude","type":"message","role":"user","blocks":[{"type":"text","text":"Synthetic f0dac37d-75f7-4f32-a161-9a6169ab922f history 0","truncated":false}],"isMeta":false,"turnID":"f0dac37d-75f7-4f32-a161-9a6169ab922f-r0","truncated":false},"sourceType":"user","disposition":"message","visible":true,"sourceOffset":0,"receiptSourceIdentity":"jsonl:64769:265697","receiptSourceOffset":"0"}"#,
            #"{"id":"W1","serviceEpoch":"303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343","kind":"page.record","thread":"4cc30799ef8ea19cce9fc09d196f968a","recordID":"claude-chain:88768f3a963ada93d875693d629c8284:1","order":1,"revision":1,"record":{"provider":"claude","type":"message","role":"user","blocks":[{"type":"text","text":"Synthetic f0dac37d-75f7-4f32-a161-9a6169ab922f history 1","truncated":false}],"isMeta":false,"turnID":"f0dac37d-75f7-4f32-a161-9a6169ab922f-r1","truncated":false},"sourceType":"user","disposition":"message","visible":true,"sourceOffset":188,"receiptSourceIdentity":"jsonl:64769:265697","receiptSourceOffset":"188"}"#,
            #"{"id":"W1","serviceEpoch":"303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343","kind":"page.record","thread":"4cc30799ef8ea19cce9fc09d196f968a","recordID":"claude-chain:88768f3a963ada93d875693d629c8284:2","order":2,"revision":1,"record":{"provider":"claude","type":"message","role":"user","blocks":[{"type":"text","text":"Synthetic f0dac37d-75f7-4f32-a161-9a6169ab922f history 2","truncated":false}],"isMeta":false,"turnID":"f0dac37d-75f7-4f32-a161-9a6169ab922f-r2","truncated":false},"sourceType":"user","disposition":"message","visible":true,"sourceOffset":413,"receiptSourceIdentity":"jsonl:64769:265697","receiptSourceOffset":"413"}"#,
            #"{"id":"W1","serviceEpoch":"303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343","kind":"page.end","thread":"4cc30799ef8ea19cce9fc09d196f968a","backend":"jsonl","window":{"lane":"bootstrap","version":1,"segmentID":"fd0862a01586d8086c4fdac21b58534f","before":"43be905121ad1174b88c1bcf25f3d7a5","after":"bf4ccb9fa41b9466913a2e3d43136921","hasOlder":false,"hasNewer":false},"hasOlder":false,"liveCursor":"bf4ccb9fa41b9466913a2e3d43136921","hasNewer":false,"sourceEnd":638,"records":3,"bytesRead":1914,"hostPeakRSSBytes":2359296,"codexSampledPeakRSSBytes":0}"#,
        ]
        let bytes = frames.reduce(into: Data()) { data, frame in
            let json = Data(frame.utf8), size = UInt32(json.count)
            data.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
            data.append(json)
        }
        let page = try AgentIngestionProjection.decode(bytes, epoch: "303297c313ebdf143dc989caee9e5e1ce72f80c9ba652fea1274eb1ceb91a343",
                                                       thread: "4cc30799ef8ea19cce9fc09d196f968a")
        XCTAssertEqual(page.records.map(\.receiptSourceOffset), [0, 188, 413])
        XCTAssertEqual(Set(page.records.map(\.receiptSourceIdentity)), ["jsonl:64769:265697"])
        XCTAssertEqual(page.records.map(\.sourceOffset), [0, 188, 413])
        XCTAssertEqual(page.ingestion?.window?.version, 1)
    }

    func testReceiptOffsetAcceptsOnlyCanonicalDecimalStringsOrIntegers() throws {
        func decode(_ offset: Any) throws -> UInt64? {
            var decoder = try AgentIngestionPageDecoder(epoch: "epoch")
            _ = try decoder.accept(begin())
            _ = try decoder.accept(data(["kind": "page.record", "id": "read", "thread": "thread", "serviceEpoch": "epoch",
                "order": 900, "recordID": "record-900", "revision": 1, "record": ["type": "assistant", "text": "Hello"],
                "receiptSourceIdentity": "jsonl:1:2", "receiptSourceOffset": offset]))
            return try decoder.accept(end())?.page.records.first?.receiptSourceOffset
        }
        XCTAssertEqual(try decode("31971"), 31_971)
        XCTAssertEqual(try decode("0"), 0)
        XCTAssertEqual(try decode("18446744073709551615"), .max)
        XCTAssertEqual(try decode(31_971), 31_971)
        for invalid: Any in ["007", "+7", "7.0", " 7", "-1", "", "18446744073709551616", 7.5, -1] {
            XCTAssertThrowsError(try decode(invalid), "\(invalid)") {
                XCTAssertEqual($0 as? AgentIngestionError, .malformedFrame)
            }
        }
    }

    func testSummaryDoesNotInsertMessagesAdvanceCursorsOrCreateAttention() async throws {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        let before = await runtime.snapshot(for: id)!
        let summary = try AgentIngestionSummary.decode(data(["kind": "summary", "id": "watch_summary", "thread": "thread",
            "serviceEpoch": "epoch", "revision": "revision", "modified": 1_000,
            "records": [["type": "assistant", "text": "Card preview"], ["type": "status", "status": "waiting_for_input"]]]),
            epoch: "epoch", thread: "thread")
        let accepted = await runtime.apply(summary: summary, to: id)
        XCTAssertTrue(accepted)
        let after = await runtime.snapshot(for: id)!
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.summary.attention, before.summary.attention)
        XCTAssertEqual(after.summary.status, before.summary.status)
        XCTAssertEqual(after.summary.availability, before.summary.availability)
        XCTAssertEqual(after.summary.preview, "Card preview")
        let checkpoint = await runtime.ingestionCheckpoint(for: id)
        XCTAssertEqual(checkpoint?.cursor, "live")
        await runtime.select(threadID: id)
        let selectedAccepted = await runtime.apply(summary: summary, to: id)
        XCTAssertTrue(selectedAccepted)
    }

    func testSummaryCarriesTheHostMetadataIssueAsABoundedCode() throws {
        // The host reports a failed card-metadata read (a Codex state store it
        // could not open) beside the records; the code is the diagnosable part
        // and must never be free text. A newer host's unknown spelling reads as
        // unclassified: this field feeds only the log and never costs the frame.
        let base: [String: Any] = ["kind": "summary", "id": "watch_summary", "thread": "thread",
            "serviceEpoch": "epoch", "revision": "revision", "modified": 1_000, "records": []]
        XCTAssertNil(try AgentIngestionSummary.decode(data(base), epoch: "epoch", thread: "thread").metadataIssue)
        var flagged = base; flagged["metadataIssue"] = "codexTitleUnavailable"
        XCTAssertEqual(try AgentIngestionSummary.decode(data(flagged), epoch: "epoch", thread: "thread").metadataIssue, "codexTitleUnavailable")
        for bad in ["", "open /home/x/.codex: denied", "opencode_title_unavailable", String(repeating: "a", count: 81)] {
            var invalid = base; invalid["metadataIssue"] = bad
            XCTAssertEqual(try AgentIngestionSummary.decode(data(invalid), epoch: "epoch", thread: "thread").metadataIssue, "unclassified", bad)
        }
        var wrongType = base; wrongType["metadataIssue"] = 7
        XCTAssertEqual(try AgentIngestionSummary.decode(data(wrongType), epoch: "epoch", thread: "thread").metadataIssue, "unclassified")
        // The store's own code rides beside the issue under the same rule: a
        // closed Codex store and a refused one are different failures.
        XCTAssertNil(try AgentIngestionSummary.decode(data(flagged), epoch: "epoch", thread: "thread").metadataReason)
        var reasoned = flagged; reasoned["metadataReason"] = "opencodeDatabaseUnavailable"
        let decoded = try AgentIngestionSummary.decode(data(reasoned), epoch: "epoch", thread: "thread")
        XCTAssertEqual(decoded.metadataIssue, "codexTitleUnavailable")
        XCTAssertEqual(decoded.metadataReason, "opencodeDatabaseUnavailable")
        var leaked = flagged; leaked["metadataReason"] = "unable to open database file /home/x/.codex/state_5.sqlite"
        XCTAssertEqual(try AgentIngestionSummary.decode(data(leaked), epoch: "epoch", thread: "thread").metadataReason, "unclassified")
    }

    func testSelectedThreadAcceptsExternalProviderTitleButNotSummaryContent() async throws {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        await runtime.select(threadID: id)
        let before = await runtime.snapshot(for: id)!
        let summary = try AgentIngestionSummary.decode(data(["kind": "summary", "id": "metadata", "thread": "thread",
            "serviceEpoch": "epoch", "revision": "revision", "modified": 1_000,
            "records": [["type": "session-title", "title": "Native Codex title"],
                        ["type": "assistant", "text": "Not the selected transcript"],
                        ["type": "status", "status": "waiting_for_input"]]]), epoch: "epoch", thread: "thread")
        let accepted = await runtime.apply(summary: summary, to: id)
        XCTAssertTrue(accepted)
        let after = await runtime.snapshot(for: id)!
        XCTAssertEqual(after.summary.title, "Native Codex title")
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.summary.preview, before.summary.preview)
        XCTAssertEqual(after.summary.status, before.summary.status)
        XCTAssertEqual(after.summary.attention, before.summary.attention)
        XCTAssertEqual(after.summary.lastActivity, before.summary.lastActivity)
    }

    private func hook(_ index: Int, text: String, final: Bool = false, message: String = "display", event: String = "MessageDisplay") throws -> AgentIngestionHook {
        try AgentIngestionHook.decode(data(["kind": "hookPreview", "id": "hook_\(index)", "thread": "thread", "serviceEpoch": "epoch",
            "event": ["hook_event_name": event, "session_id": "ingestion", "message_id": message, "turn_id": "turn",
                      "index": index, "delta": text, "final": final]]), epoch: "epoch", thread: "thread")
    }

    func testHookReorderDuplicateConflictAndOverflowAreBounded() throws {
        var state = AgentHookOverlayState()
        state.accept(try hook(0, text: "Unique "))
        state.accept(try hook(2, text: "!", final: true))
        XCTAssertEqual(state.preview?.text, "Unique ")
        XCTAssertEqual(state.preview?.hasGap, true)
        state.accept(try hook(1, text: "message"))
        XCTAssertEqual(state.preview?.text, "Unique message!")
        XCTAssertEqual(state.preview?.hasGap, false)
        state.accept(try hook(1, text: "message"))
        XCTAssertEqual(state.preview?.text, "Unique message!")
        state.accept(try hook(1, text: "conflicting"))
        XCTAssertNil(state.preview)
        state.accept(try hook(0, text: String(repeating: "x", count: 32768), message: "next"))
        state.accept(try hook(1, text: "over budget", message: "next"))
        XCTAssertNil(state.preview)
        XCTAssertLessThan(state.estimatedBytes, 1024)
    }

    func testHookPreviewFiltersDisplayControlsWithoutHidingConflictingBatches() throws {
        var state = AgentHookOverlayState()
        state.accept(try hook(0, text: "safe\u{202e}text\u{1b}\u{85}\t\n"))
        XCTAssertEqual(state.preview?.text, "safetext\t\n")
        state.accept(try hook(0, text: "safetext\t\n"))
        XCTAssertNil(state.preview, "different raw batches must still conflict")
    }

    func testHookOverlayRetiresAgainstCanonicalTextWithoutEnteringHistory() async throws {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        let before = await runtime.snapshot(for: id)!
        let accepted = await runtime.apply(hook: try hook(0, text: "Unique live prose", final: true), to: id)
        XCTAssertTrue(accepted)
        let provisional = await runtime.snapshot(for: id)!
        XCTAssertEqual(provisional.livePreview?.text, "Unique live prose")
        XCTAssertEqual(provisional.messages, before.messages)
        XCTAssertEqual(provisional.cursor, before.cursor)
        XCTAssertEqual(provisional.summary.attention, before.summary.attention)
        _ = await runtime.apply(page: page(.updates, id: "canonical", orders: [1000], from: "live",
            history: nil, live: "live2", text: "Unique live prose"), to: id)
        let canonical = await runtime.snapshot(for: id)!
        XCTAssertNil(canonical.livePreview)
        XCTAssertEqual(canonical.messages.count, 2)
        _ = await runtime.apply(hook: try hook(0, text: "Unique live prose", final: true), to: id)
        let delayed = await runtime.snapshot(for: id)!
        XCTAssertNil(delayed.livePreview)
    }

    func testHookExpirationClearsOnlyProvisionalState() async throws {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        _ = await runtime.apply(hook: try hook(0, text: "Unique incomplete"), to: id)
        _ = await runtime.apply(hook: try hook(0, text: "", event: "TesseraHookExpired"), to: id)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertNil(snapshot.livePreview)
        XCTAssertEqual(snapshot.messages.count, 1)
        let checkpoint = await runtime.ingestionCheckpoint(for: id)
        XCTAssertEqual(checkpoint?.cursor, "live")
    }

    func testOldCommonPrefixAndHistoryDoNotRetireNewPreview() async throws {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500], text: "Sure, an older answer"), to: id)
        _ = await runtime.apply(hook: try hook(0, text: "Sure"), to: id)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.livePreview?.text, "Sure")
        _ = await runtime.apply(page: page(.history, id: "history", orders: [100], from: "older",
            text: "Sure, an even older answer"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.livePreview?.text, "Sure")
        _ = await runtime.apply(hook: try hook(1, text: ", a new answer", final: true), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.livePreview?.text, "Sure, a new answer")
        _ = await runtime.apply(page: page(.updates, id: "update", orders: [1000], from: "live",
            live: "live2", text: "Sure, a new answer"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertNil(snapshot.livePreview)
    }

    private func page(_ operation: AgentIngestionRange.Operation, id: String, orders: [UInt64],
                      from: String? = nil, history: String? = "older", live: String? = "live",
                      revision: UInt64 = 1, text: String = "Hello", epoch: String = "epoch") -> AgentProjectionPage {
        .init(sourceIdentity: "jsonl:1:2", from: from,
              records: orders.map { .init(sequence: $0, recordID: "r\($0)",
                  record: .object(["type": .string("assistant"), "text": .string(text)]), revision: revision)! },
              cursor: history, hasMore: history != nil,
              ingestion: .init(epoch: epoch, requestID: id, operation: operation,
                               liveCursor: operation == .history ? nil : live)!)!
    }

    private func runtime() async -> (AgentCenterRuntime, AgentThreadID) {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "ingestion")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        return (runtime, id)
    }

    func testSparseOrdersAndIndependentHistoryLiveContinuity() async {
        let (runtime, id) = await runtime()
        let bootstrap = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500, 1000]), to: id)
        XCTAssertEqual(bootstrap, .sourceReset)
        let live = await runtime.apply(page: page(.updates, id: "update", orders: [1200], from: "live", history: nil, live: "live2"), to: id)
        XCTAssertEqual(live, .applied)
        let afterLive = await runtime.snapshot(for: id)!
        XCTAssertEqual(afterLive.cursor, "older")
        let history = await runtime.apply(page: page(.history, id: "history", orders: [0, 250], from: "older", history: nil), to: id)
        XCTAssertEqual(history, .applied)
        let next = await runtime.apply(page: page(.updates, id: "update2", orders: [1500], from: "live2", history: nil, live: "live3"), to: id)
        XCTAssertEqual(next, .applied)
        let complete = await runtime.snapshot(for: id)!
        XCTAssertEqual(complete.messages.map(\.recordID), ["r0", "r250", "r500", "r1000", "r1200", "r1500"])
        XCTAssertFalse(complete.hasMore)
    }

    func testRevisionsUpsertAndReplayCannotDuplicateOrRewriteSameRevision() async {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        let revised = page(.updates, id: "up", orders: [500], from: "live", history: nil, live: "live2", revision: 2, text: "Revised")
        let applied = await runtime.apply(page: revised, to: id)
        XCTAssertEqual(applied, .applied)
        let replay = await runtime.apply(page: revised, to: id)
        XCTAssertEqual(replay, .duplicate)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages.first?.blocks, [.text("Revised")])
        let invalid = await runtime.apply(page: page(.updates, id: "bad", orders: [500], from: "live2", history: nil,
            live: "live3", revision: 2, text: "Invalid rewrite"), to: id)
        XCTAssertEqual(invalid, .resyncRequired)
    }

    func testWrongCursorOrEpochCannotCommitAnyRecords() async {
        let (runtime, id) = await runtime()
        _ = await runtime.apply(page: page(.bootstrap, id: "boot", orders: [500]), to: id)
        for candidate in [page(.updates, id: "bad1", orders: [1000], from: "older", history: nil),
                          page(.history, id: "bad2", orders: [0], from: "live"),
                          page(.updates, id: "bad3", orders: [1000], from: "live", history: nil, epoch: "replacement")] {
            let result = await runtime.apply(page: candidate, to: id)
            XCTAssertEqual(result, .resyncRequired)
        }
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.count, 1)
    }
}
