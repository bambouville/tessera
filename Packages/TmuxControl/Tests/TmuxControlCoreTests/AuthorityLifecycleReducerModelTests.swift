import Foundation
import XCTest
@testable import TmuxControlCore

/// Seeded random interleavings of every reducer event, checked against the
/// show rule's structural invariants rather than hand-picked sequences:
///
/// - every claim reaches exactly one terminal outcome (settled or aborted),
///   and no claim is silently replaced;
/// - no claim begins without a show, explicit open or tap behind it, or an
///   own-write-won continuation of a contested user claim (R5);
/// - a claim and a pending intent never coexist, and claims run only on an
///   attached channel;
/// - a show or explicit-open intent never carries a baseline, and nothing
///   but its fresh read (R2), a hide, its own expiry or a newer gesture ends
///   it: live observations, resets and claim acks leave it exactly as it was;
/// - a tap intent is bound to the peer its veil named and ends early only on
///   a read or observation of a different peer;
/// - a read without an intent follows the stamp: our own stamp yields to the
///   stamp-less fallback only on a foreign size, unknown geometry never
///   manufactures "another device" (nor refutes one), and only a read at the
///   size we last pushed replays geometry;
/// - a claim that loses its geometry fences again at most once per
///   generation, only while visible, and returns to `awaitingFence`; a
///   second loss, or a loss once late, aborts it (`geometryLost`);
/// - the claim end-of-life invariants of §6.10:
///   - I1: a late claim never advertises geometry (its advertised grids
///     and target never change after its deadline);
///   - I2: no stamp without the claim's own ack chain: a commit follows a
///     fence that confirmed the claim, with no re-target, unsettled
///     observation or loss in between;
///   - I3: the deadline never aborts; `geometryLost` comes only from a
///     landed foreign observation or an adapter loss, `adapterFailure` only
///     from a stall or an adapter abort, and our own grids never lose;
///   - I4: a late claim settles or aborts within a bounded number of its
///     own round trips;
/// - `describeTransition` is nil exactly for no-op reductions.
final class AuthorityLifecycleReducerModelTests: XCTestCase {
    private typealias Reducer = TmuxGridAuthorityLifecycleReducer
    private typealias Effect = TmuxGridAuthorityLifecycleReducer.Effect

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

    private enum Step: CustomStringConvertible {
        case attached
        case foregrounded
        case reset(preservingPeer: Bool)
        case shown(Reducer.ShowSource)
        case hidden
        case intentExpired(UInt64)
        case tap(channelLive: Bool)
        case observed(TmuxGridAuthoritySnapshot)
        case query(TmuxGridAuthoritySnapshot, Reducer.QueryGeometry)
        case ownStamp(UInt64)
        case timeout(UInt64)
        case fence(UInt64)
        case repaint(UInt64)
        case geometryLost(UInt64)
        case advertise(UInt64, Reducer.Grid)
        case observe(UInt64, Reducer.Grid, settleProbe: Bool)
        case stall(UInt64, canProgress: Bool)
        case commit(UInt64)
        case settle(UInt64)
        case abort(UInt64)

        var description: String {
            switch self {
            case .attached: return "attached"
            case .foregrounded: return "foregrounded"
            case .reset(let preserving): return "reset(\(preserving))"
            case .shown(let source): return "shown(\(source))"
            case .hidden: return "hidden"
            case .intentExpired(let token): return "intentExpired(\(token))"
            case .tap(let live): return "tap(live=\(live))"
            case .observed(let authority): return "observed(\(authority.traceLabel))"
            case .query(let authority, let geometry): return "query(\(authority.traceLabel), \(geometry))"
            case .ownStamp(let generation): return "ownStamp(\(generation))"
            case .timeout(let generation): return "timeout(\(generation))"
            case .fence(let generation): return "fence(\(generation))"
            case .repaint(let generation): return "repaint(\(generation))"
            case .geometryLost(let generation): return "geometryLost(\(generation))"
            case .advertise(let generation, let grid): return "advertise(\(generation), \(grid.columns)x\(grid.rows))"
            case .observe(let generation, let grid, let probe):
                return "observe(\(generation), \(grid.columns)x\(grid.rows)\(probe ? ", probe" : ""))"
            case .stall(let generation, let canProgress): return "stall(\(generation), canProgress=\(canProgress))"
            case .commit(let generation): return "commit(\(generation))"
            case .settle(let generation): return "settle(\(generation))"
            case .abort(let generation): return "abort(\(generation))"
            }
        }

        var isGesture: Bool {
            switch self {
            case .shown, .tap: return true
            default: return false
            }
        }
    }

    private let authorities: [TmuxGridAuthoritySnapshot] = [
        .unknown,
        .mine(generation: 1),
        .mine(generation: 2),
        .peer(deviceID: "ipad", displayName: "iPad", generation: 7),
        .peer(deviceID: "ipad", displayName: "iPad", generation: 8),
        .peer(deviceID: "phone", displayName: "iPhone", generation: 1),
        .peer(deviceID: "-", displayName: "another device", generation: 0),
    ]
    private let geometries: [Reducer.QueryGeometry] = [.atLocalSize, .atLastOwnedSize, .foreignSize, .unknown]
    /// Window grids: some this device advertises, some only peers use.
    private let grids: [Reducer.Grid] = [
        .init(columns: 92, rows: 38), .init(columns: 92, rows: 20),
        .init(columns: 105, rows: 31), .init(columns: 120, rows: 40),
    ]

    /// A window size a healthy adapter could report for `claim`: its
    /// target, another grid it advertised, or any grid at all.
    private func observedGrid(_ random: inout Generator, claim: Reducer.Claim?) -> Reducer.Grid {
        if let target = claim?.targetGrid, random.chance(40) { return target }
        if let advertised = claim?.advertisedGrids, !advertised.isEmpty, random.chance(30) {
            return random.pick(advertised)
        }
        return random.pick(grids)
    }

    private func peer(of authority: TmuxGridAuthoritySnapshot) -> Reducer.Peer? {
        guard case let .peer(deviceID, displayName, generation) = authority else { return nil }
        return .init(deviceID: deviceID, displayName: displayName, generation: generation)
    }

    /// The intent rules (R1–R4) for one reduction; returns a failure text.
    private func checkIntent(step: Step, before: Reducer.Snapshot, after: Reducer, began: Bool) -> String? {
        if let intent = after.pendingIntent {
            if intent.source == .tap {
                guard intent.baselineKnown, intent.baseline != nil else { return "a tap intent lost its veil peer" }
            } else if intent.baselineKnown || intent.baseline != nil {
                return "a \(intent.source) intent carries a baseline"
            }
            if intent.token != before.pendingIntent?.token, case .tap = step,
               intent.baseline != peer(of: before.authority) {
                return "a tap bound a peer its veil did not name"
            }
        }

        // R2 at the fresh read: the decision table, never a silent drop.
        if case let .query(observed, geometry) = step,
           before.channelAttached, before.claim == nil, let intent = before.pendingIntent {
            var atOurSize = false
            if case .mine = observed, geometry == .atLocalSize { atOurSize = true }
            let displacedTap = intent.baselineKnown && peer(of: observed).map { $0 != intent.baseline } == true
            if atOurSize || displacedTap {
                guard !began, after.pendingIntent == nil else { return "the read should have ended \(intent.source) without a claim" }
            } else {
                guard began else { return "the read dropped a \(intent.source) intent instead of claiming" }
            }
            return nil
        }

        guard let previous = before.pendingIntent, after.pendingIntent != previous else { return nil }
        switch step {
        case .shown, .tap, .hidden:
            return nil
        case .intentExpired(let token):
            return token == previous.token ? nil : "an expiry of another token ended the intent"
        case .observed(let observed):
            // Only a tap, and only by a different peer. A show intent must
            // survive lines that may predate it.
            guard previous.source == .tap,
                  after.pendingIntent == nil,
                  let rival = peer(of: observed), rival != previous.baseline
            else { return "a live observation ended or rebased a \(previous.source) intent" }
            return nil
        case .ownStamp:
            return began ? nil : "an own stamp ended the intent without claiming"
        default:
            return "\(step) changed the pending intent"
        }
    }

    /// The no-intent rows of the read decision table; returns a failure text.
    private func checkReadWithoutIntent(
        step: Step,
        before: Reducer.Snapshot,
        after: Reducer,
        effects: [Effect],
        ledger: inout Ledger
    ) -> String? {
        guard case let .query(observed, geometry) = step,
              before.channelAttached, before.claim == nil, before.pendingIntent == nil
        else { return nil }
        let replays = effects.contains { $0 == .replayOwnedGeometry }
        guard case .mine = observed else {
            if replays { return "a \(observed.traceLabel) read replayed geometry" }
            return after.authority == observed ? nil : "a read without an intent did not follow \(observed.traceLabel)"
        }
        let stampless = TmuxGridAuthoritySnapshot.peer(
            deviceID: Reducer.stamplessPeer.deviceID,
            displayName: Reducer.stamplessPeer.displayName,
            generation: Reducer.stamplessPeer.generation
        )
        switch geometry {
        case .foreignSize:
            guard after.authority == stampless, !replays else { return "a foreign size over our stamp did not yield (D5)" }
        case .unknown:
            ledger.unknownGeometryOwnReads += 1
            let expected = before.authority == stampless ? stampless : observed
            guard after.authority == expected, !replays else {
                return "unknown geometry turned \(before.authority.traceLabel) into \(after.authority.traceLabel)"
            }
        case .atLocalSize:
            guard after.authority == observed, !replays else { return "our stamp at our size did not follow the stamp" }
        case .atLastOwnedSize:
            guard after.authority == observed, replays else { return "our stamp at our last size did not replay" }
        }
        return nil
    }

    private func randomGeneration(_ random: inout Generator, reducer: Reducer, seen: [UInt64]) -> UInt64 {
        if let live = reducer.claim?.generation, random.chance(70) { return live }
        if !seen.isEmpty, random.chance(70) { return random.pick(seen) }
        return UInt64(random.below(6))
    }

    private func randomStep(_ random: inout Generator, reducer: Reducer, seen: [UInt64], gestures: Bool) -> Step {
        // Often advance the live claim in phase order, as a healthy adapter
        // would, so settlement is exercised and not only aborts.
        if let live = reducer.claim, random.chance(35) {
            switch live.phase {
            case .awaitingFence:
                if live.targetGrid == nil, live.presentationVisible, random.chance(50) {
                    return .advertise(live.generation, random.pick(grids))
                }
                // The fence's settle probe, or the fence's own reply.
                return random.chance(25)
                    ? .observe(live.generation, observedGrid(&random, claim: live), settleProbe: true)
                    : .fence(live.generation)
            case .awaitingRepaint:
                // Another client sometimes takes the window before the stamp,
                // and this device's own churn sometimes re-targets it.
                switch random.below(10) {
                case 0: return .geometryLost(live.generation)
                case 1, 2: return .observe(live.generation, observedGrid(&random, claim: live), settleProbe: random.chance(50))
                case 3: return .advertise(live.generation, random.pick(grids))
                default: return .repaint(live.generation)
                }
            case .awaitingStampCommit: return .commit(live.generation)
            case .awaitingSettlement: return .settle(live.generation)
            }
        }
        let generation = randomGeneration(&random, reducer: reducer, seen: seen)
        switch random.below(gestures ? 20 : 16) {
        case 0: return .attached
        case 1: return .foregrounded
        case 2: return .reset(preservingPeer: random.chance(60))
        case 3: return .observed(random.pick(authorities))
        case 4, 5: return .query(random.pick(authorities), random.pick(geometries))
        case 6: return .ownStamp(generation)
        case 7: return .timeout(generation)
        case 8: return .fence(generation)
        case 9: return .repaint(generation)
        case 10: return .commit(generation)
        case 11: return random.chance(80) ? .settle(generation) : .abort(generation)
        case 12:
            let token = reducer.pendingIntent?.token ?? UInt64(random.below(4))
            return random.chance(50) ? .hidden : .intentExpired(random.chance(70) ? token : token &+ 1)
        case 13: return .advertise(generation, random.pick(grids))
        case 14: return .observe(generation, observedGrid(&random, claim: reducer.claim), settleProbe: random.chance(50))
        case 15: return .stall(generation, canProgress: random.chance(60))
        case 16, 17: return .shown(random.chance(70) ? .show : .explicitOpen)
        default: return .tap(channelLive: random.chance(80))
        }
    }

    private func apply(_ step: Step, to reducer: inout Reducer) -> [Effect] {
        switch step {
        case .attached: return reducer.attached()
        case .foregrounded: return reducer.foregrounded()
        case .reset(let preserving): return reducer.resetTransport(preservingPeer: preserving)
        case .shown(let source): return reducer.shown(source: source)
        case .hidden: return reducer.hidden()
        case .intentExpired(let token): return reducer.intentExpired(token: token)
        case .tap(let live): return reducer.requestTakeBack(channelLive: live)
        case .observed(let authority): return reducer.observedAuthority(authority)
        case .query(let authority, let geometry): return reducer.receivedAuthorityQuery(authority, geometry: geometry)
        case .ownStamp(let generation): return reducer.observedOwnAuthorityStamp(generation: generation)
        case .timeout(let generation): return reducer.presentationTimedOut(generation: generation)
        case .fence(let generation): return reducer.fenceSucceeded(generation: generation)
        case .repaint(let generation): return reducer.repaintSucceeded(generation: generation)
        case .geometryLost(let generation): return reducer.claimGeometryLost(generation: generation)
        case .advertise(let generation, let grid):
            return reducer.claimAdvertisedGeometry(generation: generation, columns: grid.columns, rows: grid.rows)
        case .observe(let generation, let grid, let probe):
            return reducer.claimObservedGeometry(
                generation: generation, columns: grid.columns, rows: grid.rows, settleProbe: probe
            )
        case .stall(let generation, let canProgress):
            return reducer.claimStalled(generation: generation, canProgress: canProgress)
        case .commit(let generation): return reducer.stampCommitSucceeded(generation: generation)
        case .settle(let generation): return reducer.settleClaim(generation: generation)
        case .abort(let generation): return reducer.abortClaim(generation: generation)
        }
    }

    private struct Ledger {
        var showIntentsResolvedByRead = 0
        var showIntentsSurvivingObservations = 0
        var unknownGeometryOwnReads = 0
        var begun: Set<UInt64> = []
        var open: Set<UInt64> = []
        var terminated: Set<UInt64> = []
        var contested: Set<UInt64> = []
        var refenced: Set<UInt64> = []
        var refences = 0
        var geometryLostAborts = 0
        var adapterFailureAborts = 0
        var claimsBegun = 0
        var settled = 0
        var maxToken: UInt64 = 0
        /// I2: the step that last moved each claim into `awaitingRepaint`.
        var confirmedBy: [UInt64: String] = [:]
        var stamps = 0
        var retargets = 0
        var unsettledObservations = 0
        var landedObservations = 0
        var lateDrains = 0
        var lateSettled = 0
        var lateAborted = 0
    }

    /// Whether `step` reports `grid` as a foreign size the claim's landed
    /// geometry lost to (§6.10 rule 4).
    private func isLandedForeignObservation(_ step: Step, of claim: Reducer.Claim) -> Bool {
        guard case let .observe(generation, grid, probe) = step, generation == claim.generation,
              claim.phase == .awaitingFence || claim.phase == .awaitingRepaint
        else { return false }
        return (claim.geometryLanded || probe)
            && grid != claim.targetGrid
            && !claim.advertisedGrids.contains(grid)
    }

    /// Checks one reduction against the invariants; returns a failure text.
    private func check(
        step: Step,
        before: Reducer.Snapshot,
        after: Reducer,
        effects: [Effect],
        ledger: inout Ledger
    ) -> String? {
        var streamClaim = before.claim?.generation
        for effect in effects {
            switch effect {
            case .claimAborted(let reason):
                guard let generation = streamClaim, ledger.open.remove(generation) != nil else {
                    return "abort with no open claim"
                }
                guard ledger.terminated.insert(generation).inserted else { return "g\(generation) terminated twice" }
                if case .contestedByPeer = reason { ledger.contested.insert(generation) }
                // I3: the deadline only hides.
                if case .timeout = step { return "the deadline aborted g\(generation) (\(reason))" }
                if case .geometryLost = reason {
                    // Only a second loss, or a loss once late, gives a claim
                    // up: an adapter loss in `awaitingRepaint`, or a foreign
                    // size after landing.
                    guard let lost = before.claim, lost.generation == generation else {
                        return "geometryLost abort of g\(generation) that is not the live claim"
                    }
                    guard lost.geometryRefenced || !lost.presentationVisible else {
                        return "a first loss of a visible claim aborted \(lost.traceLabel)"
                    }
                    switch step {
                    case .geometryLost(generation):
                        guard lost.phase == .awaitingRepaint else { return "a loss gave up \(lost.traceLabel)" }
                    case .observe(generation, _, _):
                        guard isLandedForeignObservation(step, of: lost) else {
                            return "\(step) is no landed foreign size, yet gave up \(lost.traceLabel)"
                        }
                    default:
                        return "\(step) aborted g\(generation) as geometryLost"
                    }
                    ledger.geometryLostAborts += 1
                }
                if case .adapterFailure = reason {
                    switch step {
                    case .abort(generation):
                        break
                    case .stall(generation, let canProgress):
                        guard let stalled = before.claim,
                              stalled.phase == .awaitingFence || stalled.phase == .awaitingRepaint,
                              !canProgress || !stalled.presentationVisible
                        else { return "\(step) aborted \(before.claim.traceLabel), which could progress" }
                    default:
                        return "\(step) aborted g\(generation) as an adapter failure"
                    }
                    ledger.adapterFailureAborts += 1
                }
                streamClaim = nil
            case .claimSettled(let generation):
                guard streamClaim == generation, ledger.open.remove(generation) != nil else {
                    return "settled g\(generation) that is not the live claim"
                }
                guard ledger.terminated.insert(generation).inserted else { return "g\(generation) terminated twice" }
                ledger.settled += 1
                streamClaim = nil
            case .beginClaim(let claim):
                guard streamClaim == nil else { return "g\(claim.generation) replaced a live claim silently" }
                guard ledger.begun.insert(claim.generation).inserted else { return "generation reused" }
                ledger.open.insert(claim.generation)
                ledger.claimsBegun += 1
                streamClaim = claim.generation
                // R5: every claim has a user gesture behind it.
                switch step {
                case .tap:
                    guard claim.reason == .userTakeBack else { return "tap began \(claim.reason)" }
                case .shown(let source):
                    let expected: Reducer.ClaimReason = source == .show ? .show : .explicitOpen
                    guard claim.reason == expected,
                          let previous = before.claim, !previous.presentationVisible
                    else { return "a show began a claim outside the S4′ escape" }
                case .query:
                    guard let intent = before.pendingIntent else { return "a read claimed without an intent" }
                    guard claim.reason == intent.source.claimReason else { return "intent reason lost" }
                case .ownStamp(let generation):
                    guard claim.reason == .ownWriteWon,
                          ledger.contested.contains(generation)
                    else { return "own stamp claimed without a contested user claim" }
                default:
                    return "\(step) began a claim"
                }
                guard claim.presentationVisible else { return "a gesture claim must present" }
            case .refenceClaim(let generation):
                guard let lost = before.claim, lost.generation == generation,
                      lost.presentationVisible, !lost.geometryRefenced,
                      after.claim?.generation == generation,
                      after.claim?.phase == .awaitingFence,
                      after.claim?.geometryRefenced == true,
                      after.claim?.geometryLanded == false
                else { return "refence outside a first loss of the live, presented claim" }
                switch step {
                case .geometryLost(generation):
                    guard lost.phase == .awaitingRepaint else { return "an adapter loss re-fenced \(lost.traceLabel)" }
                case .observe(generation, _, _):
                    guard isLandedForeignObservation(step, of: lost) else {
                        return "\(step) is no landed foreign size, yet re-fenced \(lost.traceLabel)"
                    }
                default:
                    return "\(step) re-fenced g\(generation)"
                }
                guard ledger.refenced.insert(generation).inserted else { return "g\(generation) re-fenced twice" }
                ledger.refences += 1
            case .commitAuthorityStamp(let generation):
                // I2: our own ack chain, uninterrupted.
                guard case .repaint(generation) = step,
                      before.claim?.generation == generation,
                      before.claim?.phase == .awaitingRepaint,
                      ledger.confirmedBy[generation] == Step.fence(generation).description
                else {
                    return "stamp of g\(generation) at \(step) confirmed by \(ledger.confirmedBy[generation] ?? "nothing")"
                }
                ledger.stamps += 1
            case .queryAuthority, .requestRepaint, .authorityChanged,
                 .hideReclaimPresentation, .replayOwnedGeometry:
                break
            }
        }
        guard streamClaim == after.claim?.generation else { return "effects disagree with the live claim" }
        if case .geometryLost(let generation) = step,
           let lost = before.claim, lost.generation == generation, lost.phase == .awaitingRepaint {
            let firstVisibleLoss = lost.presentationVisible && !lost.geometryRefenced
            if firstVisibleLoss, after.claim?.phase != .awaitingFence {
                return "a first loss left the claim in \(after.claim.traceLabel)"
            }
            if !firstVisibleLoss, after.claim != nil {
                return "a second or late loss kept \(after.claim.traceLabel)"
            }
        }
        if let previous = before.claim, let current = after.claim, previous.generation == current.generation {
            // I1: a late claim advertises nothing.
            if !previous.presentationVisible,
               current.advertisedGrids != previous.advertisedGrids || current.targetGrid != previous.targetGrid {
                return "late \(previous.traceLabel) advertised geometry at \(step)"
            }
            // I3: our own grids never lose, and spend nothing.
            if case let .observe(_, grid, _) = step, previous.advertisedGrids.contains(grid),
               current.geometryRefenced != previous.geometryRefenced {
                return "our own grid \(grid) spent the re-fence of \(previous.traceLabel)"
            }
            if case .timeout = step, current.phase != previous.phase {
                return "the deadline moved \(previous.traceLabel) to \(current.phase)"
            }
            if case .observe = step, previous.phase == .awaitingRepaint, current.phase == .awaitingFence,
               !current.geometryRefenced || previous.geometryRefenced {
                ledger.unsettledObservations += 1
            }
            if case .advertise = step, previous.phase == .awaitingRepaint, current.phase == .awaitingFence {
                ledger.retargets += 1
            }
            if case .observe(_, _, true) = step, !previous.geometryLanded, current.geometryLanded {
                ledger.landedObservations += 1
            }
        }
        if let previous = before.claim, let current = after.claim, previous.generation == current.generation,
           case .observe(_, let grid, _) = step, previous.advertisedGrids.contains(grid) || grid == previous.targetGrid,
           effects.contains(where: { if case .claimAborted = $0 { return true } else { return false } }) {
            return "our own grid aborted \(previous.traceLabel)"
        }
        // I2 bookkeeping: what last confirmed the live claim, judged from
        // the steps themselves rather than the phase the reducer reports. A
        // re-target, an observation off the target, a loss or a stall
        // interrupts the chain; only a fence that confirmed restores it.
        if let previous = before.claim,
           previous.phase == .awaitingFence || previous.phase == .awaitingRepaint {
            var interrupted = false
            switch step {
            case .advertise(previous.generation, _):
                interrupted = previous.presentationVisible
            case .observe(previous.generation, let grid, _):
                interrupted = grid != previous.targetGrid
            case .geometryLost(previous.generation):
                interrupted = previous.phase == .awaitingRepaint
            case .stall(previous.generation, _):
                interrupted = true
            default:
                break
            }
            if interrupted { ledger.confirmedBy[previous.generation] = nil }
        }
        if let current = after.claim, current.phase == .awaitingRepaint,
           before.claim?.generation != current.generation || before.claim?.phase != .awaitingRepaint {
            ledger.confirmedBy[current.generation] = step.description
        }
        // Rule 2's predicate is exactly a visible live claim.
        if after.claimMayAdvertiseGeometry != (after.claim?.presentationVisible == true) {
            return "claimMayAdvertiseGeometry=\(after.claimMayAdvertiseGeometry) for \(after.claim.traceLabel)"
        }
        guard ledger.open == Set(after.claim.map { [$0.generation] } ?? []) else {
            return "a claim left without a terminal outcome: open=\(ledger.open)"
        }
        let began = effects.contains { if case .beginClaim = $0 { return true } else { return false } }
        if let failure = checkIntent(step: step, before: before, after: after, began: began) { return failure }
        if let failure = checkReadWithoutIntent(
            step: step, before: before, after: after, effects: effects, ledger: &ledger
        ) { return failure }
        if after.claim != nil, after.pendingIntent != nil { return "claim and intent coexist" }
        if after.claim != nil, !after.channelAttached { return "claim without a channel" }
        if after.authority != .unknown, !after.snapshot.authorityObserved { return "unobserved authority" }
        if let token = after.pendingIntent?.token, token != before.pendingIntent?.token {
            guard token > ledger.maxToken else { return "intent token not monotonic" }
            ledger.maxToken = token
        }
        if let intent = before.pendingIntent, intent.source != .tap {
            if case .observed = step, after.pendingIntent == intent { ledger.showIntentsSurvivingObservations += 1 }
            if case .query = step, before.channelAttached, after.pendingIntent == nil { ledger.showIntentsResolvedByRead += 1 }
        }
        let trace = Reducer.describeTransition(
            event: step.description, before: before, after: after.snapshot, effects: effects
        )
        let noOp = effects.isEmpty && before == after.snapshot
        if noOp != (trace == nil) { return "trace=\(trace ?? "nil") for noOp=\(noOp)" }
        return nil
    }

    private func run(seeds: Range<UInt64>, steps: Int, gestures: Bool) -> Ledger {
        var total = Ledger()
        for seed in seeds {
            var random = Generator(state: seed)
            var reducer = Reducer()
            var ledger = Ledger()
            var history: [Step] = []
            var seen: [UInt64] = []
            for _ in 0..<steps {
                let step = randomStep(&random, reducer: reducer, seen: seen, gestures: gestures)
                history.append(step)
                let before = reducer.snapshot
                let effects = apply(step, to: &reducer)
                if let generation = reducer.claim?.generation, seen.last != generation { seen.append(generation) }
                if let failure = check(step: step, before: before, after: reducer, effects: effects, ledger: &ledger) {
                    XCTFail("seed \(seed): \(failure) after \(history.suffix(12).map(\.description))")
                    return total
                }
            }
            // I4: the deadline passes over whatever claim is still live; a
            // healthy adapter then answers only the commands it already
            // had in flight (none of them new geometry), sees foreign
            // layouts, and stalls the claim once nothing of its own is left.
            // The claim must end within that bound, with no reset.
            if let live = reducer.claim {
                ledger.lateDrains += 1
                var drain: [Step] = live.presentationVisible ? [.timeout(live.generation)] : []
                var ownRepliesInFlight = random.below(4)
                var foreignLayouts = random.below(3)
                for _ in 0..<16 {
                    if drain.isEmpty {
                        guard let claim = reducer.claim, claim.generation == live.generation else { break }
                        switch claim.phase {
                        case .awaitingStampCommit: drain.append(.commit(claim.generation))
                        case .awaitingSettlement: drain.append(.settle(claim.generation))
                        case .awaitingFence, .awaitingRepaint:
                            if foreignLayouts > 0, random.chance(40) {
                                foreignLayouts -= 1
                                drain.append(.observe(claim.generation, random.pick(grids), settleProbe: random.chance(50)))
                            } else if ownRepliesInFlight > 0 {
                                ownRepliesInFlight -= 1
                                drain.append(claim.phase == .awaitingFence
                                    ? (random.chance(30)
                                        ? .observe(claim.generation, claim.targetGrid ?? random.pick(grids), settleProbe: true)
                                        : .fence(claim.generation))
                                    : .repaint(claim.generation))
                            } else {
                                drain.append(.stall(claim.generation, canProgress: false))
                            }
                        }
                    }
                    let step = drain.removeFirst()
                    history.append(step)
                    let before = reducer.snapshot
                    let effects = apply(step, to: &reducer)
                    if let failure = check(step: step, before: before, after: reducer, effects: effects, ledger: &ledger) {
                        XCTFail("seed \(seed): \(failure) in the late drain after \(history.suffix(12).map(\.description))")
                        return total
                    }
                    if effects.contains(.claimSettled(generation: live.generation)) { ledger.lateSettled += 1 }
                    if effects.contains(where: { if case .claimAborted = $0 { return true } else { return false } }) {
                        ledger.lateAborted += 1
                    }
                }
                if reducer.claim?.generation == live.generation {
                    XCTFail("seed \(seed): I4: late \(reducer.claim.traceLabel) neither settled nor aborted after \(history.suffix(16).map(\.description))")
                    return total
                }
            }

            // Close the run: a reset must terminate whatever is still open.
            let before = reducer.snapshot
            let effects = reducer.resetTransport(preservingPeer: false)
            if let failure = check(
                step: .reset(preservingPeer: false), before: before, after: reducer, effects: effects, ledger: &ledger
            ) {
                XCTFail("seed \(seed): \(failure) at the closing reset")
                return total
            }
            XCTAssertTrue(ledger.open.isEmpty, "seed \(seed)")
            XCTAssertEqual(ledger.terminated, ledger.begun, "seed \(seed): every claim needs one terminal outcome")
            total.claimsBegun += ledger.claimsBegun
            total.refences += ledger.refences
            total.geometryLostAborts += ledger.geometryLostAborts
            total.adapterFailureAborts += ledger.adapterFailureAborts
            total.stamps += ledger.stamps
            total.retargets += ledger.retargets
            total.unsettledObservations += ledger.unsettledObservations
            total.landedObservations += ledger.landedObservations
            total.lateDrains += ledger.lateDrains
            total.lateSettled += ledger.lateSettled
            total.lateAborted += ledger.lateAborted
            total.settled += ledger.settled
            total.showIntentsResolvedByRead += ledger.showIntentsResolvedByRead
            total.showIntentsSurvivingObservations += ledger.showIntentsSurvivingObservations
            total.unknownGeometryOwnReads += ledger.unknownGeometryOwnReads
        }
        return total
    }

    func testRandomInterleavingsKeepEveryClaimAccountedForAndUserCaused() {
        let total = run(seeds: 1..<401, steps: 300, gestures: true)
        // The generator must actually exercise claims, settlements and aborts,
        // or the invariants above hold vacuously.
        XCTAssertGreaterThan(total.claimsBegun, 2_000)
        XCTAssertGreaterThan(total.settled, 50)
        XCTAssertGreaterThan(total.refences, 50)
        XCTAssertGreaterThan(total.geometryLostAborts, 10)
        XCTAssertGreaterThan(total.adapterFailureAborts, 10)
        XCTAssertGreaterThan(total.stamps, 50)
        XCTAssertGreaterThan(total.retargets, 10)
        XCTAssertGreaterThan(total.unsettledObservations, 10)
        XCTAssertGreaterThan(total.landedObservations, 10)
        XCTAssertGreaterThan(total.lateDrains, 50)
        XCTAssertGreaterThan(total.lateSettled, 5)
        XCTAssertGreaterThan(total.lateAborted, 5)
        XCTAssertGreaterThan(total.showIntentsSurvivingObservations, 500)
        XCTAssertGreaterThan(total.showIntentsResolvedByRead, 500)
        XCTAssertGreaterThan(total.unknownGeometryOwnReads, 100)
    }

    func testRandomInterleavingsWithoutGesturesNeverClaim() {
        let total = run(seeds: 1_001..<1_201, steps: 300, gestures: false)
        XCTAssertEqual(total.claimsBegun, 0, "attach, reconnect, reads and observations must never claim")
        XCTAssertGreaterThan(total.unknownGeometryOwnReads, 100)
    }
}
