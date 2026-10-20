import XCTest
@testable import TmuxControlCore

/// §6.10 at the session boundary: geometry, one claim-end verdict, and
/// the gesture replay that an adapter's rule 6 stall check must preserve.
final class AuthoritySessionClaimEndOfLifeTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer
    private typealias Effect = Session.Effect
    private static let local = TmuxGridSize(columns: 92, rows: 38)
    private static let foreign = TmuxGridSize(columns: 130, rows: 50)
    private static let owned = TmuxGridSize(columns: 100, rows: 40)

    private struct Harness {
        var session = Session(localDeviceID: "SELF")
        var now: Int64 = 0
        var generation: UInt64 { session.reducer.claim?.generation ?? 0 }

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
        mutating func send(_ event: Session.Event, at: Int64? = nil) -> [Effect] {
            if let at { now = at }
            return session.reduce(event, now: now)
        }

        @discardableResult
        mutating func window(_ size: TmuxGridSize) -> [Effect] {
            send(.windowFacts(hydrated: true, activeWindow: .init(id: 1, size: size, authoritative: true)))
        }

        @discardableResult
        mutating func advertise(_ size: TmuxGridSize) -> [Effect] {
            send(.claimAdvertisedGeometry(generation: generation, size: size))
        }

        @discardableResult
        mutating func reply(_ raw: String) -> [Effect] {
            let id = session.query.current?.id ?? 0
            XCTAssertNotEqual(id, 0)
            return send(.queryReplied(id: id, raw: raw))
        }

        mutating func stamp() {
            let g = generation
            confirmFence(generation: g)
            send(.repaintSucceeded(generation: g))
            send(.stampCommitSucceeded(generation: g))
        }
    }

    /// Begin over our own stamp at an older owned grid: unlike a peer
    /// stamp, it leaves rule 7 to judge a foreign window after an abort.
    private func claim(configuration: Session.Configuration = .init()) -> Harness {
        var h = Harness(session: Session(localDeviceID: "SELF", configuration: configuration))
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.owned))
        h.window(Self.owned)
        h.reply("v1 SELF 3 iPad")
        h.send(.localSize(Self.local))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        h.reply("v1 SELF 3 iPad")
        XCTAssertNotEqual(h.generation, 0)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.advertise(Self.local)
        return h
    }

    private func raised(_ effects: [Effect]) -> Bool { effects.contains(.raiseStamplessPeer) }

    private func releases(_ effects: [Effect]) -> [Session.GeometryRelease] {
        effects.compactMap {
            if case .releaseGeometry(let release) = $0, release != .none { return release }
            return nil
        }
    }

    func testInactiveVisibleClaimWithholdsChurnAndNeverRefencesBeforeDeadline() {
        for inactive in [Session.Event.hidden, .backgrounded] {
            var h = claim()
            let g = h.generation
            h.send(inactive, at: 1_100)
            XCTAssertEqual(h.session.geometryHold, .withheld, "\(inactive)")
            XCTAssertFalse(h.session.claimMayAdvertiseGeometry, "\(inactive)")
            let before = h.session.reducer.claim
            let advertised = h.session.lastAdvertisedSize
            h.send(.localSize(Self.foreign))
            h.advertise(Self.foreign)
            XCTAssertEqual(h.session.reducer.claim, before, "inactive churn cannot retarget")
            XCTAssertEqual(h.session.lastAdvertisedSize, advertised)
            let loss = h.send(.claimObservedGeometry(generation: g, size: .init(columns: 150, rows: 60), settleProbe: true))
            XCTAssertFalse(loss.contains(.refenceClaim(generation: g)), "inactive loss cannot fence")
            XCTAssertTrue(loss.contains(.claimAborted(.geometryLost)), "a landed loss ends the late claim")
            XCTAssertTrue(releases(loss).isEmpty)
        }
    }

    func testDeferredAbortOwnStampReadRetainsTheClaimsAdvertisedExclusions() {
        for held in [false, true] {
            var h = claim()
            h.send(.localSize(.init(columns: 110, rows: 42)))
            h.window(Self.local)
            h.send(.attached)
            if held {
                h.send(.windowFacts(hydrated: false, activeWindow: .init(id: 1, size: Self.local, authoritative: true)))
                h.reply("v1 SELF 3 iPad")
                XCTAssertNotNil(h.session.query.held)
            }
            h.send(.abortClaim(generation: h.generation, reason: .superseded))
            let effects = held ? h.window(Self.local) : h.reply("v1 SELF 3 iPad")
            XCTAssertFalse(raised(effects), "our aborted advertisement is not a peer")
            XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        }
    }

    func testDeferredAbortEmptyReadJudgesBeforeAnyGeometryRelease() {
        var h = claim()
        h.window(Self.foreign)
        h.send(.attached)
        h.send(.abortClaim(generation: h.generation, reason: .superseded))
        let effects = h.reply("")
        XCTAssertTrue(raised(effects))
        XCTAssertTrue(releases(effects).isEmpty, "a yielded reduction must send no geometry")
        XCTAssertEqual(h.session.lastAdvertisedSize, Self.local)
    }

    func testParkedFailureExpirySchedulesAndRequestsAnAuthorityJudgmentWhileUnpaintable() {
        var h = claim()
        h.window(Self.foreign)
        h.send(.paintable(false))
        h.send(.abortClaim(generation: h.generation, reason: .adapterFailure))
        XCTAssertNotNil(h.session.replay.parked)
        XCTAssertEqual(h.session.nextDeadline, 21_000, "the original step bounds replay")
        let expired = h.send(.tick, at: 21_000)
        XCTAssertNil(h.session.replay.parked, "expiry does not wait for paintability")
        XCTAssertTrue(expired.contains(where: { if case .queryAuthority = $0 { return true }; return false }),
                      "expiry must arrange a fresh authority verdict")
        let paintable = h.send(.paintable(true))
        XCTAssertFalse(paintable.contains(where: { if case .beginClaim = $0 { return true }; return false }))
        XCTAssertNotNil(h.session.query.current)
        XCTAssertTrue(raised(h.reply("v1 SELF 3 iPad")))
        XCTAssertEqual(h.session.geometryHold, .withheld)
    }

    func testCancellingParkedFailureStillJudgesAndRecoversOrdinaryGeometry() {
        var h = claim()
        h.window(Self.local)
        h.send(.paintable(false))
        h.send(.abortClaim(generation: h.generation, reason: .adapterFailure))
        let cancelled = h.send(.cancelIntent)
        XCTAssertNil(h.session.replay.parked)
        XCTAssertFalse(raised(cancelled))
        XCTAssertNotNil(h.session.query.current, "cancelling replay must not strand the abort's hold")
        h.reply("v1 SELF 3 iPad")
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertNil(h.session.reducer.claim, "cancelled replay never claims")
    }

    func testReadWhileFailureIsParkedNeverReleasesGeometryIncludingAtExpiry() {
        for replyAt: Int64 in [1_100, 21_000] {
            var h = claim()
            h.window(Self.foreign)
            h.send(.paintable(false))
            h.send(.abortClaim(generation: h.generation, reason: .adapterFailure))
            h.send(.attached)
            h.now = replyAt
            let effects = h.reply("")
            XCTAssertTrue(releases(effects).isEmpty, "a parked or expiring abort still needs its verdict")
            XCTAssertEqual(h.session.geometryHold, .withheld)
            if replyAt == 21_000 {
                XCTAssertNil(h.session.replay.parked)
                XCTAssertNotNil(h.session.query.current)
                XCTAssertTrue(raised(h.reply("")))
            } else {
                XCTAssertNotNil(h.session.replay.parked)
            }
        }
    }

    func testAbortRecoveryReadKeepsItsRetryBudgetBounded() {
        var h = claim(configuration: .init(replayBudget: 0))
        h.window(Self.local)
        h.send(.abortClaim(generation: h.generation, reason: .adapterFailure))
        XCTAssertNotNil(h.session.query.current)
        for attempt in 1...4 {
            h.send(.queryFailed(id: h.session.query.current?.id ?? 0))
            XCTAssertEqual(h.session.query.failures, attempt)
            if attempt < 4 {
                h.send(.tick, at: h.now + Int64(attempt) * 250)
                XCTAssertNotNil(h.session.query.current)
            }
        }
        XCTAssertNil(h.session.query.current)
        XCTAssertNil(h.session.query.retryAt)
        XCTAssertNil(h.session.nextDeadline)
        XCTAssertEqual(h.send(.tick, at: 30_000), [])
        XCTAssertEqual(h.session.geometryHold, .withheld, "exhausted read retries still fail closed")
    }

    func testSettlementKeepsChurnPendingUntilTheChannelHealsExactlyOnce() {
        var h = claim()
        let g = h.generation
        h.window(Self.local)
        h.stamp()
        h.send(.tick, at: 4_000)
        let changed = TmuxGridSize(columns: 140, rows: 55)
        h.send(.localSize(changed))
        h.send(.channelLiveness(false))
        let settled = h.send(.settleClaim(generation: g))
        XCTAssertTrue(releases(settled).isEmpty, "a dead channel cannot consume churn")
        XCTAssertEqual(h.session.lastAdvertisedSize, Self.local)
        XCTAssertFalse(h.session.evidence.owned.contains(changed))
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertTrue(h.session.query.wanted)
        let healed = h.send(.channelLiveness(true))
        XCTAssertEqual(healed.filter { if case .queryAuthority = $0 { return true }; return false }.count, 1)
        let reply = h.reply("v1 SELF 3 iPad")
        XCTAssertEqual(releases(reply), [.ownerReplay])
        XCTAssertEqual(h.session.lastAdvertisedSize, changed)
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertTrue(releases(h.send(.tick)).isEmpty)
        XCTAssertTrue(releases(h.send(.channelLiveness(true))).isEmpty)
    }

    func testDeadChannelSettlementKeepsLaterChurnPendingUntilHealing() {
        var h = claim()
        let g = h.generation
        h.window(Self.local)
        h.stamp()
        h.send(.channelLiveness(false))
        let settled = h.send(.settleClaim(generation: g))
        XCTAssertTrue(releases(settled).isEmpty)
        XCTAssertEqual(h.session.geometryHold, .withheld, "a dead channel must retain the settlement hold")
        let changed = TmuxGridSize(columns: 140, rows: 55)
        h.send(.localSize(changed))
        let healed = h.send(.channelLiveness(true))
        XCTAssertEqual(healed.filter { if case .queryAuthority = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(releases(h.reply("v1 SELF 3 iPad")), [.ownerReplay])
        XCTAssertEqual(h.session.lastAdvertisedSize, changed)
        XCTAssertTrue(releases(h.send(.tick)).isEmpty)
    }

    func testVisibleAdvertisementRetargetsWithoutRecordingOwnership() {
        var h = claim()
        let changed = TmuxGridSize(columns: 110, rows: 42)
        h.confirmFence(generation: h.generation)
        h.advertise(changed)
        XCTAssertEqual(h.session.lastAdvertisedSize, changed)
        XCTAssertEqual(h.session.lastAdvertisedAt, 1_000)
        XCTAssertEqual(h.session.reducer.claim?.targetGrid, .init(columns: 110, rows: 42))
        XCTAssertEqual(h.session.reducer.claim?.phase, .awaitingFence)
        XCTAssertFalse(h.session.evidence.owned.contains(changed))
        XCTAssertTrue(h.session.claimMayAdvertiseGeometry)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func testStaleAndInvalidAdvertisementReportsChangeNothing() {
        var h = claim()
        let before = h.session
        XCTAssertEqual(h.send(.claimAdvertisedGeometry(generation: h.generation + 1, size: Self.foreign)), [])
        XCTAssertEqual(h.send(.claimAdvertisedGeometry(generation: h.generation, size: .init(columns: 0, rows: 1))), [])
        XCTAssertEqual(h.session, before)
        XCTAssertEqual(h.send(.sizeAdvertised(Self.foreign)), [], "a live claim uses only its own report")
        XCTAssertEqual(h.session, before)
    }

    func testAcceptedClaimAdvertisementForgetsAnOwnedReplayMemo() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.owned))
        h.window(Self.owned)
        h.reply("v1 SELF 3 iPad")
        h.send(.localSize(Self.local))
        h.send(.foregrounded)
        h.reply("v1 SELF 3 iPad")
        let edge = TmuxStamplessPeerJudge.Edge(windowID: 1, size: Self.owned)
        XCTAssertTrue(h.session.stamplessJudge.replayedOwnedEdges.contains(edge))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        h.reply("v1 SELF 3 iPad")
        h.advertise(Self.owned)
        XCTAssertFalse(h.session.stamplessJudge.replayedOwnedEdges.contains(edge))
    }

    func testDeadlineLeavesLateClaimBusyAndIgnoresAllAdvertisements() {
        var h = claim()
        let g = h.generation
        XCTAssertEqual(h.send(.tick, at: 4_000), [.hideReclaimPresentation])
        let before = h.session
        XCTAssertFalse(h.session.claimMayAdvertiseGeometry)
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 1_000))
        XCTAssertEqual(h.send(.claimAdvertisedGeometry(generation: g, size: Self.foreign), at: 4_100), [])
        XCTAssertEqual(h.session, before)
        h.window(Self.foreign)
        XCTAssertFalse(h.session.reducer.authority.isPeer, "a late claim still blocks the ordinary judge")
        XCTAssertNotNil(h.session.reducer.claim)
    }

    func testLandedForeignObservationPassesThroughOneRefenceThenGeometryLost() {
        var h = claim()
        let g = h.generation
        h.window(Self.foreign)
        let loss = Session.Event.claimObservedGeometry(generation: g, size: Self.foreign, settleProbe: true)
        XCTAssertEqual(h.send(loss), [.refenceClaim(generation: g)])
        XCTAssertTrue(h.session.reducer.claim?.geometryRefenced == true)
        XCTAssertEqual(h.send(loss), [.hideReclaimPresentation, .claimAborted(.geometryLost),
                                     .authorityChanged(.peer(deviceID: "-", displayName: "another device", generation: 0)),
                                     .raiseStamplessPeer])
        XCTAssertNil(h.session.replay.parked)
        XCTAssertEqual(h.session.replay.count, 0)
        XCTAssertEqual(h.send(.paintable(true)), [])
        XCTAssertNil(h.session.query.current, "geometryLost never replays or rereads")
    }

    func testAdapterGeometryLostUsesTheSameRefenceAndAbortPath() {
        var h = claim()
        let g = h.generation
        h.confirmFence(generation: g)
        XCTAssertEqual(h.send(.claimGeometryLost(generation: g)), [.refenceClaim(generation: g)])
        h.confirmFence(generation: g)
        XCTAssertTrue(h.send(.claimGeometryLost(generation: g)).contains(.claimAborted(.geometryLost)))
    }

    func testAbortRejudgesImmediatelyWithoutReplaySuppressionOrTheClaimsHold() {
        var h = claim()
        h.window(Self.foreign)
        XCTAssertTrue(h.session.heldForRead)
        let effects = h.send(.abortClaim(generation: h.generation, reason: .superseded))
        XCTAssertTrue(raised(effects))
        XCTAssertEqual(effects.filter { if case .raiseStamplessPeer = $0 { return true }; return false }.count, 1)
        XCTAssertNil(h.session.query.current)
        XCTAssertEqual(h.window(Self.foreign), [], "the judged edge is consumed once")
        XCTAssertEqual(h.send(.tick, at: 3_100), [])
    }

    func testAbortExcludesLocalTargetAdvertisedAndOwnedGrids() {
        let advertised = TmuxGridSize(columns: 115, rows: 44)
        for size in [Self.local, advertised, Self.owned] {
            var h = claim()
            h.advertise(advertised)
            h.advertise(Self.local)
            h.window(size)
            XCTAssertFalse(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))), "\(size)")
            XCTAssertFalse(h.session.reducer.authority.isPeer)
        }
    }

    func testAbortExcludesTargetEvenWhenVisibleStampPhaseChurnChangesTheLastAdvertisement() {
        var h = claim()
        h.stamp()
        h.advertise(Self.foreign)
        h.send(.localSize(.init(columns: 140, rows: 55)))
        h.window(Self.local)
        XCTAssertFalse(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))))
    }

    func testAbortUsesCompleteAdvertisedMembershipBeyondDiagnosticLimit() {
        var h = claim()
        let first = TmuxGridSize(columns: 101, rows: 41)
        h.advertise(first)
        for columns in 102...125 { h.advertise(.init(columns: columns, rows: 41)) }
        XCTAssertEqual(h.session.reducer.claim?.advertisedGrids.count, Reducer.maximumAdvertisedGrids)
        XCTAssertFalse(h.session.reducer.claim!.advertisedGrids.contains(.init(columns: 101, rows: 41)))
        h.window(first)
        XCTAssertFalse(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))))
        XCTAssertFalse(h.session.reducer.authority.isPeer)
    }

    func testParkedAdapterFailureUsesOnlyTheReplaysFreshRead() {
        for paintable in [false, true] {
            var h = claim()
            h.send(.paintable(paintable))
            h.window(Self.foreign)
            let effects = h.send(.abortClaim(generation: h.generation, reason: .adapterFailure))
            XCTAssertFalse(raised(effects))
            XCTAssertEqual(effects.filter { if case .queryAuthority = $0 { return true }; return false }.count, paintable ? 1 : 0)
            if !paintable {
                XCTAssertNotNil(h.session.replay.parked)
                XCTAssertFalse(raised(h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))))
                XCTAssertEqual(h.send(.paintable(true)), [.queryAuthority(id: 3)])
            }
            let fresh = h.reply("v1 SELF 3 iPad")
            XCTAssertFalse(raised(fresh), "the replay's intent claims against the fresh read")
            XCTAssertNotNil(h.session.reducer.claim)
        }
    }

    func testUnparkableAdapterFailureRunsRuleSeven() {
        var h = claim()
        h.window(Self.foreign)
        let effects = h.send(.abortClaim(generation: h.generation, reason: .adapterFailure), at: 21_000)
        XCTAssertNil(h.session.replay.parked, "R3 expired")
        XCTAssertTrue(raised(effects))
        XCTAssertNil(h.session.query.current)
        for expired in [true, false] {
            var target = claim(configuration: .init(replayBudget: expired ? TmuxAuthorityClaimReplay.defaultBudget : 0))
            target.window(Self.local)
            let aborted = target.send(.abortClaim(generation: target.generation, reason: .adapterFailure),
                                      at: expired ? 21_000 : 1_100)
            XCTAssertFalse(raised(aborted))
            XCTAssertNil(target.session.replay.parked)
            XCTAssertTrue(target.session.query.current != nil || target.session.geometryHold == .owner,
                          "rule 7 must leave a concrete recovery path at the claim target")
            if target.session.query.current != nil { target.reply("v1 SELF 3 iPad") }
            XCTAssertEqual(target.session.geometryHold, .owner)
        }
    }

    func testTransportResetHiddenAndBackgroundAbortNeverJudge() {
        for state in ["reset", "hidden", "background"] {
            var h = claim()
            h.window(Self.foreign)
            let g = h.generation
            if state == "hidden" { h.send(.hidden) }
            if state == "background" { h.send(.backgrounded) }
            let effects = state == "reset"
                ? h.send(.resetTransport(preservingPeer: false))
                : h.send(.abortClaim(generation: g, reason: .superseded))
            XCTAssertFalse(raised(effects), state)
        }
    }

    func testContestedAbortKeepsTheForeignStampedPeer() {
        var h = claim()
        h.window(Self.foreign)
        let peer = TmuxGridAuthoritySnapshot.peer(deviceID: "MAC", displayName: "Mac", generation: 7)
        XCTAssertFalse(raised(h.send(.observedAuthority(peer))))
        XCTAssertEqual(h.session.reducer.authority, peer)
    }

    func testAbortVerdictWaitsForAnActualReadAndRetainsAdvertisedExclusions() {
        for size in [Self.foreign, Self.local] {
            var h = claim()
            h.send(.attached)
            h.window(size)
            XCTAssertFalse(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))))
            let effects = h.reply("garbled")
            XCTAssertEqual(raised(effects), size == Self.foreign)
        }
    }

    func testHeldAndRetryReadsDeferTheAbortVerdict() {
        for held in [true, false] {
            var h = claim()
            h.send(.attached)
            let g = h.generation
            if held {
                h.send(.windowFacts(hydrated: false, activeWindow: .init(id: 1, size: Self.foreign, authoritative: true)))
                h.reply("v1 SELF 3 iPad")
                XCTAssertNotNil(h.session.query.held)
            } else {
                h.window(Self.foreign)
                h.send(.queryFailed(id: h.session.query.current!.id))
                XCTAssertNotNil(h.session.query.retryAt)
            }
            XCTAssertFalse(raised(h.send(.abortClaim(generation: g, reason: .superseded))))
            if held {
                XCTAssertTrue(raised(h.window(Self.foreign)))
            } else {
                h.send(.tick, at: 1_250)
                XCTAssertTrue(raised(h.reply("garbled")))
            }
        }
    }

    func testWantedReadAndOrdinaryRecoveryDoNotDeferTheAbortVerdict() {
        for wanted in [true, false] {
            var h = claim()
            h.window(Self.foreign)
            if wanted {
                h.send(.attached)
                h.send(.channelLiveness(false))
                h.send(.queryFailed(id: h.session.query.current!.id))
                h.send(.tick, at: 1_250)
                XCTAssertTrue(h.session.query.wanted)
                XCTAssertNil(h.session.query.current)
                XCTAssertNil(h.session.query.retryAt)
            } else {
                h.send(.ordinaryRecovery(active: true, proven: false))
            }
            XCTAssertTrue(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))))
        }
    }

    func testDeferredAbortEvidenceDoesNotCrossAControlSessionReplacement() {
        var h = claim()
        h.advertise(Self.foreign)
        h.window(Self.foreign)
        h.send(.attached)
        XCTAssertFalse(raised(h.send(.abortClaim(generation: h.generation, reason: .superseded))))
        // A switch resets the session (§6.18): the deferred verdict goes
        // with the old session, and the new one's attach reads afresh.
        XCTAssertFalse(raised(h.send(.controlSessionChanged(replacedKnownSession: true))))
        XCTAssertNil(h.session.query.current)
        h.send(.attached)
        h.send(.sizeAdvertised(Self.local))
        h.window(Self.foreign)
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.now = 3_500
        XCTAssertTrue(raised(h.reply("garbled")), "the old claim's grids are not evidence on this session")
    }

    func testSettlementRecordsTargetAndRaisesForAForeignWindowWithoutSuppression() {
        var h = claim()
        let g = h.generation
        h.stamp()
        h.advertise(.init(columns: 120, rows: 45))
        h.send(.localSize(.init(columns: 140, rows: 55)))
        h.window(Self.foreign)
        let effects = h.send(.settleClaim(generation: g))
        XCTAssertTrue(h.session.evidence.owned.contains(Self.local), "the target, not the newest advertisement, was stamped")
        XCTAssertFalse(h.session.evidence.owned.contains(.init(columns: 120, rows: 45)))
        XCTAssertTrue(raised(effects))
        XCTAssertFalse(effects.contains(.releaseGeometry(.ownerReplay)))
        XCTAssertEqual(h.session.geometryHold, .withheld)
    }

    func testSettlementAtTargetLocalOrOwnedGridReplaysHeldBackChurnOnce() {
        let changed = TmuxGridSize(columns: 140, rows: 55)
        for window in [Self.local, Self.owned, changed] {
            var h = claim()
            let g = h.generation
            h.send(.tick, at: 4_000)
            h.send(.localSize(changed))
            h.stamp()
            // The fence observes its target first; this is the later window
            // that the settlement verdict must judge.
            h.window(window)
            let effects = h.send(.settleClaim(generation: g))
            XCTAssertFalse(raised(effects), "\(window)")
            XCTAssertEqual(effects.filter { $0 == .releaseGeometry(.ownerReplay) }.count, 1)
            XCTAssertEqual(h.session.lastAdvertisedSize, changed)
            XCTAssertEqual(h.send(.tick), [])
        }
    }

    func testSettlementNeedsLatestPolicyToRaiseAndNoChurnNeedsNoReplay() {
        for (windowID, policy) in [(1, "smallest"), (1, "largest"), (2, "latest")] {
            var h = claim()
            let g = h.generation
            h.stamp()
            // Settlement uses the policy and facts current after confirmation.
            h.send(.windowSizePolicyReplied(windowID: windowID, raw: policy))
            h.window(Self.foreign)
            let effects = h.send(.settleClaim(generation: g))
            XCTAssertFalse(raised(effects))
            XCTAssertFalse(effects.contains(.releaseGeometry(.ownerReplay)))
        }
    }

    func testDeferredSettlementAndTheReadsOwnedReplayReleaseChurnOnlyOnce() {
        let changed = TmuxGridSize(columns: 140, rows: 55)
        for window in [Self.local, changed] {
            var h = claim()
            let g = h.generation
            h.stamp()
            h.send(.attached)
            h.send(.localSize(changed))
            h.window(window)
            let settled = h.send(.settleClaim(generation: g))
            XCTAssertTrue(releases(settled).isEmpty, "the read decides first")
            let effects = h.reply("v1 SELF 3 iPad")
            XCTAssertFalse(raised(effects))
            XCTAssertEqual(releases(effects), window == Self.local ? [.ownerReplay] : [.advertise],
                           "advertise and ownerReplay both release churn exactly once")
        }
    }

    func testInitiallyTargetlessClaimRequiresAdvertisementThenRecordsTargetAndJudges() {
        for window in [Self.local, Self.foreign] {
            var h = Harness()
            h.send(.attached)
            h.send(.adoptShown)
            h.send(.localSize(Self.local))
            h.window(Self.foreign)
            h.reply("v1 PEER 3 Mac")
            h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
            h.reply("v1 PEER 3 Mac")
            let g = h.generation
            XCTAssertNotEqual(g, 0)
            XCTAssertNil(h.session.reducer.claim?.targetGrid)
            XCTAssertNil(h.session.lastAdvertisedSize)
            let targetless = h.session
            XCTAssertEqual(h.send(.claimFenceSent(generation: g, windowID: 1)), [])
            XCTAssertEqual(h.send(.confirmClaimFence), [])
            XCTAssertEqual(h.session, targetless, "a targetless claim cannot confirm its fence")
            h.stamp()
            XCTAssertEqual(h.session.reducer.claim?.targetGrid, .init(columns: Self.local.columns, rows: Self.local.rows))
            h.window(window)
            let settled = h.send(.settleClaim(generation: g))
            XCTAssertTrue(h.session.evidence.owned.contains(Self.local))
            XCTAssertEqual(raised(settled), window == Self.foreign)
            XCTAssertFalse(settled.contains(.releaseGeometry(.ownerReplay)), "no local churn after the advertised target")
        }
    }

    func testDeferredSettlementDoesNotReplayAsOwnerWhenTheReadFindsNoStamp() {
        var h = claim()
        let g = h.generation
        h.window(Self.local)
        h.stamp()
        h.send(.tick, at: 4_000)
        h.send(.localSize(Self.foreign))
        h.send(.attached)
        XCTAssertNotNil(h.session.query.current)
        XCTAssertFalse(h.send(.settleClaim(generation: g)).contains(.releaseGeometry(.ownerReplay)))
        let reply = h.reply("")
        XCTAssertEqual(h.session.reducer.authority, .unknown)
        XCTAssertEqual(h.session.geometryHold, .advertiseOnly)
        XCTAssertFalse(reply.contains(.releaseGeometry(.ownerReplay)), "the deferred read removed ownership")
        XCTAssertFalse(raised(reply), "the settled target is still recently owned geometry")
    }

    func testHiddenAndBackgroundSettlementRecordTargetButNeverJudgeOrReplay() {
        for background in [true, false] {
            var h = claim()
            let g = h.generation
            h.stamp()
            h.send(.localSize(Self.foreign))
            h.window(Self.foreign)
            h.send(background ? .backgrounded : .hidden)
            let effects = h.send(.settleClaim(generation: g))
            XCTAssertTrue(h.session.evidence.owned.contains(Self.local))
            XCTAssertFalse(raised(effects))
            XCTAssertFalse(effects.contains(.releaseGeometry(.ownerReplay)))
            XCTAssertEqual(h.session.geometryHold, .withheld)
        }
    }

    func testDeadlineThenStallAbortsAndParksTheOriginalStep() {
        var h = claim()
        let g = h.generation
        h.send(.tick, at: 4_000)
        XCTAssertNotNil(h.session.reducer.claim)
        XCTAssertEqual(h.send(.claimStalled(generation: g, canProgress: false)),
                       [.hideReclaimPresentation, .claimAborted(.adapterFailure)])
        XCTAssertNil(h.session.reducer.claim)
        XCTAssertEqual(h.session.replay.parked?.stepAt, 1_000)
        XCTAssertEqual(h.session.carriedShow(now: 4_000), .init(source: .show, stepAt: 1_000))
        XCTAssertEqual(h.send(.paintable(true)), [.queryAuthority(id: 3)])
    }

    func testVisibleStallReturnsToGeometryAndStaleEventsAreNoOps() {
        var h = claim()
        let g = h.generation
        h.confirmFence(generation: g)
        XCTAssertEqual(h.send(.claimStalled(generation: g, canProgress: true)), [])
        XCTAssertEqual(h.session.reducer.claim?.phase, .awaitingFence)
        let before = h.session
        h.send(.claimObservedGeometry(generation: g + 1, size: Self.foreign, settleProbe: true))
        h.send(.claimGeometryLost(generation: g + 1))
        h.send(.claimStalled(generation: g + 1, canProgress: false))
        XCTAssertEqual(h.session, before)
    }
}
