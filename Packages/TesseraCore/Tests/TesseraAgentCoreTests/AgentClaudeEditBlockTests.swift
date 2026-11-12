import XCTest
@testable import TesseraAgentCore

/// Claude's Edit, MultiEdit and Write calls become edit cards beside the
/// call, which stays where it was in its tool run (F-03).
final class AgentClaudeEditBlockTests: XCTestCase {
    private func record(_ sequence: UInt64, _ id: String, _ object: [String: AgentJSONValue]) -> AgentProjectionRecord {
        .init(sequence: sequence, recordID: id, record: .object(object))!
    }

    private func call(_ sequence: UInt64, _ id: String, name: String, preview: String) -> AgentProjectionRecord {
        record(sequence, id, ["type": .string("assistant"), "role": .string("assistant"), "blocks": .array([
            .object(["type": .string("tool_call"), "name": .string(name), "toolCallID": .string("t\(sequence)"), "preview": .string(preview)]),
        ])])
    }

    private func result(_ sequence: UInt64, _ id: String) -> AgentProjectionRecord {
        record(sequence, id, ["type": .string("user"), "role": .string("user"), "blocks": .array([
            .object(["type": .string("tool_result"), "toolCallID": .string("t\(sequence - 1)"), "preview": .string("The file has been updated.")]),
        ])])
    }

    private func snapshot(_ provider: AgentProviderID, _ records: [AgentProjectionRecord]) async throws -> AgentThreadSnapshot {
        let thread = AgentThreadID(hostID: UUID(uuidString: "A11CE000-0000-4000-8000-0000000000E1")!, providerID: provider, providerSessionID: "edits")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: thread, title: "Edits", providerName: "Agent", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: true)))
        _ = await runtime.apply(page: AgentProjectionPage(sourceIdentity: "edit-fixture", records: records, cursor: nil, hasMore: false)!, to: thread)
        let snapshot = await runtime.snapshot(for: thread)
        return try XCTUnwrap(snapshot)
    }

    private let edit = #"{"file_path":"/home/u/plan.md","new_string":"Version four.\nDone.","old_string":"Version three."}"#

    func testAnEditFollowsItsCallWithAHunkOfItsOldAndNewText() async throws {
        let snapshot = try await snapshot(.claude, [call(1, "edit", name: "Edit", preview: edit)])
        let blocks = try XCTUnwrap(snapshot.messages.first?.blocks)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first, .toolCall(name: "Edit", preview: edit, callID: "t1"))
        XCTAssertEqual(blocks.last, .edit(path: "/home/u/plan.md", diff: "@@ -0,1 +0,2 @@\n-Version three.\n+Version four.\n+Done.\n"))
        XCTAssertEqual(snapshot.changes.edits.map(\.path), ["/home/u/plan.md"])
        XCTAssertEqual(snapshot.changes.edits.first?.additions, 2)
        XCTAssertEqual(snapshot.changes.edits.first?.deletions, 1)
    }

    func testAMultiEditKeepsItsEditsInOrderAndCRLFSplitsLines() async throws {
        let preview = #"{"edits":[{"new_string":"b","old_string":"a"},{"new_string":"d\r\ne","old_string":"c"}],"file_path":"/x.txt"}"#
        let snapshot = try await snapshot(.claude, [call(1, "multi", name: "MultiEdit", preview: preview)])
        XCTAssertEqual(snapshot.messages.first?.blocks.last,
                       .edit(path: "/x.txt", diff: "@@ -0,1 +0,1 @@\n-a\n+b\n@@ -0,1 +0,2 @@\n-c\n+d\n+e\n"))
    }

    func testAWriteAddsTheWholeFileFromItsFirstLine() async throws {
        let preview = #"{"content":"one\ntwo\n","file_path":"/new.txt"}"#
        let snapshot = try await snapshot(.claude, [call(1, "write", name: "Write", preview: preview)])
        XCTAssertEqual(snapshot.messages.first?.blocks.last, .edit(path: "/new.txt", diff: "@@ -0,0 +1,2 @@\n+one\n+two\n"))
    }

    func testAnIncompleteOrMistypedInputStaysAPlainCall() async throws {
        let previews = [
            String(edit.dropLast(8)),
            #"{"new_string":"b","old_string":"a"}"#,
            #"{"file_path":"/x","new_string":"b","old_string":3}"#,
        ]
        for preview in previews {
            let snapshot = try await snapshot(.claude, [call(1, "bad", name: "Edit", preview: preview)])
            XCTAssertEqual(snapshot.messages.first?.blocks, [.toolCall(name: "Edit", preview: preview, callID: "t1")], preview)
            XCTAssertTrue(snapshot.changes.edits.isEmpty)
        }
    }

    func testAnotherProvidersCallOfTheSameNameStaysAPlainCall() async throws {
        let snapshot = try await snapshot(.codex, [call(1, "edit", name: "Edit", preview: edit)])
        XCTAssertEqual(snapshot.messages.first?.blocks, [.toolCall(name: "Edit", preview: edit, callID: "t1")])
    }

    func testTheCallStaysInItsToolRunAndTheCardFollowsIt() async throws {
        let snapshot = try await snapshot(.claude, [
            call(1, "read", name: "Read", preview: #"{"file_path":"/home/u/plan.md"}"#),
            result(2, "read-result"),
            call(3, "edit", name: "Edit", preview: edit),
            result(4, "edit-result"),
        ])
        let items = AgentTranscriptGrouping.items(snapshot.messages)
        guard items.count == 3, case .toolRun(let before) = items[0], case .toolRun(let after) = items[2] else {
            return XCTFail("expected run, card, run: \(items)")
        }
        XCTAssertEqual(before.callCount, 2)
        XCTAssertEqual(before.latestCall?.name, "Edit")
        XCTAssertEqual(after.resultCount, 1)
    }
}
