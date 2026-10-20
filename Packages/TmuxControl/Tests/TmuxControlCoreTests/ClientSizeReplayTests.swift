import XCTest
@testable import TmuxControlCore

final class ClientSizeReplayTests: XCTestCase {
    func testInlineReplayFencesLatestWithATargetlessSelectWindow() {
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .inline),
            ["refresh-client -C 54,37", "select-window"]
        )
        XCTAssertEqual(TmuxClientSizeReplay.latestFenceCommand, "select-window")
    }

    func testAClaimsReplayLeavesTheFenceToTheClaim() {
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .inline, belongsToClaim: true),
            ["refresh-client -C 54,37"]
        )
    }

    func testSideChannelReplayOnlyRefreshes() {
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .sideChannel),
            ["refresh-client -C 54,37"]
        )
    }

    /// P6: an advertised grid drops the refresh. The inline fence still goes
    /// out (it re-takes `latest` from the stored size); a claim's replay and
    /// the side channel then have nothing left to send.
    func testAnAdvertisedGridSendsNoRefresh() {
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .inline, sizeAlreadyAdvertised: true),
            ["select-window"]
        )
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(
                columns: 54, rows: 37, path: .inline, belongsToClaim: true, sizeAlreadyAdvertised: true
            ),
            []
        )
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .sideChannel, sizeAlreadyAdvertised: true),
            []
        )
    }

    func testRejectsAGridTmuxWouldRefuse() {
        XCTAssertEqual(TmuxClientSizeReplay.commands(columns: 0, rows: 37, path: .inline), [])
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(
                columns: 54, rows: TmuxClientGeometry.maximumDimension + 1, path: .inline
            ),
            []
        )
    }
}
