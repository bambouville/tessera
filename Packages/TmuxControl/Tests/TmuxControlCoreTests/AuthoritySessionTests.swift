import Foundation
import XCTest
@testable import TmuxControlCore

/// `TmuxGridAuthoritySession`: the show rule's reads, holds, clocks, replay
/// and projection, driven event by event on an injected millisecond clock.
/// Cases follow both platforms' grid-authority tests (iOS
/// `GridAuthorityTests`, the show-coordinator delivery cases of
/// `SessionShowEdgeTrackerTests`; Android's controller authority tests) at
/// the level of the shared policy.
final class AuthoritySessionTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private typealias Effect = TmuxGridAuthoritySession.Effect
    private typealias Event = TmuxGridAuthoritySession.Event
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer

    private static let mine = "v1 SELF 3 iPad"
    private static let pastEcho: Int64 = TmuxStamplessPeer.replaySuppressionMillis + 1_000
    private static let mac = "v1 MAC 7 Mac"
    private static let laptop = "v1 LAP 2 Laptop"
    private let macPeer = TmuxGridAuthoritySnapshot.peer(deviceID: "MAC", displayName: "Mac", generation: 7)
    private let laptopPeer = TmuxGridAuthoritySnapshot.peer(deviceID: "LAP", displayName: "Laptop", generation: 2)
    private var stamplessPeer: TmuxGridAuthoritySnapshot {
        let peer = Reducer.stamplessPeer
        return .peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation)
    }

    private static func size(_ columns: Int, _ rows: Int) -> TmuxGridSize { .init(columns: columns, rows: rows) }
    private static func window(_ id: Int, _ size: TmuxGridSize, authoritative: Bool = true) -> Event {
        .windowFacts(hydrated: true, activeWindow: .init(id: id, size: size, authoritative: authoritative))
    }

    private struct Harness {
        var session: TmuxGridAuthoritySession
        var now: Int64 = 0

        init(localDeviceID: String = "SELF") {
            session = .init(localDeviceID: localDeviceID)
        }

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
            return session.reduce(event, now: now)
        }

        /// Answers the deciding read.
        @discardableResult
        mutating func reply(_ raw: String, at time: Int64? = nil, file: StaticString = #filePath, line: UInt = #line) -> [Effect] {
            guard let id = session.query.current?.id else {
                XCTFail("no read outstanding", file: file, line: line)
                return []
            }
            return send(.queryReplied(id: id, raw: raw), at: time)
        }

        var claim: Reducer.Claim? { session.reducer.claim }
    }

    private func claims(in effects: [Effect]) -> [Reducer.Claim] {
        effects.compactMap { effect in
            if case .beginClaim(let claim) = effect { return claim }
            return nil
        }
    }

    private func reads(in effects: [Effect]) -> Int {
        effects.filter { if case .queryAuthority = $0 { return true } else { return false } }.count
    }

    /// Attached, shown, our stamp at our 92x38 grid on window @1. The read's
    /// release advertised that size at 0, so a layout is judged outside the
    /// echo window from `Self.pastEcho` on.
    private func owner(at local: TmuxGridSize = size(92, 38)) -> Harness {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(local))
        h.send(Self.window(1, local))
        h.reply(Self.mine)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertEqual(h.session.presentation, .none)
        return h
    }

    /// Attached and shown, yielded to the Mac.
    private func yielded() -> Harness {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(Self.mac)
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        return h
    }

    // MARK: Start, attach and the R5 read

    func test_aNewSessionStartsHiddenWithGeometryWithheld() {
        let session = Session(localDeviceID: "SELF")
        XCTAssertTrue(session.hidden)
        XCTAssertEqual(session.geometryHold, .withheld)
        XCTAssertEqual(session.presentation, .none)
        XCTAssertFalse(session.gatesTyping)
        XCTAssertNil(session.mutationRefusal)
        XCTAssertNil(session.carriedShow(now: 0))
        XCTAssertNil(session.nextDeadline)
    }

    func test_attachReadsAndNeverClaims() {
        var h = Harness()
        XCTAssertEqual(h.send(.attached), [.queryAuthority(id: 1)])
        XCTAssertEqual(h.session.nextDeadline, 5_000, "the overdue bound")
        XCTAssertEqual(h.reply(Self.mac, at: 100), [.authorityChanged(macPeer)])
        XCTAssertNil(h.claim)
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: false),
                       "registered off screen: hidden, the peer is not drawn")
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(h.send(.adoptShown), [])
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        XCTAssertTrue(h.session.gatesTyping)
        XCTAssertEqual(h.session.mutationRefusal, .yielded)
    }

    func test_aShowOverAPeerClaimsAndSettles() {
        var h = yielded()
        XCTAssertEqual(h.send(.shown(source: .show, stepAt: 1_000), at: 1_000), [.queryAuthority(id: 2)])
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: false))
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 1_000))
        XCTAssertEqual(h.session.nextDeadline, 6_000)

        let begun = claims(in: h.reply(Self.mac, at: 1_200))
        XCTAssertEqual(begun.map(\.reason), [.show])
        let generation = try! XCTUnwrap(begun.first?.generation)
        XCTAssertEqual(h.session.geometryHold, .owner, "a claim owns geometry through its fence")
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: false))
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 1_000), "the claim keeps the user's step")
        XCTAssertEqual(h.session.nextDeadline, 4_200, "the claim's 3 s presentation budget")

        XCTAssertEqual(h.confirmFence(generation: generation), [.requestRepaint(generation: generation)])
        XCTAssertEqual(h.send(.repaintSucceeded(generation: generation)), [.commitAuthorityStamp(generation: generation)])
        XCTAssertEqual(h.send(.claimAdvertisedGeometry(generation: generation, size: Self.size(92, 38))), [])
        XCTAssertEqual(h.send(.stampCommitSucceeded(generation: generation)), [])
        XCTAssertEqual(h.send(.settleClaim(generation: generation)), [
            .authorityChanged(.mine(generation: generation)),
            .hideReclaimPresentation,
            .claimSettled(generation: generation),
        ])
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertTrue(h.session.evidence.owned.contains(Self.size(92, 38)), "the claim pushed this size and it settled")
        XCTAssertNil(h.session.carriedShow(now: h.now))
        XCTAssertNil(h.session.nextDeadline)
    }

    // MARK: Reads

    func test_readsForOneIntentCoalesceAndTheNewestWins() {
        var h = Harness()
        var total = reads(in: h.send(.attached))
        h.send(.adoptShown)
        total += reads(in: h.send(.shown(source: .show, stepAt: 0)))
        XCTAssertEqual(h.send(.queryReplied(id: 1, raw: Self.mac)), [], "superseded by the show's read")
        total += reads(in: h.send(.attached))
        total += reads(in: h.send(.foregrounded))
        XCTAssertEqual(total, 2, "a show costs one round trip")
        XCTAssertEqual(claims(in: h.reply(Self.mac)).map(\.reason), [.show])
    }

    func test_aReplyIssuedBeforeTheGestureReadsAgain() {
        var h = yielded()
        XCTAssertEqual(h.send(.foregrounded), [.queryAuthority(id: 2)])
        h.send(.channelLiveness(false))
        XCTAssertEqual(h.send(.requestTakeBack), [], "the tap waits for its channel")
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: true))
        XCTAssertEqual(h.reply(Self.mac), [], "issued before the tap: it cannot decide it")
        XCTAssertTrue(h.session.query.wanted)
        XCTAssertEqual(h.send(.channelLiveness(true)), [.queryAuthority(id: 3)])
        XCTAssertEqual(claims(in: h.reply(Self.mac)).map(\.reason), [.userTakeBack])
    }

    func test_aFailedReadRetriesThreeTimesThenFailsClosed() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        XCTAssertEqual(h.send(.queryFailed(id: 1), at: 100), [])
        XCTAssertEqual(h.session.nextDeadline, 350)
        XCTAssertEqual(h.send(.tick, at: 349), [])
        XCTAssertEqual(h.send(.tick, at: 350), [.queryAuthority(id: 2)])
        XCTAssertEqual(h.send(.queryFailed(id: 2), at: 400), [])
        XCTAssertEqual(h.send(.tick, at: 900), [.queryAuthority(id: 3)])
        XCTAssertEqual(h.send(.queryFailed(id: 3), at: 1_000), [])
        XCTAssertEqual(h.send(.tick, at: 1_750), [.queryAuthority(id: 4)])
        XCTAssertEqual(h.send(.queryFailed(id: 4), at: 1_800), [])
        XCTAssertNil(h.session.nextDeadline, "three retries, then nothing until the next show or attach")
        XCTAssertEqual(h.session.geometryHold, .withheld, "fails closed")
        XCTAssertEqual(h.send(.foregrounded, at: 5_000), [.queryAuthority(id: 5)])
    }

    func test_anUnansweredReadMarksTheChannelUnresponsiveOnce() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        XCTAssertEqual(h.send(.tick, at: 4_999), [])
        XCTAssertEqual(h.send(.tick, at: 5_000), [.controlChannelUnresponsive])
        XCTAssertFalse(h.session.channelIsLive)
        XCTAssertNil(h.session.nextDeadline)
        XCTAssertEqual(h.send(.tick, at: 9_000), [])
        XCTAssertEqual(h.send(.shown(source: .show, stepAt: 9_000)), [], "never re-sent on the stuck queue")
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: true))
        XCTAssertFalse(h.session.gatesTyping, "M7: nobody is known to hold the grid")
        XCTAssertEqual(h.send(.queryReplied(id: 1, raw: ""), at: 10_000), [.queryAuthority(id: 2)],
                       "the late reply clears it and sends the read the show wanted")
        XCTAssertTrue(h.session.channelIsLive)
        XCTAssertEqual(claims(in: h.reply("")).map(\.reason), [.show])
    }

    /// The reply lands past the bound before the wake ran (a busy main
    /// actor): it is the queue moving, not an unresponsive channel, and the
    /// adapter must not be told to drop the channel that just answered.
    func test_aReplyLandingPastItsBoundIsNotAnUnresponsiveChannel() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        let effects = h.send(.queryReplied(id: 1, raw: Self.mac), at: 5_001)
        XCTAssertFalse(effects.contains(.controlChannelUnresponsive), "\(effects)")
        XCTAssertTrue(h.session.channelIsLive)
        XCTAssertFalse(h.session.query.overdue)
        XCTAssertEqual(h.session.reducer.authority, .peer(deviceID: "MAC", displayName: "Mac", generation: 7))
    }

    func test_aFailureLandingPastItsBoundIsNotAnUnresponsiveChannel() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        let effects = h.send(.queryFailed(id: 1), at: 7_000)
        XCTAssertFalse(effects.contains(.controlChannelUnresponsive), "\(effects)")
        XCTAssertTrue(h.session.channelIsLive)
    }

    func test_aLateReplyToAnOlderReadLeavesTheNewerOneOverdue() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        XCTAssertEqual(h.send(.shown(source: .show, stepAt: 0), at: 0), [.queryAuthority(id: 2)])
        XCTAssertEqual(h.send(.queryReplied(id: 1, raw: Self.mac), at: 4_000), [])
        XCTAssertEqual(h.session.nextDeadline, 5_000, "read 2 was issued at 0")
        XCTAssertEqual(h.send(.tick, at: 5_000), [.controlChannelUnresponsive])
    }

    // MARK: Own-stamp hold (M5)

    func test_ownStampReplyWaitsForGeometryEvidence() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        XCTAssertEqual(h.reply(Self.mine, at: 100), [])
        XCTAssertNotNil(h.session.query.held)
        XCTAssertEqual(h.session.presentation, .none, "slow hydration is not a stamp-less peer")
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(h.session.nextDeadline, 10_100)
        XCTAssertEqual(h.send(.localSize(Self.size(92, 38)), at: 200), [])
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: 300), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.advertise),
        ])
        XCTAssertNil(h.session.query.held)
        XCTAssertEqual(h.session.geometryHold, .owner)
        XCTAssertTrue(h.session.evidence.owned.contains(Self.size(92, 38)))
    }

    func test_theHoldBoundStillDeliversTheReplyAsUnknownGeometry() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(Self.mine, at: 100)
        XCTAssertEqual(h.send(.tick, at: 10_099), [])
        XCTAssertEqual(h.send(.tick, at: 10_100), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.none),
        ], "an evidence-free read replays nothing")
        XCTAssertNil(h.claim, "a bounded read never claims")
        XCTAssertEqual(h.session.presentation, .none, "never veiled as another device")
        XCTAssertFalse(h.session.gatesTyping)
    }

    func test_aDifferentLiveStampWhileHeldDropsTheReplyAndReadsAgain() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.reply(Self.mine)
        XCTAssertEqual(h.send(.observedAuthority(laptopPeer)), [
            .queryAuthority(id: 2),
            .authorityChanged(laptopPeer),
        ])
        XCTAssertNil(h.session.query.held)
    }

    func test_onlyAReplyNamingThisDeviceIsHeld() {
        for raw in ["v1 android-id 2 Android-Phone", "  v1  android-id 12 Android-Phone \n"] {
            var h = Harness(localDeviceID: "android-id")
            h.send(.attached)
            h.reply(raw)
            XCTAssertNotNil(h.session.query.held, raw)
        }
        for raw in ["v1 ipad-id 4 iPad", "", "android-id"] {
            var h = Harness(localDeviceID: "android-id")
            h.send(.attached)
            h.reply(raw)
            XCTAssertNil(h.session.query.held, raw)
            XCTAssertNil(h.session.query.current, raw)
        }
    }

    // MARK: Geometry release (D3, L4, M3, P6)

    func test_reconnectAtTheLastOwnedSizeReplaysOwnedGeometry() {
        var h = owner()
        h.send(.resetTransport(preservingPeer: true))
        XCTAssertEqual(h.session.geometryHold, .withheld)
        h.send(.localSize(Self.size(100, 40)))
        XCTAssertEqual(h.send(.attached), [.queryAuthority(id: 2)])
        h.send(Self.window(1, Self.size(92, 38)))
        XCTAssertEqual(h.reply(Self.mine), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.ownerReplay),
        ], "one ordinary owner resize, never a claim or a stamp")
        XCTAssertNil(h.claim)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_aHoldReleasedUnderANonLatestPolicyReplaysTheWithheldSize() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(80, 30)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "smallest"))
        XCTAssertEqual(h.reply(Self.mine), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.ownerReplay),
        ])
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_reconnectOwnStampOverAForeignSizeYieldsToAnotherDevice() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(Self.window(1, Self.size(120, 40)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        XCTAssertEqual(h.reply(Self.mine), [.authorityChanged(stamplessPeer), .raiseStamplessPeer])
        XCTAssertNil(h.claim, "our stamp over a foreign grid must not claim")
        XCTAssertEqual(h.session.presentation, .veiled(peerName: TmuxStamplessPeer.displayName))
        XCTAssertEqual(h.session.geometryHold, .withheld)
    }

    func test_anUnstampedServerReleasesABareClientSizeOnly() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        XCTAssertEqual(h.reply(""), [.releaseGeometry(.advertise)])
        XCTAssertEqual(h.session.geometryHold, .advertiseOnly)
        XCTAssertEqual(h.session.reducer.authority, .unknown, "no stamp means nobody's")
        XCTAssertEqual(h.session.presentation, .none)

        var garbled = Harness()
        garbled.send(.attached)
        garbled.send(.adoptShown)
        XCTAssertEqual(garbled.reply("android-id"), [], "an unparsable stamp is not an absent one")
        XCTAssertEqual(garbled.session.geometryHold, .withheld)
    }

    func test_aReattachAtOurSizeAdvertisesOnlyWhenThisConnectionHasNot() {
        var h = owner()
        h.send(.sizeAdvertised(Self.size(92, 38)))
        XCTAssertEqual(h.send(.foregrounded), [.queryAuthority(id: 2)])
        XCTAssertEqual(h.reply(Self.mine), [.releaseGeometry(.none)], "P6: this connection already did")
        h.send(.resetTransport(preservingPeer: true))
        h.send(.attached)
        h.send(Self.window(1, Self.size(92, 38)))
        XCTAssertEqual(h.reply(Self.mine), [
            .authorityChanged(.mine(generation: 3)),
            .releaseGeometry(.advertise),
        ], "a new connection has advertised nothing yet")
    }

    func test_backgroundWithholdsGeometryUntilTheForegroundRead() {
        var h = owner()
        XCTAssertEqual(h.send(.backgrounded), [])
        XCTAssertEqual(h.session.geometryHold, .withheld, "M6: an inactive device sizes nothing")
        XCTAssertEqual(h.send(.foregrounded), [.queryAuthority(id: 2)])
        XCTAssertEqual(h.session.geometryHold, .withheld)
        h.reply(Self.mine)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_aHiddenSessionNeverSizes() {
        var h = owner()
        h.send(.hidden)
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertEqual(h.session.presentation, .none)
        h.send(.adoptShown)
        XCTAssertEqual(h.session.geometryHold, .owner)
    }

    func test_aTransportResetDuringAClaimKeepsGeometryWithheld() {
        var h = yielded()
        let begun = claims(in: h.send(.requestTakeBack))
        XCTAssertEqual(begun.count, 1)
        let effects = h.send(.resetTransport(preservingPeer: true))
        XCTAssertTrue(effects.contains(.claimAborted(.transportReset)), "\(effects)")
        XCTAssertEqual(h.session.geometryHold, .withheld)
        XCTAssertNil(h.session.replay.parked, "a transport reset is not an adapter failure")
    }

    func test_aSessionChangeReadsAgainAndAKnownSwitchResetsTheSession() {
        var h = Harness()
        h.send(.attached)
        XCTAssertEqual(h.send(.controlSessionChanged(replacedKnownSession: false)), [.queryAuthority(id: 2)],
                       "a read queued before the session resolved cannot speak for it")
        XCTAssertEqual(h.send(.queryReplied(id: 1, raw: Self.mac)), [])

        var owned = owner()
        owned.send(.sizeAdvertised(Self.size(100, 40)))
        XCTAssertFalse(owned.session.evidence.owned.sizes.isEmpty)
        XCTAssertEqual(owned.send(.controlSessionChanged(replacedKnownSession: false)), [])
        XCTAssertFalse(owned.session.evidence.owned.sizes.isEmpty)
        let switched = owned.send(.controlSessionChanged(replacedKnownSession: true))
        XCTAssertTrue(owned.session.evidence.owned.sizes.isEmpty)
        XCTAssertEqual(owned.session.reducer.authority, .unknown, "\(switched)")
        XCTAssertEqual(reads(in: switched), 0, "the read waits for the adapter's attach, after the scope resolves")
        XCTAssertEqual(owned.session.geometryHold, .withheld)
        XCTAssertEqual(reads(in: owned.send(.attached)), 1)
    }

    /// Authority is a session option: the old session's peer is no verdict
    /// on the new one. Android kept it (nothing read again unless a read was
    /// outstanding), so a switch to an unowned session stayed veiled.
    func test_aKnownSwitchForgetsTheOldSessionsPeer() {
        var h = yielded()
        h.send(.controlSessionChanged(replacedKnownSession: true))
        XCTAssertEqual(h.session.reducer.authority, .unknown)
        XCTAssertNotEqual(h.session.presentation, .veiled(peerName: "Mac"))
        XCTAssertEqual(reads(in: h.send(.attached)), 1)
        h.reply("")
        XCTAssertFalse(h.session.reducer.authority.isPeer)
        XCTAssertFalse(h.session.gatesTyping)
    }

    /// A claim on the old session's windows ends with the switch.
    func test_aKnownSwitchEndsAClaimAsATransportResetDoes() {
        var h = yielded()
        XCTAssertEqual(claims(in: h.send(.requestTakeBack)).count, 1)
        let effects = h.send(.controlSessionChanged(replacedKnownSession: true))
        XCTAssertTrue(effects.contains(.claimAborted(.transportReset)), "\(effects)")
        XCTAssertNil(h.session.reducer.claim)
    }

    // MARK: Stamp-less peer

    func test_aForeignLayoutUnderLatestRaisesTheStamplessPeer() {
        var h = owner()
        XCTAssertEqual(h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: Self.pastEcho), [])
        XCTAssertEqual(h.send(Self.window(1, Self.size(92, 38)), at: Self.pastEcho), [], "a matching layout does not trigger")
        XCTAssertEqual(h.send(Self.window(1, Self.size(120, 40)), at: Self.pastEcho),
                       [.authorityChanged(stamplessPeer), .raiseStamplessPeer])
        XCTAssertEqual(h.session.presentation, .veiled(peerName: TmuxStamplessPeer.displayName))
    }

    func test_aForeignLayoutWhileAuthorityIsUnresolvedDoesNotRaiseAPeer() {
        var h = Harness()
        h.send(.attached)
        h.send(.adoptShown)
        h.send(.localSize(Self.size(92, 38)))
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        XCTAssertEqual(h.send(Self.window(1, Self.size(120, 40))), [])
        XCTAssertEqual(h.session.reducer.authority, .unknown)

        var hidden = owner()
        hidden.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        hidden.send(.hidden)
        XCTAssertEqual(hidden.send(Self.window(1, Self.size(120, 40))), [], "a hidden session's next show decides")
    }

    func test_aProvisionalActiveWindowIsNeverJudged() {
        var h = owner()
        h.send(.windowSizePolicyReplied(windowID: 2, raw: "latest"), at: Self.pastEcho)
        XCTAssertEqual(h.send(Self.window(2, Self.size(120, 40), authoritative: false), at: Self.pastEcho), [])
        XCTAssertEqual(h.send(Self.window(2, Self.size(120, 40), authoritative: true), at: Self.pastEcho),
                       [.authorityChanged(stamplessPeer), .raiseStamplessPeer])
    }

    func test_aPolicyProbeRechecksALayoutThatArrivedWhileThePolicyWasUnknown() {
        var h = owner()
        XCTAssertEqual(h.send(Self.window(2, Self.size(120, 40)), at: Self.pastEcho), [])
        XCTAssertFalse(h.session.reducer.authority.isPeer)
        XCTAssertEqual(h.send(.windowSizePolicyReplied(windowID: 2, raw: "latest"), at: Self.pastEcho),
                       [.authorityChanged(stamplessPeer), .raiseStamplessPeer])
    }

    func test_aLayoutInsideTheEchoWindowIsJudgedAgainAfterIt() {
        var h = owner()
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"))
        h.send(.sizeAdvertised(Self.size(100, 40)), at: 1_000)
        XCTAssertEqual(h.send(Self.window(1, Self.size(120, 40)), at: 1_500), [], "maybe our own echo")
        XCTAssertEqual(h.session.nextDeadline, 3_050)
        XCTAssertEqual(h.send(.tick, at: 3_049), [])
        XCTAssertEqual(h.send(.tick, at: 3_050), [.authorityChanged(stamplessPeer), .raiseStamplessPeer])
    }

    func test_anOrdinaryRecoveryThatCannotProveTheWindowRejudgesIt() {
        for proven in [false, true] {
            var h = owner()
            h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: Self.pastEcho)
            h.send(.ordinaryRecovery(active: true, proven: false), at: Self.pastEcho)
            XCTAssertEqual(h.send(Self.window(1, Self.size(120, 40)), at: Self.pastEcho), [], "a recovery proving ownership blocks")
            let effects = h.send(.ordinaryRecovery(active: false, proven: proven), at: Self.pastEcho)
            XCTAssertEqual(effects, proven ? [] : [.authorityChanged(stamplessPeer), .raiseStamplessPeer], "proven=\(proven)")
        }
    }

    private func recoveryWithOwnRead(intent: Bool = false) -> Harness {
        var h = owner()
        h.send(.windowSizePolicyReplied(windowID: 1, raw: "latest"), at: Self.pastEcho)
        h.send(.ordinaryRecovery(active: true, proven: false))
        h.send(Self.window(1, Self.size(80, 24)))
        if intent {
            h.send(.shown(source: .show, stepAt: Self.pastEcho))
            XCTAssertNotNil(h.session.query.current?.intentToken)
        } else {
            h.send(.attached)
            XCTAssertNil(h.session.query.current?.intentToken)
        }
        return h
    }

    func test_ownForeignReadDuringRecoveryWaitsForProvenLocalWindow() {
        var h = recoveryWithOwnRead()
        XCTAssertEqual(h.reply(Self.mine), [])
        XCTAssertNotNil(h.session.query.held)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        h.send(Self.window(1, Self.size(92, 38)))
        h.send(.ordinaryRecovery(active: false, proven: true))
        XCTAssertNil(h.session.query.held)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        XCTAssertEqual(h.session.presentation, .none)
    }

    func test_ownForeignReadRejudgesExactlyOnceWhenRecoveryEndsUnproven() {
        var h = recoveryWithOwnRead()
        XCTAssertEqual(h.reply(Self.mine), [])
        XCTAssertNotNil(h.session.query.held)
        let effects = h.send(.ordinaryRecovery(active: false, proven: false))
        XCTAssertEqual(effects.filter { if case .authorityChanged = $0 { return true }; return false }, [.authorityChanged(stamplessPeer)])
        XCTAssertNil(h.session.query.held)
        XCTAssertEqual(h.session.reducer.authority, stamplessPeer)
        XCTAssertEqual(h.send(.ordinaryRecovery(active: false, proven: false)), [])
        XCTAssertEqual(h.send(.tick), [])
    }

    func test_intentOwnForeignReadDuringRecoveryStillBeginsClaim() {
        var ordinary = recoveryWithOwnRead()
        XCTAssertEqual(ordinary.reply(Self.mine), [])
        XCTAssertNotNil(ordinary.session.query.held)
        var h = recoveryWithOwnRead(intent: true)
        XCTAssertEqual(claims(in: h.reply(Self.mine)).count, 1)
        XCTAssertNil(h.session.query.held)
        XCTAssertNotNil(h.claim)
    }

    func test_ownForeignReadHoldBoundDuringRecoveryFollowsStampWithUnknownGeometry() {
        var h = recoveryWithOwnRead()
        XCTAssertEqual(h.reply(Self.mine), [])
        let deadline = h.session.query.held?.deadline
        XCTAssertNotNil(deadline)
        let effects = h.send(.tick, at: deadline ?? Self.pastEcho + 10_000)
        XCTAssertEqual(effects, [.releaseGeometry(.none)])
        XCTAssertNil(h.session.query.held)
        XCTAssertTrue(h.session.ordinaryRecoveryActive)
        XCTAssertEqual(h.session.reducer.authority, .mine(generation: 3))
        XCTAssertEqual(h.session.presentation, .none)
        XCTAssertTrue(claims(in: effects).isEmpty)
    }

    // MARK: Claim replay

    private func showClaim(paintable: Bool) -> (Harness, UInt64) {
        var h = yielded()
        h.send(.paintable(paintable))
        h.send(.shown(source: .show, stepAt: 1_000), at: 1_000)
        let generation = claims(in: h.reply(Self.mac, at: 1_100)).first?.generation ?? 0
        XCTAssertNotEqual(generation, 0)
        return (h, generation)
    }

    func test_aClaimKilledByAnAdapterFailureReplaysWhenTheSurfaceCanPaint() {
        var (h, generation) = showClaim(paintable: false)
        XCTAssertEqual(h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 2_000), [
            .hideReclaimPresentation,
            .claimAborted(.adapterFailure),
        ])
        XCTAssertNotNil(h.session.replay.parked)
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 1_000))
        XCTAssertEqual(h.send(.paintable(true), at: 2_500), [.queryAuthority(id: 3)])
        XCTAssertEqual(h.session.replay.count, 1)
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: false))
        XCTAssertEqual(claims(in: h.reply(Self.mac)).map(\.reason), [.show])
    }

    func test_replaysStopAtTheBudget() {
        var (h, generation) = showClaim(paintable: true)
        for attempt in 1...8 {
            let effects = h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 1_100 + Int64(attempt) * 100)
            XCTAssertEqual(reads(in: effects), 1, "replay \(attempt) reads again")
            generation = claims(in: h.reply(Self.mac)).first?.generation ?? 0
            XCTAssertNotEqual(generation, 0)
        }
        XCTAssertEqual(h.session.replay.count, 8)
        let last = h.send(.abortClaim(generation: generation, reason: .adapterFailure))
        XCTAssertEqual(last, [.hideReclaimPresentation, .claimAborted(.adapterFailure)], "budget spent")
        XCTAssertNil(h.session.replay.parked)
        XCTAssertNil(h.session.reducer.pendingIntent)
    }

    func test_aHiddenSessionNeverReplays() {
        var (h, generation) = showClaim(paintable: false)
        XCTAssertEqual(h.send(.hidden), [.hideReclaimPresentation], "a claim keeps its ack chain but cannot fence off screen")
        XCTAssertNotNil(h.claim)
        h.send(.abortClaim(generation: generation, reason: .adapterFailure))
        XCTAssertNil(h.session.replay.parked)
        XCTAssertEqual(h.send(.paintable(true)), [])
    }

    func test_aContestedClaimIsNeverReplayed() {
        var (h, _) = showClaim(paintable: false)
        let effects = h.send(.observedAuthority(laptopPeer))
        XCTAssertTrue(effects.contains(.claimAborted(.contestedByPeer(.init(deviceID: "LAP", displayName: "Laptop", generation: 2)))))
        XCTAssertNil(h.session.replay.parked)
        XCTAssertEqual(h.send(.paintable(true)), [])
    }

    func test_aTakeBackReplaysOnlyAgainstThePeerItsVeilNamed() {
        for sameHolder in [true, false] {
            var h = yielded()
            h.send(.paintable(false))
            let generation = claims(in: h.send(.requestTakeBack, at: 1_000)).first?.generation ?? 0
            h.send(.abortClaim(generation: generation, reason: .adapterFailure))
            XCTAssertNotNil(h.session.replay.parked)
            XCTAssertNil(h.session.carriedShow(now: h.now), "a take-back is never carried")
            if !sameHolder { h.send(.observedAuthority(laptopPeer)) }
            let replayed = claims(in: h.send(.paintable(true), at: 2_000))
            XCTAssertEqual(replayed.map(\.reason), sameHolder ? [.userTakeBack] : [], "sameHolder=\(sameHolder)")
            XCTAssertNil(h.session.replay.parked)
        }
    }

    func test_aParkedClaimLapsesWithItsWindow() {
        var (h, generation) = showClaim(paintable: false)
        h.send(.abortClaim(generation: generation, reason: .adapterFailure), at: 1_500)
        XCTAssertEqual(h.send(.paintable(true), at: 21_500), [], "20 s after the first park")
        XCTAssertNil(h.session.replay.parked)
    }

    func test_aNewGestureEndsTheReplayState() {
        var (h, generation) = showClaim(paintable: false)
        h.send(.abortClaim(generation: generation, reason: .adapterFailure))
        XCTAssertNotNil(h.session.replay.parked)
        let begun = claims(in: h.send(.requestTakeBack))
        XCTAssertEqual(begun.map(\.reason), [.userTakeBack])
        XCTAssertNil(h.session.replay.parked)
        XCTAssertEqual(h.session.replay.count, 0)
    }

    // MARK: Clocks

    func test_aClaimsProgressPresentationTimesOutAfterThreeSeconds() {
        var h = yielded()
        XCTAssertEqual(claims(in: h.send(.requestTakeBack, at: 1_000)).count, 1)
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: false))
        XCTAssertEqual(h.session.nextDeadline, 4_000)
        XCTAssertEqual(h.send(.tick, at: 4_000), [.hideReclaimPresentation])
        XCTAssertNotNil(h.claim, "the chain keeps running (S4')")
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"), "a re-tap can restart it")
        let restarted = h.send(.requestTakeBack, at: 4_100)
        XCTAssertEqual(restarted.first, .claimAborted(.superseded))
        XCTAssertEqual(claims(in: restarted).map(\.generation), [2])
    }

    func test_anIntentExpiresTwentySecondsAfterTheStep() {
        var h = yielded()
        h.send(.channelLiveness(false))
        XCTAssertEqual(h.send(.shown(source: .show, stepAt: 1_000), at: 1_000), [])
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: true))
        XCTAssertEqual(h.session.nextDeadline, 21_000)
        XCTAssertEqual(h.send(.tick, at: 20_999), [])
        XCTAssertNotNil(h.session.reducer.pendingIntent)
        h.send(.tick, at: 21_000)
        XCTAssertNil(h.session.reducer.pendingIntent)
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        XCTAssertEqual(h.send(.channelLiveness(true), at: 22_000), [.queryAuthority(id: 2)])
        XCTAssertEqual(claims(in: h.reply(Self.mac)), [], "an expired show never claims")
    }

    func test_anIntentWhoseWindowRanOutAsleepNeverClaimsOnTheWakeRead() {
        var h = yielded()
        h.send(.channelLiveness(false))
        h.send(.shown(source: .show, stepAt: 0), at: 0)
        // Asleep for ten minutes: no tick ran. The wake's events see the
        // overdue deadline first.
        XCTAssertEqual(h.send(.channelLiveness(true), at: 600_000), [.queryAuthority(id: 2)])
        XCTAssertNil(h.session.reducer.pendingIntent)
        XCTAssertEqual(claims(in: h.reply(Self.mac)), [])
    }

    func test_aShowCarriedFromAReplacedSessionKeepsWhatIsLeftOfItsWindow() {
        var h = Harness()
        h.send(.shown(source: .show, stepAt: 5_000), at: 12_000)
        XCTAssertNotNil(h.session.reducer.pendingIntent, "the user's step waits for the replacement's first read")
        XCTAssertEqual(h.session.nextDeadline, 25_000)
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 5_000))

        var stale = Harness()
        XCTAssertEqual(stale.send(.shown(source: .explicitOpen, stepAt: 0), at: 20_000), [])
        XCTAssertNil(stale.session.reducer.pendingIntent, "its window already ran out")
        XCTAssertFalse(stale.session.hidden, "displayed all the same")
    }

    func test_carriedShowNeverCarriesATap() {
        var h = yielded()
        h.send(.channelLiveness(false))
        h.send(.requestTakeBack)
        XCTAssertEqual(h.session.reducer.pendingIntent?.source, .tap)
        XCTAssertNil(h.session.carriedShow(now: h.now))

        var shown = Harness()
        shown.send(.shown(source: .explicitOpen, stepAt: 0))
        XCTAssertEqual(shown.session.carriedShow(now: shown.now), .init(source: .explicitOpen, stepAt: 0))
        shown.send(.hidden)
        XCTAssertNil(shown.session.carriedShow(now: shown.now))
    }

    func test_promptsPauseTheIntentClock() {
        var h = Harness()
        h.send(.shown(source: .show, stepAt: 0), at: 0)
        XCTAssertEqual(h.session.nextDeadline, 20_000)
        h.send(.prompt(scope: .session, active: true), at: 5_000)
        XCTAssertTrue(h.session.intentClockPaused)
        XCTAssertNil(h.session.nextDeadline)
        XCTAssertEqual(h.session.carriedShow(now: h.now)?.stepAt, 5_000, "a carried show restarts the full window")
        let paused = h.session
        XCTAssertEqual(h.send(.tick, at: 60_000), [])
        XCTAssertEqual(h.session, paused, "an idle tick under a prompt changes nothing (the ABI's unchanged reply)")
        XCTAssertEqual(h.session.carriedShow(now: h.now)?.stepAt, 60_000)
        XCTAssertNotNil(h.session.reducer.pendingIntent)
        h.send(.prompt(scope: .session, active: false), at: 65_000)
        XCTAssertEqual(h.session.nextDeadline, 85_000, "answering the prompt is the user's next step")
    }

    func test_connectPromptsPauseOnlySessionsWithoutALiveChannel() {
        var connecting = Harness()
        connecting.send(.shown(source: .show, stepAt: 0))
        connecting.send(.prompt(scope: .connect, active: true))
        XCTAssertTrue(connecting.session.intentClockPaused)

        var live = Harness()
        live.send(.attached)
        live.send(.shown(source: .show, stepAt: 0))
        live.send(.prompt(scope: .connect, active: true))
        XCTAssertFalse(live.session.intentClockPaused, "a live session is not waiting on another session's host key")
        live.send(.channelLiveness(false), at: 1_000)
        XCTAssertTrue(live.session.intentClockPaused)
        live.send(.prompt(scope: .session, active: true), at: 2_000)
        live.send(.prompt(scope: .connect, active: false), at: 3_000)
        XCTAssertTrue(live.session.intentClockPaused, "the session's own password prompt is still open")
    }

    func test_retryRestartsTheShowWindow() {
        var h = Harness()
        h.send(.shown(source: .show, stepAt: 0), at: 0)
        h.send(.userStep, at: 15_000)
        XCTAssertEqual(h.session.nextDeadline, 35_000)
        XCTAssertEqual(h.session.carriedShow(now: h.now), .init(source: .show, stepAt: 15_000))
    }

    // MARK: Cancel and hide

    func test_cancellingATapWhileTheChannelIsDownLeavesATappableVeil() {
        var h = yielded()
        h.send(.channelLiveness(false))
        h.send(.requestTakeBack)
        XCTAssertEqual(h.session.presentation, .reclaiming(peerName: "Mac", awaitingConnection: true))
        h.send(.cancelIntent)
        XCTAssertNil(h.session.reducer.pendingIntent)
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        h.send(.resetTransport(preservingPeer: true))
        h.send(.channelLiveness(true))
        XCTAssertEqual(h.send(.attached), [.queryAuthority(id: 2)])
        XCTAssertEqual(claims(in: h.reply(Self.mac)), [], "a cancelled tap never claims")
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"))
        XCTAssertEqual(claims(in: h.send(.requestTakeBack)).count, 1, "the veil still takes control back")
    }

    func test_aSessionShownOverAPeerAfterRegisteringHiddenVeilsOnCancel() {
        var h = Harness()
        h.send(.attached)
        h.reply(Self.mac)
        XCTAssertEqual(h.session.presentation, .resuming(awaitingConnection: false))
        h.send(.shown(source: .show, stepAt: 0))
        XCTAssertEqual(h.session.reducer.pendingIntent?.source, .show, "the rename is its show")
        h.send(.cancelIntent)
        XCTAssertEqual(h.session.presentation, .veiled(peerName: "Mac"), "displayed: the peer is the tappable veil")
    }

    // MARK: Input gates (M7, D7)

    func test_inputWhileAShowWaitsForAConnection() {
        var disconnectedOwner = owner()
        disconnectedOwner.send(.resetTransport(preservingPeer: true))
        disconnectedOwner.send(.shown(source: .show, stepAt: disconnectedOwner.now))
        XCTAssertEqual(disconnectedOwner.session.presentation, .resuming(awaitingConnection: true))
        XCTAssertFalse(disconnectedOwner.session.gatesTyping, "typing reaches the shell through mosh")
        XCTAssertNil(disconnectedOwner.session.mutationRefusal)

        var disconnectedPeer = yielded()
        disconnectedPeer.send(.resetTransport(preservingPeer: true))
        disconnectedPeer.send(.shown(source: .show, stepAt: disconnectedPeer.now))
        XCTAssertEqual(disconnectedPeer.session.presentation, .resuming(awaitingConnection: true))
        XCTAssertTrue(disconnectedPeer.session.gatesTyping, "the last-known holder is a peer")
        XCTAssertEqual(disconnectedPeer.session.mutationRefusal, .yielded)

        var live = owner()
        live.send(.shown(source: .show, stepAt: live.now))
        XCTAssertEqual(live.session.presentation, .resuming(awaitingConnection: false))
        XCTAssertTrue(live.session.gatesTyping, "a live read is moments away")
        XCTAssertNil(live.session.mutationRefusal, "D7: resuming refuses only over a peer")

        let veiled = yielded()
        XCTAssertTrue(veiled.session.gatesTyping)
        XCTAssertEqual(veiled.session.mutationRefusal, .yielded)
    }

    // MARK: Value semantics and trace

    func test_aNoOpEventChangesNothingAndTracesNothing() {
        var h = owner()
        let before = h.session
        XCTAssertEqual(h.send(.tick, at: 50_000), [])
        XCTAssertEqual(h.send(.localSize(Self.size(92, 38))), [])
        XCTAssertEqual(h.send(.adoptShown), [])
        XCTAssertEqual(h.session, before)
        XCTAssertNil(Session.describeTransition(event: .tick, before: before, after: h.session, effects: []))

        let changing = h.session
        let effects = h.send(.requestTakeBack)
        XCTAssertEqual(effects, [], "nobody to take back from")
        let hidden = h.send(.hidden)
        let line = Session.describeTransition(event: .hidden, before: changing, after: h.session, effects: hidden)
        XCTAssertEqual(line, "event=hidden authority=mine#3 claim=none hidden=false->true hold=owner->withheld")
    }
}
