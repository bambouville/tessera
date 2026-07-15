import XCTest

/// Fast end-to-end check for Tessera's indirect-pointer scroll wiring.
///
/// The app launches a DEBUG-only, host-free TerminalSurfaceBound with 500
/// deterministic rows. The oracle is its real UIScrollView content offset,
/// projected through accessibility as `bottom` / `history`; Metal screenshots,
/// external typing, and live-session idle waits are intentionally absent.
final class TerminalScrollHarnessTests: XCTestCase {
    func testPrimaryScrollMovesIntoHistoryAndBackToBottom() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_SCROLL_CAPTURE"] == "1" else {
            throw XCTSkip(
                "scroll wiring is driven by scripts/integration/run-integration-tests.sh"
            )
        }
        XCTAssertTrue(XCUIDevice.shared.supportsPointerInteraction)
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        // The runner injects TESSERA_SCROLL_HARNESS into the dedicated
        // simulator's launchd environment. `activate` avoids asking XCTest to
        // wait for terminal rendering to become globally quiescent.
        app.activate()

        let state = app.descendants(matching: .any)["terminal-scroll-harness"]
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        try waitForValue("bottom", on: state, timeout: 5)

        app.scroll(byDeltaX: 0, deltaY: -800)
        try waitForValue("history", on: state, timeout: 5)

        app.scroll(byDeltaX: 0, deltaY: 800)
        try waitForValue("bottom", on: state, timeout: 5)
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "expected scroll state \(value), got \(String(describing: element.value))"
        )
    }
}
