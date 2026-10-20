import Foundation

/// Detects a grid takeover by a client that does not stamp `@tessera_authority`
/// — a laptop's bare `tmux attach`, or any pre-authority Tessera build.
///
/// A window resize this device did not initiate, away from its own grid, means
/// some other client took the size. The decision lives in the portable core so
/// every platform veils on the same evidence: a device that cannot see a
/// stamp-less peer keeps re-publishing its own grid against it, which is a
/// silent tug-of-war with no overlay and no explanation for the user.
public enum TmuxStamplessPeer {
    /// A local size replay makes the server echo our own new geometry back.
    /// Ignore layouts for this long afterwards so rotation and keyboard churn
    /// cannot mistake their own echo for a peer.
    public static let replaySuppressionSeconds: Double = 2.0

    /// - Parameters:
    ///   - participatesInAuthority: false for observer/harness clients, which
    ///     never contend for the grid and so can never be taken over.
    ///   - windowSizePolicyIsLatest: only `window-size latest` ties the window
    ///     to a client at all; under `manual` or a fixed size a mismatch is
    ///     expected and proves nothing.
    ///   - layoutIsForRenderedWindow: `window-size` is per-window, so a
    ///     background window legitimately keeps another client's geometry. Only
    ///     the window this device actually renders is evidence.
    ///   - secondsSinceLocalSizeReplay: nil when this device has never replayed
    ///     a size on this connection.
    public static func shouldRaisePeer(
        participatesInAuthority: Bool,
        windowSizePolicyKnown: Bool,
        windowSizePolicyIsLatest: Bool,
        rederiveInFlight: Bool,
        alreadyPeer: Bool,
        reclaimInFlight: Bool,
        layoutIsForRenderedWindow: Bool,
        layoutColumns: Int,
        layoutRows: Int,
        localColumns: Int,
        localRows: Int,
        secondsSinceLocalSizeReplay: Double?
    ) -> Bool {
        guard participatesInAuthority,
              windowSizePolicyKnown,
              windowSizePolicyIsLatest,
              !rederiveInFlight,
              !alreadyPeer,
              !reclaimInFlight,
              layoutIsForRenderedWindow,
              layoutColumns > 0, layoutRows > 0,
              localColumns > 0, localRows > 0,
              layoutColumns != localColumns || layoutRows != localRows
        else { return false }
        if let secondsSinceLocalSizeReplay,
           secondsSinceLocalSizeReplay < replaySuppressionSeconds {
            return false
        }
        return true
    }

    /// Display name a stamp-less peer is shown under. It has no stamp, so
    /// there is nothing better to call it, and both platforms must agree.
    public static let displayName = "another device"

    /// `replaySuppressionSeconds` on the millisecond clock the stateful judge
    /// runs on.
    public static let replaySuppressionMillis = Int64(replaySuppressionSeconds * 1_000)
}

/// The stateful half of the stamp-less rule: which layouts to judge, and
/// when to judge one again.
///
/// - **Edges, not snapshots.** One verdict per change of the rendered
///   window's (id, size). Re-judging an unchanged layout on every event would
///   let any output arriving mid-resize convict a window this device is
///   itself moving.
/// - **Blocked edges stay unconsumed.** While the session is hidden or in
///   the background, a read is in flight, held, waiting for the channel or
///   for its retry, a claim runs, or an ordinary window recovery is proving
///   ownership, the edge is left for later rather than judged on evidence
///   that is about to change: a fresh read must precede geometry evidence, a
///   claim's own fence is not a peer's resize, and a hidden or inactive
///   session's next show or foreground decides afresh. A read that settled
///   without releasing the hold (a stamp this build cannot parse, retries
///   spent) blocks nothing: nothing else would ever judge the window.
/// - **A size we owned is ours.** A window at the grid this device last
///   pushed, or at an older grid it owned (`TmuxOwnedSizeHistory`: a
///   reattach or a foreground after a background rotation, a mosh side
///   channel frozen at a transient), is never another device's: our replay
///   of the current grid can take seconds to land (a cellular round trip, a
///   side channel after a wake), and no clock or read can tell that from a
///   client that stays there. At an older owned grid our geometry is
///   replayed (L4: the read path calls it `atLastOwnedSize`), and the judge
///   asks for that replay outside the echo window of a size of ours already
///   on its way. Either replays an owned edge once, until this device pushes
///   that grid again, so a client that keeps restoring it cannot loop us,
///   however many layouts or reads arrive. An owned edge the owner may not
///   replay yet (no measured viewport, a hold not released, a channel that
///   cannot carry it) stays unconsumed and is judged once it may. The
///   trade-off: a client without a stamp parked exactly on a grid this
///   device once owned is not veiled. Reads and stamps still decide
///   authority, and any other grid is judged by the rule.
/// - **A verdict put off is judged again.** `shouldRaisePeer` ignores layouts
///   inside the echo window of our own size replay, which a claim or an
///   ordinary replay makes moments before a peer can act (a show settling,
///   then a laptop's keystroke). The edge is consumed, so the judge records a
///   re-judge just after the echo window ends; without it a peer that resized
///   inside the window would never be seen.
public struct TmuxStamplessPeerJudge: Equatable, Sendable {
    /// Slack after the echo window so the re-judge lands outside it.
    public static let rejudgeSlackMillis: Int64 = 50

    public struct Edge: Equatable, Sendable {
        public let windowID: Int
        public let size: TmuxGridSize

        public init(windowID: Int, size: TmuxGridSize) {
            self.windowID = windowID
            self.size = size
        }
    }

    /// Everything one verdict needs, gathered by the caller.
    public struct Evidence: Equatable, Sendable {
        /// Hidden or inactive, a read pending in any form, a claim, or an
        /// ordinary recovery: leave the edge unconsumed.
        public var blocked: Bool
        /// The window tmux names active, with its grid.
        public var window: Edge?
        /// The probed policy, if it was probed for `window`.
        public var policyIsLatest: Bool?
        /// The grid this device last advertised (what tmux would have
        /// applied had no one else taken the window), else the local size.
        public var local: TmuxGridSize?
        public var alreadyPeer: Bool
        /// When this device last pushed a client size, if it ever did.
        public var lastLocalReplayAt: Int64?
        /// The grids this device recently owned on this session's windows.
        public var owned: TmuxOwnedSizeHistory
        /// This device owns the grid and may send an ordinary owner resize
        /// now, on a channel that can carry it, so an older owned grid can
        /// be repaired by a replay.
        public var ownerMayReplay: Bool

        public init(
            blocked: Bool,
            window: Edge?,
            policyIsLatest: Bool?,
            local: TmuxGridSize?,
            alreadyPeer: Bool,
            lastLocalReplayAt: Int64?,
            owned: TmuxOwnedSizeHistory = .init(),
            ownerMayReplay: Bool = false
        ) {
            self.blocked = blocked
            self.window = window
            self.policyIsLatest = policyIsLatest
            self.local = local
            self.alreadyPeer = alreadyPeer
            self.lastLocalReplayAt = lastLocalReplayAt
            self.owned = owned
            self.ownerMayReplay = ownerMayReplay
        }
    }

    /// Never `.none`: that would read as `Optional.none` wherever a
    /// verdict is optional.
    public enum Verdict: Equatable, Sendable {
        /// Nothing to do for this edge (now).
        case nothing
        /// A stamp-less peer took the window: the caller veils for
        /// `TmuxGridAuthorityLifecycleReducer.stamplessPeer`.
        case stamplessPeer
        /// The window holds an older grid of ours: replay the local one
        /// (`releaseGeometry(.ownerReplay)`) and record it as advertised
        /// now. Asked once per owned edge.
        case replayOwnedGeometry
    }

    /// The last edge judged; nil before any, or when forgotten so the next
    /// judgement re-reads the current edge.
    public private(set) var lastJudged: Edge?
    /// A verdict the echo window put off, and when to judge it again.
    public struct Deferred: Equatable, Sendable {
        public let edge: Edge
        public let at: Int64
    }

    public private(set) var deferred: Deferred?
    /// Owned edges our geometry was already replayed over, by the judge or
    /// the read path, newest last, at most `TmuxOwnedSizeHistory.limit`:
    /// each is replayed once per connection, until this device pushes its
    /// grid again.
    public private(set) var replayedOwnedEdges: [Edge] = []

    public init() {}

    public var nextDeadline: Int64? { deferred?.at }

    /// Forgets the judged edge, so the current one is judged afresh (after a
    /// fresh authority read, or once the window-size policy is known).
    public mutating func forgetJudgedEdge() {
        lastJudged = nil
    }

    /// A transport reset: no edge of the old connection is evidence.
    public mutating func reset() {
        lastJudged = nil
        deferred = nil
        forgetOwnedReplays()
    }

    /// The read path replayed our geometry over `edge` (`atLastOwnedSize`):
    /// that arrival is answered, and neither path replays it again.
    public mutating func noteOwnedReplay(_ edge: Edge) {
        guard !replayedOwnedEdges.contains(edge) else { return }
        replayedOwnedEdges.append(edge)
        if replayedOwnedEdges.count > TmuxOwnedSizeHistory.limit {
            replayedOwnedEdges.removeFirst(replayedOwnedEdges.count - TmuxOwnedSizeHistory.limit)
        }
    }

    /// The owned grids of another tmux session, or connection, are no
    /// evidence here.
    public mutating func forgetOwnedReplays() {
        guard !replayedOwnedEdges.isEmpty else { return }
        replayedOwnedEdges.removeAll()
    }

    /// This device pushed `size` again: it is current again, and its next
    /// arrival after the window leaves it is a new one.
    public mutating func forgetOwnedReplays(of size: TmuxGridSize) {
        guard replayedOwnedEdges.contains(where: { $0.size == size }) else { return }
        replayedOwnedEdges.removeAll { $0.size == size }
    }

    /// Judges the current edge (see the type's rules).
    public mutating func judge(_ evidence: Evidence, now: Int64) -> Verdict {
        guard !evidence.blocked,
              let window = evidence.window,
              let local = evidence.local
        else { return .nothing }
        guard lastJudged != window else { return .nothing }
        lastJudged = window
        if evidence.owned.contains(window.size) {
            return judgeOwned(evidence, window: window, local: local, now: now)
        }
        let sinceReplay = evidence.lastLocalReplayAt.map { Double(now.clampedSubtracting($0)) / 1_000 }
        if rule(evidence, window: window, local: local, secondsSinceLocalSizeReplay: sinceReplay) {
            deferred = nil
            return .stamplessPeer
        }
        if let replayAt = evidence.lastLocalReplayAt,
           rule(evidence, window: window, local: local, secondsSinceLocalSizeReplay: nil) {
            let echoEnds = replayAt.clampedAdding(TmuxStamplessPeer.replaySuppressionMillis)
            deferred = Deferred(edge: window, at: max(echoEnds, now).clampedAdding(Self.rejudgeSlackMillis))
        }
        return .nothing
    }

    /// §6.10 rule 7 and the post-stamp settlement race. The claim's own
    /// replay cannot suppress this verdict, and a previously judged edge
    /// must be read afresh. Its target and every advertised grid are its
    /// own geometry, including entries evicted from the diagnostic list.
    /// Claim-end judgements never request an owned replay; settlement's
    /// caller releases held-back local churn after this verdict instead.
    public mutating func judgeAfterClaimEnd(
        _ evidence: Evidence,
        abortedClaim: TmuxGridAuthorityLifecycleReducer.Claim?,
        now: Int64
    ) -> Verdict {
        forgetJudgedEdge()
        deferred = nil
        guard !evidence.blocked, let window = evidence.window, let local = evidence.local else { return .nothing }
        let grid = TmuxGridAuthorityLifecycleReducer.Grid(columns: window.size.columns, rows: window.size.rows)
        if window.size == local || grid == abortedClaim?.targetGrid
            || abortedClaim?.hasAdvertisedGrid(grid) == true || evidence.owned.contains(window.size) {
            lastJudged = window
            return .nothing
        }
        var unsuppressed = evidence
        unsuppressed.lastLocalReplayAt = nil
        unsuppressed.ownerMayReplay = false
        return judge(unsuppressed, now: now)
    }

    /// A window at a grid we owned: never a verdict, at most our replay.
    private mutating func judgeOwned(_ evidence: Evidence, window: Edge, local: TmuxGridSize, now: Int64) -> Verdict {
        if deferred?.edge == window { deferred = nil }
        guard window.size != local,
              evidence.policyIsLatest == true,
              !evidence.alreadyPeer,
              !replayedOwnedEdges.contains(window)
        else {
            // The grid we last pushed, nothing a replay could repair (a
            // policy that keeps the window off our grid, a peer's grid), or
            // an edge already replayed over: ours, as it is. A policy that
            // arrives later re-judges it.
            return .nothing
        }
        guard evidence.ownerMayReplay else {
            // Not yet (no viewport, a hold, a dead channel): leave the edge
            // for the event that lets the owner replay, or it is never
            // repaired.
            lastJudged = nil
            return .nothing
        }
        if let replayAt = evidence.lastLocalReplayAt {
            let echoEnds = replayAt.clampedAdding(TmuxStamplessPeer.replaySuppressionMillis)
            if now < echoEnds {
                // A size of ours may still be landing; look again after it.
                deferred = Deferred(edge: window, at: echoEnds.clampedAdding(Self.rejudgeSlackMillis))
                return .nothing
            }
        }
        noteOwnedReplay(window)
        return .replayOwnedGeometry
    }

    /// The deferred re-judge is due: forget that edge (only that one: a
    /// newer layout was judged on its own) so `judge` reads it again.
    /// Returns whether a re-judge should run now.
    public mutating func takeDueRejudge(now: Int64) -> Bool {
        guard let deferred, now >= deferred.at else { return false }
        self.deferred = nil
        guard lastJudged == deferred.edge else { return false }
        lastJudged = nil
        return true
    }

    private func rule(
        _ evidence: Evidence,
        window: Edge,
        local: TmuxGridSize,
        secondsSinceLocalSizeReplay: Double?
    ) -> Bool {
        TmuxStamplessPeer.shouldRaisePeer(
            participatesInAuthority: true,
            windowSizePolicyKnown: evidence.policyIsLatest != nil,
            windowSizePolicyIsLatest: evidence.policyIsLatest ?? false,
            rederiveInFlight: false,
            alreadyPeer: evidence.alreadyPeer,
            reclaimInFlight: false,
            layoutIsForRenderedWindow: true,
            layoutColumns: window.size.columns,
            layoutRows: window.size.rows,
            localColumns: local.columns,
            localRows: local.rows,
            secondsSinceLocalSizeReplay: secondsSinceLocalSizeReplay
        )
    }
}
