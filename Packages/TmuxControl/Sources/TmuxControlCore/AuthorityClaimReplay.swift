import Foundation

/// Replays a user's claim that an adapter failure killed (§6.9, "A claim that
/// an intent started and that dies to an adapter failure ... is replayed once
/// the surface can paint again").
///
/// Typical failures are a render surface removed during a transparent
/// interval (an activity recreation, a picker excursion) and a viewport
/// change in the middle of the claim's repaint. Neither is the user changing
/// their mind, so the gesture is parked and replayed when a surface can
/// paint again, within the same R3 budget as the gesture itself:
///
/// - Only gestures replay: a show, an explicit open, a veil tap, and the
///   own-write-won continuation of a contested tap. Nothing else claims (R5).
/// - At most `budget` replays, all within `windowMillis` of the first park
///   and of the user's step: a replay keeps the gesture's step, so R3 ends
///   it about 20 s after the user acted however often it was retried.
/// - Never into a hidden session: a hide drops the parked gesture, and the
///   next show decides afresh. A new gesture, a settlement and a contest
///   (a peer's verdict) also end it.
/// - A take-back replays only against the peer its veil named: a different
///   peer since then drops it (R3); no peer at all replays it as a show, as
///   the user asked for control.
public struct TmuxAuthorityClaimReplay: Equatable, Sendable {
    public typealias Reducer = TmuxGridAuthorityLifecycleReducer

    public static let defaultBudget = 8
    public static let defaultWindowMillis: Int64 = TmuxAuthorityIntentClock.defaultWindowMillis

    /// The gesture behind an aborted claim, waiting for a paintable surface.
    public struct Parked: Equatable, Sendable {
        public let generation: UInt64
        public let reason: Reducer.ClaimReason
        public let contestedPeer: Reducer.Peer?
        /// The user's step behind the claim, so a show carried to a
        /// successor session keeps only what is left of its window.
        public let stepAt: Int64

        var isTakeBack: Bool { reason == .userTakeBack || reason == .ownWriteWon }
    }

    /// What the adapter-independent replay decided.
    public enum Decision: Equatable, Sendable {
        /// Nothing parked, or the surface cannot paint yet.
        case wait
        /// The parked gesture was dropped; the reason is for diagnostics.
        case dropped(Parked, reason: String)
        /// Replay as a show (or explicit open): record a fresh intent.
        case show(Parked, source: Reducer.ShowSource)
        /// Replay the take-back against the peer its veil named.
        case takeBack(Parked)
    }

    public let budget: Int
    public let windowMillis: Int64
    public private(set) var parked: Parked?
    /// Replays spent since the first park.
    public private(set) var count = 0
    /// The first park plus `windowMillis`; nil when nothing was parked.
    public private(set) var windowDeadline: Int64?

    /// Expiry is independent of whether the surface can paint again.
    public var nextDeadline: Int64? {
        guard let parked else { return nil }
        let stepDeadline = parked.stepAt.clampedAdding(windowMillis)
        return windowDeadline.map { min($0, stepDeadline) } ?? stepDeadline
    }

    public init(budget: Int = Self.defaultBudget, windowMillis: Int64 = Self.defaultWindowMillis) {
        self.budget = max(0, budget)
        self.windowMillis = max(0, windowMillis)
    }

    /// Parks the gesture behind `claim`, which an adapter failure ended.
    /// Returns nil when it parked, otherwise why not.
    public mutating func park(
        _ claim: Reducer.Claim,
        stepAt: Int64,
        hidden: Bool,
        now: Int64
    ) -> String? {
        let deadline = windowDeadline ?? now.clampedAdding(windowMillis)
        windowDeadline = deadline
        let refusal: String?
        if hidden {
            // R3: a claim that outlived a real hide finishes or fails on its
            // own (S4′); its gesture is not replayed into a hidden session.
            refusal = "hidden"
        } else if now >= deadline || outlivedStep(stepAt, now: now) {
            refusal = "window expired"
        } else if count >= budget {
            refusal = "budget spent"
        } else {
            refusal = nil
        }
        guard refusal == nil else {
            parked = nil
            return refusal
        }
        parked = Parked(
            generation: claim.generation,
            reason: claim.reason,
            contestedPeer: claim.contestedPeer,
            stepAt: stepAt
        )
        return nil
    }

    /// Takes the parked gesture once a surface can paint its claim.
    ///
    /// - Parameters:
    ///   - paintable: a render surface could carry the claim's repaint now
    ///     (mounted, on an attached terminal, the app in the foreground).
    ///   - busy: a claim or an intent exists already; the parked gesture is
    ///     superseded by it.
    public mutating func take(
        paintable: Bool,
        hidden: Bool,
        busy: Bool,
        authority: TmuxGridAuthoritySnapshot,
        now: Int64
    ) -> Decision {
        guard let parked else { return .wait }
        if hidden {
            // Unreachable while a hide resets the state; kept so no path can
            // replay into a hidden session.
            self.parked = nil
            return .dropped(parked, reason: "hidden")
        }
        if let windowDeadline, now >= windowDeadline {
            self.parked = nil
            return .dropped(parked, reason: "window expired")
        }
        if outlivedStep(parked.stepAt, now: now) {
            self.parked = nil
            return .dropped(parked, reason: "window expired")
        }
        guard paintable else { return .wait }
        self.parked = nil
        if busy { return .dropped(parked, reason: "superseded") }
        let peer = authority.lifecyclePeer
        if parked.isTakeBack, let peer, let contested = parked.contestedPeer, peer != contested {
            return .dropped(parked, reason: "another peer")
        }
        count += 1
        if parked.isTakeBack, peer != nil { return .takeBack(parked) }
        return .show(parked, source: parked.reason == .explicitOpen ? .explicitOpen : .show)
    }

    /// R3: the user's step is more than a window old.
    private func outlivedStep(_ stepAt: Int64, now: Int64) -> Bool {
        now.clampedSubtracting(stepAt) >= windowMillis
    }

    /// A new gesture, a real hide, a settlement or a peer's verdict ends the
    /// replay state, budget included.
    public mutating func reset() {
        guard parked != nil || count != 0 || windowDeadline != nil else { return }
        parked = nil
        count = 0
        windowDeadline = nil
    }
}

extension TmuxGridAuthoritySnapshot {
    /// The reducer's peer for a `.peer` snapshot.
    var lifecyclePeer: TmuxGridAuthorityLifecycleReducer.Peer? {
        guard case let .peer(deviceID, displayName, generation) = self else { return nil }
        return .init(deviceID: deviceID, displayName: displayName, generation: generation)
    }
}
