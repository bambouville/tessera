import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentProjectionRecordBoundsTests: XCTestCase {
    func testLegacyClaudeQueuePayloadDoesNotRejectItsConversationPage() throws {
        let raw: [String: Any] = [
            "sourceIdentity": "fixture", "hasMore": true, "cursor": "older",
            "records": [
                ["sequence": 1, "recordID": "queue", "sourceOffset": 42,
                 "sourceHash": String(repeating: "a", count: 64),
                 "record": ["type": "queue-operation", "provider": "claude",
                            "pending": 2, "content": String(repeating: "é", count: 10_000)]],
                ["sequence": 2, "recordID": "reply",
                 "record": ["type": "assistant", "text": "The next message remains readable."]],
            ],
        ]
        let page = try JSONDecoder().decode(AgentProjectionPage.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(page.records.map(\.recordID), ["queue", "reply"])
        XCTAssertEqual(page.records[0].record.objectValue?["pending"], .number(2))
        XCTAssertNil(page.records[0].record.objectValue?["content"])
        XCTAssertEqual(page.records[0].sourceOffset, 42)
        XCTAssertEqual(page.records[0].sourceHash, String(repeating: "a", count: 64))
        XCTAssertTrue(page.records[0].record.isBounded())
        XCTAssertEqual(page.records[1].record.objectValue?["text"], .string("The next message remains readable."))
    }

    func testOversizedConversationTextStillFailsAtTheRecordField() throws {
        let raw: [String: Any] = ["sequence": 1, "recordID": "message",
                                 "record": ["type": "assistant", "text": String(repeating: "x", count: 16_385)]]
        XCTAssertThrowsError(try JSONDecoder().decode(AgentProjectionRecord.self, from: JSONSerialization.data(withJSONObject: raw))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(context.codingPath.last?.stringValue, "record")
        }
    }

    func testQueueCompatibilityDoesNotRelaxOtherRecordBounds() throws {
        let longText = String(repeating: "x", count: 16_385)
        let cases: [(String, [String: Any], [String: Any])] = [
            ("record", ["provider": "codex", "type": "queue-operation", "content": longText], [:]),
            ("record", ["provider": "claude", "type": "assistant", "content": longText], [:]),
            ("record", ["provider": "claude", "type": "queue-operation", "content": longText, "other": longText], [:]),
            ("sourceHash", ["provider": "claude", "type": "queue-operation", "content": longText], ["sourceHash": "invalid"]),
            ("recordID", ["provider": "claude", "type": "queue-operation", "content": longText], ["recordID": ""]),
        ]
        for (field, record, overrides) in cases {
            var raw: [String: Any] = ["sequence": 1, "recordID": "queue", "record": record]
            raw.merge(overrides) { _, replacement in replacement }
            XCTAssertThrowsError(try JSONDecoder().decode(AgentProjectionRecord.self, from: JSONSerialization.data(withJSONObject: raw))) { error in
                guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(context.codingPath.last?.stringValue, field)
            }
        }
    }
}
