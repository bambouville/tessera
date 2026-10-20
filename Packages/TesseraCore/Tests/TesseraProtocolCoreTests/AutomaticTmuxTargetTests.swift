import XCTest
@testable import TesseraProtocolCore

final class AutomaticTmuxTargetTests: XCTestCase {
    func testAutomaticTargetIsStableAcrossPlatforms() {
        XCTAssertEqual(
            AutomaticTmuxTarget.sessionName(
                username: "alice",
                hostname: "example.com",
                port: 2222
            ),
            "tessera-b266b78c"
        )
    }

    func testHostIdentityChangesTarget() {
        let first = AutomaticTmuxTarget.sessionName(username: "alice", hostname: "example.com", port: 22)
        let second = AutomaticTmuxTarget.sessionName(username: "alice", hostname: "example.com", port: 2222)
        XCTAssertNotEqual(first, second)
    }
}
