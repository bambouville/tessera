import XCTest
@testable import ScrollDispatcher

final class ScrollDispatcherTests: XCTestCase {

    // MARK: - Primary screen (scrollback pass-through)

    func test_primaryScreen_passesDeltaThroughAsScrollback() {
        var dispatcher = ScrollDispatcher()
        let state = ScrollDispatcher.TerminalState(isAltScreen: false, mouseReporting: .off)
        let event = ScrollDispatcher.ScrollEvent(deltaY: 42)

        let actions = dispatcher.handle(event: event, terminal: state)

        XCTAssertEqual(actions, [.scrollbackDelta(pointsY: 42)])
    }

    func test_primaryScreen_mouseModeIrrelevant() {
        // Even if the app stupidly enables mouse mode on the primary screen,
        // we still treat primary screen as scrollback. The alternate screen
        // is the signal that matters.
        var dispatcher = ScrollDispatcher()
        let state = ScrollDispatcher.TerminalState(isAltScreen: false, mouseReporting: .vt200OrLater)
        let event = ScrollDispatcher.ScrollEvent(deltaY: -30)

        let actions = dispatcher.handle(event: event, terminal: state)

        XCTAssertEqual(actions, [.scrollbackDelta(pointsY: -30)])
    }

    func test_primaryScreen_endPhaseProducesNothing() {
        var dispatcher = ScrollDispatcher()
        let state = ScrollDispatcher.TerminalState(isAltScreen: false)
        let event = ScrollDispatcher.ScrollEvent(deltaY: 20, phase: .ended)

        XCTAssertEqual(dispatcher.handle(event: event, terminal: state), [])
    }

    // MARK: - Alt-screen + arrow-key translation

    func test_altScreenNoMouse_accumulatesBelowThreshold() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        // Below 20 points — should emit nothing.
        let actions = dispatcher.handle(
            event: .init(deltaY: 10),
            terminal: state
        )
        XCTAssertEqual(actions, [])
    }

    func test_altScreenNoMouse_emitsOneArrowKeyAtThreshold() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        // Two 10-point events accumulate to 20 → one ↑ arrow.
        _ = dispatcher.handle(event: .init(deltaY: 10), terminal: state)
        let actions = dispatcher.handle(event: .init(deltaY: 10), terminal: state)

        XCTAssertEqual(actions, [.writeBytes([0x1B, 0x5B, 0x41])]) // ESC [ A = up
    }

    func test_altScreenNoMouse_emitsDownArrowWhenScrollingDown() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        let actions = dispatcher.handle(
            event: .init(deltaY: -25),
            terminal: state
        )

        XCTAssertEqual(actions, [.writeBytes([0x1B, 0x5B, 0x42])]) // ESC [ B = down
    }

    func test_altScreenNoMouse_flingIsCappedAtMaxEventsPerFlush() {
        var dispatcher = ScrollDispatcher(
            config: .init(pointsPerArrowKey: 10, maxEventsPerFlush: 5)
        )
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        // A 500-point fling would theoretically produce 50 arrow keys.
        // With a cap of 5 per flush we emit exactly 5.
        let actions = dispatcher.handle(
            event: .init(deltaY: 500),
            terminal: state
        )

        guard case .writeBytes(let bytes) = actions.first else {
            return XCTFail("expected writeBytes")
        }
        XCTAssertEqual(bytes.count, 3 * 5, "expected 5 arrow-up sequences")
        XCTAssertEqual(Array(bytes.prefix(3)), [0x1B, 0x5B, 0x41])
    }

    func test_altScreenNoMouse_accumulatorPersistsAcrossEvents() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        // 15 + 15 = 30 → one key, 10 residual
        _ = dispatcher.handle(event: .init(deltaY: 15), terminal: state)
        let first = dispatcher.handle(event: .init(deltaY: 15), terminal: state)
        XCTAssertEqual(first, [.writeBytes([0x1B, 0x5B, 0x41])])

        // next 15 → 10 + 15 = 25 → one more key, 5 residual
        let second = dispatcher.handle(event: .init(deltaY: 15), terminal: state)
        XCTAssertEqual(second, [.writeBytes([0x1B, 0x5B, 0x41])])
    }

    func test_altScreenNoMouse_endPhasePreservesAccumulator() {
        // Discrete mouse-wheel clicks on iPadOS arrive as .began→.ended
        // pairs with no intermediate .changed events (each click ~3pt).
        // For that to ever cross a 6pt arrow-key threshold, the
        // accumulator has to survive the .ended gesture boundary.
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        // Accumulate 15 points (under threshold).
        _ = dispatcher.handle(event: .init(deltaY: 15), terminal: state)

        // Gesture ends — accumulator preserved, no output.
        let endActions = dispatcher.handle(
            event: .init(deltaY: 0, phase: .ended),
            terminal: state
        )
        XCTAssertEqual(endActions, [])

        // Next gesture picks up where we left off: 15 + 15 = 30 crosses
        // the 20-point threshold and emits one ↑ arrow.
        let nextActions = dispatcher.handle(
            event: .init(deltaY: 15),
            terminal: state
        )
        XCTAssertEqual(nextActions, [.writeBytes([0x1B, 0x5B, 0x41])])
    }

    func test_altScreenNoMouse_cancelPhaseClearsAccumulator() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        _ = dispatcher.handle(event: .init(deltaY: 19), terminal: state)
        _ = dispatcher.handle(
            event: .init(deltaY: 0, phase: .cancelled),
            terminal: state
        )
        let actions = dispatcher.handle(event: .init(deltaY: 19), terminal: state)

        XCTAssertEqual(actions, [])
    }

    // MARK: - Alt-screen + mouse mode (semantic wheel events)

    func test_altScreenMouseMode_emitsWheelUpAction() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10, maxEventsPerFlush: 5)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        let actions = dispatcher.handle(
            event: .init(deltaY: 10, cursorColumn: 42, cursorRow: 7),
            terminal: state
        )

        XCTAssertEqual(
            actions,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 42, cursorRow: 7, repeatCount: 1)]
        )
    }

    func test_altScreenMouseMode_emitsWheelDownAction() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        let actions = dispatcher.handle(
            event: .init(deltaY: -12, cursorColumn: 1, cursorRow: 1),
            terminal: state
        )

        XCTAssertEqual(
            actions,
            [.mouseWheel(buttonFlags: 65, cursorColumn: 1, cursorRow: 1, repeatCount: 1)]
        )
    }

    func test_altScreenMouseMode_multipleTicksPerEvent() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10, maxEventsPerFlush: 5)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        // 35 points / 10 per tick = 3 ticks.
        let actions = dispatcher.handle(
            event: .init(deltaY: 35, cursorColumn: 10, cursorRow: 20),
            terminal: state
        )

        XCTAssertEqual(
            actions,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 10, cursorRow: 20, repeatCount: 3)]
        )
    }

    func test_altScreenMouseMode_belowThresholdEmitsNothing() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        let actions = dispatcher.handle(
            event: .init(deltaY: 3),
            terminal: state
        )

        XCTAssertEqual(actions, [])
    }

    func test_altScreenMouseMode_accumulatesDiscreteWheelTicks() {
        // Discrete mouse-wheel clicks on iPadOS arrive as 3pt-per-event
        // gestures. A naive per-event threshold check (deltaY < threshold)
        // would never emit for wheel-click scrolling because 3 < any
        // reasonable threshold. The accumulator has to carry residual
        // across events in mouse-forwarding mode too, not just in
        // arrow-key mode.
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 6, maxEventsPerFlush: 5)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        // First click: 3pt, below threshold, no output.
        let first = dispatcher.handle(
            event: .init(deltaY: 3, cursorColumn: 1, cursorRow: 1),
            terminal: state
        )
        XCTAssertEqual(first, [])

        // Second click: acc=6, threshold crossed, one wheel-up tick.
        let second = dispatcher.handle(
            event: .init(deltaY: 3, cursorColumn: 1, cursorRow: 1),
            terminal: state
        )
        XCTAssertEqual(
            second,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 1, cursorRow: 1, repeatCount: 1)]
        )
    }

    func test_altScreenMouseMode_endPhasePreservesAccumulator() {
        // Same invariant as the arrow-key path: `.began`→`.ended` pairs
        // with no `.changed` in between must not wipe the accumulator,
        // or discrete wheel ticks never cross the threshold.
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 6)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        _ = dispatcher.handle(
            event: .init(deltaY: 3, cursorColumn: 1, cursorRow: 1, phase: .began),
            terminal: state
        )
        _ = dispatcher.handle(
            event: .init(deltaY: 0, cursorColumn: 1, cursorRow: 1, phase: .ended),
            terminal: state
        )
        let next = dispatcher.handle(
            event: .init(deltaY: 3, cursorColumn: 1, cursorRow: 1, phase: .began),
            terminal: state
        )

        XCTAssertEqual(
            next,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 1, cursorRow: 1, repeatCount: 1)]
        )
    }

    func test_altScreenMouseMode_cappedAtMaxEventsPerFlush() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10, maxEventsPerFlush: 3)
        )
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: .vt200OrLater
        )

        // 200 / 10 = 20 ticks, cap 3.
        let actions = dispatcher.handle(
            event: .init(deltaY: 200, cursorColumn: 1, cursorRow: 1),
            terminal: state
        )

        guard case .mouseWheel(_, _, _, let repeatCount) = actions.first else {
            return XCTFail("expected mouseWheel")
        }
        XCTAssertEqual(repeatCount, 3)
    }

    // MARK: - State transitions between events

    func test_reset_clearsAccumulator() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 20))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        _ = dispatcher.handle(event: .init(deltaY: 19), terminal: state)
        dispatcher.reset()
        let actions = dispatcher.handle(event: .init(deltaY: 10), terminal: state)

        XCTAssertEqual(actions, [])
    }

    func test_transitioningToMouseMode_clearsArrowAccumulator() {
        var dispatcher = ScrollDispatcher(
            config: .init(pointsPerArrowKey: 20, mouseWheelThresholdPoints: 10)
        )
        let noMouse = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)
        let withMouse = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .vt200OrLater)

        // Build up almost-a-key in arrow mode.
        _ = dispatcher.handle(event: .init(deltaY: 19), terminal: noMouse)

        // Switch to mouse mode and scroll — the old 19 must not leak.
        let actions = dispatcher.handle(
            event: .init(deltaY: 10, cursorColumn: 1, cursorRow: 1),
            terminal: withMouse
        )
        XCTAssertEqual(
            actions,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 1, cursorRow: 1, repeatCount: 1)]
        )

        // And switching back, the old 19 should be gone.
        let back = dispatcher.handle(event: .init(deltaY: 10), terminal: noMouse)
        XCTAssertEqual(back, []) // only 10 accumulated, still under threshold
    }

    // MARK: - Zero-threshold edge case

    func test_zeroPointsPerArrowKey_returnsNothing() {
        var dispatcher = ScrollDispatcher(config: .init(pointsPerArrowKey: 0))
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .off)

        let actions = dispatcher.handle(event: .init(deltaY: 100), terminal: state)

        // A zero threshold would be a divide-by-zero; guard it.
        XCTAssertEqual(actions, [])
    }

    // MARK: - Cursor position safety

    func test_cursorZeroClampedToOne() {
        var dispatcher = ScrollDispatcher(
            config: .init(mouseWheelThresholdPoints: 10)
        )
        let state = ScrollDispatcher.TerminalState(isAltScreen: true, mouseReporting: .vt200OrLater)

        // Column 0 is illegal in xterm (1-indexed); dispatcher clamps to 1.
        let actions = dispatcher.handle(
            event: .init(deltaY: 10, cursorColumn: 0, cursorRow: 0),
            terminal: state
        )

        XCTAssertEqual(
            actions,
            [.mouseWheel(buttonFlags: 64, cursorColumn: 1, cursorRow: 1, repeatCount: 1)]
        )
    }
}
