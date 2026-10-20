import Foundation
import XCTest
@testable import TmuxControlCore

/// Regressions found by the adversarial review of the shared session and
/// show tracker, each replaying the reviewer's sequence. Named by finding.
final class AuthorityReviewRegressionTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private typealias Effect = TmuxGridAuthoritySession.Effect
    private typealias Event = TmuxGridAuthoritySession.Event

    private static let mine = "v1 SELF 3 iPad"
    private static let mac = "v1 MAC 7 Mac"
    private let macPeer = TmuxGridAuthoritySnapshot.peer(deviceID: "MAC", displayName: "Mac", generation: 7)

    private static func size(_ columns: Int, _ rows: Int) -> TmuxGridSize { .init(columns: columns, rows: rows) }
    private static func window(_ id: Int, _ size: TmuxGridSize) -> Event {
        .windowFacts(hydrated: true, activeWindow: .init(id: id, size: size, authoritative: true))
    }

    private struct Harness {
        var session = TmuxGridAuthoritySession(localDeviceID: "SELF")
        var now: Int64 = 0
        /// Every effect so far, for "never claimed" checks.
        var log: [Effect] = []
        /// Releases that sized the grid while the session was hidden.
        var sizedWhileHidden: [Effect] = []
        /// Claims begun into a hidden or background session.
        var claimedWhileInactive: [Effect] = []

        /// Confirm only through the same fence evidence production reports.
        @discardableResult
        mutating func confirmFence(generation: UInt64, at time: Int64? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) -> [Effect] {
            if let time { now = time }
            var effects: [Effect] = []
            if session.reducer.claim?.targetGrid == nil {
                effects += send(.claimAdvertisedGeometry(generation: generation,
                    size: session.evidence.localSize ?? .init(columns: 92, rows: 38)))
            }
            guard let target = session.reducer.claim?.targetGrid else {
                XCTFail("claim has no advertised target", file: file, line: line)
                return effects
            }
            let windowID = session.evidence.activeWindow?.id ?? 1
            effects += send(.claimFenceSent(generation: generation, windowID: windowID))
            guard let fenceID = session.claimFence?.id else {
                XCTFail("claim has no fence", file: file, line: line)
                return effects
            }
            effects += send(.claimFenceAcknowledged(fenceID: fenceID))
            effects += send(.windowSizePolicyReplied(windowID: windowID, raw: "latest", fenceID: fenceID))
            effects += send(.windowFacts(hydrated: true, activeWindow: .init(id: windowID,
                size: .init(columns: target.columns, rows: target.rows), authoritative: true)))
            effects += send(.confirmClaimFence)
            XCTAssertEqual(session.reducer.claim?.generation, generation, file: file, line: line)
            XCTAssertEqual(session.reducer.claim?.phase, .awaitingRepaint, file: file, line: line)
            return effects
        }

        @discardableResult
        mutating func send(_ event: Event, at time: Int64? = nil) -> [Effect] {
            if let time { now = time }
            let effects = session.reduce(event, now: now)
            log += effects
            if session.hidden {
                sizedWhileHidden += effects.filter { effect in
                    guard case .releaseGeometry(let release) = effect else { return false }
                    return release != .none
                }
            }
            if session.hidden || session.inBackground {
                claimedWhileInactive += effects.filter { if case .beginClaim = $0 { return true } else { return false } }
            }
            return effects
        }

        @discardableResult
        mutating func reply(_ raw: String, at time: Int64? = nil, file: StaticString = #filePath, line: UInt = #line) -> [Effect] {
            guard let id = session.query.current?.id else {
                XCTFail("no read outstanding", file: file, line: line)
                return []
            }
            return send(.queryReplied(id: id, raw: raw), at: time)
        }

        var claimed: Bool {
            log.contains { if case .beginClaim = $0 { return true } else { return false } }
        }
    }

    private func claims(in effects: [Effect]) -> [TmuxGridAuthorityLifecycleReducer.Claim] {
        effects.compactMap { if case .beginClaim(let claim) = $0 { return claim } else { return nil } }
    }

    private func reads(in effects: [Effect]) -> Int {
        effects.filter { if case .queryAuthority = $0 { return true } else { return false } }.count
    }

    private var stamplessPeer: TmuxGridAuthoritySnapshot {
        let peer = TmuxGridAuthorityLifecycleReducer.stamplessPeer
        return .peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation)
    }

    /// Attached and shown, our stamp at our 92x38 grid on window @1 under
    /// `latest`, the hold released.
    private func owner() -> Harness {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.reply(Self.mine)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        XCTAssertEqual(h.session.geometryHold, .owner)
        h.log.removeAll()
        return h
    }

    /// Attached and shown, yielded to the Mac.
    private func yielded() -> Harness {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(Self.mac)
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        h.log.removeAll()
        return h
    }

    private var raisedStamplessPeer: (Harness) -> Bool {
        { $0.log.contains(.raiseStamplessPeer) }
    }

    // MARK: F1: our own grid is never "another device"

    func test_F1_aReconnectOverAnOwnedSizeAfterALocalChangeReplaysOwnerGeometry() {
        var h = owner()
        h.send(.resetTransport(preservingPeer: true), at: 1_000)
        h.send(.localSize(Self.size(100, 40)), at: 2_000)
        h.send(.attached, at: 3_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 3_050)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 3_060)
        XCTAssertEqual(h.reply(Self.mine, at: 3_100), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.ownerReplay),
        ])
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertEqual(h.session.lastAdvertisedSize, Self.size(100, 40), "the replay the adapter is about to send")
        // Past the echo window, before the adapter's resize lands.
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
    }

    func test_F1_aForegroundAfterABackgroundResizeKeepsOurOwnGrid() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.send(.shown(source: .show, stepAt: 0))
        XCTAssertTrue(claims(in: h.reply(Self.mine, at: 100)).isEmpty, "ours at our size: zero commands")
        XCTAssertNil(h.session.lastAdvertisedSize)
        h.send(.backgrounded, at: 1_000)
        h.send(.localSize(Self.size(100, 40)), at: 2_000)
        h.send(.foregrounded, at: 3_000)
        let effects = h.reply(Self.mine, at: 3_100)
        XCTAssertTrue(effects.contains(.releaseGeometry(.ownerReplay)), "\(effects)")
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_F1_aLayoutWhileGeometryIsHeldForAReadIsNotJudged() {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(Self.window(1, Self.size(120, 40)), at: 2_000)
        XCTAssertFalse(raisedStamplessPeer(h), "the foreground read decides first")
        h.send(.foregrounded, at: 3_000)
        h.reply(Self.mine, at: 3_100)
        XCTAssertTrue(raisedStamplessPeer(h), "a foreign size under latest, judged after the read")
    }

    // MARK: F3: a healed channel serves the waiting gesture

    func test_F3_aTapOnADeadChannelReadsAndClaimsWhenItHeals() {
        var h = yielded()
        h.send(.channelLiveness(false), at: 1_000)
        XCTAssertEqual(h.send(.requestTakeBack, at: 1_100), [])
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: true))
        XCTAssertEqual(reads(in: h.send(.channelLiveness(true), at: 2_000)), 1, "not a spinner with nothing in flight")
        XCTAssertEqual(claims(in: h.reply(Self.mac, at: 2_100)).map(\.reason), [.userTakeBack])
    }

    func test_F3_anAttachIsALiveChannel() {
        var h = yielded()
        h.send(.channelLiveness(false), at: 1_000)
        h.send(.resetTransport(preservingPeer: true), at: 1_100)
        XCTAssertEqual(reads(in: h.send(.attached, at: 1_200)), 1)
        XCTAssertTrue(h.session.channelIsLive)
    }

    func test_F3_aTapThatWaitedOnAStuckQueueReadsWhenItMoves() {
        var h = yielded()
        XCTAssertEqual(reads(in: h.send(.foregrounded, at: 1_000)), 1)
        let stuck = h.session.query.current?.id ?? 0
        XCTAssertEqual(h.send(.tick, at: 6_000), [.controlChannelUnresponsive])
        XCTAssertEqual(h.send(.requestTakeBack, at: 6_100), [], "no claim on a stuck queue")
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: true))
        XCTAssertEqual(reads(in: h.send(.queryReplied(id: stuck, raw: Self.mac), at: 7_000)), 1,
                       "the late reply frees the queue for the tap's read")
        XCTAssertEqual(claims(in: h.reply(Self.mac, at: 7_100)).map(\.reason), [.userTakeBack])
    }

    // MARK: F4: a waiting tap keeps its veil's peer

    func test_F4_aWaitingTapGatesTypingAfterAResetForgetsThePeer() {
        var h = yielded()
        h.send(.channelLiveness(false), at: 1_000)
        h.send(.requestTakeBack, at: 1_100)
        h.send(.resetTransport(preservingPeer: false), at: 1_200)
        XCTAssertEqual(h.session.reducer.authority, .unknown)
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: true))
        XCTAssertTrue(h.session.gatesTyping, "the tap's veil named the Mac (R2)")
        XCTAssertEqual(h.session.mutationRefusal, .reclaiming)
    }

    // MARK: F7: an aborted claim never releases unproven owner geometry

    func test_F7_anAbortedShowClaimOverAForeignWindowJudgesOrParksBeforeSizing() {
        // A failure parks the gesture behind an unpaintable surface; a
        // never-sent claim abandoned at a cancel (L2) is superseded.
        for reason in [TmuxGridAuthorityLifecycleReducer.AbortReason.adapterFailure, .superseded] {
            var h = owner()
            h.send(.hidden, at: 1_000)
            h.send(Self.window(1, Self.size(120, 40)), at: 5_000)
            h.send(.paintable(false), at: 6_000)
            h.send(.shown(source: .show, stepAt: 10_000), at: 10_000)
            let generation = claims(in: h.reply(Self.mine, at: 10_100)).first?.generation ?? 0
            XCTAssertNotEqual(generation, 0, "foreign size with an intent: claim")
            let aborted = h.send(.abortClaim(generation: generation, reason: reason), at: 10_200)
            XCTAssertNotEqual(h.session.geometryHold, .owner, "\(reason.wireName): \(aborted)")
            XCTAssertEqual(reads(in: aborted), 0, "§6.10 replaces the abort reread with exactly one verdict")
            if reason == .adapterFailure {
                XCTAssertNotNil(h.session.replay.parked)
                XCTAssertFalse(raisedStamplessPeer(h), "the parked gesture's fresh read decides")
                XCTAssertEqual(reads(in: h.send(.paintable(true), at: 10_300)), 1)
                XCTAssertNotNil(h.session.query.current?.intentToken)
                XCTAssertEqual(claims(in: h.reply(Self.mine, at: 10_400)).count, 1)
                XCTAssertFalse(raisedStamplessPeer(h), "the same gesture claims against the fresh read")
            } else {
                XCTAssertTrue(raisedStamplessPeer(h), "rule 7 judges immediately, without replay suppression")
                XCTAssertEqual(h.session.reducer.authority, stamplessPeer)
                XCTAssertEqual(h.session.geometryHold, .withheld)
                XCTAssertEqual(h.session.presentation, .veiled(peerName: TmuxStamplessPeer.displayName))
            }
            XCTAssertFalse(h.log.contains { if case .releaseGeometry = $0 { return true } else { return false } })
        }
    }

    func test_F7_anAbortOverAPeerKeepsTheVeilWithoutARead() {
        var h = yielded()
        h.send(.paintable(true))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        let generation = claims(in: h.reply(Self.mac, at: 1_100)).first?.generation ?? 0
        h.send(.hidden, at: 1_150)
        let effects = h.send(.abortClaim(generation: generation, reason: .superseded), at: 1_200)
        XCTAssertEqual(reads(in: effects), 0, "the peer's verdict stands")
        XCTAssertEqual(h.session.geometryHold, .withheld)
    }

    func test_F7_anAbortReplayedAtOnceSendsOneRead() {
        var h = yielded()
        h.send(.paintable(true))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        let generation = claims(in: h.reply(Self.mac, at: 1_100)).first?.generation ?? 0
        let effects = h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 1_200)
        XCTAssertEqual(reads(in: effects), 1, "the replay's read covers the re-read")
        XCTAssertNotNil(h.session.query.current?.intentToken)
    }

    // MARK: F8: no sizing while inactive

    func test_F8_aClaimSettlingInTheBackgroundWaitsForTheForegroundRead() {
        var h = yielded()
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        let generation = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        h.confirmFence(generation: generation)
        h.send(.repaintSucceeded(generation: generation))
        h.send(.stampCommitSucceeded(generation: generation))
        h.send(.backgrounded, at: 1_500)
        h.send(.settleClaim(generation: generation), at: 1_600)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: generation))
        XCTAssertEqual(h.session.geometryHold, .withheld, "M6: an inactive device sizes nothing")
        XCTAssertEqual(reads(in: h.send(.foregrounded, at: 5_000)), 1)
        XCTAssertEqual(h.session.geometryHold, .withheld)
        h.reply("v1 SELF \(generation) iPad", at: 5_100)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_F8_aReadAnsweredInTheBackgroundReleasesNothing() {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(.resetTransport(preservingPeer: true), at: 1_100)
        h.send(.attached, at: 1_200)
        h.send(Self.window(1, Self.size(92, 38)), at: 1_250)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 1_260)
        let effects = h.reply(Self.mine, at: 1_300)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3), "the reply still decides authority (D4)")
        XCTAssertFalse(effects.contains { if case .releaseGeometry = $0 { return true } else { return false } }, "\(effects)")
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(reads(in: h.send(.foregrounded, at: 5_000)), 1)
        XCTAssertEqual(h.reply(Self.mine, at: 5_100), [.releaseGeometry(.advertise)])
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    // MARK: F1: the judge itself

    func test_F1_theJudgeReplaysAnOwnedEdgeOnceAndNeverConvictsIt() {
        let owned = TmuxOwnedSizeHistory([Self.size(92, 38), Self.size(100, 40)])
        func evidence(
            _ size: TmuxGridSize,
            replayAt: Int64?,
            mayReplay: Bool = true,
            latest: Bool = true
        ) -> TmuxStamplessPeerJudge.Evidence {
            .init(
                blocked: false,
                window: .init(windowID: 1, size: size),
                policyIsLatest: latest,
                local: Self.size(100, 40),
                alreadyPeer: false,
                lastLocalReplayAt: replayAt,
                owned: owned,
                ownerMayReplay: mayReplay
            )
        }
        var judge = TmuxStamplessPeerJudge()
        XCTAssertEqual(judge.judge(evidence(Self.size(100, 40), replayAt: nil), now: 1_000), .nothing, "the grid we last pushed")
        XCTAssertEqual(judge.judge(evidence(Self.size(92, 38), replayAt: 500), now: 10_000), .replayOwnedGeometry,
                       "an older owned grid, nothing of ours on its way")
        XCTAssertNil(judge.nextDeadline, "no clock judges it")
        judge.forgetJudgedEdge()
        XCTAssertEqual(judge.judge(evidence(Self.size(92, 38), replayAt: 10_000), now: 60_000), .nothing,
                       "still there 50 s later: ours, and replayed once")
        XCTAssertEqual(judge.judge(evidence(Self.size(100, 40), replayAt: 10_000), now: 60_100), .nothing)
        XCTAssertEqual(judge.judge(evidence(Self.size(92, 38), replayAt: 10_000), now: 70_000), .nothing,
                       "restored again: neither replayed again nor convicted")
        XCTAssertEqual(judge.judge(evidence(Self.size(130, 40), replayAt: 10_000), now: 80_000), .stamplessPeer,
                       "a grid this device never pushed")
        judge.reset()
        XCTAssertEqual(judge.replayedOwnedEdges, [])
        XCTAssertEqual(judge.judge(evidence(Self.size(92, 38), replayAt: nil), now: 90_000), .replayOwnedGeometry,
                       "a new connection replays it again")

        var read = TmuxStamplessPeerJudge()
        read.noteOwnedReplay(.init(windowID: 1, size: Self.size(92, 38)))
        XCTAssertEqual(read.judge(evidence(Self.size(92, 38), replayAt: nil), now: 10_000), .nothing,
                       "the read path already replayed this arrival")

        var landing = TmuxStamplessPeerJudge()
        XCTAssertEqual(landing.judge(evidence(Self.size(92, 38), replayAt: 9_500), now: 10_000), .nothing,
                       "inside the echo window of a size of ours already on its way")
        XCTAssertEqual(landing.nextDeadline, 11_550)
        XCTAssertTrue(landing.takeDueRejudge(now: 11_550))
        XCTAssertEqual(landing.judge(evidence(Self.size(92, 38), replayAt: 9_500), now: 11_550), .replayOwnedGeometry,
                       "still there after it: replay, never convict")

        var waiting = TmuxStamplessPeerJudge()
        XCTAssertEqual(waiting.judge(evidence(Self.size(92, 38), replayAt: nil, mayReplay: false), now: 10_000), .nothing)
        XCTAssertNil(waiting.lastJudged, "left for the event that lets the owner replay")
        XCTAssertEqual(waiting.judge(evidence(Self.size(92, 38), replayAt: nil), now: 11_000), .replayOwnedGeometry)

        var manual = TmuxStamplessPeerJudge()
        XCTAssertEqual(manual.judge(evidence(Self.size(92, 38), replayAt: nil, latest: false), now: 10_000), .nothing)
        XCTAssertNil(manual.nextDeadline, "nothing a replay could repair")
    }

    // MARK: Second review (P1-P4, M6)

    /// A stamp this build cannot parse leaves the hold withheld for good;
    /// the judge must still see a laptop take the window.
    func test_P1a_anUnparseableStampDoesNotBlindTheStamplessJudge() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.reply("v2 OTHER 4 Phone @1", at: 100)
        XCTAssertEqual(h.session.reducer.authority, .unknown)
        h.send(Self.window(1, Self.size(120, 40)), at: 30_000)
        h.send(.tick, at: 60_000)
        XCTAssertTrue(raisedStamplessPeer(h), "heldForRead=\(h.session.heldForRead) log=\(h.log)")
    }

    func test_P1b_spentReadRetriesDoNotBlindTheStamplessJudge() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        var now: Int64 = 100
        var failures = 0
        while let id = h.session.query.current?.id, now <= 10_000 {
            h.send(.queryFailed(id: id), at: now)
            failures += 1
            now += 1_000
            h.send(.tick, at: now)
        }
        XCTAssertEqual(failures, 4, "the first read and three retries")
        XCTAssertNil(h.session.query.current)
        XCTAssertNil(h.session.query.retryAt)
        h.send(Self.window(1, Self.size(120, 40)), at: 30_000)
        h.send(.tick, at: 60_000)
        XCTAssertTrue(raisedStamplessPeer(h), "heldForRead=\(h.session.heldForRead) log=\(h.log)")
    }

    func test_P1c_aReadWaitingToRetryStillBlocksTheJudge() {
        var h = owner()
        h.send(.foregrounded, at: 5_000)
        h.send(.queryFailed(id: h.session.query.current?.id ?? 0), at: 5_100)
        XCTAssertEqual(h.session.query.retryAt, 5_350)
        h.send(Self.window(1, Self.size(120, 40)), at: 5_300)
        XCTAssertFalse(raisedStamplessPeer(h), "the retry's read decides first")
        XCTAssertEqual(reads(in: h.send(.tick, at: 5_350)), 1)
        h.reply(Self.mine, at: 5_400)
        XCTAssertTrue(raisedStamplessPeer(h), "our stamp over a foreign size, once read")
    }

    /// Owned 92x38, rotated to 100x40 while hidden, shown: the show's read
    /// finds the older grid and claims; hidden again before the claim's
    /// fence, the claim is aborted. Nothing may size the hidden session.
    func test_P2_anAbortAfterAHideNeverSizesTheHiddenSession() {
        for reason in [TmuxGridAuthorityLifecycleReducer.AbortReason.adapterFailure, .superseded] {
            var h = owner()
            h.send(.paintable(true), at: 500)
            h.send(.hidden, at: 1_000)
            h.send(.localSize(Self.size(100, 40)), at: 2_000)
            h.send(.shown(source: .show, stepAt: 3_000), at: 3_000)
            let generation = claims(in: h.reply(Self.mine, at: 3_100)).first?.generation ?? 0
            XCTAssertNotEqual(generation, 0, "an owned, not local, size with an intent: claim")
            h.send(.hidden, at: 3_200)
            let aborted = h.send(.abortClaim(generation: generation, reason: reason), at: 3_300)
            XCTAssertEqual(reads(in: aborted), 0, "\(reason.wireName): the next show's read decides")
            if h.session.query.current != nil { h.reply(Self.mine, at: 3_400) }
            XCTAssertTrue(h.session.hidden)
            XCTAssertEqual(h.session.geometryHold, .withheld)
            XCTAssertEqual(h.sizedWhileHidden, [], "\(reason.wireName)")
            XCTAssertEqual(h.session.lastAdvertisedSize, Self.size(92, 38), "\(reason.wireName): nothing was sent")
        }
    }

    func test_P2b_aHiddenReattachNeverSizesTheHiddenSession() {
        var h = owner()
        h.send(.hidden, at: 1_000)
        h.send(.resetTransport(preservingPeer: true), at: 1_100)
        h.send(.localSize(Self.size(100, 40)), at: 1_200)
        h.send(.attached, at: 1_300)
        h.send(Self.window(1, Self.size(92, 38)), at: 1_350)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 1_360)
        h.reply(Self.mine, at: 1_400)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3), "the read still decides authority (D4)")
        XCTAssertEqual(h.sizedWhileHidden, [])
        XCTAssertNil(h.session.lastAdvertisedSize)
        // A successor adopting the shown slot has no show read: it asks.
        XCTAssertEqual(reads(in: h.send(.adoptShown, at: 2_000)), 1)
        XCTAssertEqual(h.reply(Self.mine, at: 2_100), [.releaseGeometry(.ownerReplay)])
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    /// 100x40 pushed and confirmed; 30 s later, nothing of ours in flight,
    /// the window moves to the older owned 92x38: one replay, and never a
    /// veil, whether or not the window follows (§6.9: an owned size is
    /// mine).
    func test_P3_aMoveToAnOlderOwnedGridIsReplayedOnceAndNeverVeiled() {
        for lands in [false, true] {
            var h = owner()
            h.send(.localSize(Self.size(100, 40)), at: 1_000)
            h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
            h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
            XCTAssertEqual(h.session.evidence.owned.sizes, [Self.size(92, 38), Self.size(100, 40)])
            XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 30_000), [.releaseGeometry(.ownerReplay)],
                           "lands=\(lands)")
            XCTAssertEqual(h.session.lastAdvertisedAt, 30_000)
            XCTAssertNil(h.session.nextDeadline, "lands=\(lands): no clock judges it")
            if lands { h.send(Self.window(1, Self.size(100, 40)), at: 33_000) }
            h.send(.tick, at: 60_000)
            XCTAssertFalse(raisedStamplessPeer(h), "lands=\(lands): \(h.log)")
            XCTAssertEqual(h.session.presentation, .none)
            XCTAssertEqual(h.session.geometryHold, .owner)
            XCTAssertTrue(h.session.evidence.owned.contains(Self.size(92, 38)), "still ours")
            XCTAssertEqual(h.log.filter { $0 == .releaseGeometry(.ownerReplay) }.count, 1, "one replay per edge")
        }
    }

    /// A tap's claim contested by a newer Mac stamp continues as
    /// `ownWriteWon` when ours lands last; that continuation is the tap's.
    func test_P4_anOwnWriteWonReplayIsBoundedByTheTapNotTheEcho() {
        var h = yielded()
        h.send(.paintable(true), at: 900)
        let tap = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        h.confirmFence(generation: tap, at: 1_100)
        h.send(.repaintSucceeded(generation: tap), at: 1_200)
        h.send(.observedAuthority(.peer(deviceID: "MAC", displayName: "Mac", generation: 8)), at: 15_000)
        let won = claims(in: h.send(.ownStampObserved(generation: tap), at: 15_100)).first
        XCTAssertEqual(won?.reason, .ownWriteWon)
        h.send(.paintable(false), at: 15_200)
        h.send(.abortClaim(generation: won?.generation ?? 0, reason: .adapterFailure), at: 15_300)
        XCTAssertEqual(h.session.replay.parked?.stepAt, 1_000, "the tap's step")
        XCTAssertEqual(claims(in: h.send(.paintable(true), at: 22_500)), [], "21.5 s after the tap: past R3")
    }

    /// The adapter contract for a session created while the app is in the
    /// background: `backgrounded` before `attached`.
    func test_M6_aSessionCreatedInTheBackgroundHearsBackgroundedFirst() {
        func run(backgroundedFirst: Bool) -> [Effect] {
            var h = Harness()
            if backgroundedFirst { h.send(.backgrounded) }
            h.send(.attached)
            h.send(.adoptShown)
            h.send(.localSize(Self.size(92, 38)))
            h.send(Self.window(1, Self.size(92, 38)))
            h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
            let released = h.reply(Self.mine, at: 100).filter { if case .releaseGeometry = $0 { return true } else { return false } }
            if backgroundedFirst {
                XCTAssertEqual(h.session.geometryHold, .withheld)
                XCTAssertEqual(reads(in: h.send(.foregrounded, at: 5_000)), 1)
                XCTAssertEqual(h.reply(Self.mine, at: 5_100), [.releaseGeometry(.advertise)])
                XCTAssertEqual(h.session.geometryHold, .owner)
            }
            return released
        }
        XCTAssertEqual(run(backgroundedFirst: true), [], "the contract: nothing sized from the background")
        XCTAssertEqual(run(backgroundedFirst: false), [.releaseGeometry(.advertise)], "the hazard the contract exists for")
    }

    // MARK: Third review (Q1-Q4)

    /// a397a054's F1 sequence with our resize landing at 5.6 s, 2.5 s after
    /// the reconnect read's replay, ticked at the moment a clock convicted
    /// it: never "another device".
    func test_Q1a_aReconnectReplayLandingAfterTheEchoWindowIsNotAnotherDevice() {
        var h = owner()
        h.send(.resetTransport(preservingPeer: true), at: 1_000)
        h.send(.localSize(Self.size(100, 40)), at: 2_000)
        h.send(.attached, at: 3_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 3_050)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 3_060)
        XCTAssertTrue(h.reply(Self.mine, at: 3_100).contains(.releaseGeometry(.ownerReplay)))
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 3_120)
        // A 2.5 s round trip (cellular, a mosh side channel after a wake):
        // our own resize lands at 5.6 s.
        h.send(.tick, at: 5_170)
        h.send(Self.window(1, Self.size(100, 40)), at: 5_600)
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_Q1b_aForegroundAfterABackgroundRotationOnASlowLinkKeepsOurGrid() {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(.localSize(Self.size(100, 40)), at: 2_000)
        h.send(.foregrounded, at: 3_000)
        XCTAssertTrue(h.reply(Self.mine, at: 3_100).contains(.releaseGeometry(.ownerReplay)))
        h.send(.tick, at: 5_150)
        h.send(Self.window(1, Self.size(100, 40)), at: 5_600)
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none, "veil over our own session after our replay landed")
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    /// A replay that never lands leaves our grid ours (§6.9: an owned size
    /// is mine), and no read or clock waits on it: a grid this device never
    /// pushed is still another device's.
    func test_Q1c_aReplayThatNeverLandsIsNotConvicted() {
        for lands in [true, false] {
            var h = owner()
            h.send(.resetTransport(preservingPeer: true), at: 1_000)
            h.send(.localSize(Self.size(100, 40)), at: 2_000)
            h.send(.attached, at: 3_000)
            h.send(Self.window(1, Self.size(92, 38)), at: 3_050)
            h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 3_060)
            XCTAssertTrue(h.reply(Self.mine, at: 3_100).contains(.releaseGeometry(.ownerReplay)))
            h.send(.sizeAdvertised(Self.size(100, 40)), at: 3_120)
            if lands { h.send(Self.window(1, Self.size(100, 40)), at: 5_600) }
            h.send(.tick, at: 60_000)
            XCTAssertFalse(raisedStamplessPeer(h), "lands=\(lands): \(h.log)")
            XCTAssertEqual(h.session.presentation, .none)
            XCTAssertEqual(h.session.geometryHold, .owner)
            h.send(Self.window(1, Self.size(160, 48)), at: 70_000)
            XCTAssertTrue(raisedStamplessPeer(h), "lands=\(lands): a grid we never pushed")
        }
    }

    /// A reattach finds the window back at the older grid: its read replays
    /// again, and the new connection forgets the old one's replays.
    func test_Q1d_aReattachReplaysAnOwnedGridAgain() {
        var h = owner()
        h.send(.localSize(Self.size(100, 40)), at: 1_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 30_000), [.releaseGeometry(.ownerReplay)])
        h.send(.resetTransport(preservingPeer: true), at: 30_100)
        XCTAssertEqual(h.session.stamplessJudge.replayedOwnedEdges, [])
        XCTAssertTrue(h.session.evidence.owned.contains(Self.size(92, 38)))
        h.send(.attached, at: 31_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 31_050)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 31_060)
        let effects = h.reply(Self.mine, at: 31_100)
        XCTAssertTrue(effects.contains(.releaseGeometry(.ownerReplay)), "\(effects)")
        h.send(.tick, at: 60_000)
        XCTAssertEqual(h.log.filter { $0 == .releaseGeometry(.ownerReplay) }.count, 2, "one per connection")
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
    }

    /// A client that keeps putting an older grid of ours back while our
    /// replay lands each time (the second review's probe: 10 replays). One
    /// replay per owned edge, and never a veil over our own grid.
    func test_Q2_aClientRestoringAnOlderOwnedGridGetsOneReplayNotALoop() {
        var h = owner()
        h.send(.localSize(Self.size(100, 40)), at: 1_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        var t: Int64 = 10_000
        for _ in 0..<10 {
            h.send(Self.window(1, Self.size(92, 38)), at: t)
            h.send(Self.window(1, Self.size(100, 40)), at: t + 300)
            if h.session.query.current != nil { h.reply(Self.mine, at: t + 400) }
            t += 3_000
            h.send(.tick, at: t - 100)
        }
        XCTAssertEqual(h.log.filter { $0 == .releaseGeometry(.ownerReplay) }.count, 1, "\(h.log)")
        XCTAssertFalse(raisedStamplessPeer(h), "an owned size is mine")
        XCTAssertEqual(h.session.presentation, .none)
    }

    /// An owned edge the owner could not replay yet stays unconsumed: it is
    /// repaired once a viewport is measured, or once the channel can carry
    /// the replay.
    func test_Q2b_anOwnedEdgeWaitingToBeReplayedIsReplayedWhenItMay() {
        var h = owner()
        h.send(.localSize(Self.size(100, 40)), at: 1_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        h.send(.localSize(nil), at: 2_000)
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 10_000), [], "no viewport to replay")
        let measured = h.send(.localSize(Self.size(100, 40)), at: 11_000)
        XCTAssertEqual(measured.first, .releaseGeometry(.ownerReplay), "\(measured)")

        var g = owner()
        g.send(.localSize(Self.size(100, 40)), at: 1_000)
        g.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        g.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        g.send(.channelLiveness(false), at: 2_000)
        XCTAssertEqual(g.send(Self.window(1, Self.size(92, 38)), at: 10_000), [], "a channel that cannot carry it")
        XCTAssertEqual(g.send(.channelLiveness(true), at: 11_000), [.releaseGeometry(.ownerReplay)])
    }

    /// A show whose carried step outlived R3, after a read answered while
    /// hidden, re-derives as a foreground does: one read, never a claim, and
    /// a layout from while hidden is judged behind it.
    func test_Q3_aStaleCarriedShowAfterAHiddenReadReadsAgain() {
        for foreignWhileHidden in [false, true] {
            var h = Harness()
            h.send(.attached)
            h.send(.localSize(Self.size(92, 38)))
            h.send(Self.window(1, Self.size(92, 38)))
            h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
            h.reply(Self.mine, at: 100)
            XCTAssertTrue(h.session.hidden)
            XCTAssertEqual(h.session.geometryHold, .withheld)
            if foreignWhileHidden { h.send(Self.window(1, Self.size(120, 40)), at: 10_000) }
            let effects = h.send(.shown(source: .show, stepAt: 0), at: 25_000)
            XCTAssertFalse(h.session.hidden)
            XCTAssertEqual(reads(in: effects), 1, "foreignWhileHidden=\(foreignWhileHidden): \(effects)")
            XCTAssertEqual(claims(in: effects), [], "R5: never a claim")
            XCTAssertFalse(raisedStamplessPeer(h), "the read decides first")
            h.reply(Self.mine, at: 25_100)
            XCTAssertEqual(raisedStamplessPeer(h), foreignWhileHidden)
            XCTAssertEqual(h.session.geometryHold, foreignWhileHidden ? .withheld : .owner)
            XCTAssertFalse(h.claimed)
        }
    }

    /// A tap's claim contested by a newer Mac stamp, then a hide: our own
    /// stamp landing afterwards must not fence the hidden session, and the
    /// continuation is dropped, not deferred to the next show.
    func test_Q4_anOwnWriteWonClaimNeverBeginsInAHiddenSession() {
        var h = yielded()
        h.send(.paintable(true), at: 900)
        let tap = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        XCTAssertNotEqual(tap, 0)
        h.confirmFence(generation: tap, at: 1_100)
        h.send(.repaintSucceeded(generation: tap), at: 1_200)
        h.send(.observedAuthority(.peer(deviceID: "MAC", displayName: "Mac", generation: 8)), at: 1_300)
        h.send(.hidden, at: 3_000)
        XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 3_100)), [],
                       "a fresh fence from a hidden session")
        h.send(.adoptShown, at: 4_000)
        XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 4_100)), [], "dropped, not deferred")
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
    }

    // MARK: Fourth review (R1-R7): an owned grid is never convicted

    private var ownerReplays: (Harness) -> Int {
        { $0.log.filter { $0 == .releaseGeometry(.ownerReplay) }.count }
    }

    private var contested: (Harness) -> Bool {
        { $0.log.contains { if case .claimAborted(.contestedByPeer) = $0 { return true } else { return false } } }
    }

    /// Owner at 92x38, the viewport now 100x40 from a background rotation,
    /// the foreground read answered with the window still at 92x38.
    private func foregroundedOverAnOlderOwnedGrid(replyAt: Int64 = 3_100) -> Harness {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(.localSize(Self.size(100, 40)), at: 2_000)
        h.send(.foregrounded, at: 3_000)
        XCTAssertEqual(h.reply(Self.mine, at: replyAt), [.releaseGeometry(.ownerReplay)])
        return h
    }

    /// The foreground read finds the older owned grid while the side
    /// channel has a gap: a replay sent then is lost and nothing would send
    /// it again, so the hold stays and the heal reads again, whose reply
    /// replays. Never "another device", whether or not it lands.
    func test_R1_aReplayWaitsForAChannelThatCanCarryIt() {
        for lands in [true, false] {
            var h = owner()
            h.send(.backgrounded, at: 1_000)
            h.send(.localSize(Self.size(100, 40)), at: 2_000)
            h.send(.foregrounded, at: 3_000)
            h.send(.channelLiveness(false), at: 3_050)
            XCTAssertEqual(h.reply(Self.mine, at: 3_100), [], "lands=\(lands)")
            XCTAssertEqual(h.session.geometryHold, .withheld)
            XCTAssertTrue(h.session.query.wanted)
            let healed = h.send(.channelLiveness(true), at: 4_000)
            XCTAssertEqual(reads(in: healed), 1, "lands=\(lands): \(healed)")
            XCTAssertFalse(healed.contains(.releaseGeometry(.ownerReplay)))
            XCTAssertEqual(h.reply(Self.mine, at: 4_100), [.releaseGeometry(.ownerReplay)], "lands=\(lands)")
            XCTAssertEqual(h.session.geometryHold, .owner)
            if lands { h.send(Self.window(1, Self.size(100, 40)), at: 6_000) }
            h.send(.tick, at: 10_000)
            h.send(.tick, at: 60_000)
            XCTAssertFalse(raisedStamplessPeer(h), "lands=\(lands): \(h.log)")
            XCTAssertEqual(h.session.presentation, .none)
            XCTAssertEqual(ownerReplays(h), 1, "lands=\(lands)")
        }
    }

    /// The same through a reply held for a viewport, released by a
    /// measurement (which needs no channel) during the gap.
    func test_R1b_aHeldReplyReleasedOnADeadChannelReplaysOnceItHeals() {
        var h = owner()
        h.send(.localSize(nil), at: 500)
        h.send(.backgrounded, at: 1_000)
        h.send(.foregrounded, at: 3_000)
        XCTAssertEqual(h.reply(Self.mine, at: 3_100), [])
        XCTAssertNotNil(h.session.query.held, "held for a viewport")
        h.send(.channelLiveness(false), at: 3_200)
        XCTAssertEqual(h.send(.localSize(Self.size(100, 40)), at: 3_300), [])
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(reads(in: h.send(.channelLiveness(true), at: 4_000)), 1)
        XCTAssertEqual(h.reply(Self.mine, at: 4_100), [.releaseGeometry(.ownerReplay)])
        XCTAssertEqual(ownerReplays(h), 1)
    }

    /// Any later read, framed behind the replay or not (an explicit open on
    /// a slow link, then cancelled), answered before the replay lands: the
    /// edge is answered already, so it neither replays again nor convicts.
    func test_R2_aReadAnsweredBeforeTheReplayLandsNeverConvicts() {
        var h = foregroundedOverAnOlderOwnedGrid()
        XCTAssertNil(h.session.query.current, "no read waits behind the replay")
        XCTAssertEqual(reads(in: h.send(.shown(source: .explicitOpen, stepAt: 3_200), at: 3_200)), 1)
        h.send(.cancelIntent, at: 3_400)
        let answered = h.reply(Self.mine, at: 5_050)
        XCTAssertEqual(claims(in: answered), [], "cancelled: R5")
        h.send(Self.window(1, Self.size(100, 40)), at: 5_100)
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertFalse(h.claimed)
        XCTAssertEqual(ownerReplays(h), 1)
    }

    /// The same with the session's re-read (`controlSessionChanged`) of a
    /// foreground read issued after the replay.
    func test_R2b_aSessionReReadAnsweredBeforeTheReplayLandsNeverConvicts() {
        var h = foregroundedOverAnOlderOwnedGrid()
        XCTAssertEqual(reads(in: h.send(.foregrounded, at: 3_150)), 1)
        XCTAssertEqual(reads(in: h.send(.controlSessionChanged(replacedKnownSession: false), at: 3_200)), 1)
        h.reply(Self.mine, at: 3_300)
        h.send(Self.window(1, Self.size(100, 40)), at: 3_350)
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    /// Our own re-push of the older grid after the replay (a keyboard
    /// animation's transient height), then the current grid again: tmux
    /// shows replay, re-push, current, and a read lands in between.
    func test_R3_ourOwnRePushOfAnOlderGridIsNeverAnotherDevice() {
        var h = foregroundedOverAnOlderOwnedGrid()
        h.send(.localSize(Self.size(92, 38)), at: 3_200)
        h.send(.sizeAdvertised(Self.size(92, 38)), at: 3_200)
        h.send(.localSize(Self.size(100, 40)), at: 3_700)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 3_700)
        XCTAssertEqual(reads(in: h.send(.foregrounded, at: 3_750)), 1)
        h.send(Self.window(1, Self.size(100, 40)), at: 4_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 4_050)
        h.reply(Self.mine, at: 4_100)
        h.send(Self.window(1, Self.size(100, 40)), at: 4_600)
        h.send(.tick, at: 10_000)
        XCTAssertFalse(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    /// A tap's claim still in flight at a hide (S4') and contested after
    /// it: its own stamp must not fence the hidden session, nor, landing
    /// first after the next show, continue the gesture the hide ended.
    func test_R4_aClaimContestedAfterTheHideNeverContinuesOwnWriteWon() {
        for stampWhileHidden in [true, false] {
            var h = yielded()
            h.send(.paintable(true), at: 900)
            let tap = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
            XCTAssertNotEqual(tap, 0)
            h.confirmFence(generation: tap, at: 1_100)
            h.send(.repaintSucceeded(generation: tap), at: 1_200)
            h.send(.hidden, at: 1_250)
            h.log.removeAll()
            h.send(.observedAuthority(.peer(deviceID: "MAC", displayName: "Mac", generation: 8)), at: 1_300)
            XCTAssertTrue(contested(h), "stampWhileHidden=\(stampWhileHidden): \(h.log)")
            if stampWhileHidden {
                XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 1_400)), [],
                               "a fence from a hidden session")
            }
            h.send(.adoptShown, at: 2_000)
            XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 2_100)), [],
                           "stampWhileHidden=\(stampWhileHidden): the hide ended that gesture")
            XCTAssertFalse(h.claimed, "stampWhileHidden=\(stampWhileHidden)")
            XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        }
    }

    /// The same in the background, contested before or after it.
    func test_R4b_aContestedClaimNeverContinuesOwnWriteWonFromTheBackground() {
        for contestFirst in [false, true] {
            var h = yielded()
            h.send(.paintable(true), at: 900)
            let tap = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
            XCTAssertNotEqual(tap, 0)
            h.confirmFence(generation: tap, at: 1_100)
            h.send(.repaintSucceeded(generation: tap), at: 1_200)
            h.log.removeAll()
            let contest = Event.observedAuthority(.peer(deviceID: "MAC", displayName: "Mac", generation: 8))
            if contestFirst { h.send(contest, at: 1_250) }
            h.send(.backgrounded, at: 1_260)
            if !contestFirst { h.send(contest, at: 1_300) }
            XCTAssertTrue(contested(h), "contestFirst=\(contestFirst)")
            XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 1_400)), [],
                           "contestFirst=\(contestFirst): a fence from the background (M6)")
            h.send(.foregrounded, at: 2_000)
            XCTAssertEqual(claims(in: h.send(.ownStampObserved(generation: tap), at: 2_100)), [],
                           "contestFirst=\(contestFirst): dropped, not deferred")
            XCTAssertFalse(h.claimed, "contestFirst=\(contestFirst)")
        }
    }

    /// A gesture's read answered in the background (its hide not delivered
    /// yet) leaves the gesture unresolved: no claim from there; the
    /// foreground asks again and claims while the gesture lasts (R3).
    func test_R4c_aGesturesReadAnsweredInTheBackgroundClaimsOnlyInTheForeground() {
        for foregroundAt in [Int64(5_000), 30_000] {
            var h = Harness()
            h.send(.attached)
            h.send(.adoptShown)
            h.send(.localSize(Self.size(92, 38)))
            h.send(Self.window(1, Self.size(80, 24)))
            h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
            h.reply("", at: 100)
            h.log.removeAll()
            XCTAssertEqual(reads(in: h.send(.shown(source: .explicitOpen, stepAt: 1_000), at: 1_000)), 1)
            h.send(.backgrounded, at: 1_100)
            XCTAssertEqual(h.reply(Self.mac, at: 1_200), [], "foregroundAt=\(foregroundAt)")
            XCTAssertFalse(h.claimed, "foregroundAt=\(foregroundAt): a claim from the background")
            let foreground = h.send(.foregrounded, at: foregroundAt)
            XCTAssertEqual(reads(in: foreground), 1, "foregroundAt=\(foregroundAt): \(foreground)")
            h.reply(Self.mac, at: foregroundAt + 100)
            XCTAssertEqual(h.claimed, foregroundAt < 21_000, "foregroundAt=\(foregroundAt): \(h.log)")
        }
    }

    /// The replay asks nothing of the channel: no read waits on it, so a
    /// later takeover by a client without a stamp is still judged.
    func test_R7_aReplayLeavesNothingOutstandingAndALaterTakeoverIsJudged() {
        var h = foregroundedOverAnOlderOwnedGrid()
        XCTAssertNil(h.session.query.current)
        XCTAssertFalse(h.session.query.wanted)
        h.send(Self.window(1, Self.size(100, 40)), at: 3_300)
        XCTAssertEqual(h.send(.tick, at: 8_100), [], "nothing unanswered")
        h.send(Self.window(1, Self.size(160, 48)), at: 60_000)
        XCTAssertTrue(raisedStamplessPeer(h), "\(h.log)")
        XCTAssertEqual(ownerReplays(h), 1)
    }

    /// Generations past `Int64.max` are unparseable here as on Android,
    /// where a `Long` holds them: one stamp is never two identities.
    func test_R8_aGenerationPastInt64MaxIsUnparseable() {
        XCTAssertEqual(TmuxGridAuthorityStamp.parse("v1 MAC \(Int64.max) Mac")?.generation, UInt64(Int64.max))
        XCTAssertNil(TmuxGridAuthorityStamp.parse("v1 MAC 9223372036854775808 Mac"))
        XCTAssertNil(TmuxGridAuthorityStamp.parse("v1 MAC \(UInt64.max) Mac"))
        XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: "v1 MAC 9223372036854775808 Mac", localDeviceID: "SELF"), .unknown)
        XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: "v1 SELF 9223372036854775808 iPad", localDeviceID: "SELF"), .unknown)
    }

    // MARK: Fifth review (S1-S6): no claim begins into a hidden or background session

    /// Yielded to the Mac, a tap's claim still running after its progress
    /// presentation timed out (S4').
    private func timedOutTap() -> Harness {
        var h = yielded()
        h.send(.paintable(true), at: 900)
        XCTAssertNotEqual(claims(in: h.send(.requestTakeBack, at: 1_000)), [])
        XCTAssertEqual(h.send(.tick, at: 4_000), [.hideReclaimPresentation])
        XCTAssertEqual(h.session.reducer.claim?.presentationVisible, false)
        h.log.removeAll()
        return h
    }

    /// A show edge while backgrounded (the wake's tracker edge before
    /// `foregrounded`) over a timed-out claim: never a restart from the
    /// background. The claim gives way to the show's intent, bounded by R3
    /// from the show's step, and the foreground read decides it.
    func test_S1_aShowInTheBackgroundLeavesItsIntentToTheForegroundRead() {
        for foregroundAt in [Int64(8_000), 40_000] {
            var h = timedOutTap()
            h.send(.backgrounded, at: 5_000)
            let shown = h.send(.shown(source: .show, stepAt: 5_100), at: 5_100)
            XCTAssertEqual(claims(in: shown), [], "foregroundAt=\(foregroundAt): a restart from the background")
            XCTAssertTrue(shown.contains(.claimAborted(.superseded)), "foregroundAt=\(foregroundAt): \(shown)")
            XCTAssertNil(h.session.reducer.claim)
            XCTAssertNotNil(h.session.reducer.pendingIntent)
            if h.session.query.current != nil { XCTAssertEqual(h.reply(Self.mac, at: 5_200), [], "left unread") }
            XCTAssertEqual(reads(in: h.send(.foregrounded, at: foregroundAt)), 1, "foregroundAt=\(foregroundAt)")
            let decided = h.reply(Self.mac, at: foregroundAt + 100)
            XCTAssertEqual(claims(in: decided).map(\.reason), foregroundAt < 25_100 ? [.show] : [],
                           "foregroundAt=\(foregroundAt): R3 from the show's step")
            XCTAssertEqual(h.claimedWhileInactive, [], "foregroundAt=\(foregroundAt)")
        }
    }

    /// A take-back while backgrounded, with or without a timed-out claim
    /// running: its intent waits for the foreground read.
    func test_S2_aTakeBackInTheBackgroundLeavesItsIntentToTheForegroundRead() {
        for timedOut in [false, true] {
            var h: Harness
            if timedOut {
                h = timedOutTap()
            } else {
                h = yielded()
                h.send(.paintable(true), at: 900)
            }
            h.send(.backgrounded, at: 5_000)
            let tapped = h.send(.requestTakeBack, at: 5_100)
            XCTAssertEqual(claims(in: tapped), [], "timedOut=\(timedOut): a claim from the background")
            XCTAssertEqual(tapped.contains(.claimAborted(.superseded)), timedOut, "timedOut=\(timedOut): \(tapped)")
            XCTAssertNotNil(h.session.reducer.pendingIntent, "timedOut=\(timedOut)")
            XCTAssertEqual(reads(in: h.send(.foregrounded, at: 6_000)), 1, "timedOut=\(timedOut)")
            XCTAssertEqual(claims(in: h.reply(Self.mac, at: 6_100)).map(\.reason), [.userTakeBack], "timedOut=\(timedOut)")
            XCTAssertEqual(h.claimedWhileInactive, [], "timedOut=\(timedOut)")
        }
    }

    /// A hidden session shows no veil to tap: a take-back there (a key
    /// routed to it) neither claims nor restarts one, and leaves no intent.
    func test_S3_aTakeBackIntoAHiddenSessionIsIgnored() {
        for timedOut in [false, true] {
            var h: Harness
            if timedOut {
                h = timedOutTap()
            } else {
                h = yielded()
                h.send(.paintable(true), at: 900)
            }
            let running = h.session.reducer.claim
            h.send(.hidden, at: 5_000)
            XCTAssertEqual(h.send(.requestTakeBack, at: 5_100), [], "timedOut=\(timedOut)")
            XCTAssertEqual(h.session.reducer.claim, running, "timedOut=\(timedOut): S4', it finishes on its own")
            XCTAssertNil(h.session.reducer.pendingIntent)
            h.send(.adoptShown, at: 6_000)
            XCTAssertEqual(h.claimedWhileInactive, [], "timedOut=\(timedOut)")
            XCTAssertFalse(h.claimed, "timedOut=\(timedOut)")
        }
    }

    /// A claim an adapter failure ends in the background is parked, and
    /// replayed only once the app is in the foreground again.
    func test_S4_aParkedReplayWaitsForTheForeground() {
        var h = yielded()
        h.send(.paintable(true), at: 900)
        let tap = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        XCTAssertNotEqual(tap, 0)
        h.send(.backgrounded, at: 1_100)
        let aborted = h.send(.abortClaim(generation: tap, reason: .adapterFailure), at: 1_200)
        XCTAssertEqual(claims(in: aborted), [], "a replay from the background: \(aborted)")
        XCTAssertNotNil(h.session.replay.parked)
        h.send(.adoptShown, at: 1_500)
        h.send(.tick, at: 1_800)
        let foreground = h.send(.foregrounded, at: 2_000)
        XCTAssertEqual(claims(in: foreground).map(\.reason), [.userTakeBack], "\(foreground)")
        XCTAssertEqual(h.claimedWhileInactive, [])
    }

    /// An explicit open whose own-stamp reply waits for geometry evidence,
    /// the hold's bound coming due unobserved (a sleep, a late tick), then
    /// a hide or a background: that edge applies first, so the bound's
    /// delivery claims nothing behind a lock screen. After a background the
    /// gesture still waits for the foreground read (R3).
    func test_S7_aBoundDueBeforeAHideOrBackgroundNeverClaimsIntoIt() {
        for background in [false, true] {
            var h = Harness()
            h.send(.attached)
            h.send(.adoptShown)
            h.reply("", at: 100)
            XCTAssertEqual(reads(in: h.send(.shown(source: .explicitOpen, stepAt: 1_000), at: 1_000)), 1)
            h.reply(Self.mine, at: 1_100)
            XCTAssertNotNil(h.session.query.held, "background=\(background): waiting for evidence")
            let edge = h.send(background ? .backgrounded : .hidden, at: 12_000)
            XCTAssertEqual(claims(in: edge), [], "background=\(background): \(edge)")
            XCTAssertNil(h.session.query.held)
            XCTAssertEqual(h.claimedWhileInactive, [], "background=\(background)")
            if background {
                XCTAssertNotNil(h.session.reducer.pendingIntent)
                XCTAssertTrue(h.session.query.wanted, "left unread for the foreground")
                h.send(.localSize(Self.size(92, 38)), at: 12_500)
                h.send(Self.window(1, Self.size(80, 24)), at: 12_500)
                h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 12_500)
                XCTAssertEqual(reads(in: h.send(.foregrounded, at: 13_000)), 1)
                XCTAssertEqual(claims(in: h.reply(Self.mine, at: 13_100)).map(\.reason), [.explicitOpen])
            } else {
                XCTAssertNil(h.session.reducer.pendingIntent, "a hide ends the gesture")
                XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3), "the reply still decides authority (D4)")
                XCTAssertFalse(h.claimed)
            }
        }
    }

    /// A channel that answers a read after every layout, while a client
    /// keeps putting an older grid of ours back: the read path, like the
    /// judge, replays an owned edge once, whichever decides first.
    func test_S5_aReadPerLayoutReplaysAnOwnedGridOnce() {
        for readFirst in [true, false] {
            var h = owner()
            h.send(.localSize(Self.size(100, 40)), at: 1_000)
            h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
            h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
            var t: Int64 = 10_000
            for _ in 0..<10 {
                if readFirst { h.send(.foregrounded, at: t) }
                h.send(Self.window(1, Self.size(92, 38)), at: t + 50)
                if !readFirst { h.send(.foregrounded, at: t + 60) }
                h.reply(Self.mine, at: t + 100)
                h.send(Self.window(1, Self.size(100, 40)), at: t + 300)
                t += 3_000
            }
            XCTAssertEqual(ownerReplays(h), 1, "readFirst=\(readFirst): \(h.log)")
            XCTAssertFalse(raisedStamplessPeer(h), "readFirst=\(readFirst)")
            XCTAssertEqual(h.session.geometryHold, .owner, "readFirst=\(readFirst)")
        }
    }

    /// An owned grid this device pushes again is current again: its next
    /// arrival is replayed, by the judge or by a read.
    func test_S6_anOwnedGridWePushAgainIsReplayedOnItsNextArrival() {
        var h = owner()
        h.send(.localSize(Self.size(100, 40)), at: 1_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 30_000), [.releaseGeometry(.ownerReplay)])
        h.send(Self.window(1, Self.size(100, 40)), at: 30_300)
        h.send(.localSize(Self.size(92, 38)), at: 40_000)
        h.send(.sizeAdvertised(Self.size(92, 38)), at: 40_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 40_100)
        h.send(.localSize(Self.size(100, 40)), at: 50_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 50_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 50_100)
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 80_000), [.releaseGeometry(.ownerReplay)],
                       "pushed again since its replay")
        XCTAssertEqual(ownerReplays(h), 2)
        XCTAssertFalse(raisedStamplessPeer(h))
    }

    /// Background rotations back and forth: each foreground read finds the
    /// grid the last replay left and replays the new one, whether or not the
    /// adapter has confirmed the replay's size yet.
    func test_S6b_rotationsAcrossBackgroundsReplayEachTime() {
        for confirmed in [true, false] {
            var h = owner()
            let sizes = [Self.size(100, 40), Self.size(92, 38), Self.size(100, 40), Self.size(92, 38)]
            var t: Int64 = 1_000
            for size in sizes {
                h.send(.backgrounded, at: t)
                h.send(.localSize(size), at: t + 1_000)
                h.send(.foregrounded, at: t + 2_000)
                XCTAssertEqual(h.reply(Self.mine, at: t + 2_100), [.releaseGeometry(.ownerReplay)],
                               "confirmed=\(confirmed): to \(size) at \(t)")
                if confirmed { h.send(.sizeAdvertised(size), at: t + 2_150) }
                h.send(Self.window(1, size), at: t + 2_300)
                t += 10_000
            }
            XCTAssertEqual(ownerReplays(h), sizes.count, "confirmed=\(confirmed)")
            XCTAssertFalse(raisedStamplessPeer(h), "confirmed=\(confirmed)")
        }
    }

    // MARK: Fourth review: guards that held before the fixes

    func test_V_hiddenOrBackgroundNeverReplays() {
        for background in [false, true] {
            var h = owner()
            h.send(.localSize(Self.size(100, 40)), at: 1_000)
            h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
            h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
            h.send(background ? .backgrounded : .hidden, at: 2_000)
            h.send(Self.window(1, Self.size(92, 38)), at: 30_000)
            h.send(.tick, at: 40_000)
            XCTAssertEqual(ownerReplays(h), 0, "background=\(background)")
            XCTAssertFalse(raisedStamplessPeer(h), "background=\(background)")
            XCTAssertEqual(h.sizedWhileHidden, [])
        }
    }

    func test_V_aResetThenAHiddenReattachDoesNotReplayHidden() {
        var h = owner()
        h.send(.localSize(Self.size(100, 40)), at: 1_000)
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        h.send(Self.window(1, Self.size(100, 40)), at: 1_100)
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 30_000), [.releaseGeometry(.ownerReplay)])
        h.send(.resetTransport(preservingPeer: true), at: 30_100)
        h.send(.hidden, at: 30_200)
        h.send(.attached, at: 31_000)
        h.send(Self.window(1, Self.size(92, 38)), at: 31_050)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 31_060)
        let effects = h.reply(Self.mine, at: 31_100)
        XCTAssertFalse(effects.contains(.releaseGeometry(.ownerReplay)), "\(effects)")
        XCTAssertEqual(h.sizedWhileHidden, [])
        XCTAssertFalse(raisedStamplessPeer(h))
    }

    func test_V_aStaleShowOverAPeerSendsNoClaimAndNoRead() {
        var h = yielded()
        h.send(.hidden, at: 500)
        let effects = h.send(.shown(source: .show, stepAt: 0), at: 25_000)
        XCTAssertEqual(claims(in: effects), [])
        XCTAssertEqual(reads(in: effects), 0)
    }

    // MARK: Third review: guards that held before the fixes

    func test_V_resetWhileHiddenThenAFreshShowReleases() {
        var h = owner()
        h.send(.hidden, at: 1_000)
        h.send(.resetTransport(preservingPeer: false), at: 1_100)
        h.send(.attached, at: 1_200)
        h.send(Self.window(1, Self.size(92, 38)), at: 1_250)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 1_260)
        h.reply(Self.mine, at: 1_300)
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(reads(in: h.send(.shown(source: .show, stepAt: 5_000), at: 5_000)), 1)
        h.reply(Self.mine, at: 5_100)
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertEqual(h.sizedWhileHidden, [])
    }

    func test_V_adoptShownDuringAClaimThenSettleOrAbortResolves() {
        for settle in [true, false] {
            var h = owner()
            h.send(.paintable(true), at: 500)
            h.send(.hidden, at: 1_000)
            h.send(.localSize(Self.size(100, 40)), at: 2_000)
            h.send(.shown(source: .show, stepAt: 3_000), at: 3_000)
            let generation = claims(in: h.reply(Self.mine, at: 3_100)).first?.generation ?? 0
            XCTAssertNotEqual(generation, 0)
            h.send(.claimAdvertisedGeometry(generation: generation, size: Self.size(100, 40)))
            h.send(.hidden, at: 3_200)
            XCTAssertEqual(reads(in: h.send(.adoptShown, at: 3_300)), 0, "a claim runs")
            if settle {
                h.confirmFence(generation: generation, at: 3_400)
                h.send(.repaintSucceeded(generation: generation), at: 3_500)
                h.send(.stampCommitSucceeded(generation: generation), at: 3_600)
                h.send(.settleClaim(generation: generation), at: 3_700)
            } else {
                XCTAssertEqual(reads(in: h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 3_400)), 1)
                h.reply(Self.mine, at: 3_500)
            }
            XCTAssertEqual(h.session.geometryHold, .owner, "settle=\(settle)")
        }
    }

    func test_V_spentRetriesClearRetryAt() {
        var h = owner()
        h.send(.foregrounded, at: 1_000)
        var now: Int64 = 1_100
        var failures = 0
        while let id = h.session.query.current?.id, now < 20_000 {
            h.send(.queryFailed(id: id), at: now)
            failures += 1
            now += 2_000
            h.send(.tick, at: now)
        }
        XCTAssertEqual(failures, 4)
        XCTAssertNil(h.session.query.retryAt)
        XCTAssertNil(h.session.query.current)
        XCTAssertFalse(h.session.query.wanted)
        h.send(Self.window(1, Self.size(120, 40)), at: 30_000)
        XCTAssertTrue(raisedStamplessPeer(h))
    }

    func test_V_parseBoundsKeepRealAndOwnStamps() {
        let uuid = UUID().uuidString
        for name in ["iPad", "iPhone", "Android-Phone", "Android-Tablet", "Mac", "My iPad 🇫🇷 é", String(repeating: "N", count: 200)] {
            let identity = TmuxGridAuthorityIdentity(id: uuid, displayName: name)
            let stamp = TmuxGridAuthorityStamp(identity: identity, generation: 9)
            XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: stamp.wireValue, localDeviceID: uuid), .mine(generation: 9), name)
            let peer = TmuxGridAuthoritySnapshot.classify(rawValue: stamp.wireValue, localDeviceID: "OTHER")
            XCTAssertTrue(peer.isPeer, name)
            XCTAssertLessThanOrEqual(peer.peerDisplayName?.count ?? 0, TmuxGridAuthorityStamp.maximumDisplayNameCharacters)
        }
        let longID = String(repeating: "D", count: TmuxGridAuthorityStamp.maximumDeviceIDCharacters + 1)
        XCTAssertNil(TmuxGridAuthorityStamp.parse("v1 \(longID) 1 Mac"))
        XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: "v1 \(longID) 1 Mac", localDeviceID: longID), .unknown)
    }

    // MARK: Second review: guards that held before the fixes

    func test_V_aResetAndForegroundBeforeTheAttachDoNotStickTheHold() {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(.resetTransport(preservingPeer: true), at: 1_100)
        h.send(.foregrounded, at: 2_000)
        h.send(.attached, at: 2_100)
        h.send(Self.window(1, Self.size(92, 38)), at: 2_150)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: 2_160)
        h.reply(Self.mine, at: 2_200)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_V_aShowReadAnsweredBeforeTheForegroundReleasesOnTheForegroundRead() {
        var h = owner()
        h.send(.backgrounded, at: 1_000)
        h.send(.hidden, at: 2_500)
        h.send(.shown(source: .show, stepAt: 9_000), at: 9_000)
        h.reply(Self.mine, at: 9_050)
        XCTAssertEqual(h.session.geometryHold, .withheld)
        h.send(.foregrounded, at: 9_100)
        if h.session.query.current != nil { h.reply(Self.mine, at: 9_200) }
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_V_aClaimAbortedAfterAForegroundReleasesOnlyAfterARead() {
        var h = yielded()
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.send(.paintable(false))
        let generation = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        h.send(.backgrounded, at: 1_100)
        h.send(.foregrounded, at: 1_200)
        let aborted = h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 1_300)
        XCTAssertEqual(h.session.geometryHold, .withheld, "\(aborted)")
    }

    func test_V_abortsAndReplaysNeverLoopPastTheBudget() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(120, 40)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.reply(Self.mine)
        h.send(.paintable(true))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        var now: Int64 = 1_100
        var claimCount = 0
        for _ in 0..<40 {
            guard h.session.query.current != nil else { break }
            let effects = h.reply(Self.mine, at: now)
            now += 50
            if let claim = claims(in: effects).first {
                claimCount += 1
                let more = h.send(.abortClaim(generation: claim.generation, reason: .adapterFailure), at: now)
                now += 50
                XCTAssertLessThanOrEqual(reads(in: more), 1)
            }
        }
        XCTAssertGreaterThan(claimCount, 0)
        XCTAssertLessThanOrEqual(claimCount, TmuxAuthorityClaimReplay.defaultBudget + 1)
        XCTAssertNil(h.session.query.current)
    }

    func test_V_aCappedNameKeepsIdentityAcrossTheRuntimeAndTheRead() {
        let long = String(repeating: "N", count: 200)
        let raw = "v1 MAC 7 \(long)"
        let viaRead = TmuxGridAuthoritySnapshot.classify(rawValue: raw, localDeviceID: "SELF")
        let stamp = TmuxGridAuthorityStamp.parse(raw)
        XCTAssertEqual(viaRead, .peer(deviceID: "MAC", displayName: stamp?.displayName ?? "", generation: 7))
        let own = TmuxGridAuthorityStamp(identity: .init(id: "SELF", displayName: long), generation: 9)
        XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: own.wireValue, localDeviceID: "SELF"), .mine(generation: 9))
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(raw)
        h.send(.channelLiveness(false), at: 100)
        h.send(.requestTakeBack, at: 200)
        h.send(.observedAuthority(viaRead), at: 300)
        XCTAssertNotNil(h.session.reducer.pendingIntent, "the tap stays bound to the capped name")
    }

    // MARK: F9: adapters feed the tracker before the session on wake

    /// A show waits for a mosh side channel; the device locks and sleeps
    /// through the hide debounce; it wakes, still locked, and the channel
    /// heals. The tracker's overdue hide must reach the session before the
    /// wake's read is answered, or that read resolves the show behind the
    /// lock.
    func test_F9_onWakeTheTrackerIsFedFirstSoNothingClaimsBehindTheLock() {
        func run(trackerFirst: Bool) -> Bool {
            var tracker = TmuxShowEdgeTracker()
            var h = Harness()
            func feed(_ edges: [TmuxShowEdgeTracker.Edge], at now: Int64) {
                for edge in edges {
                    switch edge {
                    case .hide: h.send(.hidden, at: now)
                    case .show(let source, let stepAt): h.send(.shown(source: source, stepAt: stepAt), at: now)
                    }
                }
            }
            h.send(.attached, at: 0)
            h.reply(Self.mac, at: 10)
            h.send(.channelLiveness(false), at: 20)
            feed(tracker.displayed(true, now: 1_000), at: 1_000)
            feed(tracker.tick(now: 1_350), at: 1_350)
            XCTAssertNotNil(h.session.reducer.pendingIntent, "the show waits for the channel")
            // Locked: not displayed. No tick runs while the device sleeps.
            feed(tracker.displayed(false, now: 5_000), at: 5_000)
            let wake: Int64 = 15_000
            if trackerFirst {
                feed(tracker.tick(now: wake), at: wake)
                h.send(.channelLiveness(true), at: wake)
                if h.session.query.current != nil { h.reply(Self.mac, at: wake + 100) }
            } else {
                h.send(.channelLiveness(true), at: wake)
                if h.session.query.current != nil { h.reply(Self.mac, at: wake + 100) }
                feed(tracker.tick(now: wake + 200), at: wake + 200)
            }
            return h.claimed
        }
        XCTAssertFalse(run(trackerFirst: true), "the contract: tracker first, then the session")
        XCTAssertTrue(run(trackerFirst: false), "the hazard the contract exists for")
    }

    // MARK: ABI-2: a long peer name is capped, never rejected

    func test_ABI2_aLongPeerNameIsCappedAndKeepsItsIdentity() {
        let long = String(repeating: "N", count: 20_000)
        let stamp = TmuxGridAuthorityStamp.parse("v1 MAC 7 \(long)")
        XCTAssertEqual(stamp?.deviceID, "MAC")
        XCTAssertEqual(stamp?.generation, 7)
        XCTAssertEqual(stamp?.displayName, String(repeating: "N", count: TmuxGridAuthorityStamp.maximumDisplayNameCharacters))
        XCTAssertEqual(TmuxGridAuthorityStamp.maximumDisplayNameCharacters, 64)
        XCTAssertEqual(
            TmuxGridAuthoritySnapshot.classify(rawValue: "v1 MAC 7 \(long)", localDeviceID: "SELF"),
            .peer(deviceID: "MAC", displayName: String(repeating: "N", count: 64), generation: 7)
        )
        let exact = String(repeating: "x", count: 64)
        XCTAssertEqual(TmuxGridAuthorityStamp.parse("v1 MAC 7 \(exact)")?.displayName, exact, "a 64-character name is kept whole")
        XCTAssertNil(TmuxGridAuthorityStamp.parse("v1 MAC 7 \(long)!"), "an invalid name is still refused, not truncated into validity")
    }

    func test_ABI2_aLongDeviceIDMakesTheStampUnparseable() {
        let bound = TmuxGridAuthorityStamp.maximumDeviceIDCharacters
        XCTAssertEqual(bound, 128)
        let atBound = String(repeating: "D", count: bound)
        XCTAssertEqual(TmuxGridAuthorityStamp.parse("v1 \(atBound) 7 Mac")?.deviceID, atBound)
        let past = String(repeating: "D", count: bound + 1)
        XCTAssertNil(TmuxGridAuthorityStamp.parse("v1 \(past) 7 Mac"), "identity is never cut short")
        XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: "v1 \(past) 7 Mac", localDeviceID: "SELF"), .unknown)
    }

    // MARK: F2: a replayed claim stays under R3

    /// Shown at 0, claimed at 100: the user's step is 0.
    private func showClaimAtZero(paintable: Bool) -> (Harness, UInt64) {
        var h = Harness()
        h.send(.attached, at: 0)
        h.send(.adoptShown)
        h.reply(Self.mac)
        h.send(.paintable(paintable))
        h.send(.shown(source: .show, stepAt: 0), at: 0)
        let generation = claims(in: h.reply(Self.mac, at: 100)).first?.generation ?? 0
        XCTAssertNotEqual(generation, 0)
        h.log.removeAll()
        return (h, generation)
    }

    func test_F2_anAbortAfterTheGesturesWindowIsNeverReplayed() {
        var (h, generation) = showClaimAtZero(paintable: true)
        XCTAssertEqual(h.send(.tick, at: 3_100), [.hideReclaimPresentation], "the presentation timed out")
        h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 60_000)
        XCTAssertNil(h.session.replay.parked)
        XCTAssertNil(h.session.reducer.pendingIntent, "60 s after the show: R3 dropped it")
        XCTAssertNil(h.session.carriedShow(now: h.now))
        if h.session.query.current != nil { h.reply(Self.mac, at: 60_100) }
        XCTAssertFalse(h.claimed, "\(h.log)")
    }

    func test_F2_aParkedReplayLapsesWithTheUsersStepNotTheFirstPark() {
        var (h, generation) = showClaimAtZero(paintable: false)
        h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 15_000)
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 0))
        h.send(.paintable(true), at: 34_000)
        XCTAssertNil(h.session.replay.parked)
        XCTAssertNil(h.session.reducer.pendingIntent, "34 s after the show")
        h.send(.resetTransport(preservingPeer: true), at: 34_100)
        h.send(.attached, at: 50_000)
        XCTAssertNil(h.session.query.current?.intentToken)
        h.reply(Self.mac, at: 50_100)
        XCTAssertFalse(h.claimed, "\(h.log)")
    }

    func test_F2_aReplayKeepsTheUsersStepForItsIntentAndCarriedShow() {
        var (h, generation) = showClaimAtZero(paintable: false)
        h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 5_000)
        h.send(.paintable(true), at: 6_000)
        XCTAssertNotNil(h.session.reducer.pendingIntent, "replayed within the window")
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 0), "not the replay time")
        XCTAssertEqual(h.session.intentClock.deadline, 20_000)
        h.send(.tick, at: 20_000)
        XCTAssertNil(h.session.reducer.pendingIntent)
        if h.session.query.current != nil { h.reply(Self.mac, at: 20_100) }
        XCTAssertFalse(h.claimed, "the replayed intent expired with the user's step")
    }

    func test_F2_aTakeBackReplayLapsesWithItsTap() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(Self.mac)
        h.send(.paintable(false))
        let generation = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
        h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 2_000)
        h.log.removeAll()
        h.send(.paintable(true), at: 21_000)
        XCTAssertFalse(h.claimed, "20 s after the tap")
        XCTAssertNil(h.session.replay.parked)
    }

    // MARK: F5: extreme clocks clamp, never trap

    func test_F5_extremeTimesNeverTrapTheSession() {
        let extremes: [Int64] = [.min, .min + 1, -1, 0, 1, .max - 1, .max]
        for now in extremes {
            for step in extremes {
                var h = Harness()
                h.send(.attached, at: now)
                h.send(.shown(source: .show, stepAt: step), at: now)
                h.send(.localSize(Self.size(92, 38)))
                h.send(Self.window(1, Self.size(120, 40)))
                h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
                h.send(.sizeAdvertised(Self.size(92, 38)))
                h.send(.prompt(scope: .session, active: true))
                h.send(.prompt(scope: .session, active: false))
                _ = h.session.carriedShow(now: now)
                for later in extremes {
                    var copy = h
                    copy.send(.tick, at: later)
                    copy.send(.queryReplied(id: 99, raw: Self.mine))
                    copy.send(.queryFailed(id: copy.session.query.current?.id ?? 1))
                    copy.send(.tick, at: now)
                    _ = copy.session.carriedShow(now: later)
                    _ = copy.session.nextDeadline
                }
            }
        }
    }

    func test_F5_aStepFromTheFarPastIsDroppedAndOneFromTheFutureIsNow() {
        var past = Harness()
        past.send(.shown(source: .show, stepAt: .min), at: 1_000)
        XCTAssertNil(past.session.reducer.pendingIntent, "outlived its window")
        XCTAssertFalse(past.session.hidden)

        var future = Harness()
        future.send(.shown(source: .show, stepAt: .max), at: 1_000)
        XCTAssertEqual(future.session.carriedShow(now: 1_000), .init(source: .show, stepAt: 1_000))
        XCTAssertEqual(future.session.nextDeadline, 21_000)

        var late = Harness()
        late.send(.attached, at: .max)
        XCTAssertEqual(late.session.nextDeadline, .max, "a saturated bound, not a wrapped one that fires at once")
        XCTAssertEqual(late.send(.tick, at: .max - 1), [])
    }

    func test_F5_extremeTimesNeverTrapTheTrackerJudgeOrClock() {
        let extremes: [Int64] = [.min, -1, 0, 1, .max]
        for first in extremes {
            for second in extremes {
                var tracker = TmuxShowEdgeTracker()
                _ = tracker.transparentBegan(now: first)
                _ = tracker.displayed(true, now: second)
                _ = tracker.explicitOpen(now: first)
                _ = tracker.tick(now: second)
                _ = tracker.transparentEnded(now: second)
                _ = tracker.displayed(false, now: first)
                _ = tracker.tick(now: second)
                _ = tracker.nextDeadline

                var judge = TmuxStamplessPeerJudge()
                _ = judge.judge(.init(
                    blocked: false,
                    window: .init(windowID: 1, size: Self.size(120, 40)),
                    policyIsLatest: true,
                    local: Self.size(92, 38),
                    alreadyPeer: false,
                    lastLocalReplayAt: first
                ), now: second)
                _ = judge.takeDueRejudge(now: second)

                var clock = TmuxAuthorityIntentClock()
                clock.track(1, stepAt: first)
                _ = clock.remaining(now: second)
                _ = clock.elapsed(now: second)
                _ = clock.expiredToken(now: second)

                var replay = TmuxAuthorityClaimReplay()
                var reducer = TmuxGridAuthorityLifecycleReducer()
                reducer.attached()
                reducer.observedAuthority(macPeer)
                for case .beginClaim(let claim) in reducer.requestTakeBack() {
                    _ = replay.park(claim, stepAt: first, hidden: false, now: second)
                }
                _ = replay.take(paintable: true, hidden: false, busy: false, authority: macPeer, now: first)
            }
        }
        var tracker = TmuxShowEdgeTracker()
        _ = tracker.explicitOpen(now: .max - 1)
        XCTAssertEqual(tracker.explicitOpenUntil, .max, "saturated, not wrapped into the past")
    }
}
