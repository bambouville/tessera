import Foundation

// MARK: - Public surface

/// Pure-Swift state machine that decides what a trackpad scroll event should
/// do, given the terminal's current state.
///
/// Three behaviors per pillar §3.1:
///
///   1. Primary screen               → scroll the local scrollback buffer.
///   2. Alt-screen + mouse reporting → forward as mouse wheel events.
///   3. Alt-screen + no mouse mode   → translate into arrow-key presses,
///                                      velocity-integrated with a per-flush
///                                      cap so flings don't freeze the pty.
///
/// The dispatcher owns a fractional-delta accumulator shared by the
/// arrow-key and mouse-wheel encoders, plus the previous dispatch phase
/// so it can detect mode transitions. All terminal state is passed in
/// per call so the dispatcher is easy to reset and test.
///
/// This module has **no UIKit dependency** — it is unit-testable without
/// a simulator.
public struct ScrollDispatcher: Sendable {
    public var config: Config

    /// Residual scroll delta not yet converted into discrete output
    /// (arrow keys in arrow-translation mode, mouse wheel ticks in
    /// mouse-forwarding mode). Cleared on `.cancelled` (true abort)
    /// and on mode transitions, but preserved across `.ended` —
    /// discrete mouse-wheel ticks on iPadOS arrive as `.began`→`.ended`
    /// pairs with no intermediate `.changed` events, so state must
    /// survive gesture boundaries or a 3pt-per-click wheel can never
    /// cross the threshold.
    private var scrollAccumulator: Double = 0

    /// The dispatch phase at the previous call. Used to reset the
    /// accumulator when the terminal flips between alt-screen/primary
    /// or between mouse-reporting/no-reporting — residual from one
    /// mode is in different units than the next, so leaking it across
    /// a transition gives nonsensical output.
    private var lastPhase: Phase?

    public init(config: Config = .init()) {
        self.config = config
    }

    /// Handle an incoming scroll event and produce zero or more actions.
    ///
    /// Call sites: a gesture recognizer on the terminal view, invoked on
    /// each continuous-scroll update from the Magic Keyboard trackpad.
    public mutating func handle(
        event: ScrollEvent,
        terminal: TerminalState
    ) -> [Action] {
        // `.cancelled` is a true reset — the user aborted the gesture,
        // so drop any residual accumulator state regardless of mode.
        // `.ended` is NOT a reset: a discrete mouse-wheel click on iPadOS
        // produces a `.began`→`.ended` pair with no `.changed` in between
        // (each click delivering ~3pt), and the accumulator must survive
        // those pairs to ever cross the threshold.
        if event.phase == .cancelled {
            scrollAccumulator = 0
            lastPhase = phase(for: event, in: terminal)
            return []
        }

        let currentPhase = phase(for: event, in: terminal)
        // Mode transitions reset the accumulator. Residual fractional
        // points from arrow-key mode don't translate into mouse wheel
        // ticks in mouse-forwarding mode, and vice versa. The very
        // first event after init also takes this path (lastPhase nil
        // ≠ currentPhase), which is harmless — acc is already 0.
        if lastPhase != currentPhase {
            scrollAccumulator = 0
        }
        lastPhase = currentPhase

        switch currentPhase {
        case .primary:
            // Primary screen: bypass the accumulator. The scrollback view
            // already has momentum/inertia; we just pass the delta.
            if event.phase == .ended {
                return []
            }
            return [.scrollbackDelta(pointsY: event.deltaY)]

        case .altScreenMouseForward:
            if event.phase == .ended {
                return []
            }
            return encodeMouseWheel(event: event)

        case .altScreenArrowKeyTranslate:
            if event.phase == .ended {
                return []
            }
            return encodeArrowKeys(event: event)
        }
    }

    /// Reset the internal accumulator without processing an event.
    /// Call this when the terminal state changes mid-gesture or when
    /// the dispatcher is reused across unrelated sessions.
    public mutating func reset() {
        scrollAccumulator = 0
        lastPhase = nil
    }

    // MARK: - Internal dispatch

    private enum Phase {
        case primary
        case altScreenMouseForward
        case altScreenArrowKeyTranslate
    }

    private func phase(
        for event: ScrollEvent,
        in terminal: TerminalState
    ) -> Phase {
        guard terminal.isAltScreen else { return .primary }
        if terminal.mouseReporting.forwardsWheelEvents {
            return .altScreenMouseForward
        }
        return .altScreenArrowKeyTranslate
    }

    // MARK: - Encoders

    /// Velocity-integrated like `encodeArrowKeys`. Discrete mouse-wheel
    /// clicks on iPadOS deliver only ~3pt per event, so a naive
    /// per-event threshold check never emits for wheel scrolling;
    /// accumulating residual across events is necessary for any
    /// threshold > 3pt.
    private mutating func encodeMouseWheel(event: ScrollEvent) -> [Action] {
        scrollAccumulator += event.deltaY

        let threshold = config.mouseWheelThresholdPoints
        guard threshold > 0 else { return [] }

        let sign: Double = scrollAccumulator >= 0 ? 1 : -1
        let magnitude = abs(scrollAccumulator)
        let rawTicks = Int(magnitude / threshold)
        let ticks = min(rawTicks, config.maxEventsPerFlush)
        guard ticks > 0 else { return [] }

        scrollAccumulator -= sign * Double(ticks) * threshold

        // scrollAccumulator > 0 means content moves down, i.e. user
        // scrolled up. xterm/SGR wheel-up = button flag 64.
        let button = sign > 0 ? 64 : 65
        let col = max(1, min(223, event.cursorColumn)) // xterm limits to 223
        let row = max(1, min(223, event.cursorRow))
        return [.mouseWheel(
            buttonFlags: button,
            cursorColumn: col,
            cursorRow: row,
            repeatCount: ticks
        )]
    }

    /// Velocity-integrated arrow-key translation.
    ///
    /// `scrollAccumulator` holds residual delta in points. Every time
    /// the absolute accumulator crosses `pointsPerArrowKey`, one key is
    /// emitted and the accumulator decreases by that threshold. We cap
    /// the number of keys emitted per call so a trackpad fling cannot
    /// flood the pty.
    private mutating func encodeArrowKeys(event: ScrollEvent) -> [Action] {
        scrollAccumulator += event.deltaY

        let threshold = config.pointsPerArrowKey
        guard threshold > 0 else { return [] }

        let sign: Double = scrollAccumulator >= 0 ? 1 : -1
        let magnitude = abs(scrollAccumulator)
        let rawKeys = Int(magnitude / threshold)
        let keys = min(rawKeys, config.maxEventsPerFlush)
        guard keys > 0 else { return [] }

        scrollAccumulator -= sign * Double(keys) * threshold

        // deltaY > 0 = content moves down = user scrolls up = ↑ arrow.
        let direction: ArrowDirection = sign > 0 ? .up : .down
        let sequence: [UInt8] = switch direction {
        case .up:   [0x1B, 0x5B, 0x41] // ESC [ A
        case .down: [0x1B, 0x5B, 0x42] // ESC [ B
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(sequence.count * keys)
        for _ in 0..<keys {
            bytes.append(contentsOf: sequence)
        }
        return [.writeBytes(bytes)]
    }
}

// MARK: - Supporting types

extension ScrollDispatcher {
    public struct Config: Sendable, Equatable {
        /// Points of accumulated scroll delta required to emit one arrow
        /// key in arrow-key-translation mode. Default ~20 feels like
        /// iTerm2's behavior on a Magic Keyboard trackpad.
        public var pointsPerArrowKey: Double

        /// Points per mouse-wheel "tick" when forwarding wheel events.
        /// The terminal expects discrete wheel ticks, not a continuous stream.
        public var mouseWheelThresholdPoints: Double

        /// Maximum arrow-key presses OR mouse-wheel ticks emitted per
        /// single handle() call. Caps trackpad flings so the pty is
        /// never flooded with hundreds of events per frame.
        public var maxEventsPerFlush: Int

        public init(
            pointsPerArrowKey: Double = 20,
            mouseWheelThresholdPoints: Double = 10,
            maxEventsPerFlush: Int = 5
        ) {
            self.pointsPerArrowKey = pointsPerArrowKey
            self.mouseWheelThresholdPoints = mouseWheelThresholdPoints
            self.maxEventsPerFlush = maxEventsPerFlush
        }
    }

    public struct TerminalState: Sendable, Equatable {
        public var isAltScreen: Bool
        public var mouseReporting: MouseReporting

        public init(
            isAltScreen: Bool = false,
            mouseReporting: MouseReporting = .off
        ) {
            self.isAltScreen = isAltScreen
            self.mouseReporting = mouseReporting
        }
    }

    /// xterm mouse reporting modes we care about for scroll routing.
    /// The full xterm protocol has more, but for wheel-forwarding purposes
    /// this is the relevant distinction.
    public enum MouseReporting: Sendable, Equatable {
        case off
        /// Any of xterm modes 1000/1002/1003 — all of which forward wheel
        /// as button press events.
        case vt200OrLater

        public var forwardsWheelEvents: Bool {
            self != .off
        }
    }

    public struct ScrollEvent: Sendable, Equatable {
        /// Vertical scroll delta in points. Positive = content moves down
        /// (natural scrolling), i.e. user is scrolling "up" through content.
        public var deltaY: Double
        /// 1-indexed cell column of the pointer when the event fired.
        public var cursorColumn: Int
        /// 1-indexed cell row of the pointer when the event fired.
        public var cursorRow: Int
        public var phase: Phase

        public enum Phase: Sendable, Equatable {
            case began
            case changed
            case ended
            case cancelled
        }

        public init(
            deltaY: Double,
            cursorColumn: Int = 1,
            cursorRow: Int = 1,
            phase: Phase = .changed
        ) {
            self.deltaY = deltaY
            self.cursorColumn = cursorColumn
            self.cursorRow = cursorRow
            self.phase = phase
        }
    }

    public enum Action: Sendable, Equatable {
        /// Scroll the local scrollback buffer by this many points.
        /// Positive = content moves down (user scrolls up through history).
        case scrollbackDelta(pointsY: Double)
        /// Forward a mouse wheel event using the terminal's currently
        /// negotiated mouse protocol. `cursorColumn` / `cursorRow` are
        /// 1-indexed terminal cells.
        case mouseWheel(buttonFlags: Int, cursorColumn: Int, cursorRow: Int, repeatCount: Int)
        /// Write these bytes to the remote pty.
        case writeBytes([UInt8])
    }

    public enum ArrowDirection: Sendable, Equatable {
        case up, down
    }
}
