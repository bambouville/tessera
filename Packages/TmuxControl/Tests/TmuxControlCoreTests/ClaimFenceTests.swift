import XCTest
@testable import TmuxControlCore

/// The claim's fence confirmation belongs to the shared session (S3′ step 2):
/// adapters report the fence, its acknowledgement, the policy read behind it,
/// the settle probe and window forces, and the session alone decides when the
/// claim's geometry has settled.
final class ClaimFenceTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private let target = TmuxGridSize(columns: 120, rows: 40)
    private let peerSize = TmuxGridSize(columns: 80, rows: 24)

    /// A visible take-back that advertised `target` on window 3, which still
    /// stands at the peer's size; with `advertised` false, one that has not
    /// advertised yet.
    private func claiming(advertised: Bool = true) throws -> (Session, UInt64) {
        var session = Session(localDeviceID: "SELF")
        session.reduce(.attached, now: 0)
        session.reduce(.adoptShown, now: 0)
        let id = try XCTUnwrap(session.query.current?.id)
        session.reduce(.queryReplied(id: id, raw: "v1 PEER 7 iPad"), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(peerSize)), now: 0)
        session.reduce(.requestTakeBack, now: 0)
        let generation = try XCTUnwrap(session.reducer.claim?.generation)
        if advertised { session.reduce(.claimAdvertisedGeometry(generation: generation, size: target), now: 0) }
        return (session, generation)
    }

    private func window(_ size: TmuxGridSize, id: Int = 3) -> TmuxAuthorityGeometryEvidence.ActiveWindow {
        .init(id: id, size: size, authoritative: true)
    }

    private func fence(_ session: inout Session, _ generation: UInt64, window: Int = 3) throws -> UInt64 {
        session.reduce(.claimFenceSent(generation: generation, windowID: window), now: 0)
        return try XCTUnwrap(session.claimFence?.id)
    }

    private func phase(_ session: Session) -> TmuxGridAuthorityLifecycleReducer.ClaimPhase? {
        session.reducer.claim?.phase
    }

    func testAnAcknowledgedFenceConfirmsUnderLatestOnceTheWindowStandsAtTheTarget() throws {
        for policyFirst in [false, true] {
            var (session, generation) = try claiming()
            let id = try fence(&session, generation)
            let acknowledge = { (session: inout Session) in session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0) }
            let policy = { (session: inout Session) in
                session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
            }
            XCTAssertEqual(policyFirst ? policy(&session) : acknowledge(&session), [])
            XCTAssertEqual(policyFirst ? acknowledge(&session) : policy(&session), [], "the window is still the peer's size")
            XCTAssertEqual(phase(session), .awaitingFence)

            // The layout alone is a fact; the adapter says when its render
            // path has applied it.
            XCTAssertEqual(session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0), [])
            XCTAssertEqual(phase(session), .awaitingFence)
            XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
            XCTAssertEqual(phase(session), .awaitingRepaint)
            XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "confirmed once")
        }
    }

    /// A confirmed claim whose repaint an adapter retired (a layout changed
    /// its shape) re-arms it only while the fence still holds.
    func testTheFenceStaysSettledThroughTheRepaintPhaseUntilTheWindowMoves() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        XCTAssertFalse(session.claimFenceSettled, "the window is still the peer's size")
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertTrue(session.claimFenceSettled)
        session.reduce(.confirmClaimFence, now: 0)
        XCTAssertEqual(phase(session), .awaitingRepaint)
        XCTAssertTrue(session.claimFenceSettled)
        session.reduce(.claimFenceForce(fenceID: id, outstanding: true), now: 0)
        XCTAssertFalse(session.claimFenceSettled, "an unproved force")
        session.reduce(.claimFenceForce(fenceID: id, outstanding: false), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target, id: 4)), now: 0)
        XCTAssertFalse(session.claimFenceSettled, "another window is current")
    }

    /// A stamp read outside the subscription classifies as the session's
    /// own edges do, under the sanitized identity.
    func testAStampReadClassifiesUnderTheSessionsIdentity() {
        let session = Session(localDeviceID: "Dev's iPad")
        XCTAssertEqual(session.classify(raw: " v1 Dev-s-iPad 4 iPad\n"), .mine(generation: 4))
        XCTAssertEqual(session.classify(raw: "v1 PEER 2 iPhone"), .peer(deviceID: "PEER", displayName: "iPhone", generation: 2))
        XCTAssertEqual(session.classify(raw: ""), .unknown)
    }

    func testUnderAFixedPolicyTheAcknowledgementAloneConfirms() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        XCTAssertEqual(session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual", fenceID: id), now: 0), [])
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0), [.requestRepaint(generation: generation)])
    }

    func testOnlyTheCurrentFencesOwnRepliesCount() throws {
        var (session, generation) = try claiming()
        let old = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual", fenceID: old), now: 0)
        let new = try fence(&session, generation)
        XCTAssertGreaterThan(new, old)
        XCTAssertNil(session.claimFence?.policyIsLatest, "a new fence reads the policy afresh")
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: old), now: 0), [])
        // A steady probe's read, or one for another window, says nothing
        // about this fence.
        XCTAssertEqual(session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual"), now: 0), [])
        XCTAssertEqual(session.reduce(.windowSizePolicyReplied(windowID: 4, raw: "manual", fenceID: new), now: 0), [])
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: new), now: 0), [])
        XCTAssertEqual(phase(session), .awaitingFence)
        XCTAssertEqual(
            session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual", fenceID: new), now: 0),
            [.requestRepaint(generation: generation)]
        )
    }

    func testAFenceOnAnotherWindowWaitsForThatWindow() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation, window: 5)
        session.reduce(.windowSizePolicyReplied(windowID: 5, raw: "", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "window 3 at the target is not the fenced window")
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target, id: 5)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
    }

    func testASettleProbeOffTheTargetHoldsConfirmationUntilTheWindowReturns() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        // The layout reached the target before the probe read the window
        // back at the peer's size, where the claim never advertised.
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        let probe = session.reduce(.claimObservedGeometry(generation: generation, size: peerSize, settleProbe: true), now: 0)
        XCTAssertEqual(probe, [.refenceClaim(generation: generation)], "landed, then lost: rule 4")
        XCTAssertEqual(session.claimFence?.probeOffTarget, true)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "the probe outranks the cached layout")
        // The re-fence answers under the same fence; its acknowledgement
        // stood, the window has not come back yet.
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0), [])
        XCTAssertEqual(
            session.reduce(.claimObservedGeometry(generation: generation, size: target, settleProbe: false), now: 0), []
        )
        XCTAssertEqual(session.claimFence?.probeOffTarget, false)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
    }

    /// Only geometry the claim advertised can be fenced, and only before it
    /// confirmed: a fence sent later would let a confirmed claim's repaint
    /// outlive the fence it confirmed under.
    func testAFenceCountsOnlyForAnAdvertisedClaimAwaitingIt() throws {
        var (unadvertised, early) = try claiming(advertised: false)
        XCTAssertEqual(unadvertised.reduce(.claimFenceSent(generation: early, windowID: 3), now: 0), [])
        XCTAssertNil(unadvertised.claimFence, "nothing advertised, nothing to fence")

        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual", fenceID: id), now: 0)
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0), [.requestRepaint(generation: generation)])
        let confirmed = session.claimFence
        XCTAssertEqual(session.reduce(.claimFenceSent(generation: generation, windowID: 4), now: 0), [])
        XCTAssertEqual(session.claimFence, confirmed, "the confirmed fence stands")
        XCTAssertEqual(phase(session), .awaitingRepaint)
    }

    /// Under `latest` only a window tmux named active in a hydrated list is
    /// evidence the fenced window stands at the target.
    func testOnlyAJudgedWindowAtTheTargetConfirms() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        session.reduce(.windowFacts(hydrated: false, activeWindow: window(target)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "a list not yet hydrated")
        session.reduce(.windowFacts(hydrated: true, activeWindow: .init(id: 3, size: target, authoritative: false)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "a provisional window")
        XCTAssertEqual(phase(session), .awaitingFence)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
    }

    func testASettleProbeAtTheTargetConfirms() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertEqual(
            session.reduce(.claimObservedGeometry(generation: generation, size: target, settleProbe: true), now: 0),
            [.requestRepaint(generation: generation)]
        )
    }

    func testAnUnprovedForceHoldsConfirmationUnderLatestOnly() throws {
        for policy in ["latest", "manual"] {
            var (session, generation) = try claiming()
            let id = try fence(&session, generation)
            session.reduce(.claimFenceForce(fenceID: id, outstanding: true), now: 0)
            session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
            session.reduce(.windowSizePolicyReplied(windowID: 3, raw: policy, fenceID: id), now: 0)
            let acknowledged = session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
            if policy == "manual" {
                XCTAssertEqual(acknowledged, [.requestRepaint(generation: generation)], "the window follows no client")
                continue
            }
            XCTAssertEqual(acknowledged, [])
            XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [])
            XCTAssertEqual(
                session.reduce(.claimFenceForce(fenceID: id, outstanding: false), now: 0),
                [.requestRepaint(generation: generation)]
            )
        }
    }

    func testANewTargetDropsTheFenceAndTheSameGridKeepsIt() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "manual", fenceID: id), now: 0)
        // Our own grid again changes nothing the fence proved.
        session.reduce(.claimAdvertisedGeometry(generation: generation, size: target), now: 0)
        XCTAssertEqual(session.claimFence?.id, id)
        // Keyboard churn while the fence is queued: the fence predates the
        // new size, so under `manual` its acknowledgement would otherwise
        // expose the terminal before tmux saw that size.
        session.reduce(.claimAdvertisedGeometry(generation: generation, size: TmuxGridSize(columns: 120, rows: 22)), now: 0)
        XCTAssertNil(session.claimFence)
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0), [])
        XCTAssertEqual(phase(session), .awaitingFence)
    }

    func testAConfirmedClaimSentBackToItsFencePhaseConfirmsAgainOnItsOwnFence() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
        // A stale layout at an advertised grid unsettles the repaint (rule 3);
        // the window coming back is all the same fence needs.
        let unsettled = TmuxGridSize(columns: 100, rows: 30)
        session.reduce(.claimAdvertisedGeometry(generation: generation, size: unsettled), now: 0)
        let id2 = try fence(&session, generation)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id2), now: 0)
        session.reduce(.claimFenceAcknowledged(fenceID: id2), now: 0)
        session.reduce(.claimAdvertisedGeometry(generation: generation, size: unsettled), now: 0)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(unsettled)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
        session.reduce(.claimObservedGeometry(generation: generation, size: target, settleProbe: false), now: 0)
        XCTAssertEqual(phase(session), .awaitingFence, "an advertised grid off the target unsettles")
        XCTAssertEqual(session.claimFence?.id, id2)
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(target)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [], "the window is not at the target")
        session.reduce(.windowFacts(hydrated: true, activeWindow: window(unsettled)), now: 0)
        XCTAssertEqual(session.reduce(.confirmClaimFence, now: 0), [.requestRepaint(generation: generation)])
    }

    func testTheFenceEndsWithItsClaimAndANewClaimCountsOn() throws {
        var (session, generation) = try claiming()
        let id = try fence(&session, generation)
        session.reduce(.abortClaim(generation: generation, reason: .superseded), now: 0)
        XCTAssertNil(session.claimFence)
        XCTAssertEqual(session.reduce(.claimFenceAcknowledged(fenceID: id), now: 0), [])
        XCTAssertEqual(session.reduce(.claimFenceSent(generation: generation, windowID: 3), now: 0), [])
        XCTAssertNil(session.claimFence, "no fence without its claim")

        session.reduce(.requestTakeBack, now: 1)
        let next = try XCTUnwrap(session.reducer.claim?.generation)
        XCTAssertGreaterThan(next, generation)
        session.reduce(.claimAdvertisedGeometry(generation: next, size: target), now: 1)
        let nextID = try fence(&session, next)
        XCTAssertGreaterThan(nextID, id)
    }

    func testTheFenceTraceNamesNoUserHostShape() throws {
        var (session, generation) = try claiming()
        let before = session
        let event = TmuxGridAuthoritySession.Event.claimFenceSent(generation: generation, windowID: 3)
        let effects = session.reduce(event, now: 0)
        let id = try XCTUnwrap(session.claimFence?.id)
        session.reduce(.windowSizePolicyReplied(windowID: 3, raw: "latest", fenceID: id), now: 0)
        session.reduce(.claimFenceForce(fenceID: id, outstanding: true), now: 0)
        let afterAll = session
        let ack = TmuxGridAuthoritySession.Event.claimFenceAcknowledged(fenceID: id)
        let ackEffects = session.reduce(ack, now: 0)
        let traces = [
            Session.describeTransition(event: event, before: before, after: afterAll, effects: effects),
            Session.describeTransition(event: ack, before: afterAll, after: session, effects: ackEffects),
        ].compactMap { $0 }
        XCTAssertEqual(traces.count, 2)
        for trace in traces {
            XCTAssertNil(trace.range(of: #"\w@\w"#, options: .regularExpression), trace)
        }
        XCTAssertTrue(traces[1].contains("fence=f\(id)(@3 latest force)->f\(id)(@3 ack latest force)"), traces[1])
    }
}
