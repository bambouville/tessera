import XCTest
@testable import TesseraAgentCore

/// A newest-first bootstrap cannot rediscover a thread's opening prompt, so a
/// same-source viewport reset must keep one the reader already reached, for
/// every provider. A replaced source must not.
final class AgentTitleSeedResyncTests: XCTestCase {
    private static let providers: [AgentProviderID] = [.claude, .pi, .kimi, .opencode, .codex]

    private func runtime(_ provider: AgentProviderID) async -> (AgentCenterRuntime, AgentThreadID) {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "title-resync")!
        await runtime.register(.init(id: id, providerName: provider.rawValue, availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        return (runtime, id)
    }

    private func segment(_ sequence: UInt64, text: String, older: Bool, source: String = "same-source") throws -> AgentIngestionSegment {
        try AgentIngestionSegment(id: "segment-\(sequence)", source: source, before: "before-\(sequence)",
            after: "after-\(sequence)", hasOlder: older, hasNewer: false, records: [
                AgentProjectionRecord(sequence: sequence, recordID: "record-\(sequence)",
                    record: .object(["type": .string("user"), "text": .string(text)]))!
            ])
    }

    private func bootstrap(_ segment: AgentIngestionSegment, request: String) throws -> AgentProjectionPage {
        let transaction = try AgentIngestionWindowTransaction(lane: .bootstrap, version: 1, segmentID: segment.id,
            before: segment.before, after: segment.after, hasOlder: segment.hasOlder, hasNewer: false)
        return AgentProjectionPage(sourceIdentity: segment.source, records: segment.records,
            cursor: segment.hasOlder ? segment.before : nil, hasMore: segment.hasOlder,
            ingestion: .init(epoch: "epoch", requestID: request, operation: .bootstrap, liveCursor: "live", window: transaction)!)!
    }

    func testSameSourceBootstrapKeepsAnOpeningPromptFromAFullHistoryPage() async throws {
        for provider in Self.providers {
            let (runtime, id) = await runtime(provider)
            _ = await runtime.apply(page: try bootstrap(segment(1, text: "Actual opening request", older: false), request: "first"), to: id)
            let initial = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(initial.titleSeed, "Actual opening request", provider.rawValue)
            XCTAssertEqual(initial.titleProvenance, .prompt, provider.rawValue)

            _ = await runtime.apply(page: try bootstrap(segment(900, text: "Late request", older: true), request: "second"), to: id)
            let later = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(later.title, initial.title, provider.rawValue)
            XCTAssertEqual(later.titleSeed, "Actual opening request", provider.rawValue)
            XCTAssertEqual(later.titleProvenance, .prompt, provider.rawValue)
        }
    }

    func testSameSourceBootstrapKeepsAnOpeningPromptReachedByPagingBack() async throws {
        for provider in Self.providers {
            let (runtime, id) = await runtime(provider)
            let late = try segment(900, text: "Late request", older: true)
            _ = await runtime.apply(page: try bootstrap(late, request: "late"), to: id)
            let unseeded = await runtime.snapshot(for: id)!.summary
            XCTAssertNil(unseeded.titleSeed, provider.rawValue)

            let early = try segment(1, text: "Actual opening request", older: false)
            let transaction = try AgentIngestionWindowTransaction(lane: .before, version: 2, segmentID: early.id,
                before: early.before, after: early.after, hasOlder: false, hasNewer: false)
            let history = AgentProjectionPage(sourceIdentity: early.source, from: late.before, records: early.records,
                cursor: nil, hasMore: false, ingestion: .init(epoch: "epoch", requestID: "history", operation: .history,
                    liveCursor: nil, window: transaction)!)!
            _ = await runtime.apply(page: history, to: id)
            let seeded = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(seeded.titleSeed, "Actual opening request", provider.rawValue)

            _ = await runtime.apply(page: try bootstrap(late, request: "reset"), to: id)
            let reset = await runtime.snapshot(for: id)!.summary
            XCTAssertEqual(reset.title, seeded.title, provider.rawValue)
            XCTAssertEqual(reset.titleSeed, "Actual opening request", provider.rawValue)
        }
    }

    func testReplacedSourceDropsTheOldOpeningPrompt() async throws {
        for provider in Self.providers {
            let (runtime, id) = await runtime(provider)
            _ = await runtime.apply(page: try bootstrap(segment(1, text: "Actual opening request", older: false), request: "first"), to: id)
            _ = await runtime.apply(page: try bootstrap(segment(900, text: "Late request", older: true, source: "other-source"),
                request: "replacement"), to: id)
            let replaced = await runtime.snapshot(for: id)!.summary
            XCTAssertNil(replaced.titleSeed, provider.rawValue)
            XCTAssertEqual(replaced.titleProvenance, .placeholder, provider.rawValue)
        }
    }
}
