import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

/// The take-back claim's settle probe (§6.10 rule 5) through the ABI: the
/// tagged size read Android writes after each fence acknowledgement, and the
/// grid its answer reports, which lands the claim's geometry whatever size
/// it names.
final class TmuxWindowSizeReplaySettleProbeABITests: XCTestCase {
    func testTheSizeQueryIsTheReplaysOwnConfirmationRead() throws {
        let required = sizeQuery(5, nil, 0)
        XCTAssertGreaterThan(required, 0)
        var output = [UInt8](repeating: 0, count: Int(required))
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { sizeQuery(5, $0.baseAddress, $0.count) }, required)
        let query = String(decoding: output, as: UTF8.self)
        XCTAssertEqual(query, TmuxWindowSizeReplay.sizeQuery(windowID: WindowId(5)))
        let replay = TmuxWindowSizeReplay.commands(
            windowID: WindowId(5),
            requested: try TmuxClientGeometry(columns: 56, rows: 48)
        )
        XCTAssertEqual(query, replay.last)
        XCTAssertEqual(
            query,
            "display-message -p -t @5 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'"
        )
    }

    func testTheSizeQueryRejectsInvalidArgumentsAndNeverPartiallyCopies() {
        XCTAssertEqual(sizeQuery(-1, nil, 0), -1)
        XCTAssertEqual(sizeQuery(5, nil, -1), -1)
        XCTAssertGreaterThan(sizeQuery(0, nil, 0), 0)
        var short = [UInt8](repeating: 0xAA, count: Int(sizeQuery(5, nil, 0)) - 1)
        XCTAssertEqual(short.withUnsafeMutableBufferPointer { sizeQuery(5, $0.baseAddress, $0.count) }, -1)
        XCTAssertTrue(short.allSatisfy { $0 == 0xAA })
    }

    func testTheReportedGeometryIsAnySizeTheWindowHas() {
        for suffix in ["", "\n", "\r\n"] {
            XCTAssertEqual(reported("tessera-window-size\t@5\t56\t48" + suffix), 56 << 32 | 48)
        }
        XCTAssertEqual(reported("tessera-window-size\t@5\t100\t30"), 100 << 32 | 30)
        XCTAssertEqual(reported("tessera-window-size\t@5\t65535\t1"), 65_535 << 32 | 1)
        XCTAssertEqual(reported("tessera-window-size\t@7\t1\t65535", windowID: 7), 1 << 32 | 65_535)
    }

    func testAMalformedOrForeignAnswerReportsNothing() {
        let reply = "tessera-window-size\t@5\t56\t48"
        for malformed in [
            "tessera-window-size\t@4\t56\t48",
            "other-tag\t@5\t56\t48",
            "tessera-window-size\t@05\t56\t48",
            "tessera-window-size\t@5\t056\t48",
            "tessera-window-size\t@5\t56\t+48",
            "tessera-window-size\t@5\t0\t48",
            "tessera-window-size\t@5\t56\t65536",
            reply + "\tignored", reply + "\n\n", reply + "\r",
            reply + "\n" + reply, "", "56x48",
        ] {
            XCTAssertEqual(reported(malformed), 0, malformed)
        }
    }

    func testTheReportedGeometryRejectsInvalidArgumentsAndUTF8() {
        XCTAssertEqual(tesseraTmuxWindowSizeReplayReportedGeometry(windowID: -1, replyBytes: nil, replyCount: 0), -1)
        XCTAssertEqual(tesseraTmuxWindowSizeReplayReportedGeometry(windowID: 5, replyBytes: nil, replyCount: 1), -1)
        XCTAssertEqual(tesseraTmuxWindowSizeReplayReportedGeometry(windowID: 5, replyBytes: nil, replyCount: -1), -1)
        XCTAssertEqual(tesseraTmuxWindowSizeReplayReportedGeometry(windowID: 5, replyBytes: nil, replyCount: 0), 0)
        let long = [UInt8](repeating: 0x41, count: 257)
        XCTAssertEqual(long.withUnsafeBufferPointer {
            tesseraTmuxWindowSizeReplayReportedGeometry(windowID: 5, replyBytes: $0.baseAddress, replyCount: $0.count)
        }, -1)
        let invalid: [UInt8] = Array("tessera-window-size\t@5\t56\t".utf8) + [0xFF]
        XCTAssertEqual(invalid.withUnsafeBufferPointer {
            tesseraTmuxWindowSizeReplayReportedGeometry(windowID: 5, replyBytes: $0.baseAddress, replyCount: $0.count)
        }, 0)
    }

    private func sizeQuery(_ windowID: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int32 {
        tesseraTmuxWindowSizeReplaySizeQuery(windowID: windowID, outputBytes: output, outputCapacity: capacity)
    }

    private func reported(_ reply: String, windowID: Int32 = 5) -> Int64 {
        let bytes = Array(reply.utf8)
        return bytes.withUnsafeBufferPointer {
            tesseraTmuxWindowSizeReplayReportedGeometry(windowID: windowID, replyBytes: $0.baseAddress, replyCount: $0.count)
        }
    }
}
