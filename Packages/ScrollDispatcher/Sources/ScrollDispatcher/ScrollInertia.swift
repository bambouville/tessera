import Foundation

// MARK: - Velocity tracking

/// Release-velocity estimator for scroll gestures.
///
/// Feed it the per-event deltas of an active gesture (`.changed` phases
/// only); ask for `releaseVelocity(at:)` when the gesture ends. Works in
/// the same units as `ScrollDispatcher.ScrollEvent.deltaY` — raw gesture
/// points, positive = user scrolling up through content.
///
/// Each event is converted to an instantaneous velocity of
/// `delta / (time since the previous event)`. That denominator matters:
/// event timestamps are taken at *delivery*, so after a main-thread hitch
/// UIKit coalesces the whole stall's motion into one large delta — divided
/// by the stall's true duration it reads correctly as slow motion, whereas
/// any window-sum estimator would read it as a violent fling. The release
/// estimate is the **median of the trailing same-direction run** of those
/// velocities: the median rejects isolated jitter, and cutting the run at
/// the last direction flip makes a final correction flick win over earlier
/// opposite motion (matching how UIKit weights recency).
///
/// Returns nil (no inertia) when the gesture doesn't qualify:
///
///   - Too few continuous samples. Discrete mouse-wheel notches arrive on
///     iPadOS as `.began`→`.ended` pairs with **no** `.changed` events, so
///     wheels never reach the sample minimum — matching macOS, where wheel
///     scrolling has no momentum (momentum is a trackpad-only behavior).
///   - The finger paused before lifting — no samples inside the window.
///   - Release speed below `minimumStartSpeed` — a slow deliberate drag
///     stops dead, like UIKit.
///
/// Pure state machine, no UIKit dependency — unit-testable off-device.
public struct ScrollVelocityTracker: Sendable {
    public struct Config: Sendable, Equatable {
        /// Only samples within this many seconds of release count toward
        /// the velocity estimate. ~100 ms mirrors UIKit's own tracking.
        public var sampleWindow: TimeInterval

        /// Minimum in-window velocity samples (trailing same-direction
        /// run) for a fling. Trackpads deliver `.changed` events at
        /// display rate (a real flick produces well over 3 in 100 ms);
        /// wheel notches deliver none.
        public var minimumSamples: Int

        /// Speeds below this (points/second) don't start inertia.
        public var minimumStartSpeed: Double

        /// Cap on the estimated speed.
        public var maximumSpeed: Double

        /// Floor on the inter-event interval used for instantaneous
        /// velocity — two events landing in the same runloop pass must
        /// not read as infinite speed. Half a 120 Hz frame.
        public var minimumSampleInterval: TimeInterval

        public init(
            // 120 ms rather than UIKit's ~100: when the main thread is busy
            // UIKit coalesces scroll events to ~40 ms cadence, and three
            // samples must still fit in the window or flings on a loaded
            // surface can never glide. The trailing same-direction run
            // already guards recency, so the wider window doesn't admit
            // stale motion.
            sampleWindow: TimeInterval = 0.12,
            minimumSamples: Int = 3,
            minimumStartSpeed: Double = 25,
            maximumSpeed: Double = 4500,
            minimumSampleInterval: TimeInterval = 0.004
        ) {
            self.sampleWindow = sampleWindow
            self.minimumSamples = minimumSamples
            self.minimumStartSpeed = minimumStartSpeed
            self.maximumSpeed = maximumSpeed
            self.minimumSampleInterval = minimumSampleInterval
        }
    }

    public var config: Config

    private struct Sample: Sendable {
        var velocity: Double
        var timestamp: TimeInterval
    }

    private var samples: [Sample] = []
    private var lastTimestamp: TimeInterval?

    public init(config: Config = .init()) {
        self.config = config
    }

    /// Record one `.changed` delta. Timestamps must be monotonic
    /// (`CACurrentMediaTime()` at the call site).
    public mutating func record(deltaY: Double, timestamp: TimeInterval) {
        defer { lastTimestamp = timestamp }
        // The first event of a gesture only anchors timing — a delta with
        // no predecessor has no measurable span.
        guard let last = lastTimestamp else { return }
        let dt = max(timestamp - last, config.minimumSampleInterval)
        samples.append(Sample(velocity: deltaY / dt, timestamp: timestamp))
        // Keep memory bounded during long drags; only the window matters.
        let cutoff = timestamp - config.sampleWindow
        if let firstKept = samples.firstIndex(where: { $0.timestamp >= cutoff }),
           firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastTimestamp = nil
    }

    /// Estimated velocity in points/second at release, or nil when the
    /// gesture shouldn't glide.
    public func releaseVelocity(at timestamp: TimeInterval) -> Double? {
        let cutoff = timestamp - config.sampleWindow
        let recent = samples.filter { $0.timestamp >= cutoff && $0.timestamp <= timestamp }
        guard let lastSample = recent.last else { return nil }

        // Trailing run of consistent direction (zeros ride along) — motion
        // before the last direction flip is not what the finger meant.
        let direction: Double = lastSample.velocity >= 0 ? 1 : -1
        var run: [Double] = []
        for sample in recent.reversed() {
            if sample.velocity * direction < 0 { break }
            run.append(sample.velocity)
        }
        guard run.count >= config.minimumSamples else { return nil }

        let median = run.sorted()[run.count / 2]
        guard abs(median) >= config.minimumStartSpeed else { return nil }
        return median.clamped(toMagnitude: config.maximumSpeed)
    }
}

// MARK: - Deceleration

/// Frame stepper for post-release glide. Exponential decay matching
/// `UIScrollView.DecelerationRate.normal` (0.998 per millisecond) — the
/// curve Safari and every native scroll view use.
public struct ScrollInertiaDecay: Sendable {
    public struct Config: Sendable, Equatable {
        /// Per-millisecond velocity retention factor.
        public var decelerationRate: Double

        /// Glide ends when speed (points/second) falls below this.
        public var stopSpeed: Double

        public init(
            decelerationRate: Double = 0.998,
            stopSpeed: Double = 4
        ) {
            self.decelerationRate = decelerationRate
            self.stopSpeed = stopSpeed
        }
    }

    public var config: Config

    /// Current velocity in points/second; sign matches the gesture
    /// convention (positive = scrolling up through content).
    public private(set) var velocity: Double

    public init(velocity: Double, config: Config = .init()) {
        self.velocity = velocity
        self.config = config
    }

    public var isFinished: Bool {
        abs(velocity) < config.stopSpeed
    }

    /// Advance one frame; returns the scroll delta (points) to apply for
    /// this frame. Returns 0 once finished.
    public mutating func step(dt: TimeInterval) -> Double {
        guard dt > 0, !isFinished else { return 0 }
        let delta = velocity * dt
        velocity *= pow(config.decelerationRate, dt * 1000)
        if isFinished {
            velocity = 0
        }
        return delta
    }
}

private extension Double {
    func clamped(toMagnitude limit: Double) -> Double {
        Swift.min(Swift.max(self, -limit), limit)
    }
}
