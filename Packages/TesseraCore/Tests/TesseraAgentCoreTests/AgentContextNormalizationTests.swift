import XCTest
@testable import TesseraAgentCore

final class AgentContextNormalizationTests: XCTestCase {
    // Codex 0.162.1: last_token_usage input=79127, output=211,
    // model_context_window=475000. These are the native host's output fields.
    private let tokens: AgentJSONValue = .object([
        "type": .string("cost-state"), "used_tokens": .number(79_338), "max_tokens": .number(475_000)
    ])

    private func normalize(_ body: AgentJSONValue, provider: AgentProviderID = .codex) throws -> AgentNormalizedRecord {
        let record = try XCTUnwrap(AgentProjectionRecord(sequence: 1, recordID: "tokens", record: body))
        return AgentTranscriptNormalizer().normalize(providerID: provider, record: record)
    }

    func testNativeCodexCountsDeriveContextPercentageWithoutCostOrMessage() throws {
        let normalized = try normalize(tokens)
        XCTAssertEqual(normalized.context?.usedTokens, 79_338)
        XCTAssertEqual(normalized.context?.maximumTokens, 475_000)
        XCTAssertEqual(try XCTUnwrap(normalized.context?.percentUsed), 15.0, accuracy: 0.000001)
        XCTAssertNil(normalized.cost)
        XCTAssertNil(normalized.message)
    }

    func testPercentageRequiresNonnegativeUsageAndPositiveKnownWindow() throws {
        for maximum in [nil, 0, -1] as [Int?] {
            var fields: [String: AgentJSONValue] = ["type": .string("cost-state"), "used_tokens": .number(42)]
            if let maximum { fields["max_tokens"] = .number(Decimal(maximum)) }
            let normalized = try normalize(.object(fields), provider: .pi)
            XCTAssertEqual(normalized.context?.usedTokens, 42)
            XCTAssertNil(normalized.context?.percentUsed)
        }
        let negative = try normalize(.object(["type": .string("cost-state"), "used_tokens": .number(-1), "max_tokens": .number(100)]))
        XCTAssertNil(negative.context?.percentUsed)
    }

    func testExplicitPercentageWinsAndDerivedPercentageClamps() throws {
        for (used, explicit, expected) in [(0, nil, 0.0), (200, nil, 100.0), (50, 12.5, 12.5)] as [(Int, Double?, Double)] {
            var fields: [String: AgentJSONValue] = ["type": .string("cost-state"), "used_tokens": .number(Decimal(used)), "max_tokens": .number(100)]
            if let explicit { fields["context_percent"] = .number(Decimal(explicit)) }
            XCTAssertEqual(try normalize(.object(fields), provider: .pi).context?.percentUsed, expected)
        }
    }

    func testMetadataWithoutUsageAndRequestTotalsDoNotEmitEmptyContext() throws {
        for type in ["metadata", "session_meta", "turn_context"] {
            XCTAssertNil(try normalize(.object(["type": .string(type), "model": .string("gpt-6-astra")])).context)
        }
        // Native token_usage_record output keeps these three families distinct;
        // none is an authoritative current-context/window pair.
        let usage: AgentJSONValue = .object(["input_tokens": .number(81_154), "output_tokens": .number(501), "total_tokens": .number(81_655)])
        XCTAssertNil(try normalize(.object(["type": .string("cost-state"), "usage": usage,
            "turn_token_usage": usage, "thread_token_usage": usage])).context)
    }

    func testProjectionPublishesDerivedContextAndPreservesItAcrossEmptyMetadata() async throws {
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "context-test")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: id, providerName: "Codex", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        let bodies = [tokens, .object(["type": .string("turn_context"), "model": .string("gpt-6-astra")])]
        let records = try bodies.enumerated().map { index, body in
            try XCTUnwrap(AgentProjectionRecord(sequence: UInt64(index + 1), recordID: "context-\(index)", record: body))
        }
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: records, cursor: nil, hasMore: false))
        let result = await runtime.apply(page: page, to: id)
        XCTAssertEqual(result, .applied)
        let snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(try XCTUnwrap(snapshot?.summary.context.percentUsed), 15.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot?.summary.model, "gpt-6-astra")
    }

    func testSlowSummaryPreservesContextAcrossLaterMetadataAndTotals() async throws {
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "slow-context-test")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: id, providerName: "Codex", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        let result = await runtime.apply(summary: .init(epoch: "epoch", requestID: "summary", thread: "handle",
            revision: "revision", modified: Date(), records: [tokens,
                .object(["type": .string("turn_context"), "model": .string("gpt-6-astra")]),
                .object(["type": .string("cost-state"), "thread_token_usage": .object(["total_tokens": .number(907_733)])])]), to: id)
        XCTAssertTrue(result)
        let snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.context.usedTokens, 79_338)
        XCTAssertEqual(try XCTUnwrap(snapshot?.summary.context.percentUsed), 15.0, accuracy: 0.000001)
    }

    func testSidechainContextCannotReplaceRootUsage() throws {
        var fields = try XCTUnwrap(tokens.objectValue)
        fields["isSidechain"] = .bool(true)
        XCTAssertNil(try normalize(.object(fields)).context)
    }

    func testClaudeMessageCarriesUsedOnlyContext() throws {
        let body: AgentJSONValue = .object(["type": .string("message"), "role": .string("assistant"),
            "used_tokens": .number(84_320), "text": .string("hello")])
        let value = try normalize(body, provider: .claude)
        XCTAssertEqual(value.context?.usedTokens, 84_320)
        XCTAssertNil(value.context?.maximumTokens)
        XCTAssertNil(value.context?.percentUsed)
        XCTAssertNotNil(value.message)
        for flag in ["isMeta", "isSidechain", "isSubagent"] {
            var fields = try XCTUnwrap(body.objectValue)
            fields[flag] = .bool(true)
            XCTAssertNil(try normalize(.object(fields), provider: .claude).context)
        }
        XCTAssertNil(try normalize(.object(["type": .string("message"), "text": .string("hello")]), provider: .claude).context)
    }

    func testCodexBaselineAndRoundedRemainingPercentage() throws {
        for (used, window, expected) in [(0, 475_000, 0), (11_999, 475_000, 0),
            (12_000, 475_000, 0), (12_100, 32_000, 0), (12_200, 32_000, 1),
            (79_338, 475_000, 15), (475_001, 475_000, 100)] {
            let value = try normalize(.object(["type": .string("cost-state"),
                "used_tokens": .number(Decimal(used)), "max_tokens": .number(Decimal(window))]))
            XCTAssertEqual(value.context?.percentUsed, Double(expected), "used=\(used), window=\(window)")
        }
        let explicit = try normalize(.object(["type": .string("cost-state"), "used_tokens": .number(0),
            "max_tokens": .number(12_000), "context_percent": .number(12.5)]))
        XCTAssertEqual(explicit.context?.percentUsed, 12.5)
        let other = try normalize(tokens, provider: .pi)
        XCTAssertEqual(try XCTUnwrap(other.context?.percentUsed), 16.702736842105263, accuracy: 0.000001)
    }

    func testClaudeLatestUsageWinsWithoutAccumulatingAndEmptyMetadataPreservesIt() async throws {
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "claude-context")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        let bodies: [AgentJSONValue] = [
            .object(["type": .string("message"), "role": .string("assistant"), "used_tokens": .number(80_000), "text": .string("first")]),
            .object(["type": .string("message"), "role": .string("assistant"), "used_tokens": .number(84_000), "text": .string("latest")]),
            .object(["type": .string("message"), "role": .string("assistant"), "used_tokens": .number(84_000), "text": .string("same API call")]),
            .object(["type": .string("message"), "role": .string("assistant"), "used_tokens": .number(999_000), "isSidechain": .bool(true), "text": .string("child")]),
            .object(["type": .string("metadata"), "model": .string("claude-opus")])]
        let records = try bodies.enumerated().map { index, body in
            try XCTUnwrap(AgentProjectionRecord(sequence: UInt64(index + 1), recordID: "claude-\(index)", record: body))
        }
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: records, cursor: nil, hasMore: false))
        let result = await runtime.apply(page: page, to: id)
        XCTAssertEqual(result, .applied)
        var snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.context.usedTokens, 84_000)
        XCTAssertNil(snapshot?.summary.context.percentUsed)
        let applied = await runtime.apply(summary: .init(epoch: "epoch", requestID: "summary", thread: "handle",
            revision: "revision", modified: Date(), records: bodies), to: id)
        XCTAssertTrue(applied)
        snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.context.usedTokens, 84_000)
        XCTAssertNil(snapshot?.summary.context.percentUsed)
    }

    func testCompactTokenRoundingAndContextPrecedence() {
        for (count, expected) in [(-1, "0"), (0, "0"), (950, "950"), (999, "999"),
            (1_000, "1k"), (1_499, "1k"), (1_500, "2k"), (84_320, "84k"),
            (84_500, "85k"), (999_499, "999k"), (999_500, "1M"), (1_049_999, "1M"),
            (1_050_000, "1.1M"), (1_200_000, "1.2M"), (9_007_199_254_740_991, "9007199254.7M")] {
            XCTAssertEqual(AgentCompactTokenCount.format(count, locale: Locale(identifier: "en_US")), expected)
        }
        XCTAssertEqual(AgentContextSummary(usedTokens: 84_320).compactTokenCount, "84k")
        XCTAssertNil(AgentContextSummary(usedTokens: 84_320, percentUsed: 0).compactTokenCount)
        XCTAssertNil(AgentContextSummary(usedTokens: 0).compactTokenCount)
        XCTAssertNil(AgentContextSummary().compactTokenCount)
    }


    func testCodexWindowAtOrBelowBaselineLeavesPercentageUnknown() throws {
        for maximum in [-1, 0, 1, 11_999, 12_000] {
            let value = try normalize(.object(["type": .string("cost-state"),
                "used_tokens": .number(20_000), "max_tokens": .number(Decimal(maximum))]))
            XCTAssertEqual(value.context?.usedTokens, 20_000)
            XCTAssertNil(value.context?.percentUsed, "window=\(maximum)")
            XCTAssertEqual(value.context?.compactTokenCount, "20k")
        }
    }

    func testCompactTokenCountUsesLocaleDecimalSeparator() {
        for (locale, expected) in [("en_US", "1.2M"), ("de_DE", "1,2M")] {
            XCTAssertEqual(AgentCompactTokenCount.format(1_200_000, locale: Locale(identifier: locale)), expected)
            XCTAssertEqual(AgentCompactTokenCount.format(999_500, locale: Locale(identifier: locale)), "1M")
            XCTAssertEqual(AgentCompactTokenCount.format(84_500, locale: Locale(identifier: locale)), "85k")
        }
    }

    private var claudeCompactions: [AgentJSONValue] {
        [
            .object(["type": .string("system"), "subtype": .string("compact_boundary")]),
            .object(["type": .string("message"), "role": .string("system"), "subtype": .string("compact_boundary")]),
            .object(["type": .string("user"), "isCompactSummary": .bool(true), "text": .string("Summary")]),
            .object(["type": .string("message"), "role": .string("system"), "isCompactSummary": .bool(true),
                "blocks": .array([.object(["type": .string("compact-summary"), "text": .string("Summary")])])]),
            .object(["type": .string("message"), "role": .string("system"), "isCompactSummary": .bool(true)])
        ]
    }

    private func claudeUsage(_ count: Int) -> AgentJSONValue {
        .object(["type": .string("message"), "role": .string("assistant"),
            "used_tokens": .number(Decimal(count)), "text": .string("Assistant")])
    }

    func testClaudeCompactionEmitsExplicitResetOnlyForMainThread() throws {
        for body in claudeCompactions {
            XCTAssertEqual(try normalize(body, provider: .claude).context, AgentContextSummary())
            for flag in ["isMeta", "isSidechain", "isSubagent"] {
                var fields = try XCTUnwrap(body.objectValue)
                fields[flag] = .bool(true)
                XCTAssertNil(try normalize(.object(fields), provider: .claude).context, flag)
            }
            XCTAssertNil(try normalize(body, provider: .pi).context)
        }
        // The native host strips bare system subtypes; an unmarked system
        // message cannot safely be inferred to mean compaction.
        XCTAssertNil(try normalize(.object(["type": .string("message"), "role": .string("system")]), provider: .claude).context)
    }

    func testClaudeCompactionResetsProjectionAndSlowSummaryUntilNextAssistantFigure() async throws {
        for compact in claudeCompactions {
            for slowSummary in [false, true] {
                let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "compact-context")!
                let runtime = AgentCenterRuntime()
                await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
                    status: true, actions: false, spawn: false, fork: false, search: false)))
                let bodies = [claudeUsage(180_000), compact,
                    .object(["type": .string("metadata"), "model": .string("claude")]), claudeUsage(25_000)]
                for (index, body) in bodies.enumerated() {
                    if slowSummary {
                        let applied = await runtime.apply(summary: .init(epoch: "epoch", requestID: "summary-\(index)",
                            thread: "handle", revision: "revision-\(index)", modified: Date(), records: [body]), to: id)
                        XCTAssertTrue(applied)
                    } else {
                        let record = try XCTUnwrap(AgentProjectionRecord(sequence: UInt64(index + 1), recordID: "compact-\(index)", record: body))
                        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: nil, hasMore: false))
                        let result = await runtime.apply(page: page, to: id)
                        XCTAssertEqual(result, .applied)
                    }
                    let snapshot = await runtime.snapshot(for: id)
                    let expected: Int? = index == 0 ? 180_000 : index == 3 ? 25_000 : nil
                    XCTAssertEqual(snapshot?.summary.context.usedTokens, expected, "step=\(index), summary=\(slowSummary)")
                    XCTAssertNil(snapshot?.summary.context.percentUsed)
                    if expected == nil { XCTAssertNil(snapshot?.summary.context.compactTokenCount) }
                }
            }
        }
    }

    func testClaudeCompactionContextOrderingInIngestion() async throws {
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "compact-ordering")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        func page(_ operation: AgentIngestionRange.Operation, _ sequence: UInt64, _ body: AgentJSONValue,
                  from: String? = nil, history: String? = nil, live: String? = nil) throws -> AgentProjectionPage {
            let record = try XCTUnwrap(AgentProjectionRecord(sequence: sequence, recordID: "r\(sequence)", record: body))
            return try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", from: from, records: [record],
                cursor: history, hasMore: history != nil, ingestion: .init(epoch: "epoch", requestID: "tx-\(sequence)",
                    operation: operation, liveCursor: live)))
        }
        let initial = try page(.bootstrap, 100, claudeUsage(180_000), history: "older", live: "live1")
        let reset = try page(.updates, 200, claudeCompactions[2], from: "live1", live: "live2")
        let oldUsage = try page(.history, 50, claudeUsage(170_000), from: "older", history: "older2")
        let restored = try page(.updates, 300, claudeUsage(25_000), from: "live2", live: "live3")
        let oldReset = try page(.history, 25, claudeCompactions[0], from: "older2")
        let rejectedReset = try page(.updates, 400, claudeCompactions[2], from: "live1", live: "live4")
        for (candidate, result, expected) in [
            (initial, AgentProjectionApplyResult.sourceReset, Int?(180_000)),
            (reset, .applied, nil), (oldUsage, .applied, nil), (restored, .applied, 25_000),
            (oldReset, .applied, 25_000), (reset, .duplicate, 25_000), (rejectedReset, .resyncRequired, 25_000)
        ] {
            let actual = await runtime.apply(page: candidate, to: id)
            XCTAssertEqual(actual, result)
            let snapshot = await runtime.snapshot(for: id)
            XCTAssertEqual(snapshot?.summary.context.usedTokens, expected)
        }
    }

    func testClaudeCompactionContextDoesNotRewindDuringLegacyPagination() async throws {
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "compact-legacy")!
        let runtime = AgentCenterRuntime()
        await runtime.register(.init(id: id, providerName: "Claude", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)))
        func page(_ rows: [(UInt64, AgentJSONValue)]) throws -> AgentProjectionPage {
            let records = try rows.map { sequence, body in
                try XCTUnwrap(AgentProjectionRecord(sequence: sequence, recordID: "legacy-\(sequence)", record: body))
            }
            return try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: records, cursor: nil, hasMore: false))
        }
        for (candidate, expected) in [
            (try page([(3, claudeUsage(180_000)), (4, claudeCompactions[2])]), Int?.none),
            (try page([(2, claudeUsage(170_000))]), nil),
            (try page([(5, claudeUsage(25_000))]), 25_000),
            (try page([(1, claudeCompactions[0])]), 25_000)
        ] {
            let applied = await runtime.apply(page: candidate, to: id)
            XCTAssertEqual(applied, .applied)
            let snapshot = await runtime.snapshot(for: id)
            XCTAssertEqual(snapshot?.summary.context.usedTokens, expected)
        }
    }

}
