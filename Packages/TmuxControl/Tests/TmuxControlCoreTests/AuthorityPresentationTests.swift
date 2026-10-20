import Foundation
import XCTest
@testable import TmuxControlCore

/// The shared authority projection and its gates, ported from Android
/// `TmuxAuthorityPresentationTest` (presentation and typing cases) plus the
/// iOS derivation it adopts (plan §C.4): a hidden session over a peer
/// resumes rather than drawing a veil, a missing peer name is the
/// stamp-less name, and the D7 mutation refusal.
///
/// Android's `VeilKeyPolicy` case stays on Android: key admission is
/// platform input handling, not shared policy.
final class AuthorityPresentationTests: XCTestCase {
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer
    private typealias Presentation = TmuxGridAuthorityPresentation

    private let peer = TmuxGridAuthoritySnapshot.peer(deviceID: "ipad-id", displayName: "iPad", generation: 4)

    private func attached(_ authority: TmuxGridAuthoritySnapshot = .unknown) -> Reducer {
        var reducer = Reducer()
        reducer.attached()
        if authority != .unknown { reducer.observedAuthority(authority) }
        return reducer
    }

    private func project(_ reducer: Reducer, hidden: Bool = false, live: Bool = true) -> Presentation {
        Presentation.derive(reducer: reducer, hidden: hidden, channelLive: live)
    }

    /// Show, then a buffered stamp line naming a peer, then the show's own
    /// read starting a claim, then settlement: the buffered peer never
    /// surfaces as a veil.
    func test_aShowProjectsResumingThroughABufferedPeerUntilItsClaimSettles() {
        var reducer = attached(.mine(generation: 2))
        reducer.shown(source: .show)
        var projected = [project(reducer)]
        reducer.observedAuthority(peer)
        projected.append(project(reducer))
        let effects = reducer.receivedAuthorityQuery(peer, geometry: .unknown)
        let generation = effects.compactMap { effect -> UInt64? in
            if case .beginClaim(let claim) = effect { return claim.generation }
            return nil
        }.first
        projected.append(project(reducer))
        guard let generation else { return XCTFail("the show's read claims") }
        reducer.fenceSucceeded(generation: generation)
        reducer.repaintSucceeded(generation: generation)
        reducer.stampCommitSucceeded(generation: generation)
        reducer.settleClaim(generation: generation)
        projected.append(project(reducer))

        XCTAssertEqual(projected, [
            .resuming(awaitingConnection: false),
            .resuming(awaitingConnection: false),
            .resuming(awaitingConnection: false),
            .none,
        ])
        XCTAssertFalse(projected.contains { $0.showsVeil })
    }

    func test_anExplicitOpenResumesLikeAShow() {
        var reducer = attached(peer)
        reducer.shown(source: .explicitOpen)
        XCTAssertEqual(project(reducer), .resuming(awaitingConnection: false))
        reducer.receivedAuthorityQuery(peer, geometry: .unknown)
        XCTAssertEqual(reducer.claim?.reason, .explicitOpen)
        XCTAssertEqual(project(reducer), .resuming(awaitingConnection: false))
    }

    func test_aShowWithoutAChannelSaysItWillTakeControlWhenReconnected() {
        var detached = attached(peer)
        detached.resetTransport(preservingPeer: true)
        detached.shown(source: .show)
        XCTAssertEqual(project(detached, live: true), .resuming(awaitingConnection: true),
                       "no attached channel is never live")

        var stalled = attached(peer)
        stalled.shown(source: .show)
        XCTAssertEqual(project(stalled, live: false), .resuming(awaitingConnection: true))
    }

    func test_aPeerWithoutIntentOrClaimIsVeiled() {
        XCTAssertEqual(project(attached(peer)), .veiled(peerName: "iPad"))
    }

    func test_aHiddenSessionOverAPeerResumesInsteadOfVeiling() {
        // iOS M2: its next show decides, so nothing draws (or takes first
        // responder for) a veil nobody can see.
        XCTAssertEqual(project(attached(peer), hidden: true), .resuming(awaitingConnection: false))
        XCTAssertEqual(project(attached(peer), hidden: true, live: false), .resuming(awaitingConnection: true))
        XCTAssertEqual(project(attached(.mine(generation: 1)), hidden: true), .none)
    }

    func test_aTapIsReclaimingAndWaitsVisiblyForTheChannel() {
        var waiting = attached(peer)
        waiting.requestTakeBack(channelLive: false)
        XCTAssertEqual(waiting.pendingIntent?.source, .tap)
        XCTAssertEqual(project(waiting, live: false), .reclaiming(peerName: "iPad", awaitingConnection: true))

        var live = attached(peer)
        live.requestTakeBack(channelLive: true)
        XCTAssertEqual(live.claim?.reason, .userTakeBack)
        XCTAssertEqual(project(live), .reclaiming(peerName: "iPad", awaitingConnection: false))
    }

    func test_aClaimWhosePresentationTimedOutShowsTheVeilAgain() {
        var reducer = attached(peer)
        reducer.requestTakeBack(channelLive: true)
        let generation = try! XCTUnwrap(reducer.claim?.generation)
        reducer.presentationTimedOut(generation: generation)
        XCTAssertEqual(project(reducer), .veiled(peerName: "iPad"))
        XCTAssertEqual(project(reducer, hidden: true), .resuming(awaitingConnection: false))

        // Over our own or an unknown stamp a timed-out claim no longer gates.
        var show = attached(.mine(generation: 1))
        show.shown(source: .show)
        show.receivedAuthorityQuery(.mine(generation: 1), geometry: .foreignSize)
        let showGeneration = try! XCTUnwrap(show.claim?.generation)
        show.presentationTimedOut(generation: showGeneration)
        XCTAssertEqual(project(show), .none)
    }

    func test_aMissingPeerNameIsTheStamplessName() {
        // A tap waiting for its channel after the peer was lost in a reset
        // still names someone.
        var reducer = attached(peer)
        reducer.requestTakeBack(channelLive: false)
        reducer.resetTransport(preservingPeer: false)
        XCTAssertEqual(
            project(reducer, live: false),
            .reclaiming(peerName: "iPad", awaitingConnection: true),
            "the tap's own baseline names the veil it came from"
        )
        let stampless = Reducer.stamplessPeer
        var fallback = attached(.peer(
            deviceID: stampless.deviceID,
            displayName: stampless.displayName,
            generation: stampless.generation
        ))
        XCTAssertEqual(project(fallback), .veiled(peerName: TmuxStamplessPeer.displayName))
        fallback.requestTakeBack(channelLive: true)
        XCTAssertEqual(project(fallback), .reclaiming(peerName: TmuxStamplessPeer.displayName, awaitingConnection: false))
    }

    func test_onlyNoneEnablesTheWindowChrome() {
        XCTAssertFalse(Presentation.none.gatesWindowChrome)
        XCTAssertTrue(Presentation.resuming(awaitingConnection: false).gatesWindowChrome)
        XCTAssertTrue(Presentation.resuming(awaitingConnection: true).gatesWindowChrome)
        XCTAssertTrue(Presentation.veiled(peerName: "iPad").gatesWindowChrome)
        XCTAssertTrue(Presentation.reclaiming(peerName: "iPad", awaitingConnection: false).gatesWindowChrome)
        XCTAssertTrue(Presentation.reclaiming(peerName: "iPad", awaitingConnection: true).gatesWindowChrome)
    }

    func test_typingWaitsForALiveChannelsDecisionButNotForAMissingChannel() {
        let lastKnowns: [TmuxGridAuthoritySnapshot] = [.unknown, .mine(generation: 2), peer]
        for lastKnown in lastKnowns {
            XCTAssertFalse(Presentation.none.gatesTyping(lastKnown: lastKnown))
            XCTAssertTrue(Presentation.veiled(peerName: "iPad").gatesTyping(lastKnown: lastKnown))
            XCTAssertTrue(Presentation.resuming(awaitingConnection: false).gatesTyping(lastKnown: lastKnown))
            XCTAssertTrue(Presentation.reclaiming(peerName: "iPad", awaitingConnection: false).gatesTyping(lastKnown: lastKnown))
        }
        // M7: only a known peer gates an intent still waiting for its channel.
        for lastKnown in [TmuxGridAuthoritySnapshot.unknown, .mine(generation: 2)] {
            XCTAssertFalse(Presentation.resuming(awaitingConnection: true).gatesTyping(lastKnown: lastKnown))
            XCTAssertFalse(Presentation.reclaiming(peerName: "iPad", awaitingConnection: true).gatesTyping(lastKnown: lastKnown))
        }
        XCTAssertTrue(Presentation.resuming(awaitingConnection: true).gatesTyping(lastKnown: peer))
        XCTAssertTrue(Presentation.reclaiming(peerName: "iPad", awaitingConnection: true).gatesTyping(lastKnown: peer))
    }

    /// D7: window/pane mutations and Agent Center sends never reach tmux
    /// while a peer holds the grid or a take-back runs; a resume over our
    /// own or an unknown grid may proceed (iOS `gridAuthorityRefusesAgentSend`).
    func test_mutationRefusalFollowsTheLastKnownHolder() {
        for lastKnown in [TmuxGridAuthoritySnapshot.unknown, .mine(generation: 2), peer] {
            XCTAssertNil(Presentation.none.mutationRefusal(lastKnown: lastKnown))
            XCTAssertEqual(Presentation.veiled(peerName: "iPad").mutationRefusal(lastKnown: lastKnown), .yielded)
            XCTAssertEqual(
                Presentation.reclaiming(peerName: "iPad", awaitingConnection: false).mutationRefusal(lastKnown: lastKnown),
                .reclaiming
            )
        }
        for awaiting in [false, true] {
            XCTAssertNil(Presentation.resuming(awaitingConnection: awaiting).mutationRefusal(lastKnown: .mine(generation: 1)))
            XCTAssertNil(Presentation.resuming(awaitingConnection: awaiting).mutationRefusal(lastKnown: .unknown))
            XCTAssertEqual(Presentation.resuming(awaitingConnection: awaiting).mutationRefusal(lastKnown: peer), .yielded)
        }
    }

    func test_traceLabelsAreStable() {
        XCTAssertEqual(Presentation.none.traceLabel, "none")
        XCTAssertEqual(Presentation.resuming(awaitingConnection: true).traceLabel, "resuming~")
        XCTAssertEqual(Presentation.veiled(peerName: "iPad").traceLabel, "veiled(iPad)")
        XCTAssertEqual(Presentation.reclaiming(peerName: "iPad", awaitingConnection: false).traceLabel, "reclaiming(iPad)")
    }
}
