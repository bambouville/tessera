import XCTest
@testable import ScrollDispatcher

final class ScrollInertiaTests: XCTestCase {

    // MARK: - Velocity tracking

    /// Simulate a steady trackpad drag: `count` events of `delta` points,
    /// one per `interval` seconds, ending at `end`.
    private func steadyGesture(
        into tracker: inout ScrollVelocityTracker,
        delta: Double,
        count: Int,
        interval: TimeInterval,
        endingAt end: TimeInterval
    ) {
        for i in 0..<count {
            let t = end - Double(count - 1 - i) * interval
            tracker.record(deltaY: delta, timestamp: t)
        }
    }

    func test_steadyFling_estimatesVelocity() {
        var tracker = ScrollVelocityTracker()
        // 10 events of 5pt every 8ms (120Hz) → 5/0.008 = 625 pt/s.
        steadyGesture(into: &tracker, delta: 5, count: 10, interval: 0.008, endingAt: 1.0)

        let v = tracker.releaseVelocity(at: 1.0)

        XCTAssertNotNil(v)
        // Span is (kept samples - 1) intervals; estimate lands near the
        // true rate. Allow generous tolerance — feel is tuned on device.
        XCTAssertEqual(v!, 625, accuracy: 100)
    }

    func test_downwardFling_negativeVelocity() {
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: -5, count: 10, interval: 0.008, endingAt: 1.0)

        let v = tracker.releaseVelocity(at: 1.0)

        XCTAssertNotNil(v)
        XCTAssertLessThan(v!, 0)
    }

    func test_samplesOutsideWindow_ignored() {
        var tracker = ScrollVelocityTracker()
        // Fast movement long before release…
        steadyGesture(into: &tracker, delta: 20, count: 10, interval: 0.008, endingAt: 0.5)
        // …then release much later: nothing recent → no inertia.
        XCTAssertNil(tracker.releaseVelocity(at: 1.0))
    }

    func test_pauseBeforeRelease_noInertia() {
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: 10, count: 10, interval: 0.008, endingAt: 0.9)
        // Finger held still for 150ms (window is 100ms) before lifting.
        XCTAssertNil(tracker.releaseVelocity(at: 1.05))
    }

    func test_discreteWheelNotch_noInertia() {
        var tracker = ScrollVelocityTracker()
        // iPadOS wheel click: began→ended pair with no .changed events —
        // nothing is recorded, so a notch can never launch a glide.
        XCTAssertNil(tracker.releaseVelocity(at: 1.0))

        // Even a couple of stray recorded events stay under minimumSamples.
        tracker.record(deltaY: 3, timestamp: 0.99)
        tracker.record(deltaY: 3, timestamp: 1.0)
        XCTAssertNil(tracker.releaseVelocity(at: 1.0))
    }

    func test_slowDrag_belowStartThreshold_noInertia() {
        var tracker = ScrollVelocityTracker()
        // 0.3pt every 20ms ≈ 19 pt/s — under the 25 pt/s start threshold.
        // Window is 100ms so keep samples close enough to stay counted.
        steadyGesture(into: &tracker, delta: 0.3, count: 5, interval: 0.02, endingAt: 1.0)
        XCTAssertNil(tracker.releaseVelocity(at: 1.0))
    }

    func test_velocityCappedAtMaximum() {
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: 500, count: 6, interval: 0.008, endingAt: 1.0)

        let v = tracker.releaseVelocity(at: 1.0)

        XCTAssertNotNil(v)
        XCTAssertEqual(v!, tracker.config.maximumSpeed)
    }

    func test_hitchCoalescedDelta_readsAsSlowMotion_notFling() {
        // A slow drag (~300 pt/s) stalls for 200ms (main-thread hitch, e.g.
        // a mosh capture feed); UIKit coalesces the stall's motion into ONE
        // 60pt delta delivered at hitch end. Its instantaneous velocity is
        // 60/0.2 = 300 pt/s — the drag's true speed — so the release must
        // glide gently, not launch a violent fling.
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: 2.4, count: 5, interval: 0.008, endingAt: 0.784)
        tracker.record(deltaY: 60, timestamp: 0.984)     // coalesced hitch delta
        tracker.record(deltaY: 2.4, timestamp: 0.992)
        tracker.record(deltaY: 2.4, timestamp: 1.0)

        let v = tracker.releaseVelocity(at: 1.0)

        XCTAssertNotNil(v)
        XCTAssertEqual(v!, 300, accuracy: 50)
    }

    func test_directionReversal_finalFlickWins() {
        // Fast upward scroll, then a downward correction flick in the last
        // ~40ms. The glide must follow the FINAL flick's direction, not the
        // window average (which would still be net-upward).
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: 8, count: 8, interval: 0.008, endingAt: 0.968)
        for i in 1...4 {
            tracker.record(deltaY: -3.2, timestamp: 0.968 + Double(i) * 0.008)
        }

        let v = tracker.releaseVelocity(at: 1.0)

        XCTAssertNotNil(v)
        XCTAssertLessThan(v!, 0)
        XCTAssertEqual(v!, -400, accuracy: 80)
    }

    func test_reset_dropsSamples() {
        var tracker = ScrollVelocityTracker()
        steadyGesture(into: &tracker, delta: 10, count: 10, interval: 0.008, endingAt: 1.0)
        tracker.reset()
        XCTAssertNil(tracker.releaseVelocity(at: 1.0))
    }

    func test_sameTimestampBurst_doesNotExplode() {
        var tracker = ScrollVelocityTracker()
        for _ in 0..<5 {
            tracker.record(deltaY: 10, timestamp: 1.0)
        }
        let v = tracker.releaseVelocity(at: 1.0)
        XCTAssertNotNil(v)
        // Clamped by the span floor and then by maximumSpeed.
        XCTAssertLessThanOrEqual(abs(v!), tracker.config.maximumSpeed)
    }

    // MARK: - Decay

    func test_decay_reducesVelocityMonotonically() {
        var decay = ScrollInertiaDecay(velocity: 1000)
        var previous = abs(decay.velocity)
        for _ in 0..<20 {
            _ = decay.step(dt: 1.0 / 120.0)
            XCTAssertLessThan(abs(decay.velocity), previous)
            previous = abs(decay.velocity)
        }
    }

    func test_decay_deltaMatchesVelocityTimesDt() {
        var decay = ScrollInertiaDecay(velocity: 600)
        let delta = decay.step(dt: 1.0 / 60.0)
        XCTAssertEqual(delta, 600 / 60.0, accuracy: 0.001)
    }

    func test_decay_preservesDirection() {
        var up = ScrollInertiaDecay(velocity: 500)
        var down = ScrollInertiaDecay(velocity: -500)
        XCTAssertGreaterThan(up.step(dt: 0.008), 0)
        XCTAssertLessThan(down.step(dt: 0.008), 0)
    }

    func test_decay_finishesWithinReasonableTime() {
        // v(t) = v0 · 0.998^(1000t): 1000 pt/s decays under the 4 pt/s stop
        // threshold in ~2.8s. Assert it terminates and doesn't run forever.
        var decay = ScrollInertiaDecay(velocity: 1000)
        var elapsed = 0.0
        while !decay.isFinished && elapsed < 10 {
            _ = decay.step(dt: 1.0 / 120.0)
            elapsed += 1.0 / 120.0
        }
        XCTAssertTrue(decay.isFinished)
        XCTAssertEqual(elapsed, 2.8, accuracy: 0.5)
        XCTAssertEqual(decay.velocity, 0)
    }

    func test_decay_finishedStepsReturnZero() {
        var decay = ScrollInertiaDecay(velocity: 1)  // below stopSpeed already
        XCTAssertTrue(decay.isFinished)
        XCTAssertEqual(decay.step(dt: 0.008), 0)
    }

    func test_decay_zeroOrNegativeDt_noMovement() {
        var decay = ScrollInertiaDecay(velocity: 500)
        XCTAssertEqual(decay.step(dt: 0), 0)
        XCTAssertEqual(decay.step(dt: -0.008), 0)
        XCTAssertEqual(decay.velocity, 500)
    }

    func test_decay_totalGlideDistanceApproximatesClosedForm() {
        // Closed form: distance = v0 / -ln(r^1000) ≈ v0 / 2.002 for r=0.998.
        var decay = ScrollInertiaDecay(velocity: 1000)
        var distance = 0.0
        while !decay.isFinished {
            distance += decay.step(dt: 1.0 / 120.0)
        }
        XCTAssertEqual(distance, 1000 / 2.002, accuracy: 15)
    }
}
