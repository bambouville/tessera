import XCTest
@testable import TesseraAgentCore

final class AgentHostSearchTests: XCTestCase {
    private let epoch = "epoch_1"
    private let requestID = "request_1"

    private func frame(_ kind: String, _ fields: [String: AgentJSONValue] = [:]) -> [String: AgentJSONValue] {
        fields.merging(["kind": .string(kind), "id": .string(requestID), "serviceEpoch": .string(epoch)]) { _, envelope in envelope }
    }

    private func record(_ thread: String, _ id: String, _ order: Int, _ body: [String: AgentJSONValue]) -> [String: AgentJSONValue] {
        frame("search.record", ["thread": .string(thread), "recordID": .string(id), "sourceIdentity": .string("jsonl:1:2"),
                                "order": .number(Decimal(order)), "revision": .number(1), "record": .object(body)])
    }

    private func message(_ text: String) -> [String: AgentJSONValue] {
        ["type": .string("message"), "role": .string("user"),
         "blocks": .array([.object(["type": .string("text"), "text": .string(text)])])]
    }

    func testHostCandidatesAreMatchedAgainExactlyForTheHeldThreadsOnly() throws {
        let first = try XCTUnwrap(AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "first"))
        let second = try XCTUnwrap(AgentThreadID(hostID: first.hostID, providerID: .codex, providerSessionID: "second"))
        let reply = try AgentHostSearchReply(frames: [
            frame("search.begin"),
            record("t1", "visible", 9, message("A visible CAFÉ note")).merging(["seekToken": .string("0123456789abcdef:u-9")]) { $1 },
            // The host prefilter folds every string value; hidden context
            // never matches in the app.
            record("t1", "hidden", 8, ["type": .string("system"), "text": .string("hidden cafe context")]),
            record("t2", "other", 3, message("another café")).merging(["seekToken": .number(7)]) { $1 },
            record("t3", "foreign", 1, message("cafe of a handle not held")),
            frame("search.skipped", ["thread": .string("t4"), "code": .string("searchUnsupported")]),
            frame("search.end", ["records": .number(4), "threadsLeft": .number(1), "cursor": .string("next_1")]),
        ], epoch: epoch, requestID: requestID)
        let results = reply.matches(threads: ["t1": first, "t2": second], query: "cafe")
        XCTAssertEqual(results.map(\.recordID), ["visible", "other"])
        XCTAssertEqual(results.map(\.threadID), [first, second])
        // The seek token rides along as given; one that is not a string is dropped.
        XCTAssertEqual(results.map(\.seekToken), ["0123456789abcdef:u-9", nil])
        XCTAssertEqual(reply.skipped, [.init(thread: "t4", code: "searchUnsupported")])
        XCTAssertTrue(AgentHostSearchReply.pagedFallbackCodes.contains("searchUnsupported"))
        XCTAssertFalse(AgentHostSearchReply.pagedFallbackCodes.contains("invalidRequest"))
        XCTAssertEqual(reply.cursor, "next_1")
    }

    func testEachThreadKeepsAtMostItsShare() throws {
        let thread = try XCTUnwrap(AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "busy"))
        let records = (0..<30).map { record("t1", "r\($0)", 100 - $0, message("needle \($0)")) }
        let reply = try AgentHostSearchReply(frames: [frame("search.begin")] + records +
            [frame("search.end", ["records": .number(30), "threadsLeft": .number(0)])], epoch: epoch, requestID: requestID)
        XCTAssertEqual(reply.matches(threads: ["t1": thread], query: "needle").count, 25)
        XCTAssertNil(reply.cursor)
    }

    func testMalformedRepliesFailClosed() throws {
        let begin = frame("search.begin"), end = frame("search.end", ["records": .number(1), "threadsLeft": .number(0)])
        let good = record("t1", "r", 1, message("x"))
        XCTAssertNoThrow(try AgentHostSearchReply(frames: [begin, good, end], epoch: epoch, requestID: requestID))
        var otherEpoch = good; otherEpoch["serviceEpoch"] = .string("epoch_2")
        XCTAssertThrowsError(try AgentHostSearchReply(frames: [begin, otherEpoch, end], epoch: epoch, requestID: requestID)) {
            XCTAssertEqual($0 as? AgentIngestionError, .staleEpoch)
        }
        var otherRequest = good; otherRequest["id"] = .string("request_2")
        var badHandle = good; badHandle["thread"] = .string("bad/handle")
        var noRevision = good; noRevision["revision"] = .number(0)
        var fractional = good; fractional["order"] = .number(1.5)
        var noBody = good; noBody["record"] = nil
        var badCursor = end; badCursor["cursor"] = .string("not an identifier")
        let cases: [String: [[String: AgentJSONValue]]] = [
            "another request": [begin, otherRequest, end],
            "a bad handle": [begin, badHandle, end],
            "a zero revision": [begin, noRevision, end],
            "a fractional order": [begin, fractional, end],
            "no record": [begin, noBody, end],
            "a miscounted end": [begin, good, good, end],
            "no begin": [good, end],
            "no end": [begin, good],
            "a second begin": [begin, begin, good, end],
            "an unknown frame": [begin, frame("search.other"), good, end],
            "a skipped thread without a code": [begin, frame("search.skipped", ["thread": .string("t2")]), good, end],
            "a cursor that is no identifier": [begin, good, badCursor],
        ]
        for (label, frames) in cases {
            XCTAssertThrowsError(try AgentHostSearchReply(frames: frames, epoch: epoch, requestID: requestID), label)
        }
        XCTAssertThrowsError(try AgentHostSearchReply(frames: [begin, good, end], epoch: "bad epoch", requestID: requestID))
    }

    func testFramedBytesDecodeWithinTheirBound() throws {
        let frames = [frame("search.begin"), record("t1", "r", 1, message("x")),
                      frame("search.end", ["records": .number(1), "threadsLeft": .number(0)])]
        var wire = Data()
        for value in frames {
            let body = try JSONEncoder().encode(AgentJSONValue.object(value))
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { wire.append(contentsOf: $0) }
            wire.append(body)
        }
        let reply = try AgentHostSearchReply.decode(wire, epoch: epoch, requestID: requestID)
        XCTAssertEqual(reply.candidates.map(\.record.recordID), ["r"])
        XCTAssertThrowsError(try AgentHostSearchReply.decode(wire.dropLast(), epoch: epoch, requestID: requestID))
        XCTAssertThrowsError(try AgentHostSearchReply.decode(Data(count: AgentHostSearchReply.maximumBytes + 1),
                                                             epoch: epoch, requestID: requestID)) {
            XCTAssertEqual($0 as? AgentIngestionError, .capacityExceeded)
        }
    }

    // MARK: One host's search run

    private func reply(records: [(String, String)], skipped: [(String, String)] = [],
                       cursor: String? = nil, oversized: Int = 0) throws -> AgentHostSearchReply {
        var end: [String: AgentJSONValue] = ["records": .number(Decimal(records.count)), "threadsLeft": .number(0)]
        if let cursor { end["cursor"] = .string(cursor) }
        if oversized > 0 { end["oversizedRecords"] = .number(Decimal(oversized)) }
        let frames = [frame("search.begin")]
            + records.enumerated().map { index, value in record(value.0, value.1, 10_000 - index, message("needle \(value.1)")) }
            + skipped.map { frame("search.skipped", ["thread": .string($0.0), "code": .string($0.1)]) }
            + [frame("search.end", end)]
        return try AgentHostSearchReply(frames: frames, epoch: epoch, requestID: requestID)
    }

    private func threads(_ handles: [String]) throws -> [String: AgentThreadID] {
        let host = UUID()
        return try Dictionary(uniqueKeysWithValues: handles.map {
            ($0, try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "s-\($0)")))
        })
    }

    func testARunTellsTheHostWhichThreadsHoldTheirShare() async throws {
        let held = try threads(["t1", "t2"])
        var sent: [[String: AgentJSONValue]] = []
        let outcome = try await AgentHostSearchRun.run(
            handles: ["t1", "t2"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { fields, deadline in
                XCTAssertLessThanOrEqual(deadline, .seconds(15))
                sent.append(fields)
                if sent.count == 1 { return try self.reply(records: (0..<30).map { ("t1", "a\($0)") }, cursor: "next_1") }
                return try self.reply(records: [("t2", "b0"), ("t2", "b1")])
            }, accept: { _ in true })
        XCTAssertEqual(outcome.results.filter { $0.threadID == held["t1"] }.count, 25)
        XCTAssertEqual(outcome.results.filter { $0.threadID == held["t2"] }.map(\.recordID), ["b0", "b1"])
        XCTAssertTrue(outcome.complete)
        XCTAssertEqual(sent[0]["threads"], .array([.string("t1"), .string("t2")]))
        XCTAssertNil(sent[0]["limit"], "the host reads each thread to its end")
        XCTAssertEqual(sent[1]["cursor"], .string("next_1"))
        XCTAssertEqual(sent[1]["satisfied"], .array([.string("t1")]))
    }

    func testARunShowsWhatEachReplyAddsAsItLands() async throws {
        let held = try threads(["t1", "t2"])
        var calls = 0
        var seen: [[String]] = []
        let outcome = try await AgentHostSearchRun.run(
            handles: ["t1", "t2"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in
                calls += 1
                switch calls {
                case 1: return try self.reply(records: [("t1", "a0"), ("t1", "a1")], cursor: "next_1")
                case 2: return try self.reply(records: [], cursor: "next_2")
                default: return try self.reply(records: [("t2", "b0")])
                }
            }, accept: { _ in true },
            progress: { seen.append($0.map(\.recordID)) })
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(seen, [["a0", "a1"], ["a0", "a1", "b0"]], "a reply that adds nothing shows nothing new")
        XCTAssertEqual(outcome.results.map(\.recordID), ["a0", "a1", "b0"])
    }

    func testTheEndKeepsTheRowsShownWhileTheSearchRan() throws {
        let host = UUID()
        let t1 = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "s-1"))
        let t2 = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "s-2"))
        let loaded = [AgentSearchResult(threadID: t1, recordID: "r9", excerpt: "loaded needle")]
        let found = [AgentSearchResult(threadID: t2, recordID: "r1", excerpt: "host needle"),
                     AgentSearchResult(threadID: t1, recordID: "r9", excerpt: "host copy"),
                     AgentSearchResult(threadID: t1, recordID: "r2", excerpt: "older needle")]
        let other = UUID()
        let merged = AgentSearchSnapshot.merging(loaded, found, unavailableHostIDs: [other])
        XCTAssertEqual(merged.results.map(\.recordID), ["r9", "r1", "r2"])
        XCTAssertEqual(merged.results.first?.excerpt, "loaded needle", "each record once, as first shown")
        XCTAssertEqual(merged.unavailableHostIDs, [other])
        let many = (0..<150).map { AgentSearchResult(threadID: t2, recordID: "m\($0)", excerpt: "needle") }
        XCTAssertEqual(AgentSearchSnapshot.merging(loaded, many).results.count, AgentSearchSnapshot.maximumResultsPerHost)
        XCTAssertEqual(AgentSearchSnapshot.merging(loaded, many).results.first?.recordID, "r9")
    }

    func testAResultCarriesItsRecordsPositionThroughMergingAndCoding() throws {
        let thread = try XCTUnwrap(AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "s-1"))
        let record = try XCTUnwrap(AgentProjectionRecord(sequence: 37, recordID: "claude-chain:g:37",
            record: .object(message("found the needle here")),
            sourceOffset: 4_096, seekToken: "0123456789abcdef:m-37"))
        let found = AgentNativePageSearch.matches(records: [record], threadID: thread, query: "needle")
        XCTAssertEqual(found.map(\.sequence), [37])
        XCTAssertEqual(found.map(\.sourceOffset), [4_096])
        XCTAssertEqual(found.map(\.seekToken), ["0123456789abcdef:m-37"])
        // A loaded copy without a position takes the host copy's.
        let loaded = AgentSearchResult(threadID: thread, recordID: "claude-chain:g:37", excerpt: "loaded")
        let merged = AgentSearchSnapshot.merging([loaded], found).results
        XCTAssertEqual(merged.map(\.excerpt), ["loaded"])
        XCTAssertEqual(merged.map(\.sequence), [37])
        XCTAssertEqual(merged.map(\.sourceOffset), [4_096])
        XCTAssertEqual(merged.map(\.seekToken), ["0123456789abcdef:m-37"])
        let coded = try JSONDecoder().decode(AgentSearchResult.self, from: JSONEncoder().encode(merged[0]))
        XCTAssertEqual(coded, merged[0])
        // An encoding from before positions still decodes, with none; one
        // that lost its order keeps no offset or token either.
        let placed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(merged[0])) as? [String: Any])
        for key in ["sequence", "sourceOffset", "seekToken"] { XCTAssertNotNil(placed[key], key) }
        for removed in [["sequence", "sourceOffset", "seekToken"], ["sequence"]] {
            var legacy = placed
            for key in removed { legacy.removeValue(forKey: key) }
            let old = try JSONDecoder().decode(AgentSearchResult.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(old.excerpt, "loaded", "\(removed)")
            XCTAssertNil(old.sequence, "\(removed)")
            XCTAssertNil(old.sourceOffset, "\(removed)")
            XCTAssertNil(old.seekToken, "\(removed)")
        }
        // A placed copy without a token takes a later copy's whole position
        // when that one carries a token; a token never joins another copy's
        // order, and a copy with a token keeps its own.
        let untokened = AgentSearchResult(threadID: thread, recordID: "claude-chain:g:37", excerpt: "loaded", sequence: 36, sourceOffset: 4_000)
        let proven = AgentSearchSnapshot.merging([untokened], found).results
        XCTAssertEqual(proven.map(\.excerpt), ["loaded"])
        XCTAssertEqual(proven.map(\.sequence), [37])
        XCTAssertEqual(proven.map(\.sourceOffset), [4_096])
        XCTAssertEqual(proven.map(\.seekToken), ["0123456789abcdef:m-37"])
        let tokened = AgentSearchResult(threadID: thread, recordID: "claude-chain:g:37", excerpt: "loaded", sequence: 36,
                                        seekToken: "fedcba9876543210:m-37")
        let kept = AgentSearchSnapshot.merging([tokened], found).results
        XCTAssertEqual(kept.map(\.sequence), [36])
        XCTAssertEqual(kept.map(\.sourceOffset), [nil])
        XCTAssertEqual(kept.map(\.seekToken), ["fedcba9876543210:m-37"])
        XCTAssertEqual(AgentSearchSnapshot.merging(found, [untokened]).results, found, "a later copy without a token changes nothing")
        // An offset or token never stands without the order it proves.
        XCTAssertNil(AgentSearchResult(threadID: thread, recordID: "r", excerpt: "e", sourceOffset: 9).sourceOffset)
        XCTAssertNil(AgentSearchResult(threadID: thread, recordID: "r", excerpt: "e", seekToken: "0123456789abcdef").seekToken)
        // A token the app could not send back is dropped, never the record.
        for bad in ["", "has space", String(repeating: "a", count: 129), "caf\u{e9}"] {
            let kept = try XCTUnwrap(AgentProjectionRecord(sequence: 1, recordID: "r", record: .object(message("x")), seekToken: bad))
            XCTAssertNil(kept.seekToken, bad)
            XCTAssertNil(AgentSearchResult(threadID: thread, recordID: "r", excerpt: "e", sequence: 1, seekToken: bad).seekToken, bad)
        }
    }

    func testARunKeepsWhatItFoundWhenTimeOrTheConnectionRunsOut() async throws {
        let held = try threads(["t1"])
        for failure in [AgentIngestionError.remote("deadlineExceeded"), .capacityExceeded] {
            var calls = 0
            let outcome = try await AgentHostSearchRun.run(
                handles: ["t1"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
                request: { _, _ in
                    calls += 1
                    if calls == 1 { return try self.reply(records: [("t1", "a"), ("t1", "b")], cursor: "next_1") }
                    throw failure
                }, accept: { _ in true })
            XCTAssertEqual(outcome.results.map(\.recordID), ["a", "b"])
            XCTAssertFalse(outcome.complete)
        }
        var budget = [Duration.seconds(30), .zero]
        let outcome = try await AgentHostSearchRun.run(
            handles: ["t1"], threads: held, query: "needle", admitted: 0, timeLeft: { budget.removeFirst() },
            request: { _, _ in try self.reply(records: [("t1", "a")], cursor: "next_1") }, accept: { _ in true })
        XCTAssertEqual(outcome.results.map(\.recordID), ["a"])
        XCTAssertFalse(outcome.complete)
    }

    func testARefusedSearchPagesAndAnUnfinishedThreadReadsIncomplete() async throws {
        let held = try threads(["t1", "t2", "t3"])
        let refused = try await AgentHostSearchRun.run(
            handles: ["t1", "t2"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in throw AgentIngestionError.remote("busy") }, accept: { _ in true })
        XCTAssertEqual(refused.paged, ["t1", "t2"])
        XCTAssertTrue(refused.complete)
        let skipped = try await AgentHostSearchRun.run(
            handles: ["t1", "t2", "t3"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in
                try self.reply(records: [("t3", "c")], skipped: [("t1", "searchUnsupported"), ("t2", "sourceChanged")])
            }, accept: { _ in true })
        XCTAssertEqual(skipped.paged, ["t1"])
        XCTAssertEqual(skipped.results.map(\.recordID), ["c"])
        XCTAssertFalse(skipped.complete)
        // A thread the host skips after it already gave matches is not paged
        // again from its start: it stands as found, and incomplete.
        var calls = 0
        let resumed = try await AgentHostSearchRun.run(
            handles: ["t1"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in
                calls += 1
                if calls == 1 { return try self.reply(records: [("t1", "a")], cursor: "next_1") }
                return try self.reply(records: [], skipped: [("t1", "searchUnsupported"), ("t1", "searchUnsupported")])
            }, accept: { _ in true })
        XCTAssertEqual(resumed.results.map(\.recordID), ["a"])
        XCTAssertEqual(resumed.paged, [])
        XCTAssertFalse(resumed.complete)
        // The app's own connection failures are not a host refusing: what
        // was found stands and the host reads incomplete, never paged.
        for failure: Error in [AgentIngestionError.remote("disconnected"), AgentIngestionError.remote("helperDiagnostic"),
                               AgentIngestionError.remote("deadlineExceeded"), CancellationError()] {
            let closed = try await AgentHostSearchRun.run(
                handles: ["t1", "t2"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
                request: { _, _ in throw failure }, accept: { _ in true })
            XCTAssertEqual(closed.paged, [], "\(failure)")
            XCTAssertFalse(closed.complete, "\(failure)")
        }
        // Only the search's own cancellation ends it.
        let search = Task {
            try await AgentHostSearchRun.run(
                handles: ["t1"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
                request: { _, _ in try await Task.sleep(for: .seconds(30)); throw AgentIngestionError.remote("busy") },
                accept: { _ in true })
        }
        search.cancel()
        do {
            _ = try await search.value
            XCTFail("cancellation must propagate")
        } catch is CancellationError {}
    }

    func testMatchesTheCallerNoLongerShowsOrTheHostLeftOutReadIncomplete() async throws {
        let held = try threads(["t1", "t2"])
        let stale = try await AgentHostSearchRun.run(
            handles: ["t1", "t2"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in try self.reply(records: [("t1", "a"), ("t2", "b")]) },
            accept: { match in match.threadID == held["t1"] })
        XCTAssertEqual(stale.results.map(\.recordID), ["a"])
        XCTAssertFalse(stale.complete)
        let oversized = try await AgentHostSearchRun.run(
            handles: ["t1"], threads: held, query: "needle", admitted: 0, timeLeft: { .seconds(30) },
            request: { _, _ in try self.reply(records: [("t1", "a")], oversized: 2) }, accept: { _ in true })
        XCTAssertEqual(oversized.results.map(\.recordID), ["a"])
        XCTAssertFalse(oversized.complete)
        let whole = try self.reply(records: [("t1", "a")])
        XCTAssertEqual(whole.oversizedRecords, 0)
        XCTAssertThrowsError(try AgentHostSearchReply(frames: [frame("search.begin"),
            frame("search.end", ["records": .number(0), "oversizedRecords": .string("2")])], epoch: epoch, requestID: requestID))
    }

    func testARunStopsAtTheHostShareAndSplitsLongThreadListsIntoBatches() async throws {
        let handles = (0..<2_500).map { String(format: "h%05d", $0) }
        let held = try threads(handles)
        var sizes: [Int] = []
        let outcome = try await AgentHostSearchRun.run(
            handles: handles, threads: held, query: "needle", admitted: 90, timeLeft: { .seconds(30) },
            request: { fields, _ in
                sizes.append(fields["threads"]?.arrayValue?.count ?? -1)
                let first = fields["threads"]?.arrayValue?.first?.stringValue ?? ""
                return try self.reply(records: sizes.count == 3 ? (0..<20).map { (first, "r\($0)") } : [])
            }, accept: { _ in true })
        XCTAssertEqual(sizes, [1_000, 1_000, 500])
        XCTAssertEqual(outcome.results.count, 10, "100 per host counting what is already admitted")
        let long = (0..<1_000).map { String(repeating: "x", count: 120) + String($0) }
        let batches = AgentHostSearchReply.batches(long)
        XCTAssertEqual(batches.flatMap { $0 }, long)
        XCTAssertTrue(batches.allSatisfy { $0.reduce(0) { $0 + $1.utf8.count + 3 } <= 49_152 })
        XCTAssertGreaterThan(batches.count, 2)
    }

    func testTheNeedleKeepsWithinTheBytesAHostAccepts() {
        let korean = String(repeating: "\u{D55C}", count: 300)
        let needle = AgentHostSearchReply.needle("  " + korean + "  ")
        XCTAssertEqual(needle.utf8.count, 510)
        XCTAssertTrue(korean.hasPrefix(needle))
        XCTAssertEqual(AgentHostSearchReply.needle(" e\u{301}x "), "e\u{301}x")
        XCTAssertEqual(AgentHostSearchReply.needle(String(repeating: "a", count: 600)).count, 512)
    }

    func testTooManyFramesFailClosed() {
        let records = (0..<AgentHostSearchReply.maximumFrames - 1).map { record("t1", "r\($0)", $0 + 1, message("x")) }
        let frames = [frame("search.begin")] + records
            + [frame("search.end", ["records": .number(Decimal(records.count)), "threadsLeft": .number(0)])]
        XCTAssertThrowsError(try AgentHostSearchReply(frames: frames, epoch: epoch, requestID: requestID))
        XCTAssertNoThrow(try AgentHostSearchReply(frames: Array(frames.prefix(2)) + [frame("search.end", ["records": .number(1), "threadsLeft": .number(0)])],
                                                  epoch: epoch, requestID: requestID))
    }
}
