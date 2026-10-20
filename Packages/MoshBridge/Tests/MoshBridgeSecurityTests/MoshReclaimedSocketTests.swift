import XCTest
import MoshBridge

final class MoshReclaimedSocketTests: XCTestCase {
    func testReclaimedSocketHopsAndReceivesOnNewPort() {
        XCTAssertEqual(MoshBridgeProbe.reclaimedSocketProbe(), 42)
    }
}
