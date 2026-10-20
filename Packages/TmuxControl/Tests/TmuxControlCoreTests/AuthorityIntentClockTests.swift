import Foundation
import XCTest
@testable import TmuxControlCore

/// §6.9 R3: an intent lasts about 20 s from the user's last step; prompts
/// pause it. Ported from Android `TmuxAuthorityIntentClockTest`, with one
/// deliberate change (plan §C.3, iOS behaviour): ending a pause is the
/// user's next step, a full window from there, rather than the old window
/// extended by the time paused.
final class AuthorityIntentClockTests: XCTestCase {
    func test_anIntentExpiresTwentySecondsAfterItBegan() {
        var clock = TmuxAuthorityIntentClock()
        clock.track(7, stepAt: 1_000)
        XCTAssertNil(clock.expiredToken(now: 20_999))
        XCTAssertEqual(clock.remaining(now: 20_999), 1)
        XCTAssertEqual(clock.deadline, 21_000)
        XCTAssertEqual(clock.expiredToken(now: 21_000), 7)
    }

    func test_theSameTokenKeepsItsDeadlineAndANewOneRestarts() {
        var clock = TmuxAuthorityIntentClock()
        clock.track(7, stepAt: 0)
        clock.track(7, stepAt: 15_000)
        XCTAssertEqual(clock.expiredToken(now: 20_000), 7)
        clock.track(8, stepAt: 20_000)
        XCTAssertNil(clock.expiredToken(now: 39_999))
        XCTAssertEqual(clock.expiredToken(now: 40_000), 8)
    }

    func test_aPromptPausesTheClockAndAnsweringItIsAFreshStep() {
        var clock = TmuxAuthorityIntentClock()
        clock.track(7, stepAt: 0)
        clock.setPaused(true, now: 5_000)
        XCTAssertTrue(clock.paused)
        XCTAssertNil(clock.expiredToken(now: 120_000), "a prompt is up: never expire")
        XCTAssertNil(clock.remaining(now: 120_000))
        XCTAssertEqual(clock.elapsed(now: 120_000), 0, "a carried show restarts the full window")
        clock.setPaused(false, now: 65_000)
        // Android extended the old window by the 60 s paused (80 s); the
        // answered prompt is the user's next step instead.
        XCTAssertNil(clock.expiredToken(now: 84_999))
        XCTAssertEqual(clock.expiredToken(now: 85_000), 7)
    }

    func test_answeringAPromptOrRetryRestartsTheWindow() {
        var clock = TmuxAuthorityIntentClock()
        clock.track(7, stepAt: 0)
        clock.userStep(now: 18_000)
        XCTAssertNil(clock.expiredToken(now: 37_999))
        XCTAssertEqual(clock.expiredToken(now: 38_000), 7)
        XCTAssertEqual(clock.elapsed(now: 20_000), 2_000)
    }

    func test_noIntentMeansNothingToExpire() {
        var clock = TmuxAuthorityIntentClock()
        clock.userStep(now: 1_000)
        XCTAssertNil(clock.expiredToken(now: 100_000))
        clock.track(7, stepAt: 0)
        clock.track(nil, stepAt: 1_000)
        XCTAssertNil(clock.expiredToken(now: 100_000))
        XCTAssertNil(clock.deadline)
        XCTAssertNil(clock.elapsed(now: 100_000))
    }

    func test_aCarriedStepKeepsOnlyWhatIsLeftOfItsWindow() {
        var clock = TmuxAuthorityIntentClock()
        // The show happened 5 s before it reached this session.
        clock.track(3, stepAt: 10_000)
        XCTAssertEqual(clock.elapsed(now: 15_000), 5_000)
        XCTAssertEqual(clock.remaining(now: 15_000), 15_000)
        XCTAssertEqual(clock.expiredToken(now: 30_000), 3)
    }
}
