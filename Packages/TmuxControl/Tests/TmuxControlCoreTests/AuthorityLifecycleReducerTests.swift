import Foundation
import XCTest
@testable import TmuxControlCore

/// The show rule (`docs/reviews/takeover-authority-review-2026-10-05.md` §6.9):
/// control moves only on a show or a veil tap. These tests pin every row of
/// the query decision table plus the intent, escape and contest mechanics.
final class AuthorityLifecycleReducerTests: XCTestCase {
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer
    private typealias Effect = TmuxGridAuthorityLifecycleReducer.Effect

    private func peer(
        _ deviceID: String = "ipad",
        _ generation: UInt64 = 7,
        _ name: String = "iPad"
    ) -> TmuxGridAuthoritySnapshot {
        .peer(deviceID: deviceID, displayName: name, generation: generation)
    }

    private func peerID(
        _ deviceID: String = "ipad",
        _ generation: UInt64 = 7,
        _ name: String = "iPad"
    ) -> Reducer.Peer {
        .init(deviceID: deviceID, displayName: name, generation: generation)
    }

    private var stampless: TmuxGridAuthoritySnapshot {
        .peer(deviceID: "-", displayName: "another device", generation: 0)
    }

    /// An attached reducer whose authority was observed on the server.
    private func live(_ authority: TmuxGridAuthoritySnapshot = .unknown) -> Reducer {
        Reducer(authority: authority, hasAttached: true)
    }

    private func claim(
        _ effects: [Effect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Reducer.Claim {
        for effect in effects {
            if case let .beginClaim(claim) = effect { return claim }
        }
        XCTFail("expected a begin-claim decision, got \(effects)", file: file, line: line)
        fatalError("unreachable after XCTest failure")
    }

    private func beginsClaim(_ effects: [Effect]) -> Bool {
        effects.contains { if case .beginClaim = $0 { return true } else { return false } }
    }

    private func walk(_ reducer: inout Reducer, to generation: UInt64) -> [Effect] {
        _ = reducer.fenceSucceeded(generation: generation)
        _ = reducer.repaintSucceeded(generation: generation)
        _ = reducer.stampCommitSucceeded(generation: generation)
        return reducer.settleClaim(generation: generation)
    }

    // MARK: - Nothing but a gesture claims (R5)

    func testAttachNeverClaimsAndEveryAttachQueries() {
        var reducer = Reducer()
        XCTAssertEqual(reducer.attached(), [.queryAuthority])
        XCTAssertNil(reducer.claim)
        XCTAssertTrue(reducer.hasAttached)
        XCTAssertTrue(reducer.channelAttached)
        XCTAssertEqual(reducer.snapshot.nextGeneration, 0)

        _ = reducer.resetTransport(preservingPeer: false)
        XCTAssertTrue(reducer.hasAttached)
        XCTAssertFalse(reducer.channelAttached)
        XCTAssertEqual(reducer.attached(), [.queryAuthority])
        XCTAssertNil(reducer.claim)

        var yielded = live(peer())
        _ = yielded.resetTransport(preservingPeer: true)
        XCTAssertEqual(yielded.attached(), [.queryAuthority])
        XCTAssertEqual(yielded.authority, peer())
        XCTAssertNil(yielded.claim)
    }

    /// D11: a process-death restore builds a fresh reducer. Its first attach
    /// only reads the stamp, whatever the stamp and geometry say.
    func testRestoreAttachFollowsTheStampAndNeverClaims() {
        for geometry in [Reducer.QueryGeometry.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown] {
            var restored = Reducer()
            _ = restored.attached()
            XCTAssertEqual(restored.receivedAuthorityQuery(peer(), geometry: geometry), [.authorityChanged(peer())])
            XCTAssertNil(restored.claim)
            XCTAssertEqual(restored.authority, peer())
        }
    }

    func testForegroundIsANonClaimingRederive() {
        var reducer = Reducer()
        XCTAssertEqual(reducer.foregrounded(), [], "an unattached session has nothing to read")

        _ = reducer.attached()
        XCTAssertEqual(reducer.foregrounded(), [.queryAuthority])
        XCTAssertEqual(
            reducer.receivedAuthorityQuery(.mine(generation: 4), geometry: .foreignSize),
            [.authorityChanged(stampless)]
        )
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.foregrounded(), [.queryAuthority])
        XCTAssertEqual(reducer.receivedAuthorityQuery(.unknown, geometry: .foreignSize), [.authorityChanged(.unknown)])
        XCTAssertNil(reducer.claim)

        var claiming = live(peer())
        let active = claim(claiming.requestTakeBack())
        for _ in 0..<3 { XCTAssertEqual(claiming.foregrounded(), [], "no query while a claim is in flight") }
        XCTAssertEqual(claiming.claim, active)

        _ = claiming.resetTransport(preservingPeer: true)
        XCTAssertEqual(claiming.foregrounded(), [], "no query while the channel is down")

        var showing = live(peer())
        XCTAssertEqual(showing.shown(source: .show), [.queryAuthority])
        XCTAssertEqual(showing.foregrounded(), [], "a pending show's own read decides it")
        XCTAssertNotNil(showing.pendingIntent)
    }

    /// No peer-departure or presence proof exists any more: while yielded and
    /// without a gesture, no observation, read or lifecycle event moves the
    /// grid, and none asks the adapter to prove anything.
    func testYieldedDeviceNeverClaimsWithoutAGesture() {
        var reducer = live(peer())
        var effects: [Effect] = []
        effects += reducer.attached()
        effects += reducer.foregrounded()
        for geometry in [Reducer.QueryGeometry.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown] {
            effects += reducer.receivedAuthorityQuery(peer(), geometry: geometry)
            effects += reducer.receivedAuthorityQuery(peer("phone", 3, "iPhone"), geometry: geometry)
        }
        effects += reducer.observedAuthority(peer("ipad", 9))
        effects += reducer.observedAuthority(.mine(generation: 2))
        effects += reducer.observedAuthority(.unknown)
        effects += reducer.resetTransport(preservingPeer: true)
        effects += reducer.attached()
        effects += reducer.receivedAuthorityQuery(.mine(generation: 2), geometry: .foreignSize)
        effects += reducer.receivedAuthorityQuery(.unknown, geometry: .atLocalSize)
        effects += reducer.observedOwnAuthorityStamp(generation: 2)
        effects += reducer.hidden()
        XCTAssertFalse(beginsClaim(effects), "\(effects)")
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.snapshot.nextGeneration, 0)
    }

    // MARK: - Query decision table without an intent

    func testQueryWithoutIntentFollowsTheStamp() {
        // .peer: yield, with no presence proof.
        var yielding = live(.mine(generation: 2))
        XCTAssertEqual(yielding.receivedAuthorityQuery(peer(), geometry: .atLocalSize), [.authorityChanged(peer())])
        XCTAssertEqual(yielding.authority, peer())
        XCTAssertEqual(yielding.receivedAuthorityQuery(peer(), geometry: .foreignSize), [])

        // .mine at the local size: ours, nothing else.
        var owner = live(peer())
        XCTAssertEqual(
            owner.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLocalSize),
            [.authorityChanged(.mine(generation: 2))]
        )
        XCTAssertEqual(owner.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLocalSize), [])

        // .mine at the size we last pushed: ordinary owner replay, not a claim.
        var resized = live(.mine(generation: 2))
        XCTAssertEqual(
            resized.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLastOwnedSize),
            [.replayOwnedGeometry]
        )
        XCTAssertNil(resized.claim)
        var resizedFromUnknown = live()
        XCTAssertEqual(
            resizedFromUnknown.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLastOwnedSize),
            [.authorityChanged(.mine(generation: 2)), .replayOwnedGeometry]
        )

        // .mine at a foreign size: a stamp-less client resized our window.
        // Yield to the fallback peer; claiming here is D5.
        var seized = live(.mine(generation: 2))
        XCTAssertEqual(
            seized.receivedAuthorityQuery(.mine(generation: 2), geometry: .foreignSize),
            [.authorityChanged(stampless)]
        )
        XCTAssertEqual(seized.authority.peerDisplayName, TmuxStamplessPeer.displayName)
        XCTAssertNil(seized.claim)
        XCTAssertEqual(seized.receivedAuthorityQuery(.mine(generation: 2), geometry: .foreignSize), [])
        XCTAssertEqual(
            Reducer.stamplessPeer,
            peerID("-", 0, "another device")
        )

        // .unknown: no claim, no geometry replay, even over a retained peer.
        for geometry in [Reducer.QueryGeometry.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown] {
            var empty = live(peer())
            XCTAssertEqual(empty.receivedAuthorityQuery(.unknown, geometry: geometry), [.authorityChanged(.unknown)])
            XCTAssertNil(empty.claim)
        }
    }

    /// No geometry evidence (slow hydration, a policy that never answered)
    /// cannot contradict our own stamp: it follows the stamp with no replay
    /// and never manufactures "another device". It cannot refute a yield
    /// that a foreign size already raised either.
    func testQueryWithoutIntentFollowsOurStampWhenGeometryIsUnknown() {
        var owner = live(.mine(generation: 2))
        XCTAssertEqual(owner.receivedAuthorityQuery(.mine(generation: 2), geometry: .unknown), [])
        XCTAssertEqual(owner.authority, .mine(generation: 2))

        for before in [TmuxGridAuthoritySnapshot.unknown, peer(), .mine(generation: 1)] {
            var reducer = live(before)
            XCTAssertEqual(
                reducer.receivedAuthorityQuery(.mine(generation: 2), geometry: .unknown),
                [.authorityChanged(.mine(generation: 2))],
                "\(before)"
            )
            XCTAssertEqual(reducer.authority, .mine(generation: 2))
            XCTAssertNil(reducer.claim)
            XCTAssertNil(reducer.pendingIntent)
        }

        var yielded = live(stampless)
        XCTAssertEqual(yielded.receivedAuthorityQuery(.mine(generation: 2), geometry: .unknown), [])
        XCTAssertEqual(yielded.authority, stampless, "unknown geometry cannot refute a foreign size")
        XCTAssertEqual(
            yielded.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLocalSize),
            [.authorityChanged(.mine(generation: 2))],
            "positive evidence at our size lifts the stamp-less yield"
        )
    }

    // MARK: - Query decision table with an intent

    func testShowAtOurOwnSizeResolvesWithZeroCommands() {
        var owner = live(.mine(generation: 3))
        XCTAssertEqual(owner.shown(), [.queryAuthority])
        XCTAssertNotNil(owner.pendingIntent)
        XCTAssertEqual(owner.receivedAuthorityQuery(.mine(generation: 3), geometry: .atLocalSize), [])
        XCTAssertNil(owner.pendingIntent)
        XCTAssertNil(owner.claim)
        XCTAssertEqual(owner.snapshot.nextGeneration, 0)

        // Under a retained veil, the fresh read lifts it without commands.
        var veiled = live(peer())
        _ = veiled.shown()
        XCTAssertEqual(
            veiled.receivedAuthorityQuery(.mine(generation: 3), geometry: .atLocalSize),
            [.authorityChanged(.mine(generation: 3))]
        )
        XCTAssertNil(veiled.pendingIntent)
        XCTAssertNil(veiled.claim)
    }

    func testShowClaimsWhenOursButNotAtOurSize() {
        for geometry in [Reducer.QueryGeometry.atLastOwnedSize, .foreignSize, .unknown] {
            var owner = live(.mine(generation: 3))
            _ = owner.shown()
            let effects = owner.receivedAuthorityQuery(.mine(generation: 3), geometry: geometry)
            let show = claim(effects)
            XCTAssertEqual(effects, [.beginClaim(show)])
            XCTAssertEqual(show.reason, .show)
            XCTAssertTrue(show.presentationVisible)
            XCTAssertNil(show.contestedPeer)
            XCTAssertEqual(show.phase, .awaitingFence)
            XCTAssertNil(owner.pendingIntent, "a sent claim ends the intent")
            XCTAssertEqual(owner.authority, .mine(generation: 3))
        }
    }

    func testShowClaimsWhenNoStampIsSet() {
        for geometry in [Reducer.QueryGeometry.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown] {
            var veiled = live(peer())
            _ = veiled.shown(source: .explicitOpen)
            let effects = veiled.receivedAuthorityQuery(.unknown, geometry: geometry)
            let open = claim(effects)
            XCTAssertEqual(effects, [.authorityChanged(.unknown), .beginClaim(open)])
            XCTAssertEqual(open.reason, .explicitOpen)
            XCTAssertNil(open.contestedPeer)
        }
    }

    func testShowClaimsAgainstTheSamePeerItSaw() {
        for geometry in [Reducer.QueryGeometry.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown] {
            var veiled = live(peer())
            _ = veiled.shown()
            let show = claim(veiled.receivedAuthorityQuery(peer(), geometry: geometry))
            XCTAssertEqual(show.contestedPeer, peerID())
            XCTAssertEqual(show.reason, .show)
            XCTAssertEqual(veiled.authority, peer(), "the veil stays until settlement")
        }
    }

    /// A show carries no baseline, so the fresh read decides alone: whichever
    /// peer it names, including one that wrote after the device last looked,
    /// is the peer the claim contests.
    func testShowClaimsAgainstWhicheverPeerTheFreshReadFinds() {
        let reads: [(TmuxGridAuthoritySnapshot, TmuxGridAuthoritySnapshot)] = [
            (peer("ipad", 7), peer("ipad", 8)),             // same device, new write
            (peer("ipad", 7), peer("phone", 1, "iPhone")),  // another device
            (peer("ipad", 7), peer("ipad", 6)),             // lower is still a new write
            (.mine(generation: 3), peer("ipad", 7)),        // we owned it before the show
            (stampless, peer("ipad", 7)),                   // a stamp after a laptop resize
            (.unknown, stampless),                          // a laptop resize after our stamp
        ]
        for (seen, read) in reads {
            var reducer = live(seen)
            _ = reducer.shown()
            let effects = reducer.receivedAuthorityQuery(read, geometry: .foreignSize)
            let show = claim(effects)
            XCTAssertEqual(effects, [.authorityChanged(read), .beginClaim(show)], "\(seen) -> \(read)")
            XCTAssertEqual(show.reason, .show)
            if case let .peer(deviceID, displayName, generation) = read {
                XCTAssertEqual(show.contestedPeer, Reducer.Peer(deviceID: deviceID, displayName: displayName, generation: generation))
            }
            XCTAssertNil(reducer.pendingIntent)
            XCTAssertEqual(reducer.authority, read, "the veil stays until settlement")
        }
    }

    /// A show made before any channel exists waits for the attach's read.
    func testColdShowWaitsForTheAttachReadAndClaims() {
        var cold = Reducer()
        XCTAssertEqual(cold.shown(), [], "no channel yet: the attach will read")
        XCTAssertEqual(cold.pendingIntent?.baselineKnown, false)
        XCTAssertNil(cold.pendingIntent?.baseline)
        XCTAssertEqual(cold.attached(), [.queryAuthority])
        let launch = claim(cold.receivedAuthorityQuery(peer("phone", 4, "iPhone"), geometry: .foreignSize))
        XCTAssertEqual(launch.reason, .show)
        XCTAssertEqual(launch.contestedPeer, peerID("phone", 4, "iPhone"))
    }

    func testIntentSourceSelectsTheClaimReason() {
        var shown = live(peer())
        _ = shown.shown(source: .show)
        XCTAssertEqual(claim(shown.receivedAuthorityQuery(peer(), geometry: .unknown)).reason, .show)

        var opened = live(peer())
        _ = opened.shown(source: .explicitOpen)
        XCTAssertEqual(opened.pendingIntent?.source, .explicitOpen)
        XCTAssertEqual(claim(opened.receivedAuthorityQuery(peer(), geometry: .unknown)).reason, .explicitOpen)

        var tapped = live(peer())
        XCTAssertEqual(tapped.requestTakeBack(channelLive: false), [])
        XCTAssertEqual(tapped.pendingIntent?.source, .tap)
        _ = tapped.attached()
        XCTAssertEqual(claim(tapped.receivedAuthorityQuery(peer(), geometry: .unknown)).reason, .userTakeBack)
    }

    func testStaleQueryReplyAfterAResetIsIgnored() {
        var reducer = live(peer())
        _ = reducer.shown()
        _ = reducer.resetTransport(preservingPeer: true)
        let before = reducer.snapshot
        XCTAssertEqual(reducer.receivedAuthorityQuery(.mine(generation: 1), geometry: .foreignSize), [])
        XCTAssertEqual(reducer.snapshot, before)
        XCTAssertNotNil(reducer.pendingIntent, "the intent waits for the replacement attach")
    }

    // MARK: - Intent mechanics (R1, R3)

    func testShowRecordsOneIntentAndQueriesOnlyOnALiveChannel() {
        var reducer = live(peer())
        XCTAssertEqual(reducer.shown(), [.queryAuthority])
        let intent = try! XCTUnwrap(reducer.pendingIntent)
        XCTAssertEqual(intent.token, 1)
        XCTAssertEqual(intent.source, .show)
        XCTAssertNil(intent.baseline, "a show never binds what it saw")
        XCTAssertFalse(intent.baselineKnown)
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.snapshot.nextGeneration, 0, "an intent is not a claim")

        _ = reducer.resetTransport(preservingPeer: true)
        XCTAssertEqual(reducer.shown(source: .explicitOpen), [], "the attach reads authority")
        XCTAssertEqual(reducer.pendingIntent, Reducer.Intent(token: 2, source: .explicitOpen, baseline: nil, baselineKnown: false))
    }

    func testANewerIntentReplacesTheOlderOne() {
        var reducer = live(peer())
        _ = reducer.shown()
        _ = reducer.shown(source: .explicitOpen)
        XCTAssertEqual(reducer.pendingIntent?.token, 2)
        XCTAssertEqual(reducer.pendingIntent?.source, .explicitOpen)
        _ = reducer.requestTakeBack(channelLive: false)
        XCTAssertEqual(reducer.pendingIntent?.token, 3)
        XCTAssertEqual(reducer.pendingIntent?.source, .tap)
        XCTAssertEqual(reducer.intentExpired(token: 2), [], "the replaced token no longer names it")
        XCTAssertEqual(reducer.pendingIntent?.token, 3)
        _ = reducer.shown()
        XCTAssertEqual(reducer.pendingIntent?.token, 4)
        XCTAssertEqual(reducer.pendingIntent?.source, .show)
        XCTAssertEqual(reducer.snapshot.nextIntentToken, 4)
    }

    func testHideDropsAnUnsentIntentButNotAnInFlightClaim() {
        var pending = live(peer())
        _ = pending.shown()
        let before = pending.snapshot
        XCTAssertEqual(pending.hidden(), [])
        XCTAssertNil(pending.pendingIntent)
        XCTAssertNotNil(Reducer.describeTransition(
            event: "hidden", before: before, after: pending.snapshot, effects: []
        ))
        XCTAssertFalse(beginsClaim(pending.receivedAuthorityQuery(peer(), geometry: .foreignSize)))
        XCTAssertNil(pending.claim)

        var claiming = live(peer())
        _ = claiming.shown()
        let show = claim(claiming.receivedAuthorityQuery(peer(), geometry: .foreignSize))
        let claimingBefore = claiming.snapshot
        XCTAssertEqual(claiming.hidden(), [])
        XCTAssertEqual(claiming.snapshot, claimingBefore)
        XCTAssertNil(Reducer.describeTransition(
            event: "hidden", before: claimingBefore, after: claiming.snapshot, effects: []
        ))
        XCTAssertTrue(walk(&claiming, to: show.generation).contains(.claimSettled(generation: show.generation)))
        XCTAssertEqual(claiming.authority, .mine(generation: show.generation))
    }

    func testIntentExpiryMatchesItsToken() {
        var reducer = live(peer())
        _ = reducer.shown()
        let token = try! XCTUnwrap(reducer.pendingIntent?.token)
        let before = reducer.snapshot
        XCTAssertEqual(reducer.intentExpired(token: token + 1), [])
        XCTAssertEqual(reducer.snapshot, before)
        XCTAssertEqual(reducer.intentExpired(token: token), [])
        XCTAssertNil(reducer.pendingIntent)
        XCTAssertEqual(reducer.intentExpired(token: token), [])
        XCTAssertFalse(beginsClaim(reducer.receivedAuthorityQuery(peer(), geometry: .foreignSize)))
    }

    /// Regression: "resume shows the terminal". iPad B owned the grid and
    /// went to the background with its transport alive; the phone claimed
    /// meanwhile and its stamp change sat unread in B's socket. On foreground
    /// B shows, and only then reads the buffered line. That line predates the
    /// show, so it must not cancel it: the read the show requested claims.
    func testBufferedForeignStampDeliveredAfterAShowCannotCancelIt() {
        let phone = peer("phone", 4, "iPhone")
        var ipad = live(.mine(generation: 3))
        XCTAssertEqual(ipad.foregrounded(), [.queryAuthority])
        XCTAssertEqual(ipad.shown(), [.queryAuthority])
        let intent = try! XCTUnwrap(ipad.pendingIntent)

        // The buffered `%subscription-changed`: projected, the intent intact.
        XCTAssertEqual(ipad.observedAuthority(phone), [.authorityChanged(phone)])
        XCTAssertEqual(ipad.authority, phone, "the snapshot stays truthful")
        XCTAssertEqual(ipad.pendingIntent, intent)
        XCTAssertNil(ipad.claim)

        // tmux orders the reply after everything queued before the query.
        let effects = ipad.receivedAuthorityQuery(phone, geometry: .foreignSize)
        let resume = claim(effects)
        XCTAssertEqual(effects, [.beginClaim(resume)])
        XCTAssertEqual(resume.reason, .show)
        XCTAssertEqual(resume.contestedPeer, peerID("phone", 4, "iPhone"))
        XCTAssertTrue(resume.presentationVisible)
        XCTAssertNil(ipad.pendingIntent)
        XCTAssertTrue(walk(&ipad, to: resume.generation).contains(.claimSettled(generation: resume.generation)))
        XCTAssertEqual(ipad.authority, .mine(generation: resume.generation))

        // A line lagging on tmux's 1 s subscription timer is no different.
        var veiled = live(peer("ipad", 7))
        _ = veiled.shown(source: .explicitOpen)
        _ = veiled.observedAuthority(peer("ipad", 6))
        _ = veiled.observedAuthority(peer("ipad", 8))
        XCTAssertNotNil(veiled.pendingIntent)
        XCTAssertEqual(claim(veiled.receivedAuthorityQuery(peer("ipad", 8), geometry: .foreignSize)).contestedPeer,
                       peerID("ipad", 8))
    }

    /// Any number of live observations leave a show intent exactly as it was;
    /// only the reply resolves it, by the R2 table.
    func testPendingShowIntentSurvivesEveryLiveObservationUntilTheReply() {
        let stream: [TmuxGridAuthoritySnapshot] = [
            peer("phone", 1, "iPhone"), peer("phone", 2, "iPhone"), .mine(generation: 9), .unknown,
            stampless, peer("ipad", 7), peer("ipad", 7), .mine(generation: 1), peer("laptop", 3, "Mac"),
        ]
        for source in [Reducer.ShowSource.show, .explicitOpen] {
            for start in [TmuxGridAuthoritySnapshot.unknown, .mine(generation: 3), peer()] {
                var reducer = live(start)
                _ = reducer.shown(source: source)
                let intent = try! XCTUnwrap(reducer.pendingIntent)
                for round in 0..<40 {
                    _ = reducer.observedAuthority(stream[round % stream.count])
                    XCTAssertEqual(reducer.pendingIntent, intent, "\(source) from \(start), round \(round)")
                    XCTAssertNil(reducer.claim)
                }
                // The R2 table at the reply.
                var atSize = reducer
                XCTAssertFalse(beginsClaim(atSize.receivedAuthorityQuery(.mine(generation: 1), geometry: .atLocalSize)))
                XCTAssertNil(atSize.pendingIntent)
                var notAtSize = reducer
                XCTAssertTrue(beginsClaim(notAtSize.receivedAuthorityQuery(.mine(generation: 1), geometry: .atLastOwnedSize)))
                var empty = reducer
                XCTAssertTrue(beginsClaim(empty.receivedAuthorityQuery(.unknown, geometry: .atLocalSize)))
                var foreign = reducer
                let contested = claim(foreign.receivedAuthorityQuery(peer("laptop", 3, "Mac"), geometry: .atLocalSize))
                XCTAssertEqual(contested.contestedPeer, peerID("laptop", 3, "Mac"))
                XCTAssertEqual(contested.reason, source == .show ? .show : .explicitOpen)
            }
        }
    }

    /// A pending intent survives a reconnect (X2) unchanged: a show has no
    /// baseline to go stale, and a tap stays bound to the veil it named.
    func testIntentsSurviveATransportResetUnchanged() {
        for preservingPeer in [false, true] {
            var owner = live(.mine(generation: 3))
            _ = owner.shown()
            let show = try! XCTUnwrap(owner.pendingIntent)
            _ = owner.resetTransport(preservingPeer: preservingPeer)
            XCTAssertEqual(owner.pendingIntent, show)
            _ = owner.attached()
            XCTAssertEqual(claim(owner.receivedAuthorityQuery(peer("phone", 2, "iPhone"), geometry: .foreignSize)).contestedPeer,
                           peerID("phone", 2, "iPhone"))

            var tapped = live(peer())
            _ = tapped.requestTakeBack(channelLive: false)
            let tap = try! XCTUnwrap(tapped.pendingIntent)
            XCTAssertEqual(tap.baseline, peerID())
            XCTAssertTrue(tap.baselineKnown)
            _ = tapped.resetTransport(preservingPeer: preservingPeer)
            XCTAssertEqual(tapped.pendingIntent, tap, "preservingPeer=\(preservingPeer)")
            _ = tapped.attached()
            XCTAssertEqual(claim(tapped.receivedAuthorityQuery(peer(), geometry: .foreignSize)).reason, .userTakeBack)

            var displaced = live(peer())
            _ = displaced.requestTakeBack(channelLive: false)
            _ = displaced.resetTransport(preservingPeer: preservingPeer)
            _ = displaced.attached()
            XCTAssertFalse(beginsClaim(displaced.receivedAuthorityQuery(peer("phone", 2, "iPhone"), geometry: .foreignSize)))
            XCTAssertNil(displaced.pendingIntent)
        }

        // A show made while the channel was already down binds nothing either.
        var asleep = live(.mine(generation: 3))
        _ = asleep.resetTransport(preservingPeer: false)
        _ = asleep.shown()
        XCTAssertEqual(asleep.pendingIntent?.baselineKnown, false)
    }

    // MARK: - Veil taps (R4)

    func testTapOnALiveChannelClaimsImmediately() {
        var reducer = live(peer())
        let tap = claim(reducer.requestTakeBack())
        XCTAssertEqual(tap.reason, .userTakeBack)
        XCTAssertTrue(tap.presentationVisible)
        XCTAssertEqual(tap.contestedPeer, peerID())
        XCTAssertNil(reducer.pendingIntent)
        XCTAssertEqual(reducer.authority, peer())

        // A tap also consumes a show intent still waiting for its read.
        var showing = live(peer())
        _ = showing.shown()
        _ = claim(showing.requestTakeBack())
        XCTAssertNil(showing.pendingIntent)
        XCTAssertEqual(showing.receivedAuthorityQuery(peer(), geometry: .foreignSize), [])
    }

    func testTapNeedsAVeil() {
        for authority in [TmuxGridAuthoritySnapshot.unknown, .mine(generation: 1)] {
            var reducer = live(authority)
            let before = reducer.snapshot
            XCTAssertEqual(reducer.requestTakeBack(), [])
            XCTAssertEqual(reducer.requestTakeBack(channelLive: false), [])
            XCTAssertEqual(reducer.snapshot, before)
        }
    }

    /// D12: a tap without a live channel is an intent bound to the peer the
    /// veil named, not a claim retained forever.
    func testTapWithoutALiveChannelWaitsForTheNextReadAndBindsItsPeer() {
        var gap = live(peer())
        XCTAssertEqual(gap.requestTakeBack(channelLive: false), [])
        XCTAssertNil(gap.claim)
        XCTAssertEqual(gap.pendingIntent?.source, .tap)
        XCTAssertEqual(gap.pendingIntent?.baseline, peerID())
        _ = gap.attached()
        XCTAssertEqual(claim(gap.receivedAuthorityQuery(peer(), geometry: .unknown)).reason, .userTakeBack)

        var worked = live(peer())
        _ = worked.resetTransport(preservingPeer: true)
        XCTAssertEqual(worked.requestTakeBack(), [], "a reset channel is not live")
        XCTAssertEqual(worked.pendingIntent?.source, .tap)
        _ = worked.attached()
        XCTAssertFalse(
            beginsClaim(worked.receivedAuthorityQuery(peer("ipad", 8), geometry: .unknown)),
            "the peer kept working during the gap: the late tap must not fire"
        )

        // The first live observation after re-attach is current, unlike a
        // line buffered across a show: a different peer ends the tap.
        var observed = live(peer())
        _ = observed.resetTransport(preservingPeer: true)
        _ = observed.requestTakeBack()
        _ = observed.attached()
        XCTAssertEqual(observed.observedAuthority(peer()), [], "the tapped veil's own stamp keeps it")
        XCTAssertEqual(observed.pendingIntent?.source, .tap)
        XCTAssertEqual(observed.observedAuthority(.mine(generation: 2)), [], "an own echo never lifts the veil")
        XCTAssertEqual(observed.pendingIntent?.source, .tap)
        XCTAssertEqual(observed.observedAuthority(peer("phone", 1, "iPhone")), [.authorityChanged(peer("phone", 1, "iPhone"))])
        XCTAssertNil(observed.pendingIntent)
        XCTAssertFalse(beginsClaim(observed.receivedAuthorityQuery(peer("phone", 1, "iPhone"), geometry: .unknown)))

        var expired = live(peer())
        _ = expired.requestTakeBack(channelLive: false)
        _ = expired.intentExpired(token: expired.pendingIntent!.token)
        _ = expired.attached()
        XCTAssertFalse(beginsClaim(expired.receivedAuthorityQuery(peer(), geometry: .unknown)))
    }

    func testRepeatedTapsOnAVisibleClaimAreNoOps() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        let current = reducer.snapshot
        for _ in 0..<8 {
            XCTAssertEqual(reducer.requestTakeBack(), [])
            XCTAssertEqual(reducer.shown(), [])
            XCTAssertEqual(reducer.snapshot, current)
        }
        XCTAssertEqual(reducer.fenceSucceeded(generation: active.generation), [.requestRepaint(generation: active.generation)])
    }

    // MARK: - S4′ escape

    func testTapOnATimedOutClaimRestartsItUnderANewGeneration() {
        var reducer = live(peer())
        let stale = claim(reducer.requestTakeBack())
        _ = reducer.fenceSucceeded(generation: stale.generation)
        XCTAssertEqual(reducer.presentationTimedOut(generation: stale.generation), [.hideReclaimPresentation])

        let effects = reducer.requestTakeBack()
        let fresh = claim(effects)
        XCTAssertEqual(effects, [.claimAborted(.superseded), .beginClaim(fresh)])
        XCTAssertGreaterThan(fresh.generation, stale.generation)
        XCTAssertEqual(fresh.reason, .userTakeBack)
        XCTAssertTrue(fresh.presentationVisible)
        XCTAssertEqual(fresh.phase, .awaitingFence)
        XCTAssertEqual(fresh.contestedPeer, peerID())

        // Late acks for the abandoned generation change nothing.
        let current = reducer.snapshot
        XCTAssertEqual(reducer.presentationTimedOut(generation: stale.generation), [])
        XCTAssertEqual(reducer.fenceSucceeded(generation: stale.generation), [])
        XCTAssertEqual(reducer.repaintSucceeded(generation: stale.generation), [])
        XCTAssertEqual(reducer.stampCommitSucceeded(generation: stale.generation), [])
        XCTAssertEqual(reducer.settleClaim(generation: stale.generation), [])
        XCTAssertEqual(reducer.abortClaim(generation: stale.generation), [])
        XCTAssertEqual(reducer.observedOwnAuthorityStamp(generation: stale.generation), [])
        XCTAssertEqual(reducer.observedAuthority(.mine(generation: stale.generation)), [])
        XCTAssertEqual(reducer.snapshot, current)

        XCTAssertEqual(walk(&reducer, to: fresh.generation), [
            .authorityChanged(.mine(generation: fresh.generation)),
            .hideReclaimPresentation,
            .claimSettled(generation: fresh.generation),
        ])
    }

    func testShowOnATimedOutClaimRestartsItWithTheShowReason() {
        var reducer = live(peer())
        _ = reducer.shown()
        let stale = claim(reducer.receivedAuthorityQuery(peer(), geometry: .foreignSize))
        _ = reducer.presentationTimedOut(generation: stale.generation)
        let effects = reducer.shown(source: .explicitOpen)
        let fresh = claim(effects)
        XCTAssertEqual(effects, [.claimAborted(.superseded), .beginClaim(fresh)])
        XCTAssertEqual(fresh.reason, .explicitOpen)
        XCTAssertTrue(fresh.presentationVisible)
        XCTAssertNil(reducer.pendingIntent, "the restarted claim satisfies the show")
    }

    func testTapOnATimedOutClaimWithoutALiveChannelAbandonsItAndWaits() {
        var reducer = live(peer())
        let stale = claim(reducer.requestTakeBack())
        _ = reducer.presentationTimedOut(generation: stale.generation)
        XCTAssertEqual(reducer.requestTakeBack(channelLive: false), [.claimAborted(.superseded)])
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.pendingIntent?.source, .tap)
        XCTAssertEqual(reducer.fenceSucceeded(generation: stale.generation), [])
        _ = reducer.attached()
        XCTAssertEqual(claim(reducer.receivedAuthorityQuery(peer(), geometry: .unknown)).reason, .userTakeBack)
    }

    /// D46, the "both ends dark" guard. Without a second gesture, a claim
    /// whose presentation timed out still walks its own chain to settlement.
    func testTimedOutClaimStillSettlesOnItsOwnGeneration() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        XCTAssertEqual(reducer.presentationTimedOut(generation: active.generation), [.hideReclaimPresentation])
        XCTAssertEqual(reducer.presentationTimedOut(generation: active.generation), [])
        XCTAssertTrue(walk(&reducer, to: active.generation).contains(.claimSettled(generation: active.generation)))
        XCTAssertNil(reducer.claim)
        XCTAssertFalse(reducer.authority.isPeer, "the veil must lift on the late success")
    }

    // MARK: - Claim chain and contests

    func testFenceRepaintCommitAndSettlementRequireTheLiveGenerationInOrder() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        XCTAssertTrue(reducer.repaintSucceeded(generation: active.generation).isEmpty)
        XCTAssertEqual(reducer.fenceSucceeded(generation: active.generation), [.requestRepaint(generation: active.generation)])
        XCTAssertEqual(
            reducer.repaintSucceeded(generation: active.generation),
            [.commitAuthorityStamp(generation: active.generation)]
        )
        XCTAssertTrue(reducer.settleClaim(generation: active.generation).isEmpty)
        XCTAssertTrue(reducer.stampCommitSucceeded(generation: active.generation).isEmpty)
        XCTAssertEqual(reducer.claim?.phase, .awaitingSettlement)

        let settled = reducer.settleClaim(generation: active.generation)
        XCTAssertEqual(reducer.authority, .mine(generation: active.generation))
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(settled.last, .claimSettled(generation: active.generation))
    }

    /// `latest` taken after the claim confirmed (`claimGeometryLost`, for
    /// adapters that decide a loss themselves): the first loss re-fences,
    /// a second loss in the same generation aborts (§6.10 rule 4), and every
    /// other phase ignores the event.
    func testGeometryLossAfterConfirmationRefencesOnceThenAborts() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        let generation = active.generation

        XCTAssertEqual(reducer.claimGeometryLost(generation: generation), [], "not confirmed yet")
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence)
        XCTAssertEqual(reducer.claim?.geometryRefenced, false)

        XCTAssertEqual(reducer.fenceSucceeded(generation: generation), [.requestRepaint(generation: generation)])
        XCTAssertEqual(reducer.claimGeometryLost(generation: generation + 1), [], "another generation")
        XCTAssertEqual(reducer.claim?.phase, .awaitingRepaint)

        XCTAssertEqual(reducer.claimGeometryLost(generation: generation), [.refenceClaim(generation: generation)])
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence)
        XCTAssertEqual(reducer.claim?.geometryRefenced, true)
        XCTAssertEqual(reducer.claim?.traceLabel, "g\(generation):userTakeBack/awaitingFence/refenced vs ipad/iPad#7")
        XCTAssertEqual(reducer.repaintSucceeded(generation: generation), [], "the lost repaint cannot commit")
        XCTAssertEqual(reducer.authority, peer(), "a loss neither aborts nor changes the veil")

        XCTAssertEqual(reducer.fenceSucceeded(generation: generation), [.requestRepaint(generation: generation)])
        XCTAssertEqual(
            reducer.claimGeometryLost(generation: generation),
            [.hideReclaimPresentation, .claimAborted(.geometryLost)],
            "one re-fence per generation"
        )
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.authority, peer(), "the veil stays")
        XCTAssertEqual(reducer.fenceSucceeded(generation: generation), [], "its late acks are ignored")

        // Once the stamp is on the wire, nothing is lost any more.
        var stamping = live(peer())
        let committed = claim(stamping.requestTakeBack())
        _ = stamping.fenceSucceeded(generation: committed.generation)
        XCTAssertEqual(stamping.repaintSucceeded(generation: committed.generation),
                       [.commitAuthorityStamp(generation: committed.generation)])
        XCTAssertEqual(stamping.claimGeometryLost(generation: committed.generation), [], "the stamp is on the wire")
        XCTAssertEqual(stamping.claim?.phase, .awaitingStampCommit)
        XCTAssertEqual(stamping.stampCommitSucceeded(generation: committed.generation), [])
        XCTAssertEqual(stamping.claimGeometryLost(generation: committed.generation), [])
        XCTAssertEqual(stamping.settleClaim(generation: committed.generation).last,
                       .claimSettled(generation: committed.generation))
        XCTAssertEqual(stamping.authority, .mine(generation: committed.generation))
        XCTAssertEqual(stamping.claimGeometryLost(generation: committed.generation), [], "no claim")
    }

    /// The bound is per generation: the tap that restarts a claim given up
    /// on its second loss may re-fence once more. A peer's stamp still
    /// contests a claim that is waiting on its re-fence.
    func testARestartedClaimMayRefenceAgainAndAPeerStampStillContestsIt() {
        var reducer = live(peer())
        let first = claim(reducer.requestTakeBack())
        _ = reducer.fenceSucceeded(generation: first.generation)
        _ = reducer.claimGeometryLost(generation: first.generation)
        _ = reducer.fenceSucceeded(generation: first.generation)
        XCTAssertEqual(
            reducer.claimGeometryLost(generation: first.generation),
            [.hideReclaimPresentation, .claimAborted(.geometryLost)]
        )
        XCTAssertNil(reducer.claim, "no late success for a claim that spent its re-fence")

        let restart = reducer.requestTakeBack()
        XCTAssertFalse(restart.contains(.claimAborted(.superseded)), "nothing left to supersede: \(restart)")
        let second = claim(restart)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertFalse(second.geometryRefenced)
        _ = reducer.fenceSucceeded(generation: second.generation)
        XCTAssertEqual(
            reducer.claimGeometryLost(generation: second.generation),
            [.refenceClaim(generation: second.generation)]
        )
        XCTAssertTrue(reducer.observedAuthority(peer("phone", 1, "iPhone"))
            .contains(.claimAborted(.contestedByPeer(peerID("phone", 1, "iPhone")))))
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.authority, peer("phone", 1, "iPhone"))
    }

    /// §6.10 rule 1: the deadline only hides, in every phase, re-fenced or
    /// not, and the late claim completes on its own acks.
    func testThePresentationTimeoutOnlyHidesAndTheLateClaimSettlesOnItsOwnAcks() {
        enum Stage: CaseIterable { case fencing, refenced, refencedAndConfirmed, stamping }
        for stage in Stage.allCases {
            var reducer = live(peer())
            let active = claim(reducer.requestTakeBack())
            let generation = active.generation
            switch stage {
            case .fencing:
                break
            case .refenced, .refencedAndConfirmed:
                _ = reducer.fenceSucceeded(generation: generation)
                _ = reducer.claimGeometryLost(generation: generation)
                if stage == .refencedAndConfirmed { _ = reducer.fenceSucceeded(generation: generation) }
            case .stamping:
                _ = reducer.fenceSucceeded(generation: generation)
                _ = reducer.repaintSucceeded(generation: generation)
            }
            let phase = reducer.claim?.phase
            XCTAssertEqual(reducer.presentationTimedOut(generation: generation), [.hideReclaimPresentation], "\(stage)")
            XCTAssertEqual(reducer.claim?.phase, phase, "\(stage)")
            XCTAssertEqual(reducer.claim?.presentationVisible, false, "\(stage)")
            XCTAssertFalse(reducer.claimMayAdvertiseGeometry, "\(stage)")
            XCTAssertEqual(reducer.presentationTimedOut(generation: generation), [], "\(stage): once")
            XCTAssertTrue(walk(&reducer, to: generation).contains(.claimSettled(generation: generation)), "\(stage)")
            XCTAssertEqual(reducer.authority, .mine(generation: generation), "\(stage)")
        }
        var waiting = live(peer())
        let unlost = claim(waiting.requestTakeBack())
        _ = waiting.presentationTimedOut(generation: unlost.generation)
        XCTAssertEqual(waiting.claim?.traceLabel, "g\(unlost.generation):userTakeBack/awaitingFence/hidden vs ipad/iPad#7")
    }

    /// A loss after the presentation timed out gives the claim up at once:
    /// the veil is back, nobody asked again, and a late claim may advertise
    /// nothing, so it never re-fences.
    func testALossAfterThePresentationTimedOutAbortsWithoutRefencing() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        XCTAssertEqual(reducer.presentationTimedOut(generation: active.generation), [.hideReclaimPresentation])
        XCTAssertEqual(reducer.fenceSucceeded(generation: active.generation), [.requestRepaint(generation: active.generation)],
                       "a late confirmation still proceeds")
        XCTAssertEqual(
            reducer.claimGeometryLost(generation: active.generation),
            [.hideReclaimPresentation, .claimAborted(.geometryLost)]
        )
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.authority, peer())
        XCTAssertEqual(
            Reducer.Effect.claimAborted(.geometryLost).traceLabel, "claimAborted(geometryLost)"
        )
    }

    // MARK: - §6.10: advertised geometry, observations, stalls

    private func grid(_ columns: Int, _ rows: Int) -> Reducer.Grid {
        .init(columns: columns, rows: rows)
    }

    /// Rule 2's predicate: a live claim whose presentation is visible. Not
    /// `claim != nil`.
    func testOnlyAVisibleClaimMayAdvertiseGeometry() {
        var reducer = live(peer())
        XCTAssertFalse(reducer.claimMayAdvertiseGeometry, "no claim")
        let first = claim(reducer.requestTakeBack())
        XCTAssertTrue(reducer.claimMayAdvertiseGeometry)
        _ = reducer.presentationTimedOut(generation: first.generation)
        XCTAssertNotNil(reducer.claim)
        XCTAssertFalse(reducer.claimMayAdvertiseGeometry, "a late claim advertises nothing")
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: first.generation, columns: 80, rows: 24), [])
        XCTAssertEqual(reducer.claim?.advertisedGrids, [], "I1: a late claim's grids do not grow")
        XCTAssertNil(reducer.claim?.targetGrid)

        let second = claim(reducer.requestTakeBack())
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertTrue(reducer.claimMayAdvertiseGeometry, "a re-tap starts a new generation that may")
        _ = walk(&reducer, to: second.generation)
        XCTAssertFalse(reducer.claimMayAdvertiseGeometry, "settled")
    }

    /// Rule 3: every advertised grid is recorded; the latest is the target.
    /// A confirmed claim re-targets back to `awaitingFence`; past the
    /// repaint it only records.
    func testAdvertisedGeometryRecordsEveryGridAndRetargetsBeforeTheStamp() {
        var reducer = live(peer())
        let generation = claim(reducer.requestTakeBack()).generation
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 38), [])
        XCTAssertEqual(reducer.claim?.targetGrid, grid(92, 38))
        XCTAssertEqual(reducer.claim?.traceLabel, "g\(generation):userTakeBack/awaitingFence(92x38) vs ipad/iPad#7")
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation + 1, columns: 1, rows: 1), [], "another generation")
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation, columns: 0, rows: 20), [], "no grid")
        XCTAssertEqual(reducer.claim?.advertisedGrids, [grid(92, 38)])

        _ = reducer.fenceSucceeded(generation: generation)
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 20), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence, "the repaint in flight shows the old grid")
        XCTAssertEqual(reducer.claim?.targetGrid, grid(92, 20))
        XCTAssertEqual(reducer.claim?.geometryRefenced, false, "our own churn spends nothing")
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 38), [])
        XCTAssertEqual(reducer.claim?.advertisedGrids, [grid(92, 20), grid(92, 38)], "deduplicated, newest last")

        _ = reducer.fenceSucceeded(generation: generation)
        _ = reducer.repaintSucceeded(generation: generation)
        XCTAssertEqual(reducer.claimAdvertisedGeometry(generation: generation, columns: 100, rows: 30), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingStampCommit, "the stamp is on the wire")
        XCTAssertEqual(reducer.claim?.targetGrid, grid(92, 38))
        XCTAssertEqual(reducer.claim?.advertisedGrids.last, grid(100, 30))

        // Keyboard animation: one grid per frame. The oldest go first, never
        // the target.
        var animated = live(peer())
        let animatedGeneration = claim(animated.requestTakeBack()).generation
        _ = animated.claimAdvertisedGeometry(generation: animatedGeneration, columns: 92, rows: 38)
        _ = animated.fenceSucceeded(generation: animatedGeneration)
        _ = animated.repaintSucceeded(generation: animatedGeneration)
        // The frames never pass through the target, so it is the oldest.
        for rows in 1...30 {
            _ = animated.claimAdvertisedGeometry(generation: animatedGeneration, columns: 80, rows: rows)
        }
        XCTAssertEqual(animated.claim?.advertisedGrids.count, Reducer.maximumAdvertisedGrids)
        XCTAssertEqual(animated.claim?.advertisedGrids.first, grid(92, 38), "the target stays")
        XCTAssertEqual(animated.claim?.advertisedGrids.dropFirst().first, grid(80, 16), "the oldest frames went")
        XCTAssertEqual(animated.claim?.advertisedGrids.last, grid(80, 30))
        XCTAssertEqual(animated.claim?.targetGrid, grid(92, 38))
        XCTAssertTrue(animated.claim?.hasAdvertisedGrid(grid(80, 1)) == true)

        // The same truncation before stamping must not turn an evicted
        // keyboard frame into a landed foreign observation.
        var observing = live(peer())
        let observingGeneration = claim(observing.requestTakeBack()).generation
        for rows in 1...30 {
            _ = observing.claimAdvertisedGeometry(generation: observingGeneration, columns: 80, rows: rows)
        }
        _ = observing.claimObservedGeometry(generation: observingGeneration, columns: 80, rows: 30, settleProbe: true)
        _ = observing.fenceSucceeded(generation: observingGeneration)
        XCTAssertFalse(observing.claim!.advertisedGrids.contains(grid(80, 1)))
        XCTAssertEqual(observing.claimObservedGeometry(generation: observingGeneration, columns: 80, rows: 1, settleProbe: false), [])
        XCTAssertEqual(observing.claim?.phase, .awaitingFence)
        XCTAssertEqual(observing.claim?.geometryRefenced, false)
    }

    /// Rules 3–5: our own grids are unsettled, never lost; a foreign size
    /// is stale until the settle probe lands the geometry, then a loss.
    func testObservedGeometryTellsOurSizesAndStaleLayoutsFromALoss() {
        var reducer = live(peer())
        let generation = claim(reducer.requestTakeBack()).generation
        _ = reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 38)
        _ = reducer.fenceSucceeded(generation: generation)

        XCTAssertEqual(reducer.claimObservedGeometry(generation: generation, columns: 92, rows: 38, settleProbe: false), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingRepaint, "at the target nothing changes")

        // A peer's resize from the same server pass as our fence.
        XCTAssertEqual(reducer.claimObservedGeometry(generation: generation, columns: 105, rows: 31, settleProbe: false), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence, "unsettled: the repaint is dropped")
        XCTAssertEqual(reducer.claim?.geometryRefenced, false, "a stale layout spends nothing")
        XCTAssertEqual(reducer.claim?.geometryLanded, false)

        // The probe lands our geometry; the window is back at the target.
        XCTAssertEqual(reducer.claimObservedGeometry(generation: generation, columns: 92, rows: 38, settleProbe: true), [])
        XCTAssertEqual(reducer.claim?.geometryLanded, true)
        XCTAssertEqual(reducer.claim?.traceLabel, "g\(generation):userTakeBack/awaitingFence(92x38)/landed vs ipad/iPad#7")
        _ = reducer.fenceSucceeded(generation: generation)

        // M2kb: a keyboard frame's echo, a grid we advertised, after landing.
        _ = reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 20)
        _ = reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: 38)
        _ = reducer.claimObservedGeometry(generation: generation, columns: 92, rows: 38, settleProbe: true)
        _ = reducer.fenceSucceeded(generation: generation)
        XCTAssertEqual(reducer.claimObservedGeometry(generation: generation, columns: 92, rows: 20, settleProbe: false), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence)
        XCTAssertEqual(reducer.claim?.geometryRefenced, false, "our own size is never a loss")

        // A foreign size after landing: the one re-fence, then an abort.
        XCTAssertEqual(
            reducer.claimObservedGeometry(generation: generation, columns: 105, rows: 31, settleProbe: false),
            [.refenceClaim(generation: generation)]
        )
        XCTAssertEqual(reducer.claim?.geometryRefenced, true)
        XCTAssertEqual(reducer.claim?.geometryLanded, false, "the re-fence lands afresh")
        XCTAssertEqual(reducer.claimObservedGeometry(generation: generation, columns: 105, rows: 31, settleProbe: false), [],
                       "stale again until the re-fence's probe")
        XCTAssertEqual(
            reducer.claimObservedGeometry(generation: generation, columns: 105, rows: 31, settleProbe: true),
            [.hideReclaimPresentation, .claimAborted(.geometryLost)]
        )
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.authority, peer())
    }

    /// The settle probe proves a loss even before confirmation, and a late
    /// claim's loss aborts without a re-fence. Past the repaint, and for
    /// other generations, observations change nothing.
    func testObservedGeometryLossesBeforeConfirmationLateClaimsAndTheStampPhases() {
        var visible = live(peer())
        let visibleGeneration = claim(visible.requestTakeBack()).generation
        _ = visible.claimAdvertisedGeometry(generation: visibleGeneration, columns: 92, rows: 38)
        XCTAssertEqual(visible.claimObservedGeometry(generation: visibleGeneration + 1, columns: 1, rows: 1, settleProbe: true), [])
        XCTAssertEqual(
            visible.claimObservedGeometry(generation: visibleGeneration, columns: 105, rows: 31, settleProbe: true),
            [.refenceClaim(generation: visibleGeneration)],
            "a steal before confirmation"
        )

        var late = live(peer())
        let lateGeneration = claim(late.requestTakeBack()).generation
        _ = late.claimAdvertisedGeometry(generation: lateGeneration, columns: 92, rows: 38)
        _ = late.fenceSucceeded(generation: lateGeneration)
        _ = late.presentationTimedOut(generation: lateGeneration)
        XCTAssertEqual(late.claimObservedGeometry(generation: lateGeneration, columns: 105, rows: 31, settleProbe: false), [],
                       "a late claim's stale layout ends nothing")
        XCTAssertNotNil(late.claim)
        XCTAssertEqual(
            late.claimObservedGeometry(generation: lateGeneration, columns: 105, rows: 31, settleProbe: true),
            [.hideReclaimPresentation, .claimAborted(.geometryLost)]
        )

        var stamping = live(peer())
        let stampingGeneration = claim(stamping.requestTakeBack()).generation
        _ = stamping.claimAdvertisedGeometry(generation: stampingGeneration, columns: 92, rows: 38)
        _ = stamping.fenceSucceeded(generation: stampingGeneration)
        _ = stamping.repaintSucceeded(generation: stampingGeneration)
        let before = stamping.snapshot
        XCTAssertEqual(stamping.claimObservedGeometry(generation: stampingGeneration, columns: 105, rows: 31, settleProbe: true), [])
        XCTAssertEqual(stamping.snapshot, before, "the stamp is on the wire")
    }

    /// Rule 6: a visible claim that can progress returns to its geometry
    /// phase; anything else ends as an adapter failure. The stamp phases
    /// ignore a stall.
    func testAStalledClaimReentersItsGeometryPhaseOrAborts() {
        var reducer = live(peer())
        let generation = claim(reducer.requestTakeBack()).generation
        _ = reducer.fenceSucceeded(generation: generation)
        XCTAssertEqual(reducer.claimStalled(generation: generation + 1, canProgress: false), [], "another generation")
        XCTAssertEqual(reducer.claimStalled(generation: generation, canProgress: true), [])
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence)
        XCTAssertEqual(reducer.claim?.geometryRefenced, false, "a stall spends no re-fence")
        XCTAssertEqual(reducer.claimStalled(generation: generation, canProgress: false),
                       [.hideReclaimPresentation, .claimAborted(.adapterFailure)])
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.authority, peer(), "the veil stays")

        var late = live(peer())
        let lateGeneration = claim(late.requestTakeBack()).generation
        _ = late.presentationTimedOut(generation: lateGeneration)
        XCTAssertEqual(late.claimStalled(generation: lateGeneration, canProgress: true),
                       [.hideReclaimPresentation, .claimAborted(.adapterFailure)],
                       "a late claim may not fence again")

        var stamping = live(peer())
        let stampingGeneration = claim(stamping.requestTakeBack()).generation
        _ = stamping.fenceSucceeded(generation: stampingGeneration)
        _ = stamping.repaintSucceeded(generation: stampingGeneration)
        XCTAssertEqual(stamping.claimStalled(generation: stampingGeneration, canProgress: false), [])
        XCTAssertEqual(stamping.claim?.phase, .awaitingStampCommit)
    }

    func testAnyChangedForeignStampContestsThePeerCapturedAtAdmission() {
        var reducer = live(peer("ipad", 7))
        _ = claim(reducer.requestTakeBack())
        XCTAssertEqual(reducer.observedAuthority(peer("ipad", 7)), [])
        XCTAssertEqual(reducer.observedAuthority(peer("ipad", 6)), [
            .authorityChanged(peer("ipad", 6)),
            .hideReclaimPresentation,
            .claimAborted(.contestedByPeer(peerID("ipad", 6))),
        ], "a contest no longer asks for a presence proof")
        XCTAssertNil(reducer.claim)

        let next = claim(reducer.requestTakeBack())
        XCTAssertEqual(next.contestedPeer?.generation, 6)
        XCTAssertTrue(reducer.observedAuthority(peer("ipad", 8)).contains(.claimAborted(.contestedByPeer(peerID("ipad", 8)))))

        // A distinct device is a newer foreign authority even if its local
        // generation happens to be lower.
        _ = claim(reducer.requestTakeBack())
        XCTAssertTrue(reducer.observedAuthority(peer("phone", 1, "iPhone")).contains { effect in
            if case .claimAborted = effect { return true } else { return false }
        })

        // A show claim that began from our own stamp contests any foreign one.
        var owner = live(.mine(generation: 2))
        _ = owner.shown()
        _ = claim(owner.receivedAuthorityQuery(.mine(generation: 2), geometry: .foreignSize))
        XCTAssertTrue(owner.receivedAuthorityQuery(peer(), geometry: .foreignSize)
            .contains(.claimAborted(.contestedByPeer(peerID()))))
    }

    func testQueryRepliesDuringAClaimOnlyContest() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        for geometry in [Reducer.QueryGeometry.atLocalSize, .foreignSize] {
            XCTAssertEqual(reducer.receivedAuthorityQuery(.mine(generation: active.generation), geometry: geometry), [])
            XCTAssertEqual(reducer.receivedAuthorityQuery(.unknown, geometry: geometry), [])
            XCTAssertEqual(reducer.receivedAuthorityQuery(peer(), geometry: geometry), [])
        }
        XCTAssertEqual(reducer.claim, active)
        XCTAssertEqual(reducer.authority, peer())
        XCTAssertTrue(reducer.receivedAuthorityQuery(peer("ipad", 8), geometry: .atLocalSize)
            .contains(.claimAborted(.contestedByPeer(peerID("ipad", 8)))))
    }

    func testOwnStampIsAdvisoryUntilTheFenceAndRepaintAreSettled() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        XCTAssertTrue(reducer.observedAuthority(.mine(generation: active.generation)).isEmpty)
        XCTAssertTrue(reducer.authority.isPeer)
        XCTAssertNotNil(reducer.claim)
    }

    /// D5's second route: a fresh engine classifies our own stale stamp as
    /// `.mine`. Without a claim that must not lift a peer veil; only
    /// settlement or a fresh read with geometry evidence can.
    func testOwnStampEchoNeverLiftsAPeerVeil() {
        for veil in [stampless, peer()] {
            var reducer = live(veil)
            XCTAssertEqual(reducer.observedAuthority(.mine(generation: 3)), [])
            XCTAssertEqual(reducer.authority, veil)
            XCTAssertEqual(reducer.observedAuthority(.unknown), [])
            XCTAssertEqual(reducer.authority, veil)
        }
    }

    func testOwnStampQueuedBeforeAContestReentersTheFenceAsOwnWriteWon() {
        var reducer = live(peer())
        let first = claim(reducer.requestTakeBack())
        _ = reducer.observedAuthority(peer("ipad", 8))
        XCTAssertNil(reducer.claim)
        XCTAssertEqual(reducer.observedOwnAuthorityStamp(generation: first.generation + 1), [])

        let replacement = claim(reducer.observedOwnAuthorityStamp(generation: first.generation))
        XCTAssertEqual(replacement.reason, .ownWriteWon)
        XCTAssertGreaterThan(replacement.generation, first.generation)
        XCTAssertTrue(replacement.presentationVisible)
        XCTAssertEqual(replacement.contestedPeer, peerID("ipad", 8))
        XCTAssertEqual(reducer.observedOwnAuthorityStamp(generation: first.generation), [], "armed once")

        var queried = live(peer())
        _ = queried.shown()
        let show = claim(queried.receivedAuthorityQuery(peer(), geometry: .unknown))
        _ = queried.receivedAuthorityQuery(peer("ipad", 8), geometry: .unknown)
        XCTAssertEqual(claim(queried.observedOwnAuthorityStamp(generation: show.generation)).reason, .ownWriteWon)
    }

    func testAbortAndTransportResetDiscardTheLiveClaimButCanPreserveThePeerVeil() {
        var reducer = live(peer())
        let active = claim(reducer.requestTakeBack())
        XCTAssertEqual(
            reducer.abortClaim(generation: active.generation),
            [.hideReclaimPresentation, .claimAborted(.adapterFailure)]
        )
        XCTAssertNil(reducer.claim)
        XCTAssertTrue(reducer.authority.isPeer)

        _ = reducer.requestTakeBack()
        let reset = reducer.resetTransport(preservingPeer: true)
        XCTAssertEqual(reset, [.claimAborted(.transportReset), .hideReclaimPresentation, .authorityChanged(peer())])
        XCTAssertNil(reducer.claim)
        XCTAssertNil(reducer.pendingIntent, "a sent claim's intent is not resurrected by a reset")
        XCTAssertTrue(reducer.authority.isPeer)
        XCTAssertEqual(reducer.attached(), [.queryAuthority])

        XCTAssertTrue(reducer.resetTransport(preservingPeer: false).contains(.authorityChanged(.unknown)))
        XCTAssertEqual(reducer.authority, .unknown)
        XCTAssertFalse(reducer.snapshot.authorityObserved)
    }

    // MARK: - Persistence and trace

    func testSnapshotRoundTripsCodablyWithAClaimAndAnIntent() throws {
        var claiming = live(peer())
        let active = claim(claiming.requestTakeBack())
        _ = claiming.fenceSucceeded(generation: active.generation)

        var pending = Reducer()
        _ = pending.shown(source: .explicitOpen)
        _ = pending.attached()
        _ = pending.observedAuthority(peer())

        var tapped = live(peer())
        _ = tapped.requestTakeBack(channelLive: false)

        for reducer in [claiming, pending, tapped] {
            let data = try JSONEncoder().encode(reducer.snapshot)
            let decoded = try JSONDecoder().decode(Reducer.Snapshot.self, from: data)
            var restored = Reducer(snapshot: decoded)
            XCTAssertEqual(restored.snapshot, reducer.snapshot)
            XCTAssertEqual(restored, reducer)
            var original = reducer
            XCTAssertEqual(restored.shown(), original.shown())
            XCTAssertEqual(restored, original)
        }

        // A decoded show cannot smuggle a baseline in, nor a tap lose its peer.
        let bound = try JSONDecoder().decode(Reducer.Intent.self, from: Data("""
            {"token":4,"source":"show","baselineKnown":true,
             "baseline":{"deviceID":"ipad","displayName":"iPad","generation":7}}
            """.utf8))
        XCTAssertEqual(bound, Reducer.Intent(token: 4, source: .show, baseline: nil, baselineKnown: false))
        let tap = try JSONDecoder().decode(Reducer.Intent.self, from: Data("""
            {"token":5,"source":"tap","baselineKnown":true,
             "baseline":{"deviceID":"ipad","displayName":"iPad","generation":7}}
            """.utf8))
        XCTAssertEqual(tap.baseline, peerID())
        XCTAssertTrue(tap.baselineKnown)

        // A claim encoded before `geometryRefenced` existed still decodes,
        // as a claim that has not re-fenced; one that has keeps the bound.
        let legacy = try JSONDecoder().decode(Reducer.Claim.self, from: Data("""
            {"generation":3,"reason":"userTakeBack","phase":"awaitingRepaint","presentationVisible":true}
            """.utf8))
        XCTAssertEqual(legacy.generation, 3)
        XCTAssertEqual(legacy.phase, .awaitingRepaint)
        XCTAssertFalse(legacy.geometryRefenced)
        XCTAssertNil(legacy.contestedPeer)

        var refenced = live(peer())
        let lostClaim = claim(refenced.requestTakeBack())
        _ = refenced.fenceSucceeded(generation: lostClaim.generation)
        _ = refenced.claimGeometryLost(generation: lostClaim.generation)
        let data = try JSONEncoder().encode(refenced.snapshot)
        var restored = Reducer(snapshot: try JSONDecoder().decode(Reducer.Snapshot.self, from: data))
        XCTAssertEqual(restored, refenced)
        XCTAssertEqual(restored.claim?.geometryRefenced, true)
        _ = restored.fenceSucceeded(generation: lostClaim.generation)
        XCTAssertEqual(restored.claimGeometryLost(generation: lostClaim.generation),
                       [.hideReclaimPresentation, .claimAborted(.geometryLost)])

        // §6.10 fields: absent on an older snapshot, kept on a round trip.
        XCTAssertEqual(legacy.advertisedGrids, [])
        XCTAssertNil(legacy.targetGrid)
        XCTAssertFalse(legacy.geometryLanded)
        var landed = live(peer())
        let landedClaim = claim(landed.requestTakeBack())
        _ = landed.claimAdvertisedGeometry(generation: landedClaim.generation, columns: 92, rows: 20)
        _ = landed.claimAdvertisedGeometry(generation: landedClaim.generation, columns: 92, rows: 38)
        _ = landed.claimObservedGeometry(generation: landedClaim.generation, columns: 92, rows: 38, settleProbe: true)
        let landedData = try JSONEncoder().encode(landed.snapshot)
        let landedRestored = Reducer(snapshot: try JSONDecoder().decode(Reducer.Snapshot.self, from: landedData))
        XCTAssertEqual(landedRestored, landed)
        XCTAssertEqual(landedRestored.claim?.advertisedGrids, [.init(columns: 92, rows: 20), .init(columns: 92, rows: 38)])
        XCTAssertEqual(landedRestored.claim?.targetGrid, .init(columns: 92, rows: 38))
        XCTAssertEqual(landedRestored.claim?.geometryLanded, true)
    }

    func testUnchangedObservationsFoldSilentlyAndTraceNothing() {
        var reducer = Reducer(authority: .unknown)
        XCTAssertEqual(reducer.observedAuthority(peer()), [.authorityChanged(peer())])
        // One stamp echo per pane on every control-mode event: the projection
        // already holds this value, so no effect and no trace line.
        for observed in [peer(), peer(), peer()] {
            let before = reducer.snapshot
            let effects = reducer.observedAuthority(observed)
            XCTAssertEqual(effects, [])
            XCTAssertNil(Reducer.describeTransition(
                event: "observedAuthority", before: before, after: reducer.snapshot, effects: effects
            ))
        }
        XCTAssertEqual(reducer.observedAuthority(peer("ipad", 8)), [.authorityChanged(peer("ipad", 8))])

        var mine = Reducer(authority: .unknown)
        XCTAssertEqual(mine.observedAuthority(.mine(generation: 3)), [.authorityChanged(.mine(generation: 3))])
        XCTAssertEqual(mine.observedAuthority(.mine(generation: 3)), [])
        XCTAssertEqual(mine.observedAuthority(.mine(generation: 4)), [.authorityChanged(.mine(generation: 4))])

        // Echoes while an intent waits and while a claim runs are silent too.
        var waiting = live(peer())
        _ = waiting.shown()
        let pendingBefore = waiting.snapshot
        let pendingEffects = waiting.observedAuthority(peer())
        XCTAssertNil(Reducer.describeTransition(
            event: "observedAuthority", before: pendingBefore, after: waiting.snapshot, effects: pendingEffects
        ))
        _ = waiting.receivedAuthorityQuery(peer(), geometry: .unknown)
        let claimBefore = waiting.snapshot
        let claimEffects = waiting.observedAuthority(peer())
        XCTAssertNil(Reducer.describeTransition(
            event: "observedAuthority", before: claimBefore, after: waiting.snapshot, effects: claimEffects
        ))
    }

    func testTransitionTraceDescribesOnlyRealTransitionsIdenticallyOnBothPlatforms() {
        func trace(_ reducer: inout Reducer, _ event: String, _ body: (inout Reducer) -> [Effect]) -> String? {
            let before = reducer.snapshot
            let effects = body(&reducer)
            return Reducer.describeTransition(event: event, before: before, after: reducer.snapshot, effects: effects)
        }

        var reducer = Reducer()
        XCTAssertEqual(
            trace(&reducer, "attached") { $0.attached() },
            "event=attached authority=unknown claim=none attached=true channel=live effects=[queryAuthority]"
        )
        XCTAssertEqual(
            trace(&reducer, "receivedAuthorityQuery") { $0.receivedAuthorityQuery(peer(), geometry: .foreignSize) },
            "event=receivedAuthorityQuery authority=unknown->peer(ipad/iPad#7) claim=none observed=true "
                + "effects=[authorityChanged(peer(ipad/iPad#7))]"
        )
        XCTAssertEqual(
            trace(&reducer, "shown") { $0.shown() },
            "event=shown authority=peer(ipad/iPad#7) claim=none intent=none->i1:show "
                + "effects=[queryAuthority]"
        )
        XCTAssertEqual(
            trace(&reducer, "receivedAuthorityQuery") { $0.receivedAuthorityQuery(peer(), geometry: .foreignSize) },
            "event=receivedAuthorityQuery authority=peer(ipad/iPad#7) "
                + "claim=none->g1:show/awaitingFence vs ipad/iPad#7 intent=i1:show->none "
                + "effects=[beginClaim(g1 show visible=true)]"
        )
        // A second show while the claim is visibly presenting: no line.
        XCTAssertNil(trace(&reducer, "shown") { $0.shown() })
        XCTAssertNil(trace(&reducer, "requestTakeBack") { $0.requestTakeBack() })

        _ = reducer.presentationTimedOut(generation: 1)
        XCTAssertEqual(
            trace(&reducer, "requestTakeBack") { $0.requestTakeBack() },
            "event=requestTakeBack authority=peer(ipad/iPad#7) "
                + "claim=g1:show/awaitingFence/hidden vs ipad/iPad#7->g2:userTakeBack/awaitingFence vs ipad/iPad#7 "
                + "effects=[claimAborted(superseded),beginClaim(g2 userTakeBack visible=true)]"
        )
        XCTAssertEqual(
            trace(&reducer, "settle") { walk(&$0, to: 2) },
            "event=settle authority=peer(ipad/iPad#7)->mine#2 "
                + "claim=g2:userTakeBack/awaitingFence vs ipad/iPad#7->none "
                + "effects=[authorityChanged(mine#2),hideReclaimPresentation,claimSettled(g2)]"
        )
        XCTAssertEqual(
            trace(&reducer, "receivedAuthorityQuery") { $0.receivedAuthorityQuery(.mine(generation: 2), geometry: .atLastOwnedSize) },
            "event=receivedAuthorityQuery authority=mine#2 claim=none effects=[replayOwnedGeometry]"
        )
        XCTAssertEqual(
            trace(&reducer, "resetTransport") { $0.resetTransport(preservingPeer: true) },
            "event=resetTransport authority=mine#2->unknown claim=none channel=down observed=false "
                + "effects=[hideReclaimPresentation,authorityChanged(unknown)]"
        )
        XCTAssertEqual(
            trace(&reducer, "shown") { $0.shown() },
            "event=shown authority=unknown claim=none intent=none->i2:show effects=[]"
        )
        XCTAssertEqual(
            trace(&reducer, "intentExpired") { $0.intentExpired(token: 2) },
            "event=intentExpired authority=unknown claim=none intent=i2:show->none effects=[]"
        )
        XCTAssertNil(trace(&reducer, "intentExpired") { $0.intentExpired(token: 2) })
        XCTAssertNil(trace(&reducer, "hidden") { $0.hidden() })

        var veiled = Reducer(authority: peer(), hasAttached: true, channelAttached: false)
        XCTAssertEqual(
            trace(&veiled, "requestTakeBack") { $0.requestTakeBack() },
            "event=requestTakeBack authority=peer(ipad/iPad#7) claim=none intent=none->i1:tap base=ipad/iPad#7 effects=[]"
        )
    }
}

extension AuthorityLifecycleReducerTests {
    func test_review610_evictedAdvertisedGridNeverBecomesForeign() {
        var reducer = live(peer())
        let generation = claim(reducer.requestTakeBack()).generation

        for rows in 1...17 {
            _ = reducer.claimAdvertisedGeometry(
                generation: generation, columns: 92, rows: rows
            )
        }
        _ = reducer.claimObservedGeometry(
            generation: generation, columns: 92, rows: 17,
            settleProbe: true
        )
        _ = reducer.fenceSucceeded(generation: generation)
        _ = reducer.presentationTimedOut(generation: generation)

        let effects = reducer.claimObservedGeometry(
            generation: generation, columns: 92, rows: 1,
            settleProbe: false
        )
        XCTAssertEqual(effects, [], "An advertised grid is never a loss")
        XCTAssertNotNil(reducer.claim)
        XCTAssertEqual(reducer.claim?.phase, .awaitingFence)
        XCTAssertEqual(reducer.claim?.geometryRefenced, false)
    }
}


extension AuthorityLifecycleReducerTests {
    func test_review610_fullMembershipSurvivesInMemorySnapshotAndEndsWithClaim() throws {
        var reducer = live(peer())
        let generation = claim(reducer.requestTakeBack()).generation
        for rows in 1...30 {
            _ = reducer.claimAdvertisedGeometry(generation: generation, columns: 92, rows: rows)
        }
        _ = reducer.claimObservedGeometry(generation: generation, columns: 92, rows: 30, settleProbe: true)
        _ = reducer.fenceSucceeded(generation: generation)
        var replacement = Reducer(snapshot: reducer.snapshot)
        XCTAssertEqual(replacement, reducer)
        XCTAssertEqual(replacement.claimObservedGeometry(generation: generation, columns: 92, rows: 1, settleProbe: false), [])
        XCTAssertEqual(replacement.claim?.geometryRefenced, false)

        let data = try JSONEncoder().encode(reducer.claim!)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set([
            "generation", "reason", "contestedPeer", "phase", "presentationVisible",
            "geometryRefenced", "advertisedGrids", "targetGrid", "geometryLanded"
        ]), "lifetime membership adds no wire fields")
        XCTAssertEqual((json["advertisedGrids"] as? [Any])?.count, Reducer.maximumAdvertisedGrids)

        _ = replacement.abortClaim(generation: generation)
        let next = claim(replacement.requestTakeBack()).generation
        _ = replacement.claimAdvertisedGeometry(generation: next, columns: 92, rows: 30)
        XCTAssertFalse(replacement.claim!.hasAdvertisedGrid(.init(columns: 92, rows: 1)))
        XCTAssertEqual(replacement.claimObservedGeometry(generation: next, columns: 92, rows: 1, settleProbe: true),
                       [.refenceClaim(generation: next)], "membership belongs to this claim only")
    }
}
