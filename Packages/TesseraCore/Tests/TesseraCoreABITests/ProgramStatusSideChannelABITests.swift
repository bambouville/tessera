import Foundation
import XCTest
@testable import TesseraCoreABI
import TmuxControlCore

private final class SideChannelStatusEvents {
    var values: [[String: Any]] = []
}

private let receiveSideChannelStatus: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context,
          let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count)) as? [String: Any]
    else { return }
    Unmanaged<SideChannelStatusEvents>.fromOpaque(context).takeUnretainedValue().values.append(event)
}

final class ProgramStatusSideChannelABITests: XCTestCase {
    func testSideChannelToggleReportsPauseAndReconnectWithoutOrdinaryOutputCallbacks() throws {
        let events = SideChannelStatusEvents()
        let context = Unmanaged.passRetained(events).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(callback: receiveSideChannelStatus, context: context)
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<SideChannelStatusEvents>.fromOpaque(context).release()
        }
        func fact(_ fact: RenderFact) throws {
            let bytes = try SharedABI.encoder.encode(fact)
            XCTAssertEqual(bytes.withUnsafeBytes {
                tesseraTmuxRuntimeSubmitFact(handle: handle, json: $0.bindMemory(to: UInt8.self).baseAddress, count: $0.count)
            }, 0)
        }
        func feed(_ text: String) {
            XCTAssertEqual(Array(text.utf8).withUnsafeBufferPointer {
                tesseraTmuxRuntimeFeed(handle: handle, bytes: $0.baseAddress, count: $0.count)
            }, 0)
        }
        func commands() -> [String] {
            events.values.flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }.compactMap {
                $0["kind"] as? String == "sendCommand" ? $0["command"] as? String : nil
            }
        }
        func snapshot() throws -> [String: Any] {
            let size = tesseraTmuxRuntimeCopyProgramStatus(handle: handle, outputBytes: nil, outputCapacity: 0)
            var bytes = [UInt8](repeating: 0, count: Int(size))
            XCTAssertEqual(bytes.withUnsafeMutableBufferPointer {
                tesseraTmuxRuntimeCopyProgramStatus(handle: handle, outputBytes: $0.baseAddress, outputCapacity: $0.count)
            }, size)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        }
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 1), 0)
        try fact(.transportAttached(.sideChannel))
        XCTAssertEqual(commands(), ["refresh-client -f '!no-output'"])
        feed("\u{1B}P1000p%begin 1 1 0\r\n%end 1 1 0\r\n")
        feed("%begin 1 2 1\r\n%end 1 2 1\r\n")
        feed("%session-changed $1 work\r\n%window-add @1\r\n%window-add @2\r\n"
                + "%window-pane-changed @1 %10\r\n%window-pane-changed @2 %31\r\n"
                + "%session-window-changed $1 @1\r\n")
        events.values.removeAll()
        feed("%output %31 audible\\007\r\n")
        XCTAssertTrue(events.values.isEmpty)
        feed("%output %31 ord")
        XCTAssertTrue(events.values.isEmpty)
        feed("inary output\r\n")
        feed("%extended-output %31 0 : more ordinary output\r\n")
        XCTAssertTrue(events.values.isEmpty)
        feed("%output %31 \\033]7501;state=blocked:\r\n")
        XCTAssertTrue(events.values.isEmpty)
        feed("%output %31 kind=permission\\007\r\n")
        XCTAssertEqual(events.values.count, 1)
        XCTAssertEqual((events.values.last?["bells"] as? [[String: Any]])?.count, 0)
        let revision = try XCTUnwrap(events.values.last?["programStatusRevision"] as? UInt64)
        XCTAssertGreaterThan(revision, 0)
        XCTAssertEqual((try snapshot()["terminals"] as? [[String: Any]])?.first?["paneID"] as? Int, 31)
        events.values.removeAll()
        feed("%subscription-changed tessera-bell $1 @2 1 %31 : 0\r\n")
        feed("%subscription-changed tessera-bell $1 @2 1 %31 : 1\r\n%output %31 audible\\007\r\n")
        XCTAssertEqual((events.values.last?["bells"] as? [[String: Any]])?.count, 1)
        let bell = try XCTUnwrap((events.values.last?["bells"] as? [[String: Any]])?.first)
        XCTAssertEqual((bell["windowID"] as? [String: Any])?["rawValue"] as? Int, 2)
        events.values.removeAll()
        feed("%pause %31\r\n")
        XCTAssertEqual(commands(), [RenderCommands.continuePane(PaneId(31))])
        let pane = try XCTUnwrap((snapshot()["terminals"] as? [[String: Any]])?.first)
        XCTAssertEqual((pane["entries"] as? [[String: Any]])?.first?["historical"] as? Bool, true)
        XCTAssertGreaterThan(try XCTUnwrap(events.values.last?["programStatusRevision"] as? UInt64), revision)
        try fact(.transportLost)
        events.values.removeAll()
        try fact(.transportAttached(.sideChannel))
        XCTAssertEqual(commands(), ["refresh-client -f '!no-output'"])
        events.values.removeAll()
        XCTAssertEqual(tesseraTmuxRuntimeSetProgramStatusEnabled(handle: handle, enabled: 0), 0)
        XCTAssertEqual(commands(), ["refresh-client -f no-output"])
    }
}
