import Foundation
import XCTest
@testable import TesseraCoreABI
@testable import TesseraAgentCore

/// Android reaches the attention pipeline only through this ABI, so its exact
/// command sequences are exercised here.
final class AgentAttentionABITests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread() -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "provider-session")!
    }

    private func binding(generation: UInt64) -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: generation,
            incarnation: AgentIncarnationToken("incarnation-\(generation)")!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send, .tmux])
    }

    private func token(_ runtime: AgentABIRuntime, _ id: AgentThreadID, _ binding: AgentTerminalBinding) -> UUID {
        runtime.registerPlatformBinding(threadID: id, hostID: hostID, binding: binding,
            sourceIdentity: "android:\(binding.carrierGeneration):%2", processIDs: [42])!
    }

    private func retainedStop(_ id: AgentThreadID) -> AgentLifecycleEnvelope {
        // Android stamps each delivered frame with a new arrival sequence;
        // the retained hook payload keeps its own source time.
        AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .stop, status: .finished,
            providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl",
            eventSequence: UInt64.random(in: 1...1_000_000), sourceTimestampNanoseconds: 1_788_703_213_997_213_000)!
    }

    /// `teardownEndpointOwners` unbinds; the reconnected endpoint replays the
    /// pane's retained Stop through a fresh bind.
    func testUnbindThenReplayedStopRelistsTheThreadAndCompletionReadNeedsNoRecord() async throws {
        let capture = AttentionEventCapture()
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let first = token(runtime, id, binding(generation: 1))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: first).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: first, lifecycle: retainedStop(id)).encoded())
        try await capture.wait(until: { $0.contains { $0.kind == .lifecycleAccepted } })
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id).encoded())
        try await capture.wait(until: { $0.last?.kind == .listSnapshot && $0.last?.list?.threads.isEmpty == true })
        let second = token(runtime, id, binding(generation: 2))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: second).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: second, lifecycle: retainedStop(id)).encoded())
        try await capture.wait(until: { $0.filter { $0.kind == .lifecycleAccepted }.count == 2 })

        let relisted = try XCTUnwrap(capture.events.last { $0.kind == .listSnapshot }?.list)
        XCTAssertEqual(relisted.threads.map(\.id), [id], "the reconnected agent is listed again")
        XCTAssertEqual(relisted.threads.first?.attention, .unreadCompletion)
        let finished = try XCTUnwrap(capture.events.last { $0.kind == .lifecycleAccepted }?.thread)
        XCTAssertTrue(finished.messages.isEmpty)
        let epoch = try XCTUnwrap(finished.attentionEpoch)
        XCTAssertEqual(epoch, 1, "a replayed finish is not a new alert")
        XCTAssertNotNil(finished.unreadCompletionKey)

        let before = capture.events.count
        runtime.submit(try AgentABICommand(kind: .acknowledgeCompletion, threadID: id, attentionEpoch: epoch + 1).encoded())
        runtime.submit(try AgentABICommand(kind: .acknowledgeCompletion, threadID: id, attentionEpoch: epoch).encoded())
        try await capture.wait(until: { $0.count >= before + 2 })
        let read = try XCTUnwrap(capture.events[before...].first { $0.kind == .threadSnapshot }?.thread)
        XCTAssertEqual(read.summary.attention, AgentAttention.none)
        XCTAssertEqual(read.summary.status, .idle)
        XCTAssertNil(read.unreadCompletionKey)
        XCTAssertEqual(read.acknowledgedCompletionKey, finished.unreadCompletionKey)
        XCTAssertEqual(capture.events[before...].map(\.kind), [.threadSnapshot, .listSnapshot],
                       "a stale epoch emits nothing; the read emits one snapshot and the list")
        runtime.destroy()
    }

    /// The stored read state Android forwards in `configure` keeps a
    /// relaunched runtime from resurrecting the retained Stop.
    func testConfiguredAcknowledgementKeepsAReplayedStopRead() async throws {
        let capture = AttentionEventCapture()
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let key = AgentCenterRuntime.completionKey(retainedStop(id))
        let metadata = AgentThreadMetadata(threadID: id, lastReadRecordID: nil, acknowledgedCompletionKey: key)
        runtime.submit(try AgentABICommand(kind: .configure, metadata: [metadata]).encoded())
        let bound = token(runtime, id, binding(generation: 1))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: bound).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: bound, lifecycle: retainedStop(id)).encoded())
        try await capture.wait(until: { $0.contains { $0.kind == .lifecycleAccepted } })
        let replayed = try XCTUnwrap(capture.events.last { $0.kind == .lifecycleAccepted }?.thread)
        XCTAssertEqual(replayed.summary.attention, AgentAttention.none)
        XCTAssertEqual(replayed.summary.status, .idle)
        runtime.destroy()
    }

    func testAcknowledgeCompletionCommandShape() throws {
        let id = thread()
        let valid = AgentABICommand(kind: .acknowledgeCompletion, threadID: id, attentionEpoch: 3)
        XCTAssertEqual(try AgentABICommand.decode(valid.encoded()).attentionEpoch, 3)
        let lifecycle = AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: UUID(), lifecycle: retainedStop(id))
        XCTAssertEqual(try AgentABICommand.decode(lifecycle.encoded()).lifecycle?.sourceTimestampNanoseconds,
                       1_788_703_213_997_213_000, "a Swift round trip keeps the retained-hook identity")
        for invalid in [
            AgentABICommand(kind: .acknowledgeCompletion, threadID: id),
            AgentABICommand(kind: .acknowledgeCompletion, attentionEpoch: 3),
            AgentABICommand(kind: .acknowledgeCompletion, threadID: id, recordID: "r", attentionEpoch: 3),
            AgentABICommand(kind: .acknowledge, threadID: id, recordID: "r", attentionEpoch: 3),
        ] {
            XCTAssertThrowsError(try invalid.encoded(), "\(invalid.kind)")
        }
        // Android spells the command as raw JSON.
        let raw = #"{"v":1,"kind":"acknowledgeCompletion","threadID":{"hostID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","providerID":{"rawValue":"codex"},"providerSessionID":"provider-session"},"attentionEpoch":2}"#
        XCTAssertEqual(try AgentABICommand.decode(Data(raw.utf8)).attentionEpoch, 2)
    }
}

private final class AttentionEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentABIEvent] = []

    var events: [AgentABIEvent] { lock.withLock { storage } }

    func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(AgentABIEvent.self, from: data) else { return }
        lock.withLock { storage.append(event) }
    }

    func wait(until predicate: ([AgentABIEvent]) -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(events) {
            guard Date() < deadline else {
                XCTFail("timed out; events: \(events.map(\.kind)) codes: \(events.compactMap(\.code))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
