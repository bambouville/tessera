import XCTest
import MoshBridge

final class MoshMouseFrameTests: XCTestCase {
    func testFullResizedAndEncodingFramesRestoreTrackingLast() {
        for mode in [9, 1000, 1002, 1003] {
            for encoding in [0, 1005, 1006, 1015] {
                for scenario in 0...2 {
                    let bytes = MoshBridgeProbe.mouseFrameProbe(mode: mode, encoding: encoding, scenario: scenario)
                    let wire = String(decoding: bytes, as: UTF8.self)
                    XCTAssertTrue(wire.hasSuffix("\u{1B}[?\(mode)h"), "mode=\(mode) encoding=\(encoding) scenario=\(scenario)")
                }
            }
        }
        let disabled = String(decoding: MoshBridgeProbe.mouseFrameProbe(mode: 0, encoding: 0, scenario: 1), as: UTF8.self)
        XCTAssertTrue(disabled.contains("\u{1B}[?1003l"))
        XCTAssertFalse(disabled.contains("\u{1B}[?1003h"))
        XCTAssertTrue(MoshBridgeProbe.mouseFrameProbe(mode: 1003, encoding: 1006, scenario: 3).isEmpty)
    }
}
