import XCTest
import MoshBridge

final class MoshFullRepaintFenceTests: XCTestCase {
    func testFreshFrameRequiresSentResizeEchoAcknowledgementAndCurrentGrid() {
        XCTAssertEqual(MoshBridgeProbe.fullRepaintFenceProbe(), 42)
    }

    func testBridgeFenceIsUnavailableBeforeStartAndAfterShutdown() throws {
        let client = try MoshBridgeClient(
            host: "127.0.0.1", port: 60_001, base64Key: "qiXpjXIk6M8/nWtBn9s6rQ")
        XCTAssertEqual(try client.beginFullRepaintFence(), 0)
        XCTAssertFalse(client.isFullRepaintFenceReady(token: 1))
        client.shutdown()
        XCTAssertEqual(try client.beginFullRepaintFence(), 0)
        XCTAssertFalse(client.isFullRepaintFenceReady(token: 1))
    }
}
