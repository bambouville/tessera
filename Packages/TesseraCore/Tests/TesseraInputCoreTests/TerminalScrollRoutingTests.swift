import XCTest
@testable import TesseraInputCore

final class TerminalScrollRoutingTests: XCTestCase {
    /// The screen decides, never mouse tracking alone: on mosh+tmux the
    /// visible client is on the primary screen with tmux's `mouse on` in
    /// force, and the swipe must move the local overlay, not enter copy-mode.
    func testPrimaryScreenStaysLocalEvenWithMouseReporting() {
        XCTAssertEqual(
            TerminalScrollRouting.route(
                bufferIsAlternate: false, mouseReporting: true, mouseReportingImpliesAltScreen: false
            ),
            .localScrollback
        )
        XCTAssertEqual(
            TerminalScrollRouting.route(
                bufferIsAlternate: false, mouseReporting: false, mouseReportingImpliesAltScreen: false
            ),
            .localScrollback
        )
    }

    /// With no local scrollback to offer (plain mosh, mosh+tmux before its
    /// pane grid) mouse reporting stands in for the alternate screen and the
    /// remote program that asked for the mouse receives the wheel.
    func testMouseReportingImpliesAltScreenOnlyWhenTheSessionSaysSo() {
        XCTAssertEqual(
            TerminalScrollRouting.route(
                bufferIsAlternate: false, mouseReporting: true, mouseReportingImpliesAltScreen: true
            ),
            .mouseWheel
        )
        XCTAssertEqual(
            TerminalScrollRouting.route(
                bufferIsAlternate: false, mouseReporting: false, mouseReportingImpliesAltScreen: true
            ),
            .localScrollback
        )
        XCTAssertFalse(TerminalScrollRouting.isAltScreen(
            bufferIsAlternate: false, mouseReporting: true, mouseReportingImpliesAltScreen: false
        ))
        XCTAssertTrue(TerminalScrollRouting.isAltScreen(
            bufferIsAlternate: false, mouseReporting: true, mouseReportingImpliesAltScreen: true
        ))
    }

    func testAlternateScreenForwardsWheelWithMouseReportingAndArrowsWithout() {
        for implies in [false, true] {
            XCTAssertEqual(
                TerminalScrollRouting.route(
                    bufferIsAlternate: true, mouseReporting: true, mouseReportingImpliesAltScreen: implies
                ),
                .mouseWheel
            )
            XCTAssertEqual(
                TerminalScrollRouting.route(
                    bufferIsAlternate: true, mouseReporting: false, mouseReportingImpliesAltScreen: implies
                ),
                .arrowKeys
            )
        }
    }
}
