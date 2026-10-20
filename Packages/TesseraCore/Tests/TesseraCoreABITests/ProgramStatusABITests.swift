import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class ProgramStatusCapture {
    var events: [Data] = []
    var onEvent: (() -> Void)?
}

private let receiveProgramStatusEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let capture = Unmanaged<ProgramStatusCapture>.fromOpaque(context).takeUnretainedValue()
    capture.events.append(Data(bytes: bytes, count: count))
    capture.onEvent?()
}

final class ProgramStatusABITests: XCTestCase {
    private var capture: ProgramStatusCapture!
    private var context: UnsafeMutableRawPointer!
    private var handle: UnsafeMutableRawPointer!

    override func setUp() {
        super.setUp()
        capture = ProgramStatusCapture()
        context = Unmanaged.passRetained(capture).toOpaque()
        handle = tesseraTmuxRuntimeCreate(callback: receiveProgramStatusEvent, context: context)
        XCTAssertEqual(feed("\u{1B}P1000p%begin 1 1 0\r\n%end 1 1 0\r\n%session-changed $1 work\r\n"), 0)
    }

    override func tearDown() {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<ProgramStatusCapture>.fromOpaque(context).release()
        super.tearDown()
    }

    private func feed(_ text: String) -> Int32 {
        Array(text.utf8).withUnsafeBufferPointer {
            tesseraTmuxRuntimeFeed(handle: handle, bytes: $0.baseAddress, count: $0.count)
        }
    }

    private func report(_ payload: String, pane: Int) -> Int32 {
        feed("%output %\(pane) \\033]7501;\(payload)\\007\r\n")
    }

    private func copy(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32) throws -> [String: Any] {
        let size = call(nil, 0)
        XCTAssertGreaterThan(size, 0)
        var bytes = [UInt8](repeating: 0xA5, count: Int(size))
        let short = bytes.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count - 1) }
        XCTAssertEqual(short, -1)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0xA5 }, "short copy must write nothing")
        let zero = bytes.withUnsafeMutableBufferPointer { call($0.baseAddress, 0) }
        XCTAssertEqual(zero, -1)
        let result = bytes.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        XCTAssertEqual(result, size)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        func hasNull(_ value: Any) -> Bool {
            if value is NSNull { return true }
            if let dict = value as? [String: Any] { return dict.values.contains(where: hasNull) }
            if let list = value as? [Any] { return list.contains(where: hasNull) }
            return false
        }
        XCTAssertFalse(hasNull(object))
        return object
    }

    private func snapshot() throws -> [String: Any] {
        try copy { tesseraTmuxRuntimeCopyProgramStatus(handle: handle, outputBytes: $0, outputCapacity: $1) }
    }

    private func terminals(_ document: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(document["terminals"] as? [[String: Any]])
    }

    private func entries(_ terminal: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(terminal["entries"] as? [[String: Any]])
    }

    private func event() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capture.events.last)) as? [String: Any])
    }

    func testRuntimeDefaultsDisabledAndCarriesRevision() throws {
        XCTAssertEqual(report("state=blocked", pane: 31), 0)
        XCTAssertTrue(try terminals(snapshot()).isEmpty)
        XCTAssertEqual(try event()["programStatusRevision"] as? UInt64, 0)
        XCTAssertEqual(try event()["version"] as? Int, 3)
    }

    func testRuntimeReportsQueriesAndAcknowledgements() throws {
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 1), 0)
        XCTAssertEqual(report("state=blocked:kind=permission", pane: 31), 0)
        let blockedRevision = try XCTUnwrap(event()["programStatusRevision"] as? UInt64)
        XCTAssertGreaterThan(blockedRevision, 0)
        var panes = try terminals(snapshot())
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0]["paneID"] as? Int, 31)
        XCTAssertEqual(panes[0]["primary"] as? Int, 0)
        let blocked = try entries(panes[0])[0]
        XCTAssertEqual(blocked["attention"] as? String, "needsInput")
        XCTAssertEqual(blocked["kind"] as? String, "permission")
        XCTAssertNil(blocked["app"])
        XCTAssertNil(blocked["resultToken"])
        XCTAssertEqual(tesseraTmuxRuntimeAcknowledgeProgramStatus(handle: handle, paneID: 31, through: .max), 0)
        XCTAssertEqual(tesseraTmuxRuntimeAcknowledgeProgramStatus(handle: handle, paneID: -1, through: .max), -1)

        XCTAssertEqual(report("?", pane: 31), 0)
        XCTAssertEqual(try event()["programStatusRevision"] as? UInt64, blockedRevision)
        let effects = try XCTUnwrap(event()["renderEffects"] as? [[String: Any]])
        XCTAssertFalse(effects.contains { $0["kind"] as? String == "sendCommand" })
        XCTAssertEqual(try event()["topologyQueries"] as? [String], [])
        XCTAssertNil(try event()["platformWireCommands"])

        XCTAssertEqual(report("state=done:app=cargo", pane: 10), 0)
        panes = try terminals(snapshot())
        XCTAssertEqual(panes.compactMap { $0["paneID"] as? Int }, [10, 31])
        let token = try XCTUnwrap(panes[0]["latestUnreadResultToken"] as? UInt64)
        let done = try entries(panes[0])[0]
        XCTAssertEqual(done["attention"] as? String, "finished")
        XCTAssertEqual(done["app"] as? String, "cargo")
        XCTAssertEqual(done["resultToken"] as? UInt64, token)
        let before = try XCTUnwrap(snapshot()["revision"] as? UInt64)
        XCTAssertEqual(tesseraTmuxRuntimeAcknowledgeProgramStatus(handle: handle, paneID: 10, through: token), 1)
        let acknowledged = try snapshot()
        XCTAssertEqual(acknowledged["revision"] as? UInt64, before + 1)
        panes = try terminals(acknowledged)
        XCTAssertNil(panes[0]["latestUnreadResultToken"])
        XCTAssertNil(try entries(panes[0])[0]["attention"])
        XCTAssertEqual(tesseraTmuxRuntimeAcknowledgeProgramStatus(handle: handle, paneID: 10, through: token), 0)
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 0), 0)
        XCTAssertTrue(try terminals(snapshot()).isEmpty)
    }

    func testRuntimeTransportLostAndCopyFromCallback() throws {
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 1), 0)
        var callbackDocument: [String: Any]?
        capture.onEvent = { [self] in callbackDocument = try? snapshot() }
        XCTAssertEqual(report("state=blocked:kind=auth", pane: 31), 0)
        XCTAssertEqual(report("state=error", pane: 10), 0)
        XCTAssertEqual(try entries(terminals(snapshot())[0])[0]["attention"] as? String, "failed")
        let data = try SharedABI.encoder.encode(RenderFact.transportLost)
        XCTAssertEqual(data.withUnsafeBytes {
            tesseraTmuxRuntimeSubmitFact(handle: handle, json: $0.bindMemory(to: UInt8.self).baseAddress, count: $0.count)
        }, 0)
        let doc = try XCTUnwrap(callbackDocument)
        XCTAssertEqual(try event()["programStatusRevision"] as? UInt64, doc["revision"] as? UInt64)
        let all = try terminals(doc).flatMap { try entries($0) }
        XCTAssertEqual(all.count, 2)
        for entry in all {
            XCTAssertEqual(entry["historical"] as? Bool, true)
            XCTAssertNil(entry["attention"])
        }
        capture.onEvent = nil
    }

    func testWireAndSplitEnvelopesCarryTheSameProgramStatusRevision() throws {
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 1), 0)
        XCTAssertEqual(report("state=blocked:kind=permission", pane: 31), 0)
        let revision = try XCTUnwrap(snapshot()["revision"] as? UInt64)
        let command = Array("display-message -p x".utf8)
        XCTAssertGreaterThan(command.withUnsafeBufferPointer {
            tesseraTmuxRuntimeQueueCommand(handle: handle, text: $0.baseAddress, count: $0.count)
        }, 0)
        XCTAssertEqual(try event()["programStatusRevision"] as? UInt64, revision)
        XCTAssertNotNil(try event()["platformWireCommands"])
        capture.events.removeAll()
        for _ in 0..<1_500 {
            XCTAssertGreaterThan(command.withUnsafeBufferPointer {
                tesseraTmuxRuntimeSendCommand(handle: handle, text: $0.baseAddress, count: $0.count)
            }, 0)
        }
        // JSON expands these bytes sixfold, splitting a read below the input ceiling.
        let filler = String(repeating: "\u{01}", count: 500)
        let replies = (2...1_501).map { "%begin 1 \($0) 1\r\n\(filler)\r\n%end 1 \($0) 1\r\n" }.joined()
        XCTAssertEqual(feed(replies), 0)
        XCTAssertGreaterThan(capture.events.count, 1)
        for data in capture.events {
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(envelope["programStatusRevision"] as? UInt64, revision)
        }
    }

    func testRuntimeStaleHandle() {
        let stale = tesseraTmuxRuntimeCreate(callback: receiveProgramStatusEvent, context: context)
        tesseraTmuxRuntimeDestroy(handle: stale)
        for handle in [stale, nil] {
            XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 1), -2)
            XCTAssertEqual(tesseraTmuxRuntimeCopyProgramStatus(handle: handle, outputBytes: nil, outputCapacity: 0), -2)
            XCTAssertEqual(tesseraTmuxRuntimeAcknowledgeProgramStatus(handle: handle, paneID: -1, through: 0), -2)
        }
    }

    func testRawMonitorReportsRepliesAndLifecycle() throws {
        let raw = tesseraProgramStatusMonitorCreate()
        defer { tesseraProgramStatusMonitorDestroy(handle: raw) }
        var revision: UInt64 = 999
        func scan(_ text: String, capacity: Int = 4096) -> [UInt8] {
            var output = [UInt8](repeating: 0xA5, count: max(1, capacity))
            let written = Array(text.utf8).withUnsafeBufferPointer { bytes in
                output.withUnsafeMutableBufferPointer {
                    tesseraProgramStatusMonitorFeed(handle: raw, bytes: bytes.baseAddress, count: bytes.count,
                        reply: $0.baseAddress, replyCapacity: capacity, revisionOut: &revision)
                }
            }
            XCTAssertGreaterThanOrEqual(written, 0)
            XCTAssertTrue(output.dropFirst(Int(max(0, written))).allSatisfy { $0 == 0xA5 })
            return Array(output.prefix(Int(max(0, written))))
        }
        func doc() throws -> [String: Any] {
            try copy { tesseraProgramStatusMonitorCopySnapshot(handle: raw, outputBytes: $0, outputCapacity: $1) }
        }
        let query = "\u{1B}]7501;?\u{1B}\\\u{1B}[c"
        XCTAssertEqual(scan(query + "\u{1B}]7501;state=done\u{07}"), [])
        XCTAssertEqual(revision, 0)
        XCTAssertTrue(try terminals(doc()).isEmpty)
        XCTAssertEqual(tesseraProgramStatusMonitorSetEnabled(handle: raw, enabled: 1), 0)
        XCTAssertEqual(scan(query), ProgramStatusReply.query)
        XCTAssertEqual(scan(String(repeating: query, count: 500), capacity: 5000),
            Array(repeating: ProgramStatusReply.query, count: 500).flatMap { $0 })
        XCTAssertEqual(revision, 0)
        XCTAssertEqual(scan(query, capacity: 5), [])
        XCTAssertEqual(scan(query + query, capacity: ProgramStatusReply.query.count + 5), ProgramStatusReply.query)
        XCTAssertEqual(scan("\u{1B}]7501;state=working:app=cargo:title=YnVpbGQ=:msg=b2s=:progress=42\u{07}"), [])
        XCTAssertGreaterThan(revision, 0)
        var terminal = try XCTUnwrap(terminals(doc()).first)
        XCTAssertNil(terminal["paneID"])
        XCTAssertEqual(terminal["primary"] as? Int, 0)
        var entry = try entries(terminal)[0]
        XCTAssertEqual(entry["idPath"] as? [String], [])
        XCTAssertEqual(entry["title"] as? String, "build")
        XCTAssertEqual(entry["message"] as? String, "ok")
        XCTAssertEqual(entry["progress"] as? Int, 42)
        XCTAssertNil(entry["attention"])
        XCTAssertEqual(scan("\u{1B}]7501;state=done:app=cargo\u{07}"), [])
        terminal = try terminals(doc())[0]
        XCTAssertEqual(try entries(terminal)[0]["attention"] as? String, "finished")
        let token = try XCTUnwrap(terminal["latestUnreadResultToken"] as? UInt64)
        XCTAssertEqual(tesseraProgramStatusMonitorAcknowledge(handle: raw, through: token), 1)
        XCTAssertEqual(tesseraProgramStatusMonitorAcknowledge(handle: raw, through: token), 0)
        XCTAssertNil(try entries(terminals(doc())[0])[0]["attention"])
        XCTAssertEqual(scan("\u{1B}]7501;state=blocked:kind=question\u{07}"), [])
        XCTAssertEqual(tesseraProgramStatusMonitorAcknowledge(handle: raw, through: .max), 0)
        XCTAssertEqual(tesseraProgramStatusMonitorNoteTransportLost(handle: raw), 0)
        terminal = try terminals(doc())[0]
        entry = try entries(terminal)[0]
        XCTAssertEqual(entry["historical"] as? Bool, true)
        XCTAssertNil(entry["attention"])
        XCTAssertEqual(tesseraProgramStatusMonitorSetEnabled(handle: raw, enabled: 0), 0)
        XCTAssertTrue(try terminals(doc()).isEmpty)
    }

    func testRawInvalidInputsAndStaleHandle() {
        let raw = tesseraProgramStatusMonitorCreate()
        var byte: UInt8 = 0
        var revision: UInt64 = 999
        XCTAssertEqual(tesseraProgramStatusMonitorFeed(handle: raw, bytes: nil, count: 1,
            reply: nil, replyCapacity: 0, revisionOut: &revision), -1)
        XCTAssertEqual(tesseraProgramStatusMonitorFeed(handle: raw, bytes: &byte, count: SharedABI.maximumInputBytes + 1,
            reply: nil, replyCapacity: 0, revisionOut: &revision), -1)
        XCTAssertEqual(tesseraProgramStatusMonitorFeed(handle: raw, bytes: nil, count: 0,
            reply: nil, replyCapacity: 1, revisionOut: &revision), -1)
        XCTAssertEqual(revision, 999)
        XCTAssertEqual(tesseraProgramStatusMonitorFeed(handle: raw, bytes: nil, count: 0,
            reply: nil, replyCapacity: 0, revisionOut: &revision), 0)
        XCTAssertEqual(revision, 0)
        tesseraProgramStatusMonitorDestroy(handle: raw)
        tesseraProgramStatusMonitorDestroy(handle: raw)
        for handle in [raw, nil] {
            XCTAssertEqual(tesseraProgramStatusMonitorSetEnabled(handle: handle, enabled: 1), -2)
            XCTAssertEqual(tesseraProgramStatusMonitorFeed(handle: handle, bytes: nil, count: 1,
                reply: nil, replyCapacity: 1, revisionOut: nil), -2)
            XCTAssertEqual(tesseraProgramStatusMonitorCopySnapshot(handle: handle, outputBytes: nil, outputCapacity: 0), -2)
            XCTAssertEqual(tesseraProgramStatusMonitorAcknowledge(handle: handle, through: 0), -2)
            XCTAssertEqual(tesseraProgramStatusMonitorNoteTransportLost(handle: handle), -2)
        }
    }
}
