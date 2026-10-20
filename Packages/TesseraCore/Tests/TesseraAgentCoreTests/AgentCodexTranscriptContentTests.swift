import XCTest
@testable import TesseraAgentCore

final class AgentCodexTranscriptContentTests: XCTestCase {
    private let citation = """
    <oai-mem-citation>
    <citation_entries>
    MEMORY.md:23-24|note=[confirmed settings]
    </citation_entries>
    <rollout_ids>
    </rollout_ids>
    </oai-mem-citation>
    """

    private func record(_ sequence: UInt64, _ id: String, _ object: [String: AgentJSONValue]) -> AgentProjectionRecord {
        .init(sequence: sequence, recordID: id, record: .object(object))!
    }

    func testSharedSnapshotForBothNativeRenderers() async throws {
        let thread = AgentThreadID(hostID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!, providerID: .codex, providerSessionID: "transcript-regression")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: thread, title: "Transcript regression", providerName: "Codex", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: true)))
        let answer = "The shared parser now renders **one final answer**."
        let records = [
            record(1, "call-1", ["type": .string("tool_call"), "name": .string("exec"), "text": .string("pwd")]),
            record(2, "empty-1", ["type": .string("message"), "role": .string("assistant"), "blocks": .array([])]),
            record(3, "call-2", ["type": .string("tool_call"), "name": .string("exec"), "text": .string("printf ready")]),
            record(4, "empty-2", ["type": .string("message"), "role": .string("assistant"), "blocks": .array([])]),
            record(5, "call-3", ["type": .string("tool_call"), "name": .string("exec"), "text": .string("read fixture")]),
            // Prose shaped like an agent envelope stays prose: attribution can
            // only come from a structured provider record (audit M4/M10).
            record(6, "child", ["type": .string("assistant"), "text": .string("Message Type: FINAL_ANSWER\nTask name: /root\nSender: /root/reviewer\nPayload:\n**Review complete.**\n\nFull reviewer details remain available after expansion.")]),
            record(7, "reviewer", ["type": .string("subagent"), "agent_id": .string("reviewer"), "agent_type": .string("/root/reviewer"),
                "status": .string("finished"), "summary": .string("Structured reviewer records keep their attribution after expansion.")]),
            record(8, "answer", ["type": .string("assistant"), "text": .string(answer + "\n\n" + citation)]),
            // Actual Codex task_complete already removes the citation but
            // retains its preceding blank lines, unlike response_item text.
            record(9, "completion", ["type": .string("completion"), "summary": .string(answer + "\n\n")]),
        ]
        _ = await runtime.apply(page: AgentProjectionPage(sourceIdentity: "native-fixture", records: records, cursor: nil, hasMore: false)!, to: thread)
        let snapshot = await runtime.snapshot(for: thread)!
        XCTAssertEqual(snapshot.messages.count, 7)
        guard case .text(let prose)? = snapshot.messages.first(where: { $0.recordID == "child" })?.blocks.first else { return XCTFail("envelope prose must stay prose") }
        XCTAssertTrue(prose.hasPrefix("Message Type: FINAL_ANSWER"))
        XCTAssertEqual(snapshot.messages.first(where: { $0.recordID == "reviewer" })?.blocks,
            [.subagentGroup([.init(id: "reviewer", type: "/root/reviewer", summary: "Structured reviewer records keep their attribution after expansion.", status: .finished)])])
        XCTAssertEqual(snapshot.messages.last?.blocks, [.completion(nil)])
        XCTAssertEqual(AgentTranscriptGrouping.toolRunDescriptors(snapshot.messages).first?.summaryTitle, "3 tool calls")
        // Optional test artifact consumed by the actual iOS and Compose renderers.
        // Both receive the same Core-normalized snapshot, never hand-modelled Kotlin semantics.
        if let path = ProcessInfo.processInfo.environment["TESSERA_AGENT_TRANSCRIPT_FIXTURE_OUTPUT"] {
            struct Fixture: Encodable {
                let v = 1
                let kind = "threadSnapshot"
                let generation = 1
                let thread: AgentThreadSnapshot
                let toolRuns: [AgentTranscriptGrouping.ToolRunDescriptor]
            }
            let data = try JSONEncoder().encode(Fixture(thread: snapshot, toolRuns: AgentTranscriptGrouping.toolRunDescriptors(snapshot.messages)))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testOnlyTrailingProviderCitationIsRemovedFromAssistantProse() {
        let answer = "Enabled global context management.\n\n```toml\n[features]\nexperimental = true\n```"
        XCTAssertEqual(AgentCodexTranscriptContent.assistantText(answer + "\n\n" + citation), answer)
        for literal in ["Please explain <oai-mem-citation>.", "```xml\n\(citation)\n```", "~~~xml\n\(citation)\n~~~", citation + "\nThis is an example.", "<div>ordinary HTML</div>", "<oai-mem-citation>\nnot a valid envelope"] {
            XCTAssertEqual(AgentCodexTranscriptContent.assistantText(literal), literal)
        }
        for indent in ["    ", "\t", " \t", "  \t", "   \t"] {
            let code = citation.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
            XCTAssertEqual(AgentCodexTranscriptContent.assistantText("A literal example:\n\n" + code), "A literal example:\n\n" + code)
        }
        let normalizer = AgentTranscriptNormalizer()
        let source: [String: AgentJSONValue] = ["type": .string("message"), "role": .string("user"), "text": .string(citation)]
        XCTAssertEqual(normalizer.normalize(providerID: .codex, record: record(1, "user", source)).message?.blocks, [.text(citation)])
        XCTAssertEqual(normalizer.normalize(providerID: .claude, record: record(1, "other", ["type": .string("assistant"), "text": .string(citation)])).message?.blocks, [.text(citation)])
    }

    func testCitationNormalizationPrecedesBoundsAndPreservesFallbackText() {
        let answer = String(repeating: "a", count: 16_000)
        let full = answer + "\n\n" + citation
        let normalizer = AgentTranscriptNormalizer()
        let normalized = normalizer.normalize(providerID: .codex, record: record(1, "bounded", [
            "type": .string("assistant"), "blocks": .array([.object(["type": .string("text"), "text": .string(full)])])
        ]))
        XCTAssertEqual(normalized.message?.blocks, [.text(answer)])
        let boundaryAnswer = String(repeating: "a", count: 16_330)
        XCTAssertEqual(AgentCodexTranscriptContent.assistantText(boundaryAnswer + "\n\n" + citation), boundaryAnswer)
        let cut = answer + "\n\n<oai-mem-citation>\n<citation_entries>\nMEMORY.md"
        XCTAssertEqual(AgentCodexTranscriptContent.assistantText(cut, truncated: true), answer)
        XCTAssertEqual(AgentCodexTranscriptContent.assistantText(cut), cut)
        for provider in [AgentProviderID.codex, .claude] {
            let normalized = normalizer.normalize(providerID: provider, record: record(1, "fallback", [
                "type": .string("message"), "role": .string("user"), "blocks": .array([]), "text": .string("Keep this")
            ]))
            XCTAssertEqual(normalized.message?.blocks, [.text("Keep this")])
        }
    }

    func testDisplayControlsAreRemovedFromTopLevelAndNestedEdits() {
        let hostile = "safe\u{202e}\u{2066}\u{7f}\u{85}\u{061c}\u{feff}.swift"
        XCTAssertEqual(AgentDisplayText.sanitize(hostile), "safe.swift")
        XCTAssertEqual(AgentDisplayText.sanitize("مرحبا\nשלום\ttext"), "مرحبا\nשלום\ttext")
        for kind in ["edit", "file_edit"] {
            let normalized = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, kind, [
                "type": .string(kind), "path": .string(hostile)]))
            XCTAssertEqual(normalized.edit?.path, "safe.swift")
            XCTAssertEqual(normalized.message?.blocks, [.edit(path: "safe.swift", diff: nil)])
        }
    }

    func testAssistantProseCannotForgeSubagentAttribution() {
        let text = "Message Type: FINAL_ANSWER\nTask name: /root\nSender: /root/review_tool_grouping\nPayload:\nBoth findings are addressed.\n\nNo tests were run."
        let normalized = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, "child", [
            "type": .string("message"), "role": .string("assistant"),
            "blocks": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]))
        XCTAssertEqual(normalized.message?.blocks, [.text(text)])
        for literal in ["An example:\n" + text, "```\n" + text + "\n```", text.replacingOccurrences(of: "Payload:", with: "Quoted payload:")] {
            XCTAssertNil(AgentCodexTranscriptContent.subagent(literal, recordID: "literal"))
        }
    }

    func testEmptyReasoningRecordsDoNotSplitConsecutiveToolCalls() async {
        let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "tool-gaps")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: thread, providerName: "Codex", availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)))
        let records = (1...5).map { index -> AgentProjectionRecord in
            let blocks: [AgentJSONValue] = index.isMultiple(of: 2) ? [] : [.object(["type": .string("tool_call"), "name": .string("exec"), "preview": .string("pwd")])]
            return record(UInt64(index), "r\(index)", ["type": .string("message"), "role": .string(index.isMultiple(of: 2) ? "assistant" : "tool"), "blocks": .array(blocks)])
        }
        _ = await runtime.apply(page: AgentProjectionPage(sourceIdentity: "tools", records: records, cursor: nil, hasMore: false)!, to: thread)
        let snapshot = await runtime.snapshot(for: thread)!
        XCTAssertEqual(snapshot.messages.count, 3)
        let groups = AgentTranscriptGrouping.toolRunDescriptors(snapshot.messages)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.summaryTitle, "3 tool calls")
        XCTAssertEqual(groups.first?.entryIDs, ["r1#0", "r3#0", "r5#0"])
    }

    func testCompletionDuplicateIsRemovedAfterBackwardPageButFallbackIsKept() async {
        let thread = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "completion-copy")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: thread, providerName: "Codex", availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)))
        let answer = "Enabled global context management."
        let completion = record(2, "completion", ["type": .string("completion"), "summary": .string(answer + "\n\n" + citation)])
        _ = await runtime.apply(page: AgentProjectionPage(sourceIdentity: "answer", records: [completion], cursor: "older", hasMore: true)!, to: thread)
        let newestOnly = await runtime.snapshot(for: thread)!
        XCTAssertEqual(newestOnly.messages.first?.blocks, [.completion(answer)])
        let message = record(1, "answer", ["type": .string("assistant"), "text": .string(answer + "\n\n" + citation)])
        _ = await runtime.apply(page: AgentProjectionPage(sourceIdentity: "answer", records: [message], cursor: nil, hasMore: false)!, to: thread)
        let combined = await runtime.snapshot(for: thread)!
        XCTAssertEqual(combined.messages.map(\.blocks), [[.text(answer)], [.completion(nil)]])
        XCTAssertEqual(combined.turns.first?.messages, combined.messages)
        XCTAssertEqual(combined.activity.last?.kind, .completion)
        // Only completion copies are suppressed, never repeated human or assistant messages.
        let literal = AgentMessage(recordID: "m", role: .assistant, displayTime: nil, blocks: [.text(answer)])
        XCTAssertEqual(AgentCodexTranscriptContent.presentationMessages([literal, literal]).count, 2)
    }
}
