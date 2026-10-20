import XCTest
@testable import TesseraAgentCore

final class AgentHistoryContinuationTests: XCTestCase {
    private func cursor(_ identity: String, _ sequence: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["identity": identity, "offset": sequence * 10,
            "sequence": sequence, "prefixHash": String(repeating: "a", count: 64)], options: [.sortedKeys])
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func testVerifiedAppendRetainsLoadedHistoryAndRebasesOldestCursor() async {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "history")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        func page(_ identity: String, _ range: Range<Int>, from: String? = nil, continued: String? = nil) -> AgentProjectionPage {
            .init(sourceIdentity: identity, from: from, records: range.map {
                .init(sequence: UInt64($0), recordID: "record-\($0)", record: .object([
                    "type": .string("assistant"), "text": .string("Message \($0)")]))!
            }, cursor: cursor(identity, range.lowerBound), hasMore: range.lowerBound > 0,
                  summary: continued.map { .object(["continuedFrom": .string($0)]) })!
        }
        _ = await runtime.apply(page: page("1:2:100:1", 10..<20), to: id)
        let oldCursor = cursor("1:2:100:1", 10)
        let result = await runtime.apply(page: page("1:2:200:2", 18..<22, continued: "1:2:100:1"), to: id)
        XCTAssertEqual(result, .applied)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.count, 12)
        XCTAssertEqual(snapshot.cursor, AgentProjectionContinuation.rebase(oldCursor, using: cursor("1:2:200:2", 18)))
        let older = await runtime.apply(page: page("1:2:300:3", 0..<10, from: snapshot.cursor, continued: "1:2:200:2"), to: id)
        XCTAssertEqual(older, .applied)
        let complete = await runtime.snapshot(for: id)!
        XCTAssertEqual(complete.messages.count, 22)
        XCTAssertFalse(complete.hasMore)
        let replacement = await runtime.apply(page: page("1:9:100:1", 0..<2), to: id)
        XCTAssertEqual(replacement, .sourceReset)
        let replaced = await runtime.snapshot(for: id)!
        XCTAssertEqual(replaced.messages.count, 2)
    }

    func testAppendLargerThanPageReanchorsInsteadOfFreezingForever() async {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "gap")!
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        func page(_ identity: String, _ range: Range<Int>, continued: String? = nil) -> AgentProjectionPage {
            .init(sourceIdentity: identity, records: range.map {
                .init(sequence: UInt64($0), recordID: "record-\($0)", record: .object([
                    "type": .string("assistant"), "text": .string("Message \($0)")]))!
            }, cursor: cursor(identity, range.lowerBound), hasMore: true,
                  summary: continued.map { .object(["continuedFrom": .string($0)]) })!
        }
        _ = await runtime.apply(page: page("old", 0..<100), to: id)
        let result = await runtime.apply(page: page("new", 150..<250, continued: "old"), to: id)
        XCTAssertEqual(result, .sourceReset)
        let snapshot = await runtime.snapshot(for: id)!
        XCTAssertEqual(snapshot.messages.last?.recordID, "record-249")
        XCTAssertEqual(snapshot.cursor, cursor("new", 150))
        XCTAssertTrue(snapshot.hasMore)
    }
}
