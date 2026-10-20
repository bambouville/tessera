import Foundation
import XCTest
@testable import TmuxControlCore

/// Seeded random interleavings of every session event on a random clock
/// (including sleeps far past every bound), checked against the show
/// rule's structural invariants rather than hand-picked sequences:
///
/// - no claim without a gesture: a run with no show, explicit open or tap
///   never begins a claim (R5), and every claim's reason is backed by a
///   pending intent, the event itself, a parked replay of the same kind, or
///   the own-write-won continuation;
/// - no claim begins into a hidden or background session, whatever the
///   entry (a show, an adoption, a tap, a replay, the own-write-won
///   continuation, a timed-out claim's restart, or a read);
/// - an intent never outlives its deadline: unless a prompt pauses it, a
///   pending intent is always younger than 20 s since the user's last step
///   (tracked here independently of the session's clock);
/// - an own-stamp reply is held at most 10 s;
/// - at most 8 replays per park window, never while hidden or in the
///   background, and nothing stays parked in a hidden session;
/// - the input gates always match the presentation, and the presentation
///   always matches a fresh derivation;
/// - nothing is left due when a reduction returns, and `describeTransition`
///   is nil exactly for no-op reductions;
/// - I1: a late claim's advertised grids never grow, and no claim may
///   advertise after its presentation deadline;
/// - settlement records the target, and a peer verdict releases no churn.
final class AuthoritySessionModelTests: XCTestCase {
    private typealias Session = TmuxGridAuthoritySession
    private typealias Event = TmuxGridAuthoritySession.Event
    private typealias Effect = TmuxGridAuthoritySession.Effect
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer

    /// SplitMix64: deterministic across platforms and runs.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    private static let stamps = ["v1 SELF 3 iPad", "v1 SELF 9 iPad", "v1 MAC 7 Mac", "v1 LAP 2 Laptop", "", "garbled"]
    private static let sizes = [
        TmuxGridSize(columns: 92, rows: 38),
        TmuxGridSize(columns: 100, rows: 40),
        TmuxGridSize(columns: 120, rows: 40),
    ]
    private static let peers: [TmuxGridAuthoritySnapshot] = [
        .peer(deviceID: "MAC", displayName: "Mac", generation: 7),
        .peer(deviceID: "MAC", displayName: "Mac", generation: 8),
        .peer(deviceID: "LAP", displayName: "Laptop", generation: 2),
        .mine(generation: 3),
        .unknown,
    ]

    /// Advance one production fence event, leaving arbitrary events free to
    /// interrupt between its advertisement, acknowledgement and evidence.
    private func fenceEvent(_ rng: inout Generator, session: Session, generation: UInt64) -> Event {
        guard let target = session.reducer.claim?.targetGrid else {
            return .claimAdvertisedGeometry(generation: generation, size: rng.pick(Self.sizes))
        }
        guard let fence = session.claimFence, fence.generation == generation else {
            return .claimFenceSent(generation: generation, windowID: session.evidence.activeWindow?.id ?? rng.below(2))
        }
        if !fence.acknowledged {
            // Out of wire order, the fence's own policy read sometimes lands
            // first: the confirmation must still wait for the acknowledgement.
            if fence.policyIsLatest == nil, rng.below(4) == 0 {
                return .windowSizePolicyReplied(windowID: fence.windowID, raw: "latest", fenceID: fence.id)
            }
            return .claimFenceAcknowledged(fenceID: fence.id)
        }
        if fence.policyIsLatest != true {
            return .windowSizePolicyReplied(windowID: fence.windowID, raw: "latest", fenceID: fence.id)
        }
        if fence.forceOutstanding { return .claimFenceForce(fenceID: fence.id, outstanding: false) }
        let size = TmuxGridSize(columns: target.columns, rows: target.rows)
        if fence.probeOffTarget {
            return .claimObservedGeometry(generation: generation, size: size, settleProbe: true)
        }
        if session.evidence.judgedWindow?.id != fence.windowID || session.evidence.judgedWindow?.size != size {
            return .windowFacts(hydrated: true, activeWindow: .init(id: fence.windowID, size: size, authoritative: true))
        }
        return .confirmClaimFence
    }

    /// The fence evidence a confirmation needs, judged here rather than by
    /// the session's own `claimFenceSettled`: this fence acknowledged, its
    /// policy read, and under `latest` the fenced window at the target.
    private func fenceProves(_ session: Session, _ claim: Reducer.Claim) -> Bool {
        guard let target = claim.targetGrid, let fence = session.claimFence, fence.generation == claim.generation,
              fence.acknowledged, let latest = fence.policyIsLatest
        else { return false }
        guard latest else { return true }
        guard let window = session.evidence.judgedWindow, window.id == fence.windowID else { return false }
        return window.size == TmuxGridSize(columns: target.columns, rows: target.rows)
    }

    private func randomEvent(_ rng: inout Generator, session: Session, now: Int64, gestures: Bool) -> Event {
        let claimGeneration = session.reducer.claim?.generation ?? UInt64(rng.below(4))
        let readID = rng.chance(80) ? (session.query.current?.id ?? session.query.nextID) : UInt64(rng.below(6))
        // Exercise full ack chains as well as arbitrary interleavings. The
        // fence evidence and four serial phases otherwise mostly reset or
        // abort before settlement, leaving its invariants untested.
        if let claim = session.reducer.claim, rng.chance(30) {
            switch claim.phase {
            case .awaitingFence:
                return fenceEvent(&rng, session: session, generation: claimGeneration)
            case .awaitingRepaint:
                // An advertisement can overtake the repaint: the new target
                // has to be fenced again before it can settle.
                return rng.chance(15)
                    ? .claimAdvertisedGeometry(generation: claimGeneration, size: rng.pick(Self.sizes))
                    : .repaintSucceeded(generation: claimGeneration)
            case .awaitingStampCommit: return .stampCommitSucceeded(generation: claimGeneration)
            case .awaitingSettlement: return .settleClaim(generation: claimGeneration)
            }
        }
        while true {
            switch rng.below(34) {
            case 0: return .attached
            case 1: return .resetTransport(preservingPeer: rng.chance(50))
            case 2: return .channelLiveness(rng.chance(60))
            case 3, 4:
                guard gestures else { continue }
                let lag = rng.chance(20) ? Int64(rng.below(30_000)) : 0
                return .shown(source: rng.chance(70) ? .show : .explicitOpen, stepAt: now - lag)
            case 5: return .adoptShown
            case 6: return .hidden
            case 7, 8:
                guard gestures else { continue }
                return .requestTakeBack
            case 9: return .cancelIntent
            case 10: return .userStep
            case 11: return .prompt(scope: rng.chance(50) ? .session : .connect, active: rng.chance(50))
            // Mostly active, as a session is: nothing claims from the
            // background (M6), so time there reaches fewer claim states.
            case 12: return rng.chance(70) ? .foregrounded : .backgrounded
            case 13: return .observedAuthority(rng.pick(Self.peers))
            case 14: return .ownStampObserved(generation: claimGeneration)
            case 15, 16: return .queryReplied(id: readID, raw: rng.pick(Self.stamps))
            case 17: return .queryFailed(id: readID)
            case 18:
                let window: TmuxAuthorityGeometryEvidence.ActiveWindow? = rng.chance(85)
                    ? .init(id: rng.below(2), size: rng.chance(90) ? rng.pick(Self.sizes) : nil, authoritative: rng.chance(80))
                    : nil
                return .windowFacts(hydrated: rng.chance(85), activeWindow: window)
            case 19: return .localSize(rng.chance(90) ? rng.pick(Self.sizes) : nil)
            case 20: return .windowSizePolicyReplied(windowID: rng.below(2), raw: rng.pick(["", "latest", "smallest"]))
            case 21:
                return session.reducer.claim != nil
                    ? .claimAdvertisedGeometry(generation: claimGeneration, size: rng.pick(Self.sizes))
                    : .sizeAdvertised(rng.pick(Self.sizes))
            case 22: return .ordinaryRecovery(active: rng.chance(50), proven: rng.chance(50))
            case 23: return .paintable(rng.chance(60))
            case 24: return .controlSessionChanged(replacedKnownSession: rng.chance(50))
            case 25: return rng.chance(50) ? fenceEvent(&rng, session: session, generation: claimGeneration) : .repaintSucceeded(generation: claimGeneration)
            case 26: return rng.chance(50) ? .stampCommitSucceeded(generation: claimGeneration) : .settleClaim(generation: claimGeneration)
            case 27:
                let reason: Reducer.AbortReason = rng.pick([.adapterFailure, .adapterFailure, .superseded, .transportReset])
                return .abortClaim(generation: claimGeneration, reason: reason)
            case 28: return .claimObservedGeometry(generation: claimGeneration, size: rng.pick(Self.sizes), settleProbe: rng.chance(50))
            case 29: return .claimGeometryLost(generation: claimGeneration)
            case 30: return .claimStalled(generation: claimGeneration, canProgress: rng.chance(50))
            case 31: return .claimFenceForce(fenceID: session.claimFence?.id ?? 0, outstanding: rng.chance(50))
            case 32: return .claimFenceAcknowledged(fenceID: rng.chance(50) ? (session.claimFence?.id ?? 0) : UInt64(rng.below(6)))
            default: return .tick
            }
        }
    }

    private func advance(_ rng: inout Generator) -> Int64 {
        switch rng.below(100) {
        case 0..<35: return 0
        case 35..<85: return Int64(rng.below(1_500))
        case 85..<95: return Int64(rng.below(12_000))
        default: return Int64(rng.below(700_000))  // asleep
        }
    }

    /// The user's step behind the pending intent, as the show rule defines
    /// it, followed independently of the session's own clock.
    private struct StepOracle {
        var token: UInt64?
        var stepAt: Int64 = 0

        mutating func observe(event: Event, before: Session, after: Session, now: Int64) {
            let token = after.reducer.pendingIntent?.token
            let resumed = before.intentClockPaused && !after.intentClockPaused
            if token != self.token {
                self.token = token
                if case .shown(_, let step) = event, token != nil {
                    stepAt = min(step, now)
                } else {
                    stepAt = now
                }
                if after.intentClockPaused || resumed { stepAt = now }
            } else if token != nil {
                if case .userStep = event { stepAt = now }
                if resumed { stepAt = now }
            }
        }
    }

    private struct Totals {
        var reductions = 0
        var claims = 0
        var replays = 0
        var holds = 0
        var expiries = 0
        var lateAdvertisements = 0
        var settlements = 0
        var acceptedStalls = 0
        var recoveringStalls = 0
        var refences = 0
        var geometryLossAborts = 0
        var settlementsFromTargetlessClaims = 0
        var repaintRetargets = 0
        var referenceChecks = 0
    }

    private func run(seed: UInt64, steps: Int, gestures: Bool, totals: inout Totals) {
        var rng = Generator(state: seed)
        var session = Session(localDeviceID: "SELF")
        var now: Int64 = 1_000
        var oracle = StepOracle()
        var heldSince: (readID: UInt64, at: Int64)?
        var claimDeadline: (generation: UInt64, at: Int64)?
        var history: [String] = []
        var initiallyTargetlessClaims: Set<UInt64> = []
        // The target each claim's last confirmation proved, by generation.
        var fencedTargets: [UInt64: Reducer.Grid] = [:]

        for _ in 0..<steps {
            now += advance(&rng)
            let event = randomEvent(&rng, session: session, now: now, gestures: gestures)
            let before = session
            let effects = session.reduce(event, now: now)
            totals.reductions += 1
            history.append("\(now) \(event.traceLabel) -> [\(effects.map(\.traceLabel).joined(separator: ","))]")
            if history.count > 40 { history.removeFirst() }
            var failed = false
            func fail(_ message: String) {
                guard !failed else { return }
                failed = true
                XCTFail("seed \(seed): \(message)\n" + history.joined(separator: "\n"))
            }

            // Differentially check the claim branches against the reference
            // reducer, including the presentation deadline that fires before
            // the event. Session-only reads, replay and rule 7 may add effects.
            var reference = Reducer(snapshot: before.reducer.snapshot)
            var deadlineEffects: [Reducer.Effect] = []
            if let deadline = claimDeadline, now >= deadline.at {
                deadlineEffects = reference.presentationTimedOut(generation: deadline.generation)
            }
            let referenceBefore = reference.claim
            var expected: [Reducer.Effect]?
            switch event {
            case .claimStalled(let generation, let canProgress):
                if let claim = referenceBefore, claim.generation == generation,
                   claim.phase == .awaitingFence || claim.phase == .awaitingRepaint {
                    totals.acceptedStalls += 1
                    if canProgress && claim.presentationVisible { totals.recoveringStalls += 1 }
                }
                expected = reference.claimStalled(generation: generation, canProgress: canProgress)
            case .claimObservedGeometry(let generation, let size, let probe):
                expected = reference.claimObservedGeometry(generation: generation, columns: size.columns,
                                                          rows: size.rows, settleProbe: probe)
            case .claimGeometryLost(let generation):
                expected = reference.claimGeometryLost(generation: generation)
            case .settleClaim(let generation):
                expected = reference.settleClaim(generation: generation)
            default:
                expected = nil
            }
            // A target settle probe can confirm a previously settled fence
            // inside the session, after the geometry reducer ran.
            if case .claimObservedGeometry(let generation, let size, true) = event,
               reference.claim?.generation == generation, reference.claim?.phase == .awaitingFence,
               reference.claim?.targetGrid == .init(columns: size.columns, rows: size.rows),
               session.claimFenceSettled {
                expected = (expected ?? []) + reference.fenceSucceeded(generation: generation)
            }
            if before.reducer.claim?.phase == .awaitingFence,
               let claim = session.reducer.claim, claim.phase == .awaitingRepaint {
                guard fenceProves(session, claim), let target = claim.targetGrid else {
                    fail("claim \(claim.traceLabel) confirmed without its fence's evidence")
                    return
                }
                fencedTargets[claim.generation] = target
            }
            if let prior = before.reducer.claim, prior.phase == .awaitingRepaint,
               let claim = session.reducer.claim, claim.generation == prior.generation,
               claim.targetGrid != prior.targetGrid {
                totals.repaintRetargets += 1
            }
            if let expected {
                let expected = deadlineEffects + expected
                totals.referenceChecks += 1
                var expectedInstructions: [Effect] = []
                for instruction in expected {
                    let translated: Effect?
                    switch instruction {
                    case .refenceClaim(let generation):
                        totals.refences += 1
                        translated = .refenceClaim(generation: generation)
                    case .claimAborted(let reason):
                        if reason == .geometryLost { totals.geometryLossAborts += 1 }
                        translated = .claimAborted(reason)
                    case .claimSettled(let generation): translated = .claimSettled(generation: generation)
                    case .hideReclaimPresentation: translated = .hideReclaimPresentation
                    case .authorityChanged: translated = nil // Rule 7 can project a peer afterwards.
                    default: translated = nil
                    }
                    if let translated, !effects.contains(translated) {
                        fail("missing reference effect \(translated.traceLabel)")
                    }
                    if let translated { expectedInstructions.append(translated) }
                }
                let actualInstructions = effects.filter {
                    switch $0 {
                    case .hideReclaimPresentation, .refenceClaim, .claimAborted, .claimSettled: return true
                    default: return false
                    }
                }
                if actualInstructions != expectedInstructions { fail("claim effects differ from reference reducer") }
                for case .refenceClaim(let generation) in effects {
                    if !expected.contains(.refenceClaim(generation: generation)) {
                        fail("re-fence absent from reference reducer")
                    }
                }
                for case .claimAborted(.geometryLost) in effects {
                    if !expected.contains(.claimAborted(.geometryLost)) {
                        fail("geometry-loss abort absent from reference reducer")
                    }
                }
                if let expectedClaim = reference.claim {
                    if session.reducer.claim != expectedClaim { fail("claim phase or geometry differs from reference reducer") }
                } else if let active = session.reducer.claim, active.generation == referenceBefore?.generation {
                    fail("reference ended the claim but the session retained it")
                }
            }

            // No claim without a gesture.
            for case .beginClaim(let claim) in effects {
                totals.claims += 1
                if claim.targetGrid == nil { initiallyTargetlessClaims.insert(claim.generation) }
                if !gestures { fail("claim \(claim.traceLabel) with no gesture in the run") }
                if session.hidden || session.inBackground {
                    fail("claim \(claim.traceLabel) begun into a \(session.hidden ? "hidden" : "background") session")
                }
                let intent = before.reducer.pendingIntent?.source
                let parked = before.replay.parked?.reason
                let backed: Bool
                switch claim.reason {
                case .show, .explicitOpen:
                    // The pending intent's read (a reply, the evidence that
                    // released its held reply, or the hold's bound), or a
                    // show restarting a claim whose presentation timed out.
                    // A replayed show records an intent; its read decides
                    // it in a later reduction.
                    let source: Reducer.IntentSource = claim.reason == .show ? .show : .explicitOpen
                    var isShowEvent = false
                    if case .shown = event { isShowEvent = true }
                    backed = intent == source || isShowEvent
                case .userTakeBack:
                    // A tap, its waiting intent's read, or a take-back
                    // replayed against the same peer: parked earlier, or
                    // parked by this very abort while a surface can paint.
                    var isTap = false
                    if case .requestTakeBack = event { isTap = true }
                    var abortedTakeBack = false
                    if effects.contains(.claimAborted(.adapterFailure)),
                       let reason = before.reducer.claim?.reason,
                       reason == .userTakeBack || reason == .ownWriteWon {
                        abortedTakeBack = true
                    }
                    backed = intent == .tap || isTap || abortedTakeBack
                        || parked == .userTakeBack || parked == .ownWriteWon
                case .ownWriteWon:
                    var isOwn = false
                    if case .ownStampObserved = event { isOwn = true }
                    backed = isOwn
                }
                if !backed { fail("claim \(claim.traceLabel) with no gesture behind it") }
                claimDeadline = (claim.generation, now + session.configuration.claimPresentationMillis)
            }

            if let live = session.reducer.claim {
                if let deadline = claimDeadline, deadline.generation == live.generation,
                   now >= deadline.at, session.claimMayAdvertiseGeometry {
                    fail("claim advertises after its presentation deadline")
                }
                if !session.claimMayAdvertiseGeometry, session.geometryHold != .withheld {
                    fail("a late claim releases geometry")
                }
            }
            if case .claimAdvertisedGeometry = event, let prior = before.reducer.claim,
               !prior.presentationVisible || (claimDeadline?.generation == prior.generation && now >= claimDeadline!.at) {
                totals.lateAdvertisements += 1
                if let live = session.reducer.claim, live.generation == prior.generation,
                   live.advertisedGrids != prior.advertisedGrids || live.targetGrid != prior.targetGrid {
                    fail("I1: a late advertisement grew or retargeted the claim")
                }
                if session.lastAdvertisedSize != before.lastAdvertisedSize || session.lastAdvertisedAt != before.lastAdvertisedAt {
                    fail("a late advertisement changed advertise bookkeeping")
                }
            }
            if effects.contains(where: { if case .claimSettled = $0 { return true }; return false }) {
                totals.settlements += 1
                guard let settlingClaim = before.reducer.claim, settlingClaim.targetGrid != nil else {
                    fail("a claim settled without an advertised target")
                    return
                }
                if fencedTargets[settlingClaim.generation] != settlingClaim.targetGrid {
                    fail("settlement's target \(settlingClaim.traceLabel) was never fenced")
                }
                if initiallyTargetlessClaims.contains(settlingClaim.generation) {
                    totals.settlementsFromTargetlessClaims += 1
                }
                if let target = settlingClaim.targetGrid,
                   !session.evidence.owned.contains(TmuxGridSize(columns: target.columns, rows: target.rows)) {
                    fail("settlement did not record its target as owned")
                }
                if session.reducer.authority.isPeer, effects.contains(.releaseGeometry(.ownerReplay)) {
                    fail("settlement replays held-back churn over a peer")
                }
            }

            // An intent never outlives its deadline.
            oracle.observe(event: event, before: before, after: session, now: now)
            if session.reducer.pendingIntent != nil, !session.intentClockPaused {
                if now - oracle.stepAt >= TmuxAuthorityIntentClock.defaultWindowMillis {
                    fail("intent \(session.reducer.pendingIntent.traceLabel) outlived its step at \(oracle.stepAt)")
                }
                if session.intentClock.token != session.reducer.pendingIntent?.token {
                    fail("the clock is not timing the pending intent")
                }
            }
            if before.reducer.pendingIntent != nil, session.reducer.pendingIntent == nil {
                totals.expiries += 1
            }

            // A held reply lasts at most 10 s.
            if let held = session.query.held {
                if heldSince?.readID != held.readID {
                    heldSince = (held.readID, now)
                    totals.holds += 1
                }
                if let since = heldSince, now - since.at >= 10_000 {
                    fail("reply r\(held.readID) held since \(since.at)")
                }
            } else {
                heldSince = nil
            }

            // At most 8 replays, never while hidden.
            if session.replay.count > TmuxAuthorityClaimReplay.defaultBudget {
                fail("\(session.replay.count) replays")
            }
            if session.replay.count > before.replay.count {
                totals.replays += 1
                if session.hidden || session.inBackground { fail("replayed into a hidden or background session") }
            }
            if session.hidden, session.replay.parked != nil {
                fail("a gesture stays parked in a hidden session")
            }

            // The input gates match the presentation.
            let derived = TmuxGridAuthorityPresentation.derive(
                reducer: session.reducer,
                hidden: session.hidden,
                channelLive: session.channelIsLive
            )
            if session.presentation != derived { fail("presentation \(session.presentation) != \(derived)") }
            // The last-known holder: the authority, or the peer a waiting
            // tap's veil named (a reset can forget the authority's peer).
            var lastKnown = session.reducer.authority
            if !lastKnown.isPeer, let intent = session.reducer.pendingIntent, intent.source == .tap,
               let peer = intent.baseline {
                lastKnown = .peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation)
            }
            if session.gatesTyping != session.presentation.gatesTyping(lastKnown: lastKnown) {
                fail("typing gate disagrees with \(session.presentation.traceLabel)")
            }
            if session.mutationRefusal != session.presentation.mutationRefusal(lastKnown: lastKnown) {
                fail("mutation gate disagrees with \(session.presentation.traceLabel)")
            }
            if case .veiled = session.presentation, !session.gatesTyping { fail("a veil that lets typing through") }
            if case .reclaiming = session.presentation, !session.gatesTyping {
                fail("a reclaiming veil that lets typing through")
            }
            if session.geometryHold == .owner,
               session.reducer.claim == nil,
               session.hidden || session.heldForRead || session.inBackground || session.reducer.authority.isPeer {
                fail("owner geometry while \(session.hidden ? "hidden" : "held, inactive or yielded")")
            }
            if session.reducer.claim != nil, session.reducer.pendingIntent != nil {
                fail("a claim and an intent coexist")
            }
            if session.carriedShow(now: now) != nil, session.hidden { fail("a hidden session carries a show") }
            if session.reducer.pendingIntent?.source == .tap, session.reducer.claim == nil,
               session.replay.parked == nil, session.carriedShow(now: now) != nil {
                fail("a tap was carried as a show")
            }

            // Nothing is left due, and the trace matches the change.
            if let deadline = session.nextDeadline, deadline <= now {
                fail("deadline \(deadline) already due at \(now)")
            }
            let line = Session.describeTransition(event: event, before: before, after: session, effects: effects)
            if (line == nil) != (before == session && effects.isEmpty) {
                fail("trace \(line ?? "nil") for a \(before == session ? "no-op" : "change")")
            }
            // One counterexample per seed is enough to read.
            if failed { return }
        }
    }

    func testRandomInterleavingsKeepTheShowRuleInvariants() {
        var totals = Totals()
        // The expanded claim geometry grammar and valid ack chains consume
        // more events per claim. Keep the original claim-count coverage
        // bound by exploring more seeds, rather than weakening the bound.
        // The real fence requires an advertised target, its own policy read
        // and authoritative window facts. Explore more seeds to retain every
        // bound despite the longer chain and intervening session switches.
        for seed in 1...2_000 as ClosedRange<UInt64> {
            run(seed: seed &* 0x5851_F42D_4C95_7F2D, steps: 400, gestures: true, totals: &totals)
        }
        XCTAssertEqual(totals.reductions, 800_000)
        // The generator must actually reach the states the invariants guard.
        XCTAssertGreaterThan(totals.claims, 800, "claims begun")
        XCTAssertGreaterThan(totals.replays, 30, "replays")
        XCTAssertGreaterThan(totals.holds, 200, "own-stamp holds")
        XCTAssertGreaterThan(totals.expiries, 500, "intents ended")
        XCTAssertGreaterThan(totals.lateAdvertisements, 0, "late advertisement attempts")
        XCTAssertGreaterThan(totals.settlements, 0, "settlements")
        XCTAssertGreaterThan(totals.acceptedStalls, 50, "accepted stalls")
        XCTAssertGreaterThan(totals.recoveringStalls, 15, "successful stall recovery")
        XCTAssertGreaterThan(totals.refences, 10, "accepted re-fences")
        XCTAssertGreaterThan(totals.geometryLossAborts, 20, "geometry-loss aborts")
        XCTAssertGreaterThan(totals.settlementsFromTargetlessClaims, 30, "initially targetless claims settled through the real fence")
        XCTAssertGreaterThan(totals.repaintRetargets, 0, "claims retargeted awaiting repaint")
        print("authority seeded totals: \(totals)")
    }

    func testRandomInterleavingsWithoutGesturesNeverClaim() {
        var totals = Totals()
        for seed in 1...200 as ClosedRange<UInt64> {
            run(seed: seed &* 0x2545_F491_4F6C_DD1D, steps: 400, gestures: false, totals: &totals)
        }
        XCTAssertEqual(totals.reductions, 80_000)
        XCTAssertEqual(totals.claims, 0)
        XCTAssertGreaterThan(totals.holds, 200, "own-stamp holds")
    }
}
