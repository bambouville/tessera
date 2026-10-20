import XCTest
@testable import TmuxControlCore

final class StamplessPeerTests: XCTestCase {
    private func decide(
        participatesInAuthority: Bool = true,
        windowSizePolicyKnown: Bool = true,
        windowSizePolicyIsLatest: Bool = true,
        rederiveInFlight: Bool = false,
        alreadyPeer: Bool = false,
        reclaimInFlight: Bool = false,
        layoutIsForRenderedWindow: Bool = true,
        layoutColumns: Int = 200,
        layoutRows: Int = 50,
        localColumns: Int = 45,
        localRows: Int = 20,
        secondsSinceLocalSizeReplay: Double? = 30
    ) -> Bool {
        TmuxStamplessPeer.shouldRaisePeer(
            participatesInAuthority: participatesInAuthority,
            windowSizePolicyKnown: windowSizePolicyKnown,
            windowSizePolicyIsLatest: windowSizePolicyIsLatest,
            rederiveInFlight: rederiveInFlight,
            alreadyPeer: alreadyPeer,
            reclaimInFlight: reclaimInFlight,
            layoutIsForRenderedWindow: layoutIsForRenderedWindow,
            layoutColumns: layoutColumns,
            layoutRows: layoutRows,
            localColumns: localColumns,
            localRows: localRows,
            secondsSinceLocalSizeReplay: secondsSinceLocalSizeReplay
        )
    }

    func testForeignGeometryOnTheRenderedWindowRaisesAPeer() {
        XCTAssertTrue(decide())
    }

    func testOurOwnGeometryIsNotAPeer() {
        XCTAssertFalse(decide(layoutColumns: 45, layoutRows: 20))
    }

    func testOurOwnReplayEchoIsSuppressed() {
        XCTAssertFalse(decide(secondsSinceLocalSizeReplay: 0.5))
        XCTAssertTrue(decide(secondsSinceLocalSizeReplay: 2.5))
        // Never having replayed a size cannot be an echo of one.
        XCTAssertTrue(decide(secondsSinceLocalSizeReplay: nil))
    }

    func testBackgroundWindowsProveNothing() {
        // `window-size` is per-window, so another client's geometry on a window
        // this device does not render is expected, not a takeover.
        XCTAssertFalse(decide(layoutIsForRenderedWindow: false))
    }

    func testANonLatestPolicyCannotEvidenceATakeover() {
        XCTAssertFalse(decide(windowSizePolicyIsLatest: false))
        XCTAssertFalse(decide(windowSizePolicyKnown: false))
    }

    func testStatesThatAlreadyOwnTheAnswerDoNotRaiseAgain() {
        XCTAssertFalse(decide(alreadyPeer: true))
        XCTAssertFalse(decide(reclaimInFlight: true))
        XCTAssertFalse(decide(rederiveInFlight: true))
        XCTAssertFalse(decide(participatesInAuthority: false))
    }

    func testDegenerateGeometryIsIgnored() {
        XCTAssertFalse(decide(layoutColumns: 0))
        XCTAssertFalse(decide(localColumns: 0))
    }
}
