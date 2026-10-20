import XCTest
@testable import TmuxControlCore

/// Subscription classification has one owner: the shared session. Every
/// migrated runtime-classifier regression enters through the raw stamp event.
final class GridAuthorityClaimTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private let peer = TmuxGridAuthoritySnapshot.peer(deviceID: "ipad", displayName: "iPad", generation: 7)
    private let peerRaw = "v1 ipad 7 iPad"

    /// Attached, its read answered: no read is outstanding, so an edge
    /// supersedes none.
    private func attached() -> Session {
        var session = Session(localDeviceID: "android")
        session.reduce(.attached, now: 0)
        session.reduce(.adoptShown, now: 0)
        if let id = session.query.current?.id { session.reduce(.queryReplied(id: id, raw: peerRaw), now: 0) }
        session.reduce(.stampObserved(raw: peerRaw), now: 0)
        XCTAssertNil(session.query.current)
        return session
    }

    private func claiming() -> Session {
        var session = attached()
        session.reduce(.requestTakeBack, now: 0)
        XCTAssertNotNil(session.reducer.claim)
        return session
    }

    private func confirmFence(_ session: inout Session, generation: UInt64) {
        let size = session.evidence.localSize ?? TmuxGridSize(columns: 92, rows: 38)
        if session.reducer.claim?.targetGrid == nil {
            session.reduce(.claimAdvertisedGeometry(generation: generation, size: size), now: 0)
        }
        let target = session.reducer.claim!.targetGrid!
        let windowID = session.evidence.activeWindow?.id ?? 1
        session.reduce(.claimFenceSent(generation: generation, windowID: windowID), now: 0)
        let fenceID = session.claimFence!.id
        session.reduce(.claimFenceAcknowledged(fenceID: fenceID), now: 0)
        session.reduce(.windowSizePolicyReplied(windowID: windowID, raw: "latest", fenceID: fenceID), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: .init(id: windowID,
            size: .init(columns: target.columns, rows: target.rows), authoritative: true)), now: 0)
        session.reduce(.confirmClaimFence, now: 0)
        XCTAssertEqual(session.reducer.claim?.phase, .awaitingRepaint)
    }

    func testUnchangedStampReplayIsNotAnArrival() {
        var session = attached()
        let before = session
        XCTAssertEqual(session.reduce(.stampObserved(raw: " \t\(peerRaw)\n "), now: 0), [])
        XCTAssertEqual(session, before)
        XCTAssertEqual(session.reducer.authority, peer)
    }

    func testClaimSurvivesReplayOfThePeerStampItIsContesting() {
        var session = claiming()
        let before = session
        XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
        XCTAssertEqual(session, before)
        // Even after an intervening own value defeats raw dedupe, reducer
        // identity+generation replay detection must protect the live claim.
        session.reduce(.stampObserved(raw: "v1 android 99 Android"), now: 0)
        XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
        XCTAssertEqual(session.reducer.claim, before.reducer.claim)
        XCTAssertEqual(session.reducer.authority, peer)
    }

    func testPeerRewritingDuringClaimIsAnArrival() {
        // Generations belong to a device lifetime; a reinstalled peer can
        // restart lower. tmux write order, not numeric ordering, decides.
        for (deviceID, generation) in [("ipad", UInt64(8)), ("ipad", 6), ("phone", 7)] {
            var session = claiming()
            let next = TmuxGridAuthoritySnapshot.peer(deviceID: deviceID, displayName: "iPad", generation: generation)
            let effects = session.reduce(.stampObserved(raw: "v1 \(deviceID) \(generation) iPad"), now: 0)
            XCTAssertTrue(effects.contains(.claimAborted(.contestedByPeer(.init(deviceID: deviceID, displayName: "iPad", generation: generation)))))
            XCTAssertNil(session.reducer.claim)
            XCTAssertEqual(session.reducer.authority, next)
        }
    }

    func testOwnStampEchoDuringClaimStaysAdvisory() throws {
        for fromUnknown in [false, true] {
            var session = fromUnknown ? Session(localDeviceID: "android") : claiming()
            if fromUnknown {
                session.reduce(.attached, now: 0)
                session.reduce(.shown(source: .show, stepAt: 0), now: 0)
                let id = try XCTUnwrap(session.query.current?.id)
                session.reduce(.queryReplied(id: id, raw: ""), now: 0)
            }
            let claim = try XCTUnwrap(session.reducer.claim)
            let authority = session.reducer.authority
            XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 android \(claim.generation) Android"), now: 0), [])
            XCTAssertEqual(session.reducer.authority, authority)
            XCTAssertEqual(session.reducer.claim, claim)
        }
    }

    func testDelayedOwnAuthorityEchoCannotReclaimFromPeer() throws {
        var session = attached()
        let raw = "v1 android 9 Android"
        XCTAssertEqual(session.reduce(.stampObserved(raw: raw), now: 0), [])
        XCTAssertEqual(session.reducer.authority, peer)
        XCTAssertNil(session.reducer.claim)
        session.reduce(.requestTakeBack, now: 0)
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        XCTAssertEqual(session.reduce(.stampObserved(raw: raw), now: 0), [])
        XCTAssertEqual(session.reducer.authority, peer)
        // Only the actual fence/repaint/write chain can turn that peer into mine.
        confirmFence(&session, generation: generation)
        session.reduce(.repaintSucceeded(generation: generation), now: 0)
        session.reduce(.stampCommitSucceeded(generation: generation), now: 0)
        session.reduce(.settleClaim(generation: generation), now: 0)
        XCTAssertEqual(session.reducer.authority, .mine(generation: generation))
        XCTAssertNil(session.reducer.claim)
    }

    func testOwnEchoCannotLiftAStamplessPeer() {
        var session = attached()
        let fallback = TmuxGridAuthoritySnapshot.peer(deviceID: "-", displayName: TmuxStamplessPeer.displayName, generation: 0)
        session.reduce(.observedAuthority(fallback), now: 0)
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 android 9 Android"), now: 0), [])
        XCTAssertEqual(session.reducer.authority, fallback)
        XCTAssertNil(session.reducer.claim)
    }

    func testOwnStampThatWonAContestBeginsOneOwnWriteWonClaim() throws {
        var session = claiming()
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        session.reduce(.stampObserved(raw: "v1 ipad 8 iPad"), now: 0)
        let effects = session.reduce(.stampObserved(raw: "v1 android \(generation) Android"), now: 0)
        let claim = try XCTUnwrap(session.reducer.claim)
        XCTAssertEqual(claim.reason, .ownWriteWon)
        XCTAssertGreaterThan(claim.generation, generation)
        XCTAssertEqual(effects, [.beginClaim(claim)])
        XCTAssertTrue(session.reducer.authority.isPeer, "the continuation still owes its fence and repaint")
        let before = session
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 android \(generation) Android"), now: 0), [])
        XCTAssertEqual(session, before)
    }

    func testHiddenOwnEchoCannotContinueAContestedClaim() throws {
        var session = claiming()
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        session.reduce(.hidden, now: 0)
        session.reduce(.stampObserved(raw: "v1 ipad 8 iPad"), now: 0)
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 android \(generation) Android"), now: 0), [])
        XCTAssertNil(session.reducer.claim)
        session.reduce(.adoptShown, now: 0)
        XCTAssertEqual(session.reduce(.ownStampObserved(generation: generation), now: 0), [])
    }

    func testBackgroundOwnEchoDropsTheContestedContinuation() throws {
        var session = claiming()
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        session.reduce(.stampObserved(raw: "v1 ipad 8 iPad"), now: 0)
        session.reduce(.backgrounded, now: 0)
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 android \(generation) Android"), now: 0), [])
        XCTAssertNil(session.reducer.claim)
        session.reduce(.foregrounded, now: 0)
        XCTAssertEqual(session.reduce(.ownStampObserved(generation: generation), now: 0), [])
    }

    func testTransportResetRearmsRawMemoAndKeepsPeerWhenRequested() {
        for preservingPeer in [false, true] {
            var session = attached()
            session.reduce(.resetTransport(preservingPeer: preservingPeer), now: 0)
            XCTAssertEqual(session.reducer.authority, preservingPeer ? peer : .unknown)
            let before = session
            session.reduce(.stampObserved(raw: peerRaw), now: 0)
            XCTAssertNotEqual(session, before, "the same subscription is new on the next connection")
            XCTAssertEqual(session.reducer.authority, peer)
            let observed = session
            XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
            XCTAssertEqual(session, observed)
        }
    }

    func testCommitAuthorityStampRearmsRawMemo() throws {
        var session = claiming()
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        confirmFence(&session, generation: generation)
        XCTAssertEqual(session.reduce(.repaintSucceeded(generation: generation), now: 0), [.commitAuthorityStamp(generation: generation)])
        let before = session
        XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
        XCTAssertNotEqual(session, before, "our impending write re-arms the raw memo")
        XCTAssertNotNil(session.reducer.claim, "a replay still does not contest")
    }

    func testIdentityChangeRearmsRawMemoAndSanitizesClassification() {
        var session = Session(localDeviceID: nil)
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 device-one 3 Phone"), now: 0), [])
        XCTAssertEqual(session.reducer.authority, .unknown)
        session.localDeviceID = "device one"
        XCTAssertEqual(session.reduce(.stampObserved(raw: "v1 device-one 3 Phone"), now: 0), [.authorityChanged(.mine(generation: 3))])
        XCTAssertEqual(session.reducer.authority, .mine(generation: 3))
        session.localDeviceID = "another"
        session.reduce(.stampObserved(raw: "v1 device-one 3 Phone"), now: 0)
        XCTAssertEqual(session.reducer.authority, .peer(deviceID: "device-one", displayName: "Phone", generation: 3))
    }

    func testInvalidValuesAreMemoizedBeforeTheyAreIgnored() {
        var session = claiming()
        for raw in ["", "broken", "v1 peer 9223372036854775808 Phone"] {
            let before = session
            XCTAssertEqual(session.reduce(.stampObserved(raw: raw), now: 0), [])
            XCTAssertNotEqual(session, before)
            let recorded = session
            // A duplicate cannot run an overdue read or a presentation clock.
            XCTAssertEqual(session.reduce(.stampObserved(raw: raw), now: 50_000), [])
            XCTAssertEqual(session, recorded)
            XCTAssertEqual(session.reducer.authority, peer)
        }
    }

    func testStampObservedLabelRedactsRawValueAndIdentity() {
        var session = Session(localDeviceID: "android")
        let event = Session.Event.stampObserved(raw: "v1 private-device 8 Secret")
        let before = session
        let effects = session.reduce(event, now: 0)
        let trace = Session.describeTransition(event: event, before: before, after: session, effects: effects)
        XCTAssertEqual(event.traceLabel, "stampObserved")
        XCTAssertNotNil(trace)
        XCTAssertFalse(event.traceLabel.contains("private-device"))
        XCTAssertFalse(event.traceLabel.contains("@"))
        XCTAssertFalse(trace?.contains("v1 private-device 8 Secret") ?? true)
        let recorded = session
        let replay = session.reduce(event, now: 0)
        XCTAssertNil(Session.describeTransition(event: event, before: recorded, after: session, effects: replay))
    }

    /// Aborts no stamp reports (an unsent fence, a vanished pane, a
    /// timeout) must unwind the claim, or this device's later echoes stay
    /// advisory for the rest of the connection.
    func testAbortedClaimRestoresSteadyStateLabelling() throws {
        var session = Session(localDeviceID: "android")
        session.reduce(.attached, now: 0)
        session.reduce(.shown(source: .show, stepAt: 0), now: 0)
        session.reduce(.queryReplied(id: try XCTUnwrap(session.query.current?.id), raw: ""), now: 0)
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        session.reduce(.abortClaim(generation: generation, reason: .superseded), now: 0)
        XCTAssertNil(session.reducer.claim)
        session.reduce(.stampObserved(raw: "v1 android 4 Android-Phone"), now: 0)
        XCTAssertEqual(session.reducer.authority, .mine(generation: 4))
    }

    /// A read sent before a stamp edge can be answered after it on Android,
    /// whose replies drain on Main while a later read's stamps reduce in the
    /// runtime callback. The edge supersedes it: the older value decides
    /// nothing, on either platform.
    func testAStampEdgeSupersedesAnOutstandingRead() throws {
        var session = Session(localDeviceID: "android")
        session.reduce(.attached, now: 0)
        let stale = try XCTUnwrap(session.query.current?.id)
        let effects = session.reduce(.stampObserved(raw: peerRaw), now: 0)
        XCTAssertEqual(session.reducer.authority, peer)
        let fresh = try XCTUnwrap(session.query.current?.id)
        XCTAssertGreaterThan(fresh, stale)
        XCTAssertTrue(effects.contains(.queryAuthority(id: fresh)))
        session.reduce(.queryReplied(id: stale, raw: ""), now: 0)
        XCTAssertEqual(session.reducer.authority, peer, "the older reply decides nothing")
        XCTAssertEqual(session.query.current?.id, fresh)
        session.reduce(.queryReplied(id: fresh, raw: peerRaw), now: 0)
        XCTAssertEqual(session.reducer.authority, peer)
        XCTAssertNil(session.query.current)
        // A replay is no edge, and supersedes nothing.
        session.reduce(.userStep, now: 0)
        XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
    }

    /// A claim, a held own reply and ownership belong to the identity that
    /// made them; under a new one they would settle or project `.mine`.
    func testIdentityChangeEndsTheOldIdentitysClaimHeldReplyAndOwnership() throws {
        var contested = claiming()
        contested.localDeviceID = "tablet"
        XCTAssertTrue(contested.reduce(.identityChanged, now: 0).contains(.claimAborted(.superseded)))
        XCTAssertNil(contested.reducer.claim)
        XCTAssertEqual(contested.reducer.authority, peer)

        // A replay parked by an adapter failure is the old identity's too.
        var parked = claiming()
        let generation = try XCTUnwrap(parked.reducer.claim?.generation)
        parked.reduce(.paintable(false), now: 0)
        parked.reduce(.abortClaim(generation: generation, reason: .adapterFailure), now: 0)
        XCTAssertNotNil(parked.replay.parked)
        parked.localDeviceID = "tablet"
        parked.reduce(.identityChanged, now: 0)
        XCTAssertNil(parked.replay.parked)
        XCTAssertFalse(parked.reduce(.paintable(true), now: 0).contains { if case .beginClaim = $0 { return true }; return false })

        // A device that stops taking part keeps no gesture, and ignores the
        // read it sent before.
        var leaving = Session(localDeviceID: "android")
        leaving.reduce(.attached, now: 0)
        leaving.reduce(.shown(source: .show, stepAt: 0), now: 0)
        let showRead = try XCTUnwrap(leaving.query.current?.id)
        XCTAssertNotNil(leaving.reducer.pendingIntent)
        leaving.localDeviceID = nil
        leaving.reduce(.identityChanged, now: 0)
        XCTAssertNil(leaving.reducer.pendingIntent)
        XCTAssertNotEqual(leaving.query.current?.id, showRead)
        leaving.reduce(.queryReplied(id: showRead, raw: ""), now: 0)
        XCTAssertNil(leaving.reducer.claim)

        var held = Session(localDeviceID: "android")
        held.reduce(.attached, now: 0)
        held.reduce(.adoptShown, now: 0)
        held.reduce(.queryReplied(id: try XCTUnwrap(held.query.current?.id), raw: "v1 android 1 Phone"), now: 0)
        XCTAssertNotNil(held.query.held)
        held.localDeviceID = "tablet"
        let effects = held.reduce(.identityChanged, now: 0)
        XCTAssertNil(held.query.held)
        XCTAssertTrue(effects.contains { if case .queryAuthority = $0 { return true }; return false },
                      "the new identity reads the stamp afresh")

        var owner = Session(localDeviceID: "android")
        owner.reduce(.stampObserved(raw: "v1 android 4 Phone"), now: 0)
        XCTAssertEqual(owner.reducer.authority, .mine(generation: 4))
        owner.localDeviceID = "tablet"
        owner.reduce(.identityChanged, now: 0)
        XCTAssertEqual(owner.reducer.authority, .unknown)
    }

    func testUnknownObservationNeverLiftsAPeer() {
        var session = attached()
        XCTAssertEqual(session.reduce(.observedAuthority(.unknown), now: 0), [])
        XCTAssertEqual(session.reduce(.stampObserved(raw: ""), now: 0), [])
        XCTAssertEqual(session.reducer.authority, peer)
    }

    func testUnchangedIdentityDoesNotRearmRawMemo() {
        var session = attached()
        let before = session
        session.localDeviceID = "android"
        XCTAssertEqual(session.reduce(.stampObserved(raw: peerRaw), now: 0), [])
        XCTAssertEqual(session, before)
    }

    func testChangedStampDropsAHeldOwnReadBeforeOwnContinuation() throws {
        var session = Session(localDeviceID: "android")
        session.reduce(.attached, now: 0)
        session.reduce(.adoptShown, now: 0)
        let id = try XCTUnwrap(session.query.current?.id)
        session.reduce(.queryReplied(id: id, raw: "v1 android 1 Phone"), now: 0)
        XCTAssertNotNil(session.query.held)
        let effects = session.reduce(.stampObserved(raw: peerRaw), now: 0)
        XCTAssertNil(session.query.held)
        XCTAssertTrue(effects.contains(.authorityChanged(peer)))
        XCTAssertTrue(effects.contains { if case .queryAuthority = $0 { return true }; return false })
    }
}
