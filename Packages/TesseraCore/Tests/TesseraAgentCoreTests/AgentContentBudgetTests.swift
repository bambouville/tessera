import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentContentBudgetTests: XCTestCase {
    private let gibibyte: UInt64 = 1 << 30

    func testDeviceTiersFollowReportedMemory() {
        // Reported memory sits below the marketed size.
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: 2 * gibibyte), .compact)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: gibibyte * 28 / 10), .compact)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: gibibyte * 37 / 10), .standard)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: gibibyte * 56 / 10), .standard)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: gibibyte * 75 / 10), .large)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: 16 * gibibyte), .large)
        XCTAssertEqual(AgentContentBudget.forDevice(physicalMemoryBytes: 16 * gibibyte, isLowRAMDevice: true), .compact)
        XCTAssertEqual([AgentContentBudget.compact, .standard, .large].map(\.perThreadBytes), [4 << 20, 8 << 20, 16 << 20])
        XCTAssertEqual([AgentContentBudget.compact, .standard, .large].map(\.globalBytes), [16 << 20, 32 << 20, 64 << 20])
        XCTAssertEqual([AgentContentBudget.compact, .standard, .large].map(\.windowSegments), [16, 32, 64])
    }

    func testBudgetClampsUntrustedValues() {
        let tiny = AgentContentBudget(perThreadBytes: 0, globalBytes: 0)
        XCTAssertEqual(tiny.perThreadBytes, 1 << 20)
        XCTAssertEqual(tiny.globalBytes, 1 << 20)
        let huge = AgentContentBudget(perThreadBytes: .max, globalBytes: .max)
        XCTAssertEqual(huge.perThreadBytes, 64 << 20)
        XCTAssertEqual(huge.globalBytes, 256 << 20)
    }

    func testWindowCapacityIsTheSmallerOfDeviceAndHost() {
        XCTAssertEqual(AgentIngestionWindowCapacity.negotiated(budget: .large, hostSegments: 4), .legacy)
        XCTAssertEqual(AgentIngestionWindowCapacity.negotiated(budget: .large, hostSegments: 1), .legacy)
        let large = AgentIngestionWindowCapacity.negotiated(budget: .large, hostSegments: 64)
        XCTAssertEqual(large, .init(segments: 64, records: 6_400, bytes: 8 << 20))
        XCTAssertEqual(AgentIngestionWindowCapacity.negotiated(budget: .compact, hostSegments: 64).segments, 16)
        XCTAssertEqual(AgentIngestionWindowCapacity.negotiated(budget: .large, hostSegments: 32).segments, 32)
        XCTAssertEqual(AgentIngestionWindowCapacity.negotiated(budget: .large, hostSegments: 1_000).segments, 64)
    }

    func testRuntimeUsesHostCapacityOnlyAfterHelloAndFromNextBootstrap() async throws {
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .large)
        let host = UUID()
        let id = try await register(runtime, host: host, session: "negotiated")
        let beforeHello = await runtime.ingestionWindowCapacity(for: id)
        XCTAssertEqual(beforeHello, .legacy)
        await runtime.setIngestionHostSegments(64, for: host)
        let afterHello = await runtime.ingestionWindowCapacity(for: id)
        XCTAssertEqual(afterHello.segments, 64)
        await runtime.setIngestionHostSegments(0, for: host)
        let clamped = await runtime.ingestionWindowCapacity(for: id)
        XCTAssertEqual(clamped, .legacy)
    }

    func testThreadScopedCapacitySurvivesAnotherConnectionsHelloForTheSameHost() async throws {
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .large)
        let host = UUID()
        let reading = try await register(runtime, host: host, session: "reading")
        let other = try await register(runtime, host: host, session: "other")
        await runtime.setIngestionHostSegments(64, for: host, thread: reading)
        // A second service on the same host (a rollout) says hello with a
        // legacy limit before the first thread's bootstrap page lands.
        await runtime.setIngestionHostSegments(4, for: host, thread: other)
        await runtime.setIngestionHostSegments(4, for: host)
        let readingCapacity = await runtime.ingestionWindowCapacity(for: reading)
        let otherCapacity = await runtime.ingestionWindowCapacity(for: other)
        XCTAssertEqual(readingCapacity.segments, 64)
        XCTAssertEqual(otherCapacity, .legacy)
        var version: UInt64 = 1
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: version), to: reading)
        await runtime.setIngestionViewportAnchor("r900", for: reading)
        for start in stride(from: 800, through: 300, by: -100) {
            version += 1
            let before = await runtime.snapshot(for: reading)!.ingestionWindow!.before!
            let result = await runtime.apply(page: try projection(segment(start), lane: .before, version: version, from: before), to: reading)
            XCTAssertEqual(result, .applied, "page \(start)")
        }
        let window = await runtime.snapshot(for: reading)?.ingestionWindow
        XCTAssertEqual(window?.viewportSegmentIDs.count, 7, "a legacy window would hold four")
        // A thread argument naming a different host never binds.
        await runtime.setIngestionHostSegments(32, for: UUID(), thread: reading)
        let unchanged = await runtime.ingestionWindowCapacity(for: reading)
        XCTAssertEqual(unchanged.segments, 64)
    }

    func testMarkdownCacheFollowsTheTierAndGoesWithTranscriptContent() async throws {
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .large)
        XCTAssertEqual(AgentMarkdownDocument.cacheLimitsForTesting.cost, 16 << 20)
        await runtime.configure(budget: .compact)
        XCTAssertEqual(AgentMarkdownDocument.cacheLimitsForTesting.cost, 4 << 20)
        XCTAssertEqual(AgentMarkdownDocument.cacheLimitsForTesting.count, 256)
        for purge in [{ await runtime.memoryWarning() }, { await runtime.setEnabled(false) }] as [() async -> Void] {
            let source = "purge **\(UUID().uuidString)**"
            _ = AgentMarkdownDocument.parse(source)
            XCTAssertTrue(AgentMarkdownDocument.cachedForTesting(source))
            await purge()
            XCTAssertFalse(AgentMarkdownDocument.cachedForTesting(source))
        }
    }

    func testLargeWindowRetainsDeepHistoryWithoutEvictingNewestPages() async throws {
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .large)
        let host = UUID()
        await runtime.setIngestionHostSegments(64, for: host)
        let id = try await register(runtime, host: host, session: "deep")
        let total = 3_000
        var version: UInt64 = 1
        let bootstrap = await runtime.apply(page: try projection(segment(total - 100, total: total), lane: .bootstrap, version: version), to: id)
        XCTAssertTrue(bootstrap.accepted)
        await runtime.setIngestionViewportAnchor("r\(total - 1)", for: id)
        for start in stride(from: total - 200, through: total - 2_000, by: -100) {
            version += 1
            let before = await runtime.snapshot(for: id)!.ingestionWindow!.before!
            let result = await runtime.apply(page: try projection(segment(start, total: total), lane: .before,
                version: version, from: before), to: id)
            XCTAssertEqual(result, .applied, "page \(start)")
        }
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.ingestionWindow?.viewportSegmentIDs.count, 20)
        XCTAssertEqual(snapshot.messages.count, 2_000)
        XCTAssertEqual(snapshot.messages.last?.recordID, "r\(total - 1)")
        XCTAssertTrue(snapshot.ingestionWindow?.hasOlder == true)
    }

    func testLegacyHostKeepsFourSegmentWindow() async throws {
        let runtime = AgentCenterRuntime()
        await runtime.configure(budget: .large)
        let id = try await register(runtime, host: UUID(), session: "legacy")
        var version: UInt64 = 1
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: version), to: id)
        await runtime.setIngestionViewportAnchor("r900", for: id)
        for start in stride(from: 800, through: 300, by: -100) {
            version += 1
            let before = await runtime.snapshot(for: id)!.ingestionWindow!.before!
            await runtime.setIngestionViewportAnchor("r\(start + 100)", for: id)
            let result = await runtime.apply(page: try projection(segment(start), lane: .before, version: version, from: before), to: id)
            XCTAssertTrue(result.accepted)
        }
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertLessThanOrEqual(snapshot.ingestionWindow?.viewportSegmentIDs.count ?? 0, 4)
        XCTAssertEqual(snapshot.messages.first?.recordID, "r300")
    }

    func testBoundedPresentationEvictsOffscreenPagesInsteadOfRejecting() async throws {
        let limit = 400_000
        let runtime = AgentCenterRuntime(presentationLimitBytes: limit)
        await runtime.configure(budget: .large)
        let host = UUID()
        await runtime.setIngestionHostSegments(64, for: host)
        let id = try await register(runtime, host: host, session: "bounded")
        let text = String(repeating: "y", count: 1_024)
        var version: UInt64 = 1
        _ = await runtime.apply(page: try projection(segment(900, text: text), lane: .bootstrap, version: version), to: id)
        for start in stride(from: 800, through: 0, by: -100) {
            version += 1
            let before = await runtime.snapshot(for: id)!.ingestionWindow!.before!
            await runtime.setIngestionViewportAnchor("r\(start + 100)", for: id)
            let result = await runtime.apply(page: try projection(segment(start, text: text), lane: .before,
                version: version, from: before), to: id)
            XCTAssertEqual(result, .applied, "page \(start)")
            let snapshot = await runtime.snapshot(for: id)!
            XCTAssertEqual(snapshot.messages.first?.recordID, "r\(start)")
            XCTAssertTrue(snapshot.messages.contains { $0.recordID == "r\(start + 100)" }, "pinned row survives")
            let messages = try JSONEncoder().encode(snapshot.messages).count
            XCTAssertLessThan(messages, limit)
        }
    }

    func testRepeatedAcknowledgementDoesNotRepublish() async throws {
        let runtime = AgentCenterRuntime()
        let id = try await register(runtime, host: UUID(), session: "ack")
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        let older = await runtime.acknowledge(threadID: id, visibleRecordID: "r998")
        XCTAssertFalse(older, "only the newest row reads the thread")
        let newest = await runtime.acknowledge(threadID: id, visibleRecordID: "r999")
        XCTAssertTrue(newest)
        let first = await runtime.snapshot(for: id)!
        let repeated = await runtime.acknowledge(threadID: id, visibleRecordID: "r999")
        XCTAssertFalse(repeated)
        let second = await runtime.snapshot(for: id)!
        XCTAssertEqual(first.deliveryGeneration, second.deliveryGeneration)
        XCTAssertEqual(first, second)
    }

    func testUnchangedSnapshotsShareTheirMessageStorage() async throws {
        let runtime = AgentCenterRuntime()
        let id = try await register(runtime, host: UUID(), session: "shared")
        _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
        let first = await runtime.snapshot(for: id)!.messages
        let second = await runtime.snapshot(for: id)!.messages
        // Array equality short-circuits on identical storage, which keeps the
        // platform's per-publish comparison O(1) for an unchanged transcript.
        XCTAssertEqual(first.withUnsafeBufferPointer { $0.baseAddress }, second.withUnsafeBufferPointer { $0.baseAddress })
        _ = await runtime.apply(page: try projection(segment(1_000, count: 1, total: 1_001), lane: .head,
            version: 2, from: "live", live: "live2"), to: id)
        let third = await runtime.snapshot(for: id)!.messages
        XCTAssertEqual(third.last?.recordID, "r1000")
    }

    func testPurgesDropTheDerivedPresentationCopy() async throws {
        for purge in ["disable", "memoryWarning"] {
            let runtime = AgentCenterRuntime()
            let id = try await register(runtime, host: UUID(), session: purge)
            _ = await runtime.apply(page: try projection(segment(900), lane: .bootstrap, version: 1), to: id)
            _ = await runtime.snapshot(for: id)
            XCTAssertEqual(retainedPresentationCount(runtime, id), 100, purge)
            if purge == "disable" { await runtime.setEnabled(false) } else { await runtime.memoryWarning() }
            // The snapshot cache is not presentation state: a purge that only
            // cleared `messages` would keep the whole transcript alive.
            XCTAssertEqual(retainedPresentationCount(runtime, id), 0, purge)
        }
    }

    /// Counts of the runtime's private per-thread presentation arrays; -1 when
    /// the thread or field cannot be found, so a rename fails the test.
    private func retainedPresentationCount(_ runtime: AgentCenterRuntime, _ id: AgentThreadID) -> Int {
        guard let threads = Mirror(reflecting: runtime).children.first(where: { $0.label == "threads" })?.value else { return -1 }
        for child in Mirror(reflecting: threads).children {
            let pair = Mirror(reflecting: child.value).children.map(\.value)
            guard pair.count == 2, pair[0] as? AgentThreadID == id else { continue }
            let state = Mirror(reflecting: pair[1]).children
            let counts = ["presentationSource", "presentationMessages"].map { label in
                (state.first { $0.label == label }?.value as? [AgentMessage])?.count
            }
            guard let source = counts[0], let presented = counts[1] else { return -1 }
            return max(source, presented)
        }
        return -1
    }

    private func register(_ runtime: AgentCenterRuntime, host: UUID, session: String) async throws -> AgentThreadID {
        let id = try XCTUnwrap(AgentThreadID(hostID: host, providerID: .claude, providerSessionID: session))
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        return id
    }

    private func segment(_ start: Int, count: Int = 100, total: Int = 1000, text: String = "hello") throws -> AgentIngestionSegment {
        try .init(id: "s\(start)", source: "source", before: "b\(start)", after: "a\(start + count)",
            hasOlder: start > 0, hasNewer: start + count < total,
            records: (start..<(start + count)).map { .init(sequence: UInt64($0), recordID: "r\($0)",
                record: .object(["type": .string("assistant"), "text": .string(text)]))! })
    }

    private func projection(_ segment: AgentIngestionSegment, lane: AgentIngestionWindowTransaction.Lane,
                            version: UInt64, from: String? = nil, live: String? = "live") throws -> AgentProjectionPage {
        let operation: AgentIngestionRange.Operation = lane == .bootstrap ? .bootstrap : (lane == .before || lane == .after) ? .history : .updates
        let window = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: segment.id,
            before: segment.before, after: segment.after, hasOlder: segment.hasOlder, hasNewer: segment.hasNewer)
        return AgentProjectionPage(sourceIdentity: segment.source, from: from, records: segment.records,
            cursor: operation == .updates || !segment.hasOlder ? nil : segment.before,
            hasMore: operation != .updates && segment.hasOlder,
            ingestion: .init(epoch: "epoch", requestID: "tx\(version)", operation: operation,
                liveCursor: operation == .history ? nil : live, window: window)!)!
    }
}
