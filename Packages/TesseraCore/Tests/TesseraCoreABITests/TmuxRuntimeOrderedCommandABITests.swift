import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class OrderedCommandABITrace: @unchecked Sendable {
    struct Write: Equatable {
        let tag: Int64?
        let command: String
    }

    var events: [[String: Any]] = []
    var writes: [Write] = []
    var errors: [String] = []
    var callbackDepth = 0
    var maximumCallbackDepth = 0
    var onEvent: (([String: Any]) -> Void)?
}

private let receiveOrderedCommandABIEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let trace = Unmanaged<OrderedCommandABITrace>.fromOpaque(context).takeUnretainedValue()
    trace.callbackDepth += 1
    trace.maximumCallbackDepth = max(trace.maximumCallbackDepth, trace.callbackDepth)
    defer { trace.callbackDepth -= 1 }
    do {
        guard let event = try JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count))
            as? [String: Any] else {
            trace.errors.append("callback was not a JSON object")
            return
        }
        trace.events.append(event)
        for effect in event["renderEffects"] as? [[String: Any]] ?? [] {
            if effect["kind"] as? String == "sendCommand", let command = effect["command"] as? String {
                trace.writes.append(.init(tag: nil, command: command))
            }
        }
        for write in event["platformWireCommands"] as? [[String: Any]] ?? [] {
            guard let tag = (write["tag"] as? NSNumber)?.int64Value,
                  let command = write["command"] as? String else {
                trace.errors.append("platform write lacked its tag or command")
                continue
            }
            trace.writes.append(.init(tag: tag, command: command))
        }
        trace.onEvent?(event)
    } catch {
        trace.errors.append("callback JSON decode failed: \(error)")
    }
}

private final class OrderedCommandABIHarness {
    let trace = OrderedCommandABITrace()
    let handle: UnsafeMutableRawPointer
    private let context: UnsafeMutableRawPointer

    init() {
        context = Unmanaged.passRetained(trace).toOpaque()
        handle = tesseraTmuxRuntimeCreate(
            callback: receiveOrderedCommandABIEvent,
            context: context
        )
    }

    deinit {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<OrderedCommandABITrace>.fromOpaque(context).release()
    }

    func submit(_ fact: RenderFact) throws -> Int32 {
        let encoded = try SharedABI.encoder.encode(fact)
        return encoded.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    func queue(_ command: String) -> Int64 {
        Array(command.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    func legacySend(_ command: String) -> Int64 {
        Array(command.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeSendCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    func listJSON(_ text: String, queued: Bool = true) -> Int64 {
        Array(text.utf8).withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            return queued
                ? tesseraTmuxRuntimeQueueCommandList(handle: handle, json: bytes, count: raw.count)
                : tesseraTmuxRuntimeSendCommandList(handle: handle, json: bytes, count: raw.count)
        }
    }

    func list(_ commands: [String], queued: Bool = true) throws -> Int64 {
        let data = try SharedABI.encoder.encode(commands)
        return listJSON(String(decoding: data, as: UTF8.self), queued: queued)
    }

    func feed(_ text: String) -> Int32 {
        Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    var replies: [[String: Any]] {
        trace.events.flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }
            .filter { $0["kind"] as? String == "commandReply" }
    }

    func response(_ sequence: Int, lines: [String] = [], success: Bool = true) -> String {
        "%begin 1 \(sequence) 1\r\n"
            + lines.map { $0 + "\r\n" }.joined()
            + "%\(success ? "end" : "error") 1 \(sequence) 1\r\n"
    }
}

final class TmuxRuntimeOrderedCommandABITests: XCTestCase {
    func testCompoundCommandRepliesIncludeFlatPartsAndOneWireLine() throws {
        for queued in [false, true] {
            let harness = OrderedCommandABIHarness()
            let tag = try harness.list(["display -p a", "display -p b"], queued: queued)
            XCTAssertGreaterThan(tag, 0)
            XCTAssertEqual(harness.trace.writes, queued
                ? [.init(tag: tag, command: "display -p a ; display -p b")] : [])
            XCTAssertEqual(harness.feed(harness.response(1, lines: ["a"])), 0)
            XCTAssertTrue(harness.replies.isEmpty)
            XCTAssertEqual(harness.feed(harness.response(2, lines: ["b", "more"])), 0)
            let reply = try XCTUnwrap(harness.replies.last)
            XCTAssertEqual(harness.replies.count, 1)
            XCTAssertEqual((reply["tag"] as? NSNumber)?.int64Value, tag)
            XCTAssertEqual(reply["success"] as? Bool, true)
            XCTAssertEqual(reply["lines"] as? [String], ["a", "b", "more"])
            let parts = try XCTUnwrap(reply["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.map { $0["success"] as? Bool }, [true, true])
            XCTAssertEqual(parts.map { $0["lines"] as? [String] }, [["a"], ["b", "more"]])
            XCTAssertTrue(parts.allSatisfy { Set($0.keys) == ["success", "lines"] })
            XCTAssertTrue(harness.trace.errors.isEmpty)
        }
    }

    func testCompoundErrorAndParseErrorLeaveFollowingReplyAligned() throws {
        for parseError in [false, true] {
            let harness = OrderedCommandABIHarness()
            let listTag = try harness.list(["display -p a", "select-window -t @999999", "display -p c"])
            let singleTag = harness.queue("display -p later")
            if !parseError {
                XCTAssertEqual(harness.feed(harness.response(1, lines: ["a"])), 0)
                XCTAssertTrue(harness.replies.isEmpty)
            }
            let error = parseError ? "parse error: unknown command: bogus" : "can't find window: @999999"
            XCTAssertEqual(harness.feed(harness.response(2, lines: [error], success: false)
                + harness.response(3, lines: ["later"])), 0)
            XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [listTag, singleTag])
            let listReply = try XCTUnwrap(harness.replies.first)
            XCTAssertEqual(listReply["success"] as? Bool, false)
            let parts = try XCTUnwrap(listReply["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, parseError ? 1 : 2)
            XCTAssertEqual(parts.last?["success"] as? Bool, false)
            XCTAssertEqual(parts.last?["lines"] as? [String], [error])
            XCTAssertNil(harness.replies.last?["parts"])
            XCTAssertEqual(harness.replies.last?["lines"] as? [String], ["later"])
        }
    }

    func testSingleCommandAndSingleElementListOmitPartsAndKeepGoldenJSON() throws {
        let single = RenderEffect.commandReply(tag: 1, success: true, lines: ["a"])
        XCTAssertEqual(String(decoding: try SharedABI.encoder.encode(single), as: UTF8.self),
                       "{\"kind\":\"commandReply\",\"lines\":[\"a\"],\"success\":true,\"tag\":1}")
        let compound = RenderEffect.commandReply(tag: 2, success: false, lines: ["a", "bad"],
            parts: [.init(success: true, lines: ["a"]), .init(success: false, lines: ["bad"])])
        XCTAssertEqual(try JSONDecoder().decode(RenderEffect.self, from: SharedABI.encoder.encode(compound)), compound)
        XCTAssertEqual(try JSONDecoder().decode(RenderEffect.self, from: SharedABI.encoder.encode(single)), single)
        for queued in [false, true] {
            let harness = OrderedCommandABIHarness()
            let tag = try harness.list(["display -p a"], queued: queued)
            let laterTag = harness.queue("display -p later")
            XCTAssertEqual(harness.feed(harness.response(1, lines: ["a"]) + harness.response(2, lines: ["later"])), 0)
            XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [tag, laterTag])
            XCTAssertTrue(harness.replies.allSatisfy { $0["parts"] == nil })
        }
    }

    func testCompoundABIRejectsMalformedArraysWithoutReservingSlots() throws {
        for queued in [false, true] {
            let harness = OrderedCommandABIHarness()
            for malformed in ["", "null", "{}", "[1]", "[null]", "[\"one\",1]", "[", "[\"one\"] trailing"] {
                XCTAssertEqual(harness.listJSON(malformed, queued: queued), -1, malformed)
            }
            for commands in [[], [""], ["one", ""], ["one;two"], ["one\ntwo"], ["one\rtwo"], ["one\0two"]] {
                XCTAssertEqual(try harness.list(commands, queued: queued), -1, "\(commands)")
            }
            XCTAssertEqual(harness.listJSON(String(repeating: "x", count: SharedABI.maximumInputBytes + 1), queued: queued), -1)
            XCTAssertTrue(harness.trace.writes.isEmpty)
            let accepted = try harness.list(["display -p a", "display -p b"], queued: queued)
            XCTAssertEqual(accepted, 1, "rejected lists do not allocate tags")
            XCTAssertEqual(harness.feed(harness.response(1, lines: ["a"]) + harness.response(2, lines: ["b"])), 0)
            XCTAssertEqual(harness.replies.count, 1)
            XCTAssertEqual((harness.replies.first?["tag"] as? NSNumber)?.int64Value, accepted)
        }
        XCTAssertEqual(tesseraTmuxRuntimeSendCommandList(handle: nil, json: nil, count: 0), -1)
        XCTAssertEqual(tesseraTmuxRuntimeQueueCommandList(handle: nil, json: nil, count: 1), -1)
        let data = Array("[\"one\",\"two\"]".utf8)
        data.withUnsafeBytes { raw in
            XCTAssertEqual(tesseraTmuxRuntimeSendCommandList(handle: nil, json: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count), -2)
            XCTAssertEqual(tesseraTmuxRuntimeQueueCommandList(handle: nil, json: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count), -2)
        }
        let invalidUTF8: [UInt8] = [0xFF]
        let harness = OrderedCommandABIHarness()
        invalidUTF8.withUnsafeBytes { raw in
            XCTAssertEqual(tesseraTmuxRuntimeSendCommandList(handle: harness.handle, json: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count), -1)
            XCTAssertEqual(tesseraTmuxRuntimeQueueCommandList(handle: harness.handle, json: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count), -1)
        }
    }

    func testCompoundEmitFailureRollsBackTheWholeListSlot() throws {
        let harness = OrderedCommandABIHarness()
        let commands = [String(repeating: "\"", count: (SharedABI.maximumInputBytes - 64) / 2), "display -p b"]
        XCTAssertLessThan(try SharedABI.encoder.encode(commands).count, SharedABI.maximumInputBytes)
        XCTAssertEqual(try harness.list(commands), -1, "wire callback overhead exceeds the output ceiling")
        XCTAssertTrue(harness.trace.events.isEmpty)
        let tag = harness.queue("display -p kept")
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["kept"])), 0)
        XCTAssertEqual(harness.replies.count, 1)
        XCTAssertEqual((harness.replies.first?["tag"] as? NSNumber)?.int64Value, tag)
        XCTAssertEqual(harness.replies.first?["lines"] as? [String], ["kept"])
    }

    func testReentrantCompoundWriteAndUnwrittenCancellationStayOrdered() throws {
        let harness = OrderedCommandABIHarness()
        var listTag: Int64 = -1
        var cancelledTag: Int64 = -1
        harness.trace.onEvent = { _ in
            harness.trace.onEvent = nil
            listTag = (try? harness.list(["display -p a", "display -p b"])) ?? -1
            cancelledTag = (try? harness.list(["display -p cancelled", "display -p tail"])) ?? -1
            XCTAssertEqual(try? harness.submit(.unwrittenCommandsCancelled(tags: [UInt64(cancelledTag)])), 0)
        }
        let parentTag = harness.queue("display -p parent")
        XCTAssertGreaterThan(listTag, 0)
        XCTAssertGreaterThan(cancelledTag, listTag)
        XCTAssertEqual(harness.trace.maximumCallbackDepth, 1)
        XCTAssertEqual(harness.trace.writes, [
            .init(tag: parentTag, command: "display -p parent"),
            .init(tag: listTag, command: "display -p a ; display -p b")
        ])
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["parent"])
            + harness.response(2, lines: ["a"]) + harness.response(3, lines: ["b"])), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [parentTag, listTag])
    }

    func testReentrantClientSizeWritesBeforeQueuedPolicyAndKeepsReplyTags() throws {
        let harness = OrderedCommandABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        let parentCommand = "display-message -p 'before'"
        let policyCommand = "show-options -wv -t @7 window-size"
        var policyTag: Int64 = -1
        var reentrantStatus: Int32 = -1
        var parentCallReturned = false
        var callbackBeforeReturn = false
        var writesBeforeParentReturns: [OrderedCommandABITrace.Write] = []
        harness.trace.onEvent = { event in
            guard (event["platformWireCommands"] as? [[String: Any]])?.first?["command"] as? String
                == parentCommand else { return }
            harness.trace.onEvent = nil
            callbackBeforeReturn = !parentCallReturned
            reentrantStatus = (try? harness.submit(.clientSize(columns: 80, rows: 24))) ?? -1
            policyTag = harness.queue(policyCommand)
            writesBeforeParentReturns = harness.trace.writes
        }

        let parentTag = harness.queue(parentCommand)
        parentCallReturned = true
        XCTAssertTrue(callbackBeforeReturn, "the opt-in ABI may synchronously deliver before returning its tag")
        XCTAssertEqual(reentrantStatus, 0)
        XCTAssertGreaterThan(parentTag, 0)
        XCTAssertGreaterThan(policyTag, parentTag)
        XCTAssertEqual(writesBeforeParentReturns, [.init(tag: parentTag, command: parentCommand)],
                       "reentrant callbacks must queue writes rather than recursively deliver them")
        XCTAssertEqual(harness.trace.writes, [
            .init(tag: parentTag, command: parentCommand),
            .init(tag: nil, command: "refresh-client -C 80,24"),
            .init(tag: nil, command: "select-window"),
            .init(tag: policyTag, command: policyCommand),
        ])
        XCTAssertEqual(harness.trace.maximumCallbackDepth, 1)

        let platformEvents = harness.trace.events.filter { $0["platformWireCommands"] != nil }
        XCTAssertEqual(platformEvents.count, 2)
        for event in platformEvents {
            XCTAssertEqual((event["version"] as? NSNumber)?.intValue, 3)
            XCTAssertNil(event["snapshot"], "a wire-only event publishes no state")
            XCTAssertTrue((event["renderEffects"] as? [[String: Any]] ?? []).isEmpty)
            XCTAssertTrue((event["bells"] as? [[String: Any]] ?? []).isEmpty)
            XCTAssertTrue((event["agentStates"] as? [[String: Any]] ?? []).isEmpty)
            XCTAssertTrue((event["topologyQueries"] as? [String] ?? []).isEmpty)
            XCTAssertEqual(event["authorityStamps"] as? [String], [])
            XCTAssertEqual(event["peerDepartureObserved"] as? Bool, false)
        }

        // Feed replies in the order the callback actually transported writes.
        // The two ledger replies must not swallow the platform policy body.
        for (index, write) in harness.trace.writes.enumerated() {
            let lines = write.command == parentCommand ? ["before"]
                : write.command == policyCommand ? ["latest"] : []
            XCTAssertEqual(harness.feed(harness.response(index + 1, lines: lines)), 0)
        }
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value },
                       [parentTag, policyTag])
        XCTAssertEqual(harness.replies.map { $0["lines"] as? [String] }, [["before"], ["latest"]])
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }

    func testCancellingQueuedUnwrittenSuffixSuppressesItsWireCallback() throws {
        let harness = OrderedCommandABIHarness()
        var cancelledTag: Int64 = -1
        var cancellationStatus: Int32 = -1
        harness.trace.onEvent = { _ in
            harness.trace.onEvent = nil
            cancelledTag = harness.queue("display-message -p 'cancelled'")
            if cancelledTag > 0 {
                cancellationStatus = (try? harness.submit(
                    .unwrittenCommandsCancelled(tags: [UInt64(cancelledTag)])
                )) ?? -1
            }
        }
        XCTAssertEqual(try harness.submit(.userInput), 0)
        XCTAssertGreaterThan(cancelledTag, 0)
        XCTAssertEqual(cancellationStatus, 0)
        XCTAssertTrue(harness.trace.writes.isEmpty)

        let keptTag = harness.queue("display-message -p 'kept'")
        XCTAssertGreaterThan(keptTag, 0)
        XCTAssertEqual(harness.trace.writes, [.init(tag: keptTag, command: "display-message -p 'kept'")])
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["kept"])), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [keptTag])
        XCTAssertEqual(harness.replies.first?["lines"] as? [String], ["kept"])
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }

    func testTransportLossSuppressesQueuedPlatformWriteAndResetsReplyFIFO() throws {
        let harness = OrderedCommandABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        var oldTag: Int64 = -1
        var lossStatus: Int32 = -1
        harness.trace.onEvent = { _ in
            harness.trace.onEvent = nil
            oldTag = harness.queue("display-message -p 'old-transport'")
            lossStatus = (try? harness.submit(.transportLost)) ?? -1
        }
        XCTAssertEqual(try harness.submit(.userInput), 0)
        XCTAssertGreaterThan(oldTag, 0)
        XCTAssertEqual(lossStatus, 0)
        XCTAssertTrue(harness.trace.writes.isEmpty)

        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        let newTag = harness.queue("display-message -p 'new-transport'")
        XCTAssertGreaterThan(newTag, 0)
        XCTAssertEqual(harness.trace.writes,
                       [.init(tag: newTag, command: "display-message -p 'new-transport'")])
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["new-transport"])), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [newTag])
        XCTAssertEqual(harness.replies.first?["lines"] as? [String], ["new-transport"])
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }

    func testLegacySendRemainsCallerWrittenAndSharesReplyFIFOWithOptIn() throws {
        let harness = OrderedCommandABIHarness()
        let legacyTag = harness.legacySend("display-message -p 'legacy'")
        XCTAssertGreaterThan(legacyTag, 0)
        XCTAssertTrue(harness.trace.events.isEmpty, "legacy registration must not introduce callback writes")
        let orderedTag = harness.queue("display-message -p 'ordered'")
        XCTAssertGreaterThan(orderedTag, legacyTag)
        XCTAssertEqual(harness.trace.writes,
                       [.init(tag: orderedTag, command: "display-message -p 'ordered'")])
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["legacy"])
            + harness.response(2, lines: ["ordered"])), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value },
                       [legacyTag, orderedTag])
        XCTAssertEqual(harness.replies.map { $0["lines"] as? [String] }, [["legacy"], ["ordered"]])
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }

    func testInvalidAndOversizedCallbackCommandsLeaveNoReplySlot() throws {
        let harness = OrderedCommandABIHarness()
        XCTAssertEqual(tesseraTmuxRuntimeQueueCommand(handle: harness.handle, text: nil, count: 0), -1)
        XCTAssertEqual(tesseraTmuxRuntimeQueueCommand(handle: harness.handle, text: nil, count: 1), -1)
        XCTAssertEqual(harness.queue(""), -1)
        XCTAssertEqual(harness.queue("bad\0command"), -1)
        let invalidUTF8: [UInt8] = [0xFF]
        XCTAssertEqual(invalidUTF8.withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(handle: harness.handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }, -1)
        XCTAssertEqual(harness.queue(String(repeating: "x", count: SharedABI.maximumInputBytes + 1)), -1)
        // Accepted input bytes can still exceed the callback ceiling after
        // JSON escaping. Rejection must roll back the reserved FIFO suffix.
        XCTAssertEqual(harness.queue(String(repeating: "\"", count: SharedABI.maximumInputBytes / 2)), -1)
        XCTAssertTrue(harness.trace.events.isEmpty)
        XCTAssertTrue(harness.trace.writes.isEmpty)

        let keptTag = harness.queue("display-message -p 'after-rejection'")
        XCTAssertGreaterThan(keptTag, 0)
        XCTAssertEqual(harness.feed(harness.response(1, lines: ["after-rejection"])), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, [keptTag])
        XCTAssertEqual(harness.replies.first?["lines"] as? [String], ["after-rejection"])
        let command = Array("display-message -p x".utf8)
        XCTAssertEqual(command.withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(handle: nil,
                text: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }, -2)
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }

    func testCallbackBackpressureRejectsCommandsWithoutLeavingReplySlots() throws {
        let harness = OrderedCommandABIHarness()
        var results: [Int64] = []
        harness.trace.onEvent = { _ in
            harness.trace.onEvent = nil
            for index in 0..<5_000 {
                results.append(harness.queue("display-message -p 'burst-\(index)'"))
            }
        }
        XCTAssertEqual(try harness.submit(.userInput), 0)
        let acceptedTags = results.filter { $0 > 0 }
        XCTAssertFalse(acceptedTags.isEmpty)
        XCTAssertTrue(results.contains(-1), "the callback queue must reject an unbounded reentrant burst")
        XCTAssertEqual(harness.trace.writes.compactMap(\.tag), acceptedTags)
        XCTAssertEqual(harness.trace.maximumCallbackDepth, 1)

        let recoveredTag = harness.queue("display-message -p 'after-burst'")
        XCTAssertGreaterThan(recoveredTag, 0)
        let allTags = acceptedTags + [recoveredTag]
        let frames = allTags.enumerated().map { index, tag in
            harness.response(index + 1, lines: ["reply-\(tag)"])
        }.joined()
        XCTAssertLessThan(frames.utf8.count, SharedABI.maximumInputBytes)
        XCTAssertEqual(harness.feed(frames), 0)
        XCTAssertEqual(harness.replies.compactMap { ($0["tag"] as? NSNumber)?.int64Value }, allTags)
        XCTAssertEqual(harness.replies.map { $0["lines"] as? [String] },
                       allTags.map { ["reply-\($0)"] })
        XCTAssertTrue(harness.trace.errors.isEmpty)
    }
}
