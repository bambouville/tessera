import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentIngestionWindowTests: XCTestCase {
    private func titleRuntime(_ provider: AgentProviderID = .codex) async -> (AgentCenterRuntime, AgentThreadID) {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "window-title")!
        await runtime.register(.init(id: id, providerName: "Agent", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        return (runtime, id)
    }

    private func titleSegment(_ sequence: UInt64, text: String, source: String = "source",
                              older: Bool = true, role: String = "user") throws -> AgentIngestionSegment {
        try AgentIngestionSegment(id: "segment-\(sequence)", source: source, before: "before-\(sequence)",
            after: "after-\(sequence)", hasOlder: older, hasNewer: false, records: [
                AgentProjectionRecord(sequence: sequence, recordID: "record-\(sequence)",
                    record: .object(["type": .string(role), "text": .string(text)]))!
            ])
    }

    func testMidThreadWindowDoesNotSeedFromLatePrompt() async throws {
        let (runtime, id) = await titleRuntime()
        let late = try titleSegment(900, text: "one more pass over the retry path…")
        let result = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1), to: id)
        XCTAssertEqual(result, .sourceReset)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, snapshot.summary.providerName)
        XCTAssertEqual(snapshot.summary.titleProvenance, .placeholder)
        XCTAssertNil(snapshot.summary.titleSeed)
        let pending = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertTrue(pending.isEmpty)
    }

    func testWindowNativeTitleIsVisibleOnFirstApplyAndAcrossSourceReplacement() async throws {
        let (runtime, id) = await titleRuntime()
        let late = try titleSegment(900, text: "one more pass over the retry path…")
        let named: AgentJSONValue = .object(["nativeTitle": .string("Survey the build cache layout")])
        _ = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1, summary: named), to: id)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Survey the build cache layout")
        XCTAssertEqual(snapshot.summary.titleProvenance, .native)
        XCTAssertNil(snapshot.summary.titleSeed)

        _ = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1,
            requestID: "same-source-rebootstrap"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Survey the build cache layout")

        let replacement = try titleSegment(900, text: "unrelated late request", source: "new-source")
        _ = await runtime.apply(page: try projection(replacement, lane: .bootstrap, version: 1,
            summary: .object(["nativeTitle": .string("A new native title")]),
            requestID: "source-replacement"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "A new native title")
        XCTAssertEqual(snapshot.summary.titleProvenance, .native)
        XCTAssertNil(snapshot.summary.titleSeed)
    }

    func testWindowOpeningPromptSeedsGenerationAndSurvivesSameSourceBootstrap() async throws {
        let (runtime, id) = await titleRuntime()
        await runtime.setTitleCharacterBudget(28)
        let late = try titleSegment(900, text: "late request")
        let opening = "  Explain   the cache eviction\npolicy for large builds  "
        _ = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1,
            summary: .object(["openingPrompt": .string(opening)])), to: id)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.titleSeed, "Explain the cache eviction policy for large builds")
        XCTAssertEqual(snapshot.summary.titleProvenance, .prompt)
        XCTAssertTrue(snapshot.summary.title.hasSuffix("…"))
        XCTAssertLessThan(snapshot.summary.title.count, snapshot.summary.titleSeed!.count)
        let pending = await runtime.threadsAwaitingGeneratedTitle()
        XCTAssertEqual(pending.map(\.seed), [snapshot.summary.titleSeed!])

        _ = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1,
            requestID: "same-source-rebootstrap"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.titleSeed, "Explain the cache eviction policy for large builds")
        XCTAssertEqual(snapshot.summary.titleProvenance, .prompt)

        let replacement = try titleSegment(900, text: "different late request", source: "new-source")
        _ = await runtime.apply(page: try projection(replacement, lane: .bootstrap, version: 1,
            requestID: "source-replacement"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertNil(snapshot.summary.titleSeed)
        XCTAssertEqual(snapshot.summary.titleProvenance, .placeholder)
    }

    func testTerminalOlderPageFindsOpeningPromptAndHeadDoesNotReseed() async throws {
        let (runtime, id) = await titleRuntime()
        let late = try titleSegment(900, text: "late request")
        _ = await runtime.apply(page: try projection(late, lane: .bootstrap, version: 1), to: id)
        let middle = try titleSegment(500, text: "middle request")
        _ = await runtime.apply(page: try projection(middle, lane: .before, version: 2, from: "before-900"), to: id)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertNil(snapshot.summary.titleSeed)
        let first = try titleSegment(0, text: "true opening request", older: false)
        _ = await runtime.apply(page: try projection(first, lane: .before, version: 3, from: "before-500"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.titleSeed, "true opening request")

        let head = try titleSegment(901, text: "even later request")
        _ = await runtime.apply(page: try projection(head, lane: .head, version: 4, from: "live", live: "live2"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertFalse(snapshot.messages.contains { $0.recordID == "record-0" }, "the terminal page was evicted")
        XCTAssertTrue(snapshot.ingestionWindow!.hasOlder)
        XCTAssertEqual(snapshot.summary.titleSeed, "true opening request")
    }

    func testWindowHeadRenameMissingMetadataAndPinnedTitle() async throws {
        let (runtime, id) = await titleRuntime()
        let first = try titleSegment(900, text: "late request")
        _ = await runtime.apply(page: try projection(first, lane: .bootstrap, version: 1,
            summary: .object(["nativeTitle": .string("Original")])) , to: id)
        let head = try titleSegment(901, text: "later request")
        _ = await runtime.apply(page: try projection(head, lane: .head, version: 2, from: "live", live: "live2",
            summary: .object(["nativeTitle": .string("Renamed")])) , to: id)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Renamed")
        let next = try titleSegment(902, text: "latest request")
        _ = await runtime.apply(page: try projection(next, lane: .head, version: 3, from: "live2", live: "live3"), to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "Renamed")
        await runtime.configure(metadata: [.init(threadID: id, pinnedTitle: "My title")])
        let last = try titleSegment(903, text: "newest request")
        _ = await runtime.apply(page: try projection(last, lane: .head, version: 4, from: "live3", live: "live4",
            summary: .object(["nativeTitle": .string("Host rename")])) , to: id)
        snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.summary.title, "My title")
        XCTAssertEqual(snapshot.summary.titleProvenance, .pinned)
    }

    func testTerminalWindowSeedsAllProvidersWhileRecordTitlesWin() async throws {
        for provider: AgentProviderID in [.claude, .codex, .pi, .kimi, .opencode] {
            let (runtime, id) = await titleRuntime(provider)
            let opening = AgentProjectionRecord(sequence: 1, recordID: "opening",
                record: .object(["type": .string("user"), "text": .string("First request")]))!
            let titled = AgentProjectionRecord(sequence: 2, recordID: "provider-title",
                record: .object(["type": .string(provider == .claude ? "ai-title" : "session-title"),
                                 "title": .string("Provider title")]))!
            let segment = try AgentIngestionSegment(id: "complete", source: "source", before: "start", after: "end",
                hasOlder: false, hasNewer: false, records: [opening, titled])
            _ = await runtime.apply(page: try projection(segment, lane: .bootstrap, version: 1), to: id)
            let snapshot = await runtime.snapshot(for: id)!
            XCTAssertEqual(snapshot.summary.titleSeed, "First request", "\(provider.rawValue)")
            XCTAssertEqual(snapshot.summary.title, "Provider title", "\(provider.rawValue)")
            XCTAssertEqual(snapshot.summary.titleProvenance, .native, "\(provider.rawValue)")
        }
    }

    func testFirstBootstrapPreservesNativeTitleAlreadyVisibleInDetectedRow() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "first-title-window")!
        await runtime.register(.init(id: id, providerName: "Codex", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let summary = try AgentIngestionSummary.decode(JSONSerialization.data(withJSONObject: [
            "kind": "summary", "id": "metadata", "thread": "thread", "serviceEpoch": "epoch",
            "revision": "title", "modified": 1_000,
            "records": [["type": "session-title", "title": "Stable provider title"]]
        ]), epoch: "epoch", thread: "thread")
        _ = await runtime.apply(summary: summary, to: id)
        await runtime.select(threadID: id)
        let latest = try AgentIngestionSegment(id: "first", source: "source", before: "begin", after: "end",
            hasOlder: true, hasNewer: false, records: [.init(sequence: 900, recordID: "latest-prompt",
                record: .object(["type": .string("user"), "text": .string("yes")]))!])
        _ = await runtime.apply(page: try projection(latest, lane: .bootstrap, version: 1), to: id)
        let opened = await runtime.snapshot(for: id)!
        XCTAssertEqual(opened.summary.title, "Stable provider title")
        XCTAssertEqual(opened.summary.titleProvenance, .native)
        XCTAssertTrue(opened.messages.contains { $0.role == .user })
    }

    func testReopeningSameSourceNeverPublishesPromptBetweenNativeTitleReplies() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "title-window")!
        await runtime.register(.init(id: id, providerName: "Codex", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let initial = try projection(segment(900), lane: .bootstrap, version: 1)
        _ = await runtime.apply(page: initial, to: id)
        let summary = try AgentIngestionSummary.decode(JSONSerialization.data(withJSONObject: [
            "kind": "summary", "id": "metadata", "thread": "thread", "serviceEpoch": "epoch",
            "revision": "title", "modified": 1_000,
            "records": [["type": "session-title", "title": "Stable provider title"]]
        ]), epoch: "epoch", thread: "thread")
        _ = await runtime.apply(summary: summary, to: id)
        await runtime.select(threadID: id)
        for _ in 0..<3 {
            await runtime.releaseIngestionWindow(for: id)
            let result = await runtime.apply(page: initial, to: id)
            XCTAssertEqual(result, .sourceReset)
            // Assert BEFORE the delayed summary response, not only afterwards.
            let reopened = await runtime.snapshot(for: id)!
            XCTAssertEqual(reopened.summary.title, "Stable provider title")
            XCTAssertEqual(reopened.summary.titleProvenance, .native)
            _ = await runtime.apply(summary: summary, to: id)
        }
        let replaced = try AgentIngestionSegment(id: "replacement", source: "different-source",
            before: "begin", after: "end", hasOlder: false, hasNewer: false, records: [])
        await runtime.releaseIngestionWindow(for: id)
        _ = await runtime.apply(page: try projection(replaced, lane: .bootstrap, version: 1), to: id)
        let changed = await runtime.snapshot(for: id)!
        XCTAssertEqual(changed.summary.titleProvenance, .placeholder)
    }

    private func segment(_ start: Int, count: Int = 100, total: Int = 1000, suffix: String = "", text: String = "hello") throws -> AgentIngestionSegment {
        try .init(id: "s\(start)\(suffix)", source: "source", before: "b\(start)", after: "a\(start + count)",
            hasOlder: start > 0, hasNewer: start + count < total,
            records: (start..<(start + count)).map { .init(sequence: UInt64($0), recordID: "r\($0)",
                record: .object(["type": .string("assistant"), "text": .string(text)]))! })
    }

    func testTraversesThousandRecordsInBothDirectionsWithoutLosingRecoveryBoundaries() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        var seen = Set(window.records.map(\.recordID))
        for start in stride(from: 800, through: 0, by: -100) {
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version,
                pinnedRecordID: window.records.first?.recordID)
            seen.formUnion(window.records.map(\.recordID))
            XCTAssertLessThanOrEqual(window.viewport.count, 4)
            XCTAssertLessThanOrEqual(window.records.count, 400)
            XCTAssertLessThanOrEqual(window.encodedBytes, 1_310_720)
            XCTAssertEqual(window.records.first?.recordID, "r\(start)")
        }
        XCTAssertEqual(seen.count, 1000)
        XCTAssertFalse(window.hasOlder)
        XCTAssertEqual(window.after, "a400")
        seen = Set(window.records.map(\.recordID))
        for start in stride(from: 400, through: 900, by: 100) {
            try window.navigate(segment(start, suffix: "reloaded"), direction: .after, from: window.after!, expectedVersion: window.version,
                pinnedRecordID: window.records.last?.recordID)
            seen.formUnion(window.records.map(\.recordID))
            XCTAssertLessThanOrEqual(window.viewport.count, 4)
            XCTAssertEqual(window.records.last?.recordID, "r\(start + 99)")
        }
        XCTAssertEqual(seen.count, 1000)
        XCTAssertTrue(window.atLiveHead)
    }

    func testPinnedVictimCannotAdvanceEitherCursorOrDropIncomingHistory() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        for start in [800, 700, 600] {
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        let previous = window
        XCTAssertThrowsError(try window.navigate(segment(500), direction: .before, from: window.before!,
            expectedVersion: window.version, pinnedRecordID: "r950"))
        XCTAssertEqual(window, previous)
    }

    func testLiveBurstDoesNotBridgeHistoricalGapOrMovePinnedReader() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        try window.navigate(segment(800), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: "r920")
        let previous = window.viewport
        try window.replaceHead(segment(1900, total: 2000), expectedVersion: window.version, pinnedRecordID: "r850")
        XCTAssertEqual(window.viewport, previous)
        XCTAssertEqual(window.head?.records.last?.recordID, "r1999")
        XCTAssertFalse(window.atLiveHead)
        XCTAssertEqual(window.retainedIDs.count, 3)
    }

    func testRevisionsCoverDeepRetainedWindowAndHeadAtomically() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        for start in [800, 700, 600, 500, 400, 300] {
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        let patches = [350, 999].map { AgentProjectionRecord(sequence: UInt64($0), recordID: "r\($0)",
            record: .object(["text": .string("revised")]), revision: 2)! }
        try window.revise(patches, expectedVersion: window.version)
        XCTAssertEqual(window.records.first(where: { $0.recordID == "r350" })?.revision, 2)
        XCTAssertEqual(window.head?.records.last?.revision, 2)
        let previous = window
        let unknown = AgentProjectionRecord(sequence: 750, recordID: "r750", record: .object([:]), revision: 2)!
        XCTAssertThrowsError(try window.revise([unknown], expectedVersion: window.version))
        XCTAssertEqual(window, previous)
    }

    func testOnlyNewerCodexFileRevisionsMayAdvancePhysicalOffset() throws {
        func row(_ offset: UInt64?, _ revision: UInt64) -> AgentProjectionRecord {
            .init(sequence: 0, recordID: "item", record: .object(["text": .string("revision \(revision)")]), sourceOffset: offset, revision: revision)!
        }
        for source in ["codex-history:fixture", "claude-chain:fixture", "codex-appserver:fixture"] {
            var window = AgentIngestionWindow()
            try window.bootstrap(.init(id: "segment", source: source, before: "before", after: "after", hasOlder: false, hasNewer: false, records: [row(100, 1)]))
            let original = window
            for invalid in [row(99, 2), row(nil, 2), row(200, 1)] {
                XCTAssertThrowsError(try window.revise([invalid], expectedVersion: window.version))
                XCTAssertEqual(window, original)
            }
            if source.hasPrefix("codex-history:") {
                try window.revise([row(200, 2)], expectedVersion: window.version)
                XCTAssertEqual(window.records.first?.sourceOffset, 200)
                XCTAssertEqual(window.head?.records.first?.revision, 2)
            } else {
                XCTAssertThrowsError(try window.revise([row(200, 2)], expectedVersion: window.version))
                XCTAssertEqual(window, original)
            }
        }
    }

    private func split(_ segment: AgentIngestionSegment) throws -> [AgentIngestionPartition] {
        try [AgentIngestionPartition(original: segment.id, id: segment.id + "left", before: segment.before,
                after: segment.id + "leftafter", offset: 0, count: 50, hasOlder: segment.hasOlder, hasNewer: true),
             AgentIngestionPartition(original: segment.id, id: segment.id + "right", before: segment.id + "rightbefore",
                after: segment.after, offset: 50, count: 50, hasOlder: true, hasNewer: segment.hasNewer)]
    }

    func testGrowingRevisionsSplitOlderAndHeadPagesAndKeepMiddlePin() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900, text: String(repeating: "a", count: 1800)))
        for start in [800, 700, 600] {
            try window.navigate(segment(start, text: String(repeating: "a", count: 1800)), direction: .before,
                from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        let old = window
        let patches = ([800, 900].flatMap { Array($0..<($0 + 7)) }).map {
            AgentProjectionRecord(sequence: UInt64($0), recordID: "r\($0)", record: .object([
                "type": .string("assistant"), "text": .string(String(repeating: "z", count: 15000))]), revision: 2)!
        }
        XCTAssertThrowsError(try window.revise(patches, expectedVersion: window.version))
        XCTAssertEqual(window, old)
        let parts = try split(window.viewport[2]) + split(window.head!)
        try window.revise(patches, expectedVersion: window.version, partitions: parts, pinnedRecordID: "r850")
        XCTAssertEqual(window.version, old.version + 1)
        XCTAssertEqual(window.viewport.count, 4)
        XCTAssertTrue(window.records.contains { $0.recordID == "r850" })
        XCTAssertEqual(window.head?.id, "s900right")
        XCTAssertEqual(window.head?.after, old.head?.after)
        XCTAssertLessThanOrEqual(window.encodedBytes, 1_310_720)
        XCTAssertTrue(window.viewport.allSatisfy { $0.encodedBytes <= 262_144 })
        XCTAssertTrue(zip(window.records, window.records.dropFirst()).allSatisfy { $0.sequence + 1 == $1.sequence })
        XCTAssertEqual(window.records.first { $0.recordID == "r800" }?.revision, 2)
    }

    func testDetachedHeadSplitDoesNotMoveHistoricalViewport() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900, text: String(repeating: "a", count: 1800)))
        for start in [800, 700, 600, 500, 400] {
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        let oldViewport = window.viewport
        let patch = AgentProjectionRecord(sequence: 900, recordID: "r900", record: .object(["text": .string("updated")]), revision: 2)!
        try window.revise([patch], expectedVersion: window.version, partitions: split(window.head!), pinnedRecordID: "r450")
        XCTAssertEqual(window.viewport, oldViewport)
        XCTAssertEqual(window.head?.id, "s900right")
        XCTAssertEqual(window.head?.after, "a1000")
        XCTAssertFalse(window.atLiveHead)
    }

    func testMalformedRevisionPartitionsCannotChangeWindow() throws {
        var window = AgentIngestionWindow(); try window.bootstrap(segment(900))
        let old = window
        let patch = AgentProjectionRecord(sequence: 900, recordID: "r900", record: .object(["text": .string("updated")]), revision: 2)!
        let parts = try split(window.head!)
        let malformed = [Array(parts.prefix(1)), parts.reversed().map { $0 }, [parts[0], parts[0]],
            [try AgentIngestionPartition(original: "foreign", id: "foreignleft", before: "b900", after: "other",
                offset: 0, count: 50, hasOlder: true, hasNewer: true), parts[1]],
            [parts[0], try AgentIngestionPartition(original: "s900", id: "badend", before: "middle", after: "wrong",
                offset: 50, count: 50, hasOlder: true, hasNewer: false)]]
        for partitions in malformed {
            XCTAssertThrowsError(try window.revise([patch], expectedVersion: window.version, partitions: partitions, pinnedRecordID: "r950"))
            XCTAssertEqual(window, old)
        }
        XCTAssertThrowsError(try AgentIngestionPartition(original: "s900", id: "huge", before: "b", after: "a",
            offset: Int.max, count: Int.max, hasOlder: true, hasNewer: true))
    }

    func testNavigationValidatesDetachedHeadProvenanceAtomically() throws {
        func row(_ sequence: UInt64, _ offset: UInt64, _ revision: UInt64, _ id: String, _ text: String = "fixture") -> AgentProjectionRecord {
            .init(sequence: sequence, recordID: id, record: .object(["text": .string(text)]), sourceOffset: offset, revision: revision)!
        }
        func page(_ id: String, _ records: [AgentProjectionRecord]) throws -> AgentIngestionSegment {
            try .init(id: id, source: "codex-history:fixture", before: id + "before", after: id + "after",
                hasOlder: true, hasNewer: false, records: records)
        }
        var window = AgentIngestionWindow()
        try window.bootstrap(page("initial", [row(10, 200, 1, "anchor")]))
        try window.navigate(page("old", [row(1, 10, 1, "olditem")]), direction: .before,
            from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        let live = row(11, 310, 2, "newitem")
        try window.replaceHead(page("live", [live]), expectedVersion: window.version, pinnedRecordID: "olditem")
        let original = window
        for invalid in [row(12, 310, 2, "newitem"), row(11, 100, 1, "newitem"),
                        row(11, 100, 3, "newitem"), row(11, 310, 2, "newitem", "changed")] {
            window = original
            XCTAssertThrowsError(try window.navigate(page("next", [invalid]), direction: .after,
                from: window.after!, expectedVersion: window.version, pinnedRecordID: "olditem"))
            XCTAssertEqual(window, original)
        }
        window = original
        try window.navigate(page("next", [live]), direction: .after,
            from: window.after!, expectedVersion: window.version, pinnedRecordID: "olditem")
        XCTAssertTrue(window.atLiveHead)
    }

    func testRollingHeadNeverLeavesGapAfterHistoricalPrefix() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        try window.navigate(segment(800), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        try window.replaceHead(segment(910, total: 1010), expectedVersion: window.version, pinnedRecordID: "r990")
        // The rolled head still holds r999: history stays, the head detaches.
        XCTAssertEqual(window.viewport.map(\.id), ["s800", "s900"])
        XCTAssertEqual(window.head?.id, "s910")
        XCTAssertTrue(window.atLiveHead)
        XCTAssertFalse(window.hasNewer)
        XCTAssertEqual(window.before, "b800")
        XCTAssertEqual(window.retainedIDs, ["s800", "s900", "s910"])
        // Once the head no longer holds the viewport's newest record, the
        // old head still proves nothing lies between them: history stays.
        try window.replaceHead(segment(1000, total: 1100), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s800", "s900"])
        XCTAssertFalse(window.atLiveHead)
        XCTAssertTrue(window.bridgesToHead)
        XCTAssertEqual(window.presentedRecords.map(\.recordID), (800..<1100).map { "r\($0)" })
        // A head that jumps past everything shown leaves a real gap: a
        // follower collapses to it rather than showing one.
        try window.replaceHead(segment(1300, total: 1400), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s1300"])
        XCTAssertTrue(window.atLiveHead)
        XCTAssertFalse(window.bridgesToHead)
        XCTAssertEqual(window.before, "b1300")
    }

    func testFollowerKeepsHistoryWhileTheFullHeadPageRolls() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        for start in [800, 700] {
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        // A working agent appends three records per refresh to a full page.
        for start in stride(from: 903, through: 999, by: 3) {
            try window.replaceHead(segment(start, total: start + 100), expectedVersion: window.version, pinnedRecordID: nil)
            XCTAssertEqual(window.viewport.map(\.id), ["s700", "s800", "s900"], "rolled to \(start)")
            XCTAssertTrue(window.atLiveHead)
            XCTAssertEqual(window.head?.records.last?.recordID, "r\(start + 99)")
            let union = Set(window.records.map(\.recordID)).union(window.head!.records.map(\.recordID))
            XCTAssertEqual(union.count, start + 100 - 700, "contiguous r700 through the newest record")
        }
    }

    func testOlderPageFitsUntilAnotherPageWouldEvictTheNewest() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        for start in [800, 700, 600] {
            XCTAssertTrue(window.olderPageFits, "room for s\(start)")
            try window.navigate(segment(start), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        }
        XCTAssertEqual(window.viewport.count, 4)
        XCTAssertFalse(window.olderPageFits, "segments")

        var records = AgentIngestionWindow(capacity: .init(segments: 8, records: 250, bytes: 8_000_000))
        try records.bootstrap(segment(900))
        XCTAssertTrue(records.olderPageFits)
        try records.navigate(segment(800), direction: .before, from: records.before!, expectedVersion: records.version, pinnedRecordID: nil)
        XCTAssertFalse(records.olderPageFits, "records")

        // An older page may be as large as the page limit.
        let wide = String(repeating: "x", count: 1_400)
        var bytes = AgentIngestionWindow(capacity: .init(segments: 8, records: 800, bytes: 600_000))
        try bytes.bootstrap(segment(900, text: wide))
        try bytes.navigate(segment(800, text: wide), direction: .before, from: bytes.before!, expectedVersion: bytes.version, pinnedRecordID: nil)
        XCTAssertLessThanOrEqual(bytes.encodedBytes + 262_144, 600_000)
        XCTAssertTrue(bytes.olderPageFits)
        try bytes.navigate(segment(700, text: wide), direction: .before, from: bytes.before!, expectedVersion: bytes.version, pinnedRecordID: nil)
        XCTAssertEqual(bytes.viewport.count, 3)
        XCTAssertGreaterThan(bytes.encodedBytes + 262_144, 600_000)
        XCTAssertFalse(bytes.olderPageFits, "bytes")
    }

    func testFollowerSnapshotShowsHistoryThroughTheRolledHeadsNewestRecord() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "rolling")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        var snapshot = await runtime.snapshot(for: id)!
        _ = await runtime.apply(page: try projection(segment(800), lane: .before, version: 2, from: snapshot.ingestionWindow?.before), to: id)
        var live = "live"
        for (offset, start) in [903, 950, 1000].enumerated() {
            let next = "live\(offset)"
            let result = await runtime.apply(page: try projection(segment(start, total: start + 100), lane: .head,
                version: UInt64(offset + 3), from: live, live: next), to: id)
            XCTAssertTrue(result.accepted)
            live = next
            snapshot = await runtime.snapshot(for: id)!
            XCTAssertTrue(snapshot.ingestionWindow!.atLiveHead)
            XCTAssertEqual(snapshot.messages.last?.recordID, "r\(start + 99)", "the rolled head's newest record is shown")
            // Past the viewport's newest record the rows between stay
            // bridged from the old head, so history survives that roll too.
            XCTAssertEqual(snapshot.messages.first?.recordID, "r800", "history survives the roll")
            XCTAssertEqual(snapshot.messages.count, start + 100 - 800)
            XCTAssertEqual(snapshot.ingestionWindow?.viewportSegmentIDs, ["s800", "s900"])
            XCTAssertEqual(snapshot.ingestionWindow?.headSegmentID, "s\(start)")
            XCTAssertEqual(snapshot.ingestionWindow?.bridgesToHead, start == 1000)
            XCTAssertEqual(snapshot.ingestionWindow?.hasNewer, false)
        }
    }

    func testRevisionSplitOfAKeptHeadKeepsItsRowsShownUntilANewerPageRetainsThem() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        try window.navigate(segment(800), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        try window.replaceHead(segment(960, total: 1060), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertTrue(window.atLiveHead)
        // The host acknowledges only the head's last part beside the
        // unchanged viewport, so r1000..r1009 leave the retained window.
        let patch = AgentProjectionRecord(sequence: 1_000, recordID: "r1000", record: .object(["text": .string("updated")]), revision: 2)!
        try window.revise([patch], expectedVersion: window.version, partitions: split(window.head!), pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s800", "s900"])
        XCTAssertEqual(window.head?.id, "s960right")
        XCTAssertEqual(window.retainedIDs, ["s800", "s900", "s960right"])
        XCTAssertFalse(window.atLiveHead)
        XCTAssertTrue(window.bridgesToHead)
        XCTAssertFalse(window.hasNewer)
        // Nothing the reader saw leaves the transcript, revised in place.
        XCTAssertEqual(window.presentedRecords.map(\.recordID), (800..<1060).map { "r\($0)" })
        XCTAssertEqual(window.bridge.first?.revision, 2)
        let bridged = window

        // A newer page that stops inside the bridge retains its first rows.
        try window.navigate(segment(1000, count: 5, total: 1060), direction: .after, from: window.after!,
            expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertTrue(window.bridgesToHead)
        XCTAssertEqual(window.bridge.map(\.recordID), (1005..<1010).map { "r\($0)" })
        XCTAssertEqual(window.presentedRecords.map(\.recordID), (800..<1060).map { "r\($0)" })
        // One that reaches the head joins them again.
        window = bridged
        try window.navigate(segment(1000, count: 30, total: 1060), direction: .after, from: window.after!,
            expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertTrue(window.atLiveHead)
        XCTAssertFalse(window.bridgesToHead)
        XCTAssertTrue(window.bridge.isEmpty)
        XCTAssertEqual(window.presentedRecords.map(\.recordID), (800..<1060).map { "r\($0)" })
        // Losing the viewport's newest record ends the bridge.
        window = bridged
        _ = window.collapseToLiveHead(pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s960right"])
        XCTAssertTrue(window.bridge.isEmpty)
    }

    func testRollingHeadExtendsTheBridgeUntilItWouldOutgrowAPage() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        try window.navigate(segment(800), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        try window.replaceHead(segment(950, total: 1050), expectedVersion: window.version, pinnedRecordID: nil)
        try window.replaceHead(segment(1010, total: 1110), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertEqual(window.bridge.map(\.recordID), (1000..<1010).map { "r\($0)" })
        // A reader pinned in history keeps it past a head that jumps beyond
        // the bridge, but nothing bridges that gap.
        var pinned = window
        try pinned.replaceHead(segment(1500, total: 1600), expectedVersion: pinned.version, pinnedRecordID: "r850")
        XCTAssertEqual(pinned.viewport.map(\.id), ["s800", "s900"])
        XCTAssertFalse(pinned.bridgesToHead)
        XCTAssertFalse(pinned.atLiveHead)
        XCTAssertEqual(pinned.presentedRecords.last?.recordID, "r999")
        try window.replaceHead(segment(1100, total: 1200), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s800", "s900"])
        XCTAssertEqual(window.bridge.count, 100)
        XCTAssertEqual(window.presentedRecords.map(\.recordID), (800..<1200).map { "r\($0)" })
        // More than a page of unretained rows falls back to the head.
        try window.replaceHead(segment(1105, total: 1205), expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertEqual(window.viewport.map(\.id), ["s1105"])
        XCTAssertTrue(window.bridge.isEmpty)
        XCTAssertTrue(window.atLiveHead)
    }

    func testOlderPageNeverEvictsAFollowersLiveHead() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(900))
        try window.navigate(segment(800), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        XCTAssertFalse(window.evictOffscreen(opposite: .before, pinnedRecordID: nil, protectedSegmentID: "s800"))
        XCTAssertEqual(window.viewport.map(\.id), ["s800", "s900"])
        // Head updates still shed the oldest history, and a reader who
        // scrolled into history may trade the newest page for more of it.
        var head = window
        XCTAssertTrue(head.evictOffscreen(opposite: .after, pinnedRecordID: nil, protectedSegmentID: nil))
        XCTAssertEqual(head.viewport.map(\.id), ["s900"])
        XCTAssertTrue(window.evictOffscreen(opposite: .before, pinnedRecordID: "r850", protectedSegmentID: "s800"))
        XCTAssertEqual(window.viewport.map(\.id), ["s800"])
        XCTAssertFalse(window.atLiveHead)
    }

    func testKeptHistoryGivesWayToTheHeadWhenThePresentationCannotHoldBoth() async throws {
        let text = String(repeating: "w", count: 2_000)
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "bounded")!
        func run(limit: Int?) async throws -> AgentThreadSnapshot {
            let runtime = AgentCenterRuntime(presentationLimitBytes: limit)
            await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
                status: true, actions: false, spawn: false, fork: false, search: false)))
            let opened = await runtime.apply(page: try projection(segment(900, text: text), lane: .bootstrap, version: 1), to: id)
            XCTAssertTrue(opened.accepted)
            let rolled = await runtime.apply(page: try projection(segment(940, total: 1040, text: text), lane: .head,
                version: 2, from: "live", live: "live2"), to: id)
            XCTAssertTrue(rolled.accepted, "limit \(String(describing: limit))")
            return await runtime.snapshot(for: id)!
        }
        let unbounded = try await run(limit: nil)
        XCTAssertEqual(unbounded.ingestionWindow?.viewportSegmentIDs, ["s900"])
        XCTAssertEqual(unbounded.ingestionWindow?.headSegmentID, "s940")
        XCTAssertEqual(unbounded.messages.count, 140)
        // One page fits the presentation frame, a page and a half does not.
        let bounded = try await run(limit: 320_000)
        XCTAssertEqual(bounded.ingestionWindow?.viewportSegmentIDs, ["s940"])
        XCTAssertTrue(bounded.ingestionWindow!.atLiveHead)
        XCTAssertEqual(bounded.messages.first?.recordID, "r940")
        XCTAssertEqual(bounded.messages.last?.recordID, "r1039")
        // Nor would an older page: filling it would evict the newest.
        XCTAssertEqual(bounded.ingestionWindow?.olderPageFits, false)
        XCTAssertEqual(unbounded.ingestionWindow?.olderPageFits, true)
    }

    func testReaderOnARowTheRolledHeadAddedKeepsItThroughTheNextRoll() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "reader")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        _ = await runtime.apply(page: try projection(segment(800), lane: .before, version: 2, from: "b900"), to: id)
        await runtime.setIngestionViewportAnchor("r850", for: id)
        _ = await runtime.apply(page: try projection(segment(950, total: 1050), lane: .head, version: 3, from: "live", live: "live2"), to: id)
        // The reader moves down onto a row only the rolled head holds.
        await runtime.setIngestionViewportAnchor("r1020", for: id)
        let rolled = await runtime.apply(page: try projection(segment(1010, total: 1110), lane: .head, version: 4,
            from: "live2", live: "live3"), to: id)
        XCTAssertTrue(rolled.accepted)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertTrue(snapshot.messages.contains { $0.recordID == "r1020" }, "the reader's row is still shown")
        XCTAssertTrue(snapshot.ingestionWindow!.atLiveHead)
        XCTAssertEqual(snapshot.ingestionWindow?.bridgesToHead, true)
        XCTAssertEqual(snapshot.ingestionWindow?.viewportSegmentIDs, ["s800", "s900"])
        XCTAssertEqual(snapshot.messages.map(\.recordID), (800..<1110).map { "r\($0)" })
        // Bridged rows are not retained history either.
        await runtime.setIngestionViewportAnchor("r1005", for: id)
        let collapsed = await runtime.apply(page: try projection(segment(1300, total: 1400), lane: .head, version: 5,
            from: "live3", live: "live4"), to: id)
        XCTAssertTrue(collapsed.accepted)
        let latest = await runtime.snapshot(for: id)!
        XCTAssertEqual(latest.ingestionWindow?.viewportSegmentIDs, ["s1300"])
    }

    func testFollowerRefusesAnOlderPageTheBudgetCannotHoldBesideTheLiveHead() async throws {
        let text = String(repeating: "q", count: 900)
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "budget")!
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .init(perThreadBytes: 1 << 20, globalBytes: 4 << 20))
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let opened = await runtime.apply(page: try projection(segment(900, text: text), lane: .bootstrap, version: 1), to: id)
        XCTAssertTrue(opened.accepted)
        // Two such pages exceed the retained budget. The older one would
        // evict the newest segment: a follower refuses it and stops asking.
        let refused = await runtime.apply(page: try projection(segment(800, text: text), lane: .before, version: 2, from: "b900"), to: id)
        XCTAssertEqual(refused, .capacityExceeded)
        let followed = await runtime.snapshot(for: id)!
        XCTAssertEqual(followed.ingestionWindow?.viewportSegmentIDs, ["s900"])
        XCTAssertEqual(followed.ingestionWindow?.atLiveHead, true)
        XCTAssertEqual(followed.ingestionWindow?.olderPageFits, false)
        // A smaller page that fits is still admitted.
        let smaller = await runtime.apply(page: try projection(segment(890, count: 10, text: text), lane: .before, version: 2, from: "b900"), to: id)
        XCTAssertTrue(smaller.accepted)
        let filled = await runtime.snapshot(for: id)!
        XCTAssertEqual(filled.ingestionWindow?.viewportSegmentIDs, ["s890", "s900"])
        XCTAssertEqual(filled.ingestionWindow?.olderPageFits, false)
    }

    func testDetachedWindowNeverReportsRoomToFill() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "detached")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        let opened = await runtime.snapshot(for: id)
        XCTAssertEqual(opened?.ingestionWindow?.olderPageFits, true)
        await runtime.setIngestionViewportAnchor("r950", for: id)
        _ = await runtime.apply(page: try projection(segment(1900, total: 2000), lane: .head, version: 2, from: "live", live: "live2"), to: id)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertFalse(snapshot.ingestionWindow!.atLiveHead)
        XCTAssertEqual(snapshot.ingestionWindow?.olderPageFits, false)
    }

    func testOverlappingHeadAllowsForwardRecoveryFromPreviouslyTerminalWindow() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(0, total: 100))
        try window.replaceHead(segment(50, total: 150), expectedVersion: window.version, pinnedRecordID: "r0")
        // The overlapping head continues the viewport: live, nothing newer.
        XCTAssertEqual(window.viewport.map(\.id), ["s0"])
        XCTAssertFalse(window.hasNewer)
        XCTAssertTrue(window.atLiveHead)
        try window.navigate(segment(100, count: 50, total: 150), direction: .after, from: window.after!,
            expectedVersion: window.version, pinnedRecordID: "r99")
        XCTAssertTrue(window.atLiveHead)
        XCTAssertFalse(window.hasNewer)
    }

    func testStaleShrinkingAndCollidingHeadsCannotCommit() throws {
        var window = AgentIngestionWindow()
        try window.bootstrap(segment(100, total: 200))
        try window.navigate(segment(0, total: 200), direction: .before, from: window.before!, expectedVersion: window.version, pinnedRecordID: nil)
        let previous = window
        XCTAssertThrowsError(try window.replaceHead(segment(150, total: 250), expectedVersion: window.version - 1, pinnedRecordID: "r190"))
        XCTAssertThrowsError(try window.replaceHead(segment(100, count: 50, total: 150, suffix: "shrink"), expectedVersion: window.version, pinnedRecordID: "r190"))
        XCTAssertThrowsError(try window.replaceHead(segment(0, total: 100), expectedVersion: window.version, pinnedRecordID: nil))
        XCTAssertEqual(window, previous)
    }

    func testMalformedAndOversizedSegmentCannotEnterWindow() throws {
        XCTAssertThrowsError(try segment(0, count: 101))
        XCTAssertThrowsError(try segment(0, text: String(repeating: "a", count: 3000)))
        let valid = try segment(0)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        object["before"] = "../../not-a-cursor"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentIngestionSegment.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func projection(_ segment: AgentIngestionSegment, lane: AgentIngestionWindowTransaction.Lane,
                            version: UInt64, from: String? = nil, live: String? = "live",
                            summary: AgentJSONValue? = nil, requestID: String? = nil) throws -> AgentProjectionPage {
        let operation: AgentIngestionRange.Operation = lane == .bootstrap ? .bootstrap : (lane == .before || lane == .after) ? .history : .updates
        let window = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: segment.id,
            before: segment.before, after: segment.after, hasOlder: segment.hasOlder, hasNewer: segment.hasNewer)
        return AgentProjectionPage(sourceIdentity: segment.source, from: from, records: segment.records,
            cursor: operation == .updates || !segment.hasOlder ? nil : segment.before,
            hasMore: operation != .updates && segment.hasOlder, summary: summary,
            ingestion: .init(epoch: "epoch", requestID: requestID ?? "tx\(version)", operation: operation,
                liveCursor: operation == .history ? nil : live, window: window)!)!
    }

    func testRuntimeCommitsViewportSeparatelyFromHeadAndRejectsUncommittedCursorAdvance() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "window")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let result = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        XCTAssertTrue(result.accepted)
        var snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.ingestionWindow?.version, 1)
        for (offset, start) in [800, 700, 600, 500, 400, 300].enumerated() {
            let page = try projection(segment(start), lane: .before, version: UInt64(offset + 2), from: snapshot.ingestionWindow?.before)
            let result = await runtime.apply(page: page, to: id)
            XCTAssertTrue(result.accepted)
            snapshot = await runtime.snapshot(for: id)!
            XCTAssertEqual(snapshot.messages.first?.recordID, "r\(start)")
            XCTAssertLessThanOrEqual(snapshot.messages.count, 400)
            XCTAssertEqual(snapshot.ingestionWindow?.liveCursor, "live")
        }
        XCTAssertFalse(snapshot.ingestionWindow!.atLiveHead)
        await runtime.setIngestionViewportAnchor("r350", for: id)
        let head = try projection(segment(1900, total: 2000), lane: .head, version: 8, from: "live", live: "live2")
        let updated = await runtime.apply(page: head, to: id)
        XCTAssertTrue(updated.accepted)
        let detached = await runtime.snapshot(for: id)!
        XCTAssertEqual(detached.messages, snapshot.messages)
        XCTAssertEqual(detached.ingestionWindow?.liveCursor, "live2")
        XCTAssertTrue(detached.ingestionWindow!.hasNewer)
        let boundary = try await runtime.nativeReceiptBoundary(for: id, after: head)
        XCTAssertEqual(boundary.records.last?.recordID, "r1999")
        let wrong = try projection(segment(200), lane: .before, version: 9, from: "foreign")
        let rejected = await runtime.apply(page: wrong, to: id)
        XCTAssertFalse(rejected.accepted)
        let unchanged = await runtime.snapshot(for: id)!
        XCTAssertEqual(unchanged.ingestionWindow, detached.ingestionWindow)
        XCTAssertEqual(unchanged.messages, detached.messages)
    }

    func testChangedReplayCannotAcknowledgeOrReplaceCommittedWindow() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "replay")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let page = try projection(segment(900), lane: .bootstrap, version: 1)
        let first = await runtime.apply(page: page, to: id)
        XCTAssertTrue(first.accepted)
        let replay = await runtime.apply(page: page, to: id)
        XCTAssertEqual(replay, .duplicate)
        let modified = try projection(segment(900, text: "changed replay"), lane: .bootstrap, version: 1)
        let rejected = await runtime.apply(page: modified, to: id)
        XCTAssertEqual(rejected, .resyncRequired)
        let current = await runtime.snapshot(for: id)!
        XCTAssertEqual(current.ingestionWindow?.version, 1)
        XCTAssertEqual(current.messages.count, 100)
    }

    func testMemoryWarningReleasesWindowAndPublishesEvictionOnce() async throws {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "memory")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        await runtime.memoryWarning()
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertNil(snapshot.ingestionWindow)
        XCTAssertTrue(snapshot.messages.isEmpty)
        let first = await runtime.takeIngestionEvictions()
        let second = await runtime.takeIngestionEvictions()
        XCTAssertEqual(first, [id]); XCTAssertTrue(second.isEmpty)
    }

    func testCapacityRejectIsAtomicAndSmallerPageKeepsHistoryBoundary() async throws {
        // The smallest budget leaves 512 KiB of retained content once the
        // per-thread reserve is set aside; the pinned bootstrap cannot be evicted.
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .init(perThreadBytes: 1 << 20, globalBytes: 1 << 20))
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "capacity")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        let initial = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        XCTAssertTrue(initial.accepted)
        await runtime.setIngestionViewportAnchor("r900", for: id)
        let previous = await runtime.snapshot(for: id)!
        let large = try projection(segment(870, count: 30, text: String(repeating: "x", count: 8192)), lane: .before, version: 2, from: "b900")
        let rejected = await runtime.apply(page: large, to: id)
        XCTAssertEqual(rejected, .capacityExceeded)
        let unchanged = await runtime.snapshot(for: id)!
        XCTAssertEqual(unchanged.ingestionWindow, previous.ingestionWindow)
        XCTAssertEqual(unchanged.messages, previous.messages)
        let smaller = try projection(segment(885, count: 15, text: String(repeating: "x", count: 8192)), lane: .before, version: 2, from: "b900")
        let accepted = await runtime.apply(page: smaller, to: id)
        XCTAssertTrue(accepted.accepted)
        let current = await runtime.snapshot(for: id)!
        XCTAssertEqual(current.ingestionWindow?.before, "b885")
        XCTAssertTrue(current.messages.contains { $0.recordID == "r900" })
        await runtime.releaseIngestionWindow(for: id)
        let released = await runtime.snapshot(for: id)!
        XCTAssertNil(released.ingestionWindow)
        XCTAssertTrue(released.messages.isEmpty)
    }
}
