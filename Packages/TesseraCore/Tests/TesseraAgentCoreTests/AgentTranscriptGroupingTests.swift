import XCTest
@testable import TesseraAgentCore

/// Shared semantics; Android tests only application of these ABI descriptors.
final class AgentTranscriptGroupingTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(_ id: String, role: AgentRole = .assistant, time: Date? = nil, _ blocks: [AgentBlock]) -> AgentMessage {
        AgentMessage(recordID: id, role: role, displayTime: time, blocks: blocks)
    }

    func testConsecutiveToolActivityCollapsesAcrossMessages() {
        let items = AgentTranscriptGrouping.items([
            message("m1", [.text("plan"), .toolCall(name: "Bash", preview: "ls -la\n(and more)"), .toolResult(preview: "a b", truncated: false)]),
            message("m2", role: .tool, [.toolResult(preview: "x", truncated: true)]),
            message("m3", [.thinking("hmm"), .toolCall(name: "Read", preview: "f.swift")]),
            message("m4", [.text("done")]),
        ])
        XCTAssertEqual(items.map(\.id), ["m1#0", "m1#1", "m4#0"])
        guard case .message(let opening) = items[0], case .toolRun(let run) = items[1], case .message(let closing) = items[2] else {
            return XCTFail("unexpected shape \(items)")
        }
        XCTAssertEqual(opening.blocks, [.text("plan")])
        XCTAssertEqual(run.entries.map(\.id), ["m1#1", "m1#2", "m2#0", "m3#0", "m3#1"])
        XCTAssertEqual(run.callCount, 2)
        XCTAssertEqual(run.resultCount, 2)
        XCTAssertEqual(run.latestRecordID, "m3")
        XCTAssertEqual(run.summaryTitle, "2 tool calls")
        XCTAssertEqual(run.latestSummary, "latest: Read · f.swift")
        XCTAssertEqual(closing.blocks, [.text("done")])
    }

    func testShortenedToolRunsStayCoalescedButProseNoticesRemainVisible() {
        let items = AgentTranscriptGrouping.items([
            message("call", role: .tool, [.toolCall(name: "Read", preview: "file")]),
            message("result", role: .tool, [.shortenedPreviewNotice, .toolResult(preview: "part", truncated: true)]),
            message("user", role: .user, [.shortenedPreviewNotice, .text("retained user text")]),
        ])
        XCTAssertEqual(items.count, 2)
        guard case .toolRun(let run) = items[0], case .message(let prose) = items[1] else {
            return XCTFail("Expected one disclosed tool run and separate user preview")
        }
        XCTAssertEqual(run.callCount, 1); XCTAssertEqual(run.resultCount, 1)
        XCTAssertEqual(run.summaryTitle, "1 tool call · shortened preview")
        XCTAssertEqual(prose.blocks, [.shortenedPreviewNotice, .text("retained user text")])
        XCTAssertEqual(AgentTranscriptGrouping.toolRunDescriptors([
            message("result", role: .tool, [.shortenedPreviewNotice, .toolResult(preview: "part", truncated: true)])
        ]).first?.summaryTitle, "1 tool result · shortened preview")
    }

    func testThinkingWithoutToolActivityStaysInItsMessage() {
        let items = AgentTranscriptGrouping.items([
            message("m1", time: stamp, [.thinking("weighing options"), .text("answer")]),
        ])
        XCTAssertEqual(items.count, 1)
        guard case .message(let part) = items[0] else { return XCTFail("expected a message") }
        XCTAssertEqual(part.blocks, [.thinking("weighing options"), .text("answer")])
        XCTAssertEqual(part.displayTime, stamp)
    }

    func testTimestampFollowsTheLastVisiblePartOfASplitMessage() {
        let items = AgentTranscriptGrouping.items([
            message("m1", time: stamp, [.text("before"), .toolCall(name: "Bash", preview: "pwd"), .text("after")]),
        ])
        XCTAssertEqual(items.map(\.id), ["m1#0", "m1#1", "m1#2"])
        guard case .message(let before) = items[0], case .message(let after) = items[2] else { return XCTFail("expected parts") }
        XCTAssertNil(before.displayTime)
        XCTAssertEqual(after.displayTime, stamp)
    }

    func testEmptyMessageSurvivesAsAnEmptyPart() {
        let items = AgentTranscriptGrouping.items([message("m1", time: stamp, [])])
        guard case .message(let part) = items.first else { return XCTFail("expected a part") }
        XCTAssertEqual(part.blocks, [])
        XCTAssertEqual(part.displayTime, stamp)
    }

    func testToolOnlyAndSplitMessageTimestampsRemainAvailableExactlyOnce() {
        let items = AgentTranscriptGrouping.items([
            message("m1", time: stamp, [.text("plan"), .toolCall(name: "Bash", preview: "pwd")]),
            message("m2", role: .tool, time: stamp, [.toolResult(preview: "/", truncated: false)]),
        ])
        guard case .message(let part) = items[0], case .toolRun(let run) = items[1] else {
            return XCTFail("expected prose followed by a run")
        }
        XCTAssertNil(part.displayTime)
        XCTAssertEqual(run.entries.map(\.displayTime), [stamp, stamp])
    }

    func testSummaryStrings() {
        XCTAssertEqual(AgentTranscriptGrouping.summaryTitle(callCount: 1, resultCount: 1), "1 tool call")
        XCTAssertEqual(AgentTranscriptGrouping.summaryTitle(callCount: 10, resultCount: 9), "10 tool calls")
        XCTAssertEqual(AgentTranscriptGrouping.summaryTitle(callCount: 0, resultCount: 1), "1 tool result")
        XCTAssertEqual(AgentTranscriptGrouping.summaryTitle(callCount: 0, resultCount: 3), "3 tool results")
        XCTAssertEqual(AgentTranscriptGrouping.latestSummary(name: "Bash", preview: "  ls -la  \nsecond"), "latest: Bash · ls -la")
        XCTAssertEqual(AgentTranscriptGrouping.latestSummary(name: "Bash", preview: ""), "latest: Bash")
        XCTAssertEqual(AgentTranscriptGrouping.latestSummary(name: "Bash", preview: String(repeating: "x", count: 200)), "latest: Bash · " + String(repeating: "x", count: 160) + "…")
    }

    func testRunIdentitySurvivesLiveAppendAndOlderPrepend() {
        let first = message("m1", [.toolCall(name: "Bash", preview: "pwd")])
        let before = AgentTranscriptGrouping.toolRunDescriptors([first])
        let after = AgentTranscriptGrouping.toolRunDescriptors([
            message("older", role: .user, [.text("start")]), first,
            message("m2", [.toolResult(preview: "/", truncated: false), .toolCall(name: "Read", preview: "x")]),
        ])
        XCTAssertEqual(before.first?.id, after.first?.id)
        XCTAssertEqual(after.first?.entryIDs, ["m1#0", "m2#0", "m2#1"])
        XCTAssertEqual(after.first?.summaryTitle, "2 tool calls")
        XCTAssertEqual(after.first?.latestSummary, "latest: Read · x")
    }
}
