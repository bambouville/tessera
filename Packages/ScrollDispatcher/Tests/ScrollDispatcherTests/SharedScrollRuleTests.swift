import XCTest
@testable import ScrollDispatcher

/// The dispatcher's phase is the shared `TerminalScrollRouting` rule: a primary
/// screen with mouse reporting scrolls locally unless the session declared
/// that mouse reporting stands in for the alternate screen.
final class SharedScrollRuleTests: XCTestCase {
    func testMouseReportingOnThePrimaryScreenStaysLocalUnlessDeclaredToImplyAltScreen() {
        var dispatcher = ScrollDispatcher()
        let event = ScrollDispatcher.ScrollEvent(deltaY: 30)

        let local = dispatcher.handle(
            event: event,
            terminal: .init(isAltScreen: false, mouseReporting: .vt200OrLater)
        )
        XCTAssertEqual(local, [.scrollbackDelta(pointsY: 30)])

        dispatcher.reset()
        let forwarded = dispatcher.handle(
            event: event,
            terminal: .init(
                isAltScreen: false,
                mouseReporting: .vt200OrLater,
                mouseReportingImpliesAltScreen: true
            )
        )
        guard case .mouseWheel? = forwarded.first else {
            return XCTFail("expected a wheel report, got \(forwarded)")
        }
    }

    func testImpliedAltScreenWithoutMouseReportingIsStillThePrimaryScreen() {
        var dispatcher = ScrollDispatcher()
        let actions = dispatcher.handle(
            event: .init(deltaY: 12),
            terminal: .init(
                isAltScreen: false,
                mouseReporting: .off,
                mouseReportingImpliesAltScreen: true
            )
        )
        XCTAssertEqual(actions, [.scrollbackDelta(pointsY: 12)])
    }
}
