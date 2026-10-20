import XCTest
@testable import TesseraAgentCore

final class AgentProjectionSummaryTests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func thread() -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "summary-test")!
    }

    private func summary(_ id: AgentThreadID) -> AgentThreadSummary {
        .init(
            id: id,
            providerName: "Codex",
            availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)
        )
    }

    private func record(_ sequence: UInt64, role: String = "assistant", text: String) -> AgentProjectionRecord {
        AgentProjectionRecord(
            sequence: sequence,
            recordID: "record-\(sequence)",
            record: .object(["type": .string("message"), "role": .string(role), "blocks": .array([.object(["type": .string("text"), "text": .string(text)])])])
        )!
    }

    func testDiscoveryRefreshDoesNotEraseProjectedMetadata() async throws {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id))
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: [record(1, text: "Live reply")], cursor: nil, hasMore: false, summary: .object([
            "model": .string("gpt-6-astra"), "permissionMode": .string("on-request"),
            "used_tokens": .number(9000), "max_tokens": .number(16000),
            "project": .string("tessera"), "branch": .string("main")
        ])))
        _ = await runtime.apply(page: page, to: id)
        let before = await runtime.snapshot(for: id)
        XCTAssertEqual(before?.summary.permissionMode, .defaultMode)
        await runtime.register(summary(id))
        let after = await runtime.snapshot(for: id)
        XCTAssertEqual(after?.summary.model, "gpt-6-astra")
        XCTAssertEqual(after?.summary.context, before?.summary.context)
        XCTAssertEqual(after?.summary.permissionMode, .defaultMode)
        XCTAssertEqual(after?.summary.projectBasename, "tessera")
        XCTAssertEqual(after?.summary.branch, "main")
        XCTAssertEqual(after?.summary.preview, "Live reply")
    }

    func testShortenedMessageUpdatesPreviewWithoutUsingSystemNotice() async throws {
        let id = thread(); let runtime = AgentCenterRuntime()
        await runtime.register(summary(id))
        let body: AgentJSONValue = .object(["type": .string("message"), "role": .string("assistant"),
            "truncated": .bool(true), "blocks": .array([.object(["type": .string("text"), "text": .string("Authored preview")])])])
        let source = try XCTUnwrap(AgentProjectionRecord(sequence: 1, recordID: "short", record: body))
        let page = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", records: [source], cursor: nil, hasMore: false))
        _ = await runtime.apply(page: page, to: id)
        let snapshot = await runtime.snapshot(for: id)
        XCTAssertEqual(snapshot?.summary.preview, "Authored preview")
        XCTAssertEqual(snapshot?.messages.first?.blocks.first, .shortenedPreviewNotice)
        var slowBody = try XCTUnwrap(body.objectValue)
        slowBody["blocks"] = .array([.object(["type": .string("text"), "text": .string("Updated slow preview")])])
        let accepted = await runtime.apply(summary: .init(epoch: "epoch", requestID: "summary", thread: "handle",
            revision: "revision", modified: Date(), records: [.object(slowBody)]), to: id)
        XCTAssertTrue(accepted)
        let updated = await runtime.snapshot(for: id)
        XCTAssertEqual(updated?.summary.preview, "Updated slow preview")
    }

    func testPageSummaryValidatesAndRoundTrips() throws {
        let page = try XCTUnwrap(AgentProjectionPage(
            sourceIdentity: "source",
            records: [record(1, text: "hello")],
            cursor: nil,
            hasMore: false,
            summary: .object(["title": .string("A native title"), "openingPrompt": .string("Opening request")])
        ))
        let decoded = try JSONDecoder().decode(AgentProjectionPage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(decoded, page)

        XCTAssertNil(AgentProjectionPage(
            sourceIdentity: "source",
            records: [],
            cursor: nil,
            hasMore: false,
            summary: .string("not an object")
        ))
        XCTAssertNil(AgentProjectionPage(
            sourceIdentity: "source",
            records: [],
            cursor: nil,
            hasMore: false,
            summary: .object(["openingPrompt": .string(String(repeating: "p", count: 4_097))])
        ))
        XCTAssertNil(AgentProjectionPage(
            sourceIdentity: "source",
            records: [],
            cursor: nil,
            hasMore: false,
            summary: .object(["detail": .string(String(repeating: "d", count: 16_384))])
        ))
    }

    func testSummaryRefreshesNewestTailAndAuthoritativeOpeningSeedWithoutCreatingRecords() async throws {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id))

        let newestTail: [AgentProjectionRecord] = (500...599).map { sequence in
            let role: String = sequence == 500 ? "user" : "assistant"
            let text: String = sequence == 500 ? "Visible tail prompt" : "tail \(sequence)"
            return self.record(UInt64(sequence), role: role, text: text)
        }
        let first = try XCTUnwrap(AgentProjectionPage(
            sourceIdentity: "source",
            records: newestTail,
            cursor: "before-500",
            hasMore: true,
            summary: .object([
                "title": .string("Host discovered title"),
                "openingPrompt": .string("  Authoritative opening request from the host scan.  "),
                "model": .string("gpt-5"),
                "project": .string("tessera"),
                "branch": .string("main"),
                "permissionMode": .string("plan"),
                "used_tokens": .number(9_000),
                "max_tokens": .number(16_000),
                "context_percent": .number(56.25),
            ])
        ))
        let firstResult = await runtime.apply(page: first, to: id)
        XCTAssertEqual(firstResult, .applied)

        let firstSnapshotValue = await runtime.snapshot(for: id)
        let firstSnapshot = try XCTUnwrap(firstSnapshotValue)
        XCTAssertEqual(firstSnapshot.messages.count, 100)
        XCTAssertFalse(firstSnapshot.messages.contains(where: { $0.recordID == "page-summary" }))
        XCTAssertEqual(firstSnapshot.summary.title, "Host discovered title")
        XCTAssertEqual(firstSnapshot.summary.titleSeed, "Authoritative opening request from the host scan.")
        XCTAssertEqual(firstSnapshot.summary.model, "gpt-5")
        XCTAssertEqual(firstSnapshot.summary.projectBasename, "tessera")
        XCTAssertEqual(firstSnapshot.summary.branch, "main")
        XCTAssertEqual(firstSnapshot.summary.permissionMode, .plan)
        XCTAssertEqual(firstSnapshot.summary.context.usedTokens, 9_000)

        let older: [AgentProjectionRecord] = (400...499).map { sequence in
            let role: String = sequence == 400 ? "user" : "assistant"
            let text: String = sequence == 400 ? "Older visible prompt" : "older \(sequence)"
            return self.record(UInt64(sequence), role: role, text: text)
        }
        let olderPage = try XCTUnwrap(AgentProjectionPage(
            sourceIdentity: "source",
            records: older,
            cursor: nil,
            hasMore: false,
            summary: .object(["model": .string("gpt-5")])
        ))
        let olderResult = await runtime.apply(page: olderPage, to: id)
        XCTAssertEqual(olderResult, .applied)

        let afterOlderValue = await runtime.snapshot(for: id)
        let afterOlder = try XCTUnwrap(afterOlderValue)
        XCTAssertEqual(afterOlder.messages.count, 200)
        XCTAssertEqual(afterOlder.summary.titleSeed, "Authoritative opening request from the host scan.")

        let emptyRefresh = try XCTUnwrap(AgentProjectionPage(
            sourceIdentity: "source",
            records: [],
            cursor: nil,
            hasMore: false,
            summary: .object([
                "model": .string("gpt-5.1"),
                "used_tokens": .number(10_000),
                "max_tokens": .number(20_000),
                "context_percent": .number(50),
            ])
        ))
        let emptyResult = await runtime.apply(page: emptyRefresh, to: id)
        XCTAssertEqual(emptyResult, .duplicate)
        let refreshedValue = await runtime.snapshot(for: id)
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertEqual(refreshed.messages.count, 200)
        XCTAssertEqual(refreshed.summary.model, "gpt-5.1")
        XCTAssertEqual(refreshed.summary.context.maximumTokens, 20_000)
        XCTAssertEqual(refreshed.summary.titleSeed, "Authoritative opening request from the host scan.")

        let next = try XCTUnwrap(AgentProjectionPage(
            sourceIdentity: "source",
            records: [record(600, text: "next")],
            cursor: nil,
            hasMore: false,
            summary: .object([:])
        ))
        let nextResult = await runtime.apply(page: next, to: id)
        XCTAssertEqual(nextResult, .applied)
        let finalValue = await runtime.snapshot(for: id)
        let final = try XCTUnwrap(finalValue)
        XCTAssertEqual(final.messages.map(\.recordID).last, "record-600")
        XCTAssertFalse(final.messages.contains(where: { $0.recordID == "page-summary" }))
    }

    func testLegacyCursorPageWaitsForTerminalHistoryBeforeSeeding() async throws {
        let id = thread()
        let runtime = AgentCenterRuntime()
        await runtime.register(summary(id))
        let newest = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source",
            records: [record(2, role: "user", text: "Late request")], cursor: "older", hasMore: true))
        _ = await runtime.apply(page: newest, to: id)
        let firstSnapshot = await runtime.snapshot(for: id)
        var snapshot = try XCTUnwrap(firstSnapshot)
        XCTAssertNil(snapshot.summary.titleSeed)
        XCTAssertEqual(snapshot.summary.titleProvenance, .placeholder)
        let older = try XCTUnwrap(AgentProjectionPage(sourceIdentity: "source", from: "older",
            records: [record(1, role: "user", text: "Opening request")], cursor: nil, hasMore: false))
        _ = await runtime.apply(page: older, to: id)
        let secondSnapshot = await runtime.snapshot(for: id)
        snapshot = try XCTUnwrap(secondSnapshot)
        XCTAssertEqual(snapshot.summary.titleSeed, "Opening request")
        XCTAssertEqual(snapshot.summary.title, "Opening request")
    }
}
