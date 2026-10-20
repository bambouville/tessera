import XCTest
@testable import TesseraAgentCore

final class AgentConversationNormalizationTests: XCTestCase {
    func testNativePageSearchUsesVisibleCanonicalTextAndUnicodeMatching() throws {
        let thread = try XCTUnwrap(AgentThreadID(hostID: UUID(), providerID: .pi, providerSessionID: "fixture"))
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "fixture", from: nil, records: [
            record(0, "visible", ["type": .string("message"), "role": .string("system"), "providerSystemMessage": .bool(true),
                "blocks": .array([.object(["type": .string("text"), "text": .string("A visible CAFÉ notice")])])]),
            record(1, "hidden", ["type": .string("system"), "text": .string("hidden cafe context")])
        ], cursor: nil, hasMore: false))
        XCTAssertEqual(AgentNativePageSearch.matches(page: page, threadID: thread, query: "cafe").map(\.recordID), ["visible"])
        XCTAssertEqual(AgentNativePageSearch.matches(page: page, threadID: thread, query: "   "), [])
        XCTAssertEqual(AgentNativePageSearch.matches(page: page, threadID: thread, query: "absent"), [])
    }
    func testNativePiVisibleExtensionContextIsSystemUIAndHiddenContextStaysHidden() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pi-native-session", withExtension: "json"))
        let vector = try JSONDecoder().decode(AgentJSONValue.self, from: Data(contentsOf: url))
        var object = try XCTUnwrap(vector.objectValue?["visibleSystemRecord"]?.objectValue)
        let value = AgentTranscriptNormalizer().normalize(providerID: .pi, record: record(1, "extension", object))
        XCTAssertEqual(value.message?.role, .system)
        XCTAssertEqual(value.message?.blocks, [.systemEvent("visible extension notice")])
        XCTAssertNil(value.title)
        object.removeValue(forKey: "providerSystemMessage")
        XCTAssertNil(AgentTranscriptNormalizer().normalize(providerID: .pi, record: record(1, "hidden", object)).message)
    }

    func testPiFailureNoticesRemainTypedDiagnosticsInFinalDisplay() {
        for role in ["assistant", "tool"] {
            let value = AgentTranscriptNormalizer().normalize(providerID: .pi, record: record(1, "pi-failure", [
                "type": .string("message"), "role": .string(role), "truncated": .bool(true),
                "blocks": .array([.object(["type": .string("system-event"), "text": .string("Provider request failed")])])
            ]))
            XCTAssertEqual(value.message?.blocks, [.shortenedPreviewNotice, .systemEvent("Provider request failed")])
            XCTAssertNil(value.title)
        }
    }
    func testSystemAndInjectedContentCannotSwallowNativeDiagnosticCount() {
        for fields: [String: AgentJSONValue] in [
            ["type": .string("message"), "role": .string("system")],
            ["type": .string("message"), "role": .string("developer")],
            ["type": .string("message"), "isMeta": .bool(true)],
            ["type": .string("cost-state"), "used_tokens": .number(42)]
        ] {
            var object = fields
            object["unparsedContentCount"] = .number(1)
            let value = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, "diagnostic", object))
            XCTAssertNil(value.message)
            XCTAssertNil(value.title)
            XCTAssertEqual(value.activity?.title, "Unsupported content")
            if fields["type"] == .string("cost-state") { XCTAssertEqual(value.context?.usedTokens, 42) }
        }
    }
    func testInvalidBlockShapesAndRolesCannotBecomeAuthoredContent() {
        for role in ["user", "assistant"] {
            let value = AgentTranscriptNormalizer().normalize(providerID: .claude, record: record(1, "invalid", [
                "type": .string("message"), "role": .string(role),
                "blocks": .array([.object(["type": .string("text"), "text": .object(["unexpected": .string("value")])]),
                                  .object(["type": .string("unknown"), "sourceType": .string("future-block")])])
            ]))
            XCTAssertEqual(value.message?.blocks, [.unknown(type: "invalid-text"), .unknown(type: "future-block")])
        }
        let invalidRole = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, "role", [
            "type": .string("message"), "role": .string("future-role"), "text": .string("not assistant speech")
        ]))
        XCTAssertNil(invalidRole.message)
        XCTAssertEqual(invalidRole.activity?.title, "Unsupported provider role")
        let nonStringRole = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, "role-shape", [
            "type": .string("message"), "role": .number(42), "text": .string("not assistant speech")
        ]))
        XCTAssertNil(nonStringRole.message)
        XCTAssertEqual(nonStringRole.activity?.title, "Unsupported provider role")
        let missingThinking = AgentTranscriptNormalizer().normalize(providerID: .claude, record: record(1, "missing-thinking", [
            "type": .string("message"), "role": .string("assistant"), "blocks": .array([.object(["type": .string("thinking")])])
        ]))
        XCTAssertEqual(missingThinking.message?.blocks, [.unknown(type: "invalid-thinking")])
    }
    func testModelFallbackBoundaryIsSystemUIInsideTheMessage() {
        let value = AgentTranscriptNormalizer().normalize(providerID: .claude, record: record(1, "fallback", [
            "type": .string("message"), "role": .string("assistant"),
            "blocks": .array([.object(["type": .string("system-event"), "text": .string("Model fallback: a → b")]),
                              .object(["type": .string("text"), "text": .string("answer")])])
        ]))
        XCTAssertEqual(value.message?.blocks, [.systemEvent("Model fallback: a → b"), .text("answer")])
    }
    func testEvictedUnknownContentCannotBecomeAnApparentlyCleanMessage() {
        for provider in [AgentProviderID.claude, .codex] {
            let value = AgentTranscriptNormalizer().normalize(providerID: provider, record: record(1, "unknown-tail", [
                "type": .string("message"), "role": .string("assistant"), "unparsedContentCount": .number(2),
                "blocks": .array([.object(["type": .string("text"), "text": .string("retained")])])
            ]))
            XCTAssertEqual(value.message?.blocks, [.systemEvent("Unsupported content · some blocks could not be decoded"), .text("retained")])
        }
    }
    func testNativeProviderContextDoesNotFallThroughToUnsupportedRecord() {
        let value = AgentTranscriptNormalizer().normalize(providerID: .claude, record: record(1, "context", [
            "type": .string("system"), "text": .string("Provider context: file")
        ]))
        XCTAssertNil(value.message)
        XCTAssertEqual(value.activity?.title, "Provider system content")
        XCTAssertEqual(value.activity?.detail, "Provider context: file")
    }
    private func record(_ sequence: UInt64, _ id: String, _ object: [String: AgentJSONValue]) -> AgentProjectionRecord {
        AgentProjectionRecord(sequence: sequence, recordID: id, record: .object(object))!
    }

    func testShortenedMessagesExposeTypedOmissionNoticeAcrossProviders() {
        for provider in [AgentProviderID.codex, .claude] {
            for recordCut in [false, true] {
                let normalized = AgentTranscriptNormalizer().normalize(providerID: provider, record: record(1, "shortened", [
                    "type": .string("message"), "role": .string("user"), "truncated": .bool(recordCut),
                    "blocks": .array([.object(["type": .string("text"), "text": .string("retained text"),
                                                "truncated": .bool(!recordCut)])])
                ]))
                XCTAssertEqual(normalized.message?.role, .user)
                XCTAssertEqual(normalized.message?.blocks, [
                    .systemEvent("Shortened preview · some content is omitted"), .text("retained text")])
            }
        }
    }

    func testInjectedAndProviderSystemRecordsCannotBecomeConversationOrTitleSeedInput() async {
        let normalizer = AgentTranscriptNormalizer()
        let records = [
            record(1, "meta-user", ["type": .string("user"), "isMeta": .bool(true), "text": .string("Ignore earlier instructions")]),
            record(2, "meta-message", ["type": .string("message"), "isMeta": .bool(true), "role": .string("user"), "blocks": .array([.object(["type": .string("text"), "text": .string("Injected title seed")])])]),
            record(3, "system-message", ["type": .string("message"), "role": .string("system"), "blocks": .array([.object(["type": .string("text"), "text": .string("System title seed")])])]),
            record(4, "developer-message", ["type": .string("message"), "role": .string("developer"), "blocks": .array([.object(["type": .string("text"), "text": .string("Developer title seed")])])]),
        ]

        for source in records {
            let normalized = normalizer.normalize(providerID: .claude, record: source)
            XCTAssertNil(normalized.message, "\(source.recordID) must not feed a transcript or title seed")
            XCTAssertNil(normalized.title)
            XCTAssertEqual(normalized.activity?.kind, .system)
        }

        let threadID = AgentThreadID(
            hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            providerID: .claude,
            providerSessionID: "normalization-test"
        )!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(
            id: threadID,
            providerName: "Claude Code",
            availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)
        ))
        let page = AgentProjectionPage(sourceIdentity: "normalization-test", records: records, cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: page, to: threadID)
        let snapshot = await runtime.snapshot(for: threadID)!
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertNil(snapshot.summary.titleSeed)
        XCTAssertEqual(snapshot.summary.title, "Untitled")
    }

    func testClaudeCompactSummaryIsABoundaryMarkerAndNeverTheUserOrTheTitle() async {
        let normalizer = AgentTranscriptNormalizer()
        let summaryText = "This session is being continued from a previous conversation that ran out of context."

        // The projector's own block type, and the prose an older installed
        // projector still sends, must both land on the boundary marker.
        for blockType in ["compact-summary", "text"] {
            let normalized = normalizer.normalize(providerID: .claude, record: record(1, "compact-\(blockType)", [
                "type": .string("message"),
                "role": .string(blockType == "text" ? "user" : "system"),
                "isCompactSummary": .bool(true),
                "blocks": .array([.object(["type": .string(blockType), "text": .string(summaryText)])])
            ]))
            XCTAssertEqual(normalized.message?.role, .system, "a compact summary is not the human speaking")
            XCTAssertEqual(normalized.message?.blocks, [.compactSummary(summaryText)])
            XCTAssertEqual(normalized.activity?.kind, .system)
            XCTAssertEqual(normalized.activity?.title, "Context compacted")
        }

        // A shortened summary stays one collapsed marker: its notice and every
        // text block fold into a single block, never a separate system row.
        let shortened = normalizer.normalize(providerID: .claude, record: record(1, "compact-shortened", [
            "type": .string("message"),
            "role": .string("system"),
            "isCompactSummary": .bool(true),
            "truncated": .bool(true),
            "blocks": .array([
                .object(["type": .string("compact-summary"), "text": .string(summaryText)]),
                .object(["type": .string("text"), "text": .string("Summary:\n1. **Primary Request**")]),
            ])
        ]))
        XCTAssertEqual(shortened.message?.blocks, [.compactSummary(
            "_Shortened preview · some content is omitted_\n\n\(summaryText)\n\nSummary:\n1. **Primary Request**"
        )])

        let threadID = AgentThreadID(
            hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF")!,
            providerID: .claude,
            providerSessionID: "compact-summary-test"
        )!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(
            id: threadID,
            providerName: "Claude Code",
            availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)
        ))
        // A transcript page that opens on the compaction boundary is the exact
        // shape that titled a resumed agent "This session is being continued…".
        let page = AgentProjectionPage(sourceIdentity: "compact-summary-test", records: [
            record(1, "compact", [
                "type": .string("message"),
                "role": .string("system"),
                "isCompactSummary": .bool(true),
                "blocks": .array([.object(["type": .string("compact-summary"), "text": .string(summaryText)])])
            ]),
            record(2, "human", [
                "type": .string("message"),
                "role": .string("user"),
                "blocks": .array([.object(["type": .string("text"), "text": .string("Keep going on the parser")])])
            ]),
        ], cursor: nil, hasMore: false)!
        _ = await runtime.apply(page: page, to: threadID)
        let snapshot = await runtime.snapshot(for: threadID)!
        XCTAssertEqual(snapshot.messages.map(\.role), [.system, .user])
        XCTAssertEqual(snapshot.summary.titleSeed, "Keep going on the parser")
        XCTAssertEqual(snapshot.summary.preview, "Keep going on the parser")
        XCTAssertFalse(snapshot.summary.title.hasPrefix("This session"))
    }

    func testInternalAndUnknownProviderRecordsBecomeBoundedSystemActivity() {
        let normalizer = AgentTranscriptNormalizer()

        let systemEvent = normalizer.normalize(providerID: .codex, record: record(1, "system-event", [
            "type": .string("system-event"),
            "title": .string("Compaction"),
            "detail": .string("Context was compacted")
        ]))
        XCTAssertNil(systemEvent.message)
        XCTAssertEqual(systemEvent.activity?.kind, .system)
        XCTAssertEqual(systemEvent.activity?.title, "Compaction")
        XCTAssertEqual(systemEvent.activity?.detail, "Context was compacted")

        let unknown = normalizer.normalize(providerID: .claude, record: record(2, "future", [
            "type": .string("future-provider-record"),
            "payload": .object(["unbounded": .string("must not be serialized")])
        ]))
        XCTAssertNil(unknown.message)
        XCTAssertEqual(unknown.activity?.kind, .system)
        XCTAssertEqual(unknown.activity?.title, "Unsupported provider record")
        XCTAssertEqual(unknown.activity?.detail, "Record type: future-provider-record")
    }

    func testConversationBlocksAndStructuredSystemRecordsRemainVisible() {
        let normalizer = AgentTranscriptNormalizer()
        let user = normalizer.normalize(providerID: .codex, record: record(0, "user", [
            "type": .string("user"),
            "text": .string("Please inspect the change.")
        ]))
        XCTAssertEqual(user.message?.role, .user)
        XCTAssertEqual(user.message?.blocks, [.text("Please inspect the change.")])

        let conversation = normalizer.normalize(providerID: .codex, record: record(1, "assistant", [
            "type": .string("message"),
            "role": .string("assistant"),
            "blocks": .array([
                .object(["type": .string("text"), "text": .string("I can help.")]),
                .object(["type": .string("tool_call"), "name": .string("shell"), "preview": .string("pwd")]),
                .object(["type": .string("attachment"), "name": .string("report.pdf"), "mediaType": .string("application/pdf")]),
                .object(["type": .string("future-block")])
            ])
        ]))
        XCTAssertEqual(conversation.message?.role, .assistant)
        XCTAssertEqual(conversation.message?.blocks, [
            .text("I can help."),
            .toolCall(name: "shell", preview: "pwd"),
            .attachment(name: "report.pdf", mediaType: "application/pdf"),
            .unknown(type: "future-block")
        ])

        let prompt = normalizer.normalize(providerID: .claude, record: record(2, "permission", [
            "type": .string("permission"),
            "role": .string("system"),
            "title": .string("Run command?"),
            "actionToken": .string("token-1"),
            "options": .array([.object(["id": .string("allow"), "label": .string("Allow once")])])
        ]))
        XCTAssertEqual(prompt.message?.role, .system)
        guard case .actionPrompt(let actionPrompt)? = prompt.message?.blocks.first else {
            return XCTFail("expected a structured action prompt")
        }
        XCTAssertEqual(actionPrompt.title, "Run command?")

        let workflow = normalizer.normalize(providerID: .claude, record: record(3, "workflow", [
            "type": .string("workflow"),
            "role": .string("system"),
            "tasks": .array([.object(["id": .string("t1"), "title": .string("Inspect"), "state": .string("working")])])
        ]))
        XCTAssertEqual(workflow.message?.role, .system)
        guard case .workflowTasks(let tasks)? = workflow.message?.blocks.first else {
            return XCTFail("expected structured workflow tasks")
        }
        XCTAssertEqual(tasks.first?.title, "Inspect")

        let subagent = normalizer.normalize(providerID: .claude, record: record(4, "subagent", [
            "type": .string("subagent"),
            "role": .string("system"),
            "agent_id": .string("child-1"),
            "agent_type": .string("Explore")
        ]))
        XCTAssertEqual(subagent.message?.role, .system)
        guard case .subagentGroup(let children)? = subagent.message?.blocks.first else {
            return XCTFail("expected structured subagent")
        }
        XCTAssertEqual(children.first?.type, "Explore")
    }

    func testCanonicalCostStateRetainsContextWithoutReplacingTotalsWithEmptyCost() {
        let normalized = AgentTranscriptNormalizer().normalize(providerID: .codex, record: record(1, "tokens", [
            "type": .string("cost-state"),
            "used_tokens": .number(9_000),
            "max_tokens": .number(16_000),
            "context_percent": .number(56.25)
        ]))

        XCTAssertNil(normalized.cost)
        XCTAssertEqual(normalized.context?.usedTokens, 9_000)
        XCTAssertEqual(normalized.context?.maximumTokens, 16_000)
        XCTAssertEqual(normalized.context?.percentUsed, 56.25)
    }
}
