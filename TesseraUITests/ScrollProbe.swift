import XCTest

/// Scroll driver for the gesture test harness.
///
/// tessbot (CGEvent/Indigo) sets up state — connects, opens an isolated ⌘T
/// window, runs the command — then these tests `activate()` the ALREADY-RUNNING
/// app (no relaunch, so the session + scrollback survive) and perform a real
/// indirect `scroll(byDeltaX:deltaY:)`, the one thing only XCUITest can do on
/// iOS 26.
///
/// NOTE: SwiftTerm renders via Metal, which XCUIScreenshot captures as black —
/// so verification is done by the HARNESS via simctl screenshots taken around
/// each run. Each scroll test therefore scrolls ONE direction and LEAVES the
/// terminal in that position so a before/after simctl diff is meaningful.
final class ScrollProbe: XCTestCase {

    func testPointerScrollAvailable() throws {
        XCTAssertTrue(
            XCUIDevice.shared.supportsPointerInteraction,
            "indirect pointer scrolling is not supported on this device"
        )
    }

    /// Scroll with negative dy (candidate: up into history) and leave it.
    func testScrollNeg() throws { scrollAndLeave(dy: -800, reps: 4) }

    /// Scroll with positive dy (candidate: down) and leave it.
    func testScrollPos() throws { scrollAndLeave(dy: 800, reps: 4) }

    private func scrollAndLeave(dy: CGFloat, reps: Int) {
        let app = XCUIApplication()
        app.activate()
        usleep(1_000_000)
        for _ in 0..<reps {
            app.scroll(byDeltaX: 0, deltaY: dy)
            usleep(300_000)
        }
    }
}
