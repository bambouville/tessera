import Foundation
import XCTest
@testable import TmuxControlCore

/// The two stateful helpers the session composes: the claim replay budget
/// (Android's `parkAuthorityClaimReplay`/`replayParkedAuthorityClaim`) and
/// the stamp-less judge's edges and deferred re-judge (Android's
/// `noteTmuxLayoutForStamplessPeer`).
final class AuthorityReplayAndJudgeTests: XCTestCase {
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer

    private let mac = TmuxGridAuthoritySnapshot.peer(deviceID: "MAC", displayName: "Mac", generation: 7)
    private let laptop = TmuxGridAuthoritySnapshot.peer(deviceID: "LAP", displayName: "Laptop", generation: 2)

    /// A real claim of `reason`, begun by the reducer over the Mac.
    private func claim(_ reason: Reducer.ClaimReason) -> Reducer.Claim {
        var reducer = Reducer()
        reducer.attached()
        reducer.observedAuthority(mac)
        let effects: [Reducer.Effect]
        switch reason {
        case .show, .explicitOpen:
            reducer.shown(source: reason == .show ? .show : .explicitOpen)
            effects = reducer.receivedAuthorityQuery(mac, geometry: .unknown)
        case .userTakeBack, .ownWriteWon:
            effects = reducer.requestTakeBack(channelLive: true)
        }
        for case .beginClaim(let claim) in effects { return claim }
        XCTFail("no claim")
        return reducer.claim!
    }

    // MARK: Claim replay

    func test_parkRefusesHiddenSpentAndExpired() {
        var replay = TmuxAuthorityClaimReplay()
        XCTAssertEqual(replay.park(claim(.show), stepAt: 0, hidden: true, now: 1_000), "hidden")
        XCTAssertEqual(replay.windowDeadline, 21_000, "the window starts at the first park, refused or not")
        XCTAssertNil(replay.parked)
        XCTAssertEqual(replay.park(claim(.show), stepAt: 0, hidden: false, now: 21_000), "window expired")
        replay.reset()
        XCTAssertNil(replay.park(claim(.show), stepAt: 0, hidden: false, now: 1_000))
        XCTAssertEqual(replay.parked?.stepAt, 0)
        for _ in 0..<8 {
            XCTAssertNil(replay.park(claim(.show), stepAt: 0, hidden: false, now: 1_000))
            guard case .show = replay.take(paintable: true, hidden: false, busy: false, authority: mac, now: 1_000) else {
                return XCTFail("replays within the budget")
            }
        }
        XCTAssertEqual(replay.park(claim(.show), stepAt: 0, hidden: false, now: 1_000), "budget spent")
    }

    func test_takeWaitsForAPaintableSurfaceAndDropsWhatNoLongerApplies() {
        var replay = TmuxAuthorityClaimReplay()
        XCTAssertEqual(replay.take(paintable: true, hidden: false, busy: false, authority: mac, now: 0), .wait)
        _ = replay.park(claim(.explicitOpen), stepAt: 0, hidden: false, now: 0)
        XCTAssertEqual(replay.take(paintable: false, hidden: false, busy: false, authority: mac, now: 100), .wait)
        guard case .show(_, let source) = replay.take(paintable: true, hidden: false, busy: false, authority: mac, now: 200) else {
            return XCTFail("an explicit open replays as one")
        }
        XCTAssertEqual(source, .explicitOpen)

        _ = replay.park(claim(.show), stepAt: 0, hidden: false, now: 300)
        guard case .dropped(_, "superseded") = replay.take(paintable: true, hidden: false, busy: true, authority: mac, now: 400) else {
            return XCTFail("a newer gesture supersedes it")
        }
        _ = replay.park(claim(.show), stepAt: 0, hidden: false, now: 500)
        guard case .dropped(_, "hidden") = replay.take(paintable: false, hidden: true, busy: false, authority: mac, now: 600) else {
            return XCTFail("never into a hidden session")
        }
    }

    func test_aTakeBackReplaysAgainstItsOwnPeerOnlyAndAsAShowWithNone() {
        var replay = TmuxAuthorityClaimReplay()
        _ = replay.park(claim(.userTakeBack), stepAt: 0, hidden: false, now: 0)
        guard case .takeBack = replay.take(paintable: true, hidden: false, busy: false, authority: mac, now: 100) else {
            return XCTFail("same peer: take back again")
        }
        _ = replay.park(claim(.userTakeBack), stepAt: 0, hidden: false, now: 200)
        guard case .dropped(_, "another peer") = replay.take(paintable: true, hidden: false, busy: false, authority: laptop, now: 300) else {
            return XCTFail("a different peer since the veil (R3)")
        }
        _ = replay.park(claim(.userTakeBack), stepAt: 0, hidden: false, now: 400)
        guard case .show(_, .show) = replay.take(paintable: true, hidden: false, busy: false, authority: .unknown, now: 500) else {
            return XCTFail("nobody holds it: the user asked for control")
        }
    }

    // MARK: Stamp-less judge

    private func evidence(
        blocked: Bool = false,
        window: TmuxGridSize? = .init(columns: 120, rows: 40),
        windowID: Int = 1,
        latest: Bool? = true,
        local: TmuxGridSize? = .init(columns: 92, rows: 38),
        replayAt: Int64? = nil
    ) -> TmuxStamplessPeerJudge.Evidence {
        .init(
            blocked: blocked,
            window: window.map { .init(windowID: windowID, size: $0) },
            policyIsLatest: latest,
            local: local,
            alreadyPeer: false,
            lastLocalReplayAt: replayAt
        )
    }

    func test_aBlockedEdgeStaysUnconsumed() {
        var judge = TmuxStamplessPeerJudge()
        XCTAssertEqual(judge.judge(evidence(blocked: true), now: 0), .nothing)
        XCTAssertNil(judge.lastJudged)
        XCTAssertEqual(judge.judge(evidence(), now: 0), .stamplessPeer, "judged once unblocked")
        XCTAssertEqual(judge.judge(evidence(), now: 10), .nothing, "one verdict per edge")
    }

    func test_aMatchingOrNonLatestLayoutNeverRaises() {
        var judge = TmuxStamplessPeerJudge()
        XCTAssertEqual(judge.judge(evidence(window: .init(columns: 92, rows: 38)), now: 0), .nothing)
        XCTAssertEqual(judge.judge(evidence(windowID: 2, latest: false), now: 0), .nothing)
        XCTAssertEqual(judge.judge(evidence(windowID: 3, latest: nil), now: 0), .nothing)
        XCTAssertNil(judge.nextDeadline, "nothing would pass after an echo window either")
    }

    func test_aVerdictInsideTheEchoWindowIsJudgedAgainOnlyForThatEdge() {
        var judge = TmuxStamplessPeerJudge()
        XCTAssertEqual(judge.judge(evidence(replayAt: 1_000), now: 1_500), .nothing)
        XCTAssertEqual(judge.nextDeadline, 3_050)
        XCTAssertFalse(judge.takeDueRejudge(now: 3_049))
        XCTAssertTrue(judge.takeDueRejudge(now: 3_050))
        XCTAssertEqual(judge.judge(evidence(replayAt: 1_000), now: 3_050), .stamplessPeer)

        var moved = TmuxStamplessPeerJudge()
        XCTAssertEqual(moved.judge(evidence(replayAt: 1_000), now: 1_500), .nothing)
        XCTAssertEqual(moved.judge(evidence(window: .init(columns: 92, rows: 38), replayAt: 1_000), now: 2_000), .nothing)
        XCTAssertFalse(moved.takeDueRejudge(now: 3_050), "a newer layout was judged on its own")
        XCTAssertNil(moved.nextDeadline)
    }
}
