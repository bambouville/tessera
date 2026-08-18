import Foundation

/// Pure decision logic for the foreground restore window.
///
/// At wake, Tessera has to work out which preserved sessions died while the app
/// was inactive and reconnect exactly those. The hard part is not the
/// reconnect — it is knowing when the answer is complete. Two facts make that
/// non-obvious, and both are load-bearing here:
///
///  1. `activeSessions` lags a session's published state. In the 2026-08-17
///     repro two SSH transports died 4ms apart and the summary logged one
///     millisecond later still reported both as connected. So "looks connected"
///     is not evidence of life until enough time has passed for a report to
///     have arrived — hence `aliveFloorSeconds`.
///  2. Mosh keeps `SessionState` at `.connected` across network loss by design
///     and only reports death on its own timeout. Its reachability signal lives
///     in `transportState`, surfaced here as `transportConfirmed`.
///
/// This type is deliberately free of SwiftUI, SwiftData, and clocks so the
/// window's behaviour is testable directly. `ContentView` owns the state and
/// supplies elapsed time.
enum ForegroundRestoreVerdict: Equatable {
    /// Reported dead, or its tab is gone. Reconnect it.
    case dead
    /// Believed alive, and enough time has passed to believe it.
    case alive
    /// No verdict yet.
    case pending
}

/// The live-session facts a verdict depends on, lifted out of `LiveSession` so
/// the decision can be exercised without a running session.
struct ForegroundRestoreLiveSession: Equatable {
    let liveSessionID: UUID
    let persistedHostID: UUID?
    let state: SessionState
    /// Transport-level reachability where the transport has such a signal.
    /// `nil` means the transport offers none (SSH), so `state` is all there is.
    let transportConfirmed: Bool?

    init(
        liveSessionID: UUID,
        persistedHostID: UUID?,
        state: SessionState,
        transportConfirmed: Bool? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.persistedHostID = persistedHostID
        self.state = state
        self.transportConfirmed = transportConfirmed
    }
}

struct ForegroundRestoreEvaluation: Equatable {
    /// Entries to reconnect now, in cohort order.
    var dead: [SessionRestoreSnapshot] = []
    /// Entries that have reached a verdict and must leave the cohort.
    var retiredIDs: [UUID] = []

    var hasWork: Bool { !dead.isEmpty || !retiredIDs.isEmpty }
}

enum ForegroundRestoreCohort {
    static func verdict(
        for snapshot: SessionRestoreSnapshot,
        live: ForegroundRestoreLiveSession?,
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval
    ) -> ForegroundRestoreVerdict {
        guard let live, live.persistedHostID == snapshot.persistedHostID else {
            // The tab is gone. `onSessionEnded` removes it for a transport death
            // and for a clean remote `exit` alike, and the two are
            // indistinguishable here — so this reconnects in both cases.
            // Explicit user gestures retire their entry before reaching this.
            return .dead
        }

        switch live.state {
        case .disconnected, .failed:
            return .dead
        case .idle, .connecting:
            return .pending
        case .connected:
            break
        }

        // `.connected` alone proves nothing on a transport that reports
        // reachability separately.
        if live.transportConfirmed == false { return .pending }

        guard elapsedSinceWindowOpened >= aliveFloorSeconds else { return .pending }
        return .alive
    }

    /// Classify a whole cohort in one pass.
    ///
    /// `retiresDeadImmediately` is false under the `.ask` policy: there, a dead
    /// entry is *offered*, not reconnected, so it keeps its place — and its
    /// snapshot protection — until the user answers. Retiring at the moment the
    /// sheet is raised would leave the entry unmatched forever, because the
    /// replacement carries a new `liveSessionID`.
    static func evaluate(
        cohort: [SessionRestoreSnapshot],
        live: [ForegroundRestoreLiveSession],
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval,
        retiresDeadImmediately: Bool
    ) -> ForegroundRestoreEvaluation {
        var liveByID: [UUID: ForegroundRestoreLiveSession] = [:]
        for session in live {
            liveByID[session.liveSessionID] = session
        }

        var evaluation = ForegroundRestoreEvaluation()
        for snapshot in cohort {
            switch verdict(
                for: snapshot,
                live: liveByID[snapshot.liveSessionID],
                elapsedSinceWindowOpened: elapsedSinceWindowOpened,
                aliveFloorSeconds: aliveFloorSeconds
            ) {
            case .dead:
                evaluation.dead.append(snapshot)
                if retiresDeadImmediately {
                    evaluation.retiredIDs.append(snapshot.liveSessionID)
                }
            case .alive:
                evaluation.retiredIDs.append(snapshot.liveSessionID)
            case .pending:
                break
            }
        }
        return evaluation
    }

    enum WindowClosure: Equatable {
        /// Every entry reached a verdict.
        case settled
        /// Time ran out with entries unresolved.
        case backstop
        /// Keep waiting.
        case open
    }

    static func windowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpened: TimeInterval,
        maxWindowSeconds: TimeInterval,
        hasUnansweredPrompt: Bool
    ) -> WindowClosure {
        // The backstop outranks settling: once it fires the window is over
        // regardless, and reporting it as `settled` would claim verdicts that
        // were never reached.
        if elapsedSinceWindowOpened >= maxWindowSeconds {
            // An on-screen restore prompt is a verdict in progress, not an
            // entry that failed to reach one. It cannot be dismissed without
            // an answer, and either answer retires the entries it offers — so
            // ending the window under it would strip the snapshots the sheet
            // is offering while the user reads them.
            return hasUnansweredPrompt ? .open : .backstop
        }
        return remainingCohortCount == 0 ? .settled : .open
    }

    /// How far the window's clock advances on one pass.
    ///
    /// The backstop is derived from the SSH handshake budget so a wedged
    /// `.connecting` entry reaches its watchdog verdict before losing its
    /// cohort place. That budget charges only clamped, non-prompt time, so a
    /// wall-clock window runs faster than the thing it is meant to outlive:
    /// a host-key sheet the user leaves up pauses every connecting session's
    /// budget while the window keeps spending, and the entry is dropped
    /// unresolved. Charging identically keeps the two in the same units.
    ///
    /// `maxTick` bounds a single step for the same reason the watchdog does:
    /// a larger gap means the process was suspended, not that time was spent
    /// waiting on the wake.
    static func chargeDelta(
        now: Date,
        lastChargeAt: Date?,
        isPrompting: Bool,
        maxTick: TimeInterval
    ) -> TimeInterval {
        guard let lastChargeAt, !isPrompting else { return 0 }
        return max(0, min(now.timeIntervalSince(lastChargeAt), maxTick))
    }

    /// What a snapshot write may do to the document already in the store.
    ///
    /// A write that mirrors `activeSessions` deletes everything it cannot
    /// see, and the sessions worth restoring are exactly the ones that are no
    /// longer there — so the choice of mode is what decides whether a wake
    /// still has something to restore from.
    enum PersistMode: Equatable {
        /// Nothing is at risk: write exactly what is live.
        case liveOnly
        /// The window is open — entries awaiting a verdict keep their
        /// snapshots even once their tab is gone.
        case keepCohort
        /// Merge over the stored document instead of replacing it.
        case mergeWithStored
    }

    static func persistMode(
        isActive: Bool,
        hasPreservedSnapshots: Bool,
        isWindowOpen: Bool,
        hasCohortEntries: Bool
    ) -> PersistMode {
        // The background edge is the write that has to carry the dead
        // forward: a session that failed on the way out is precisely what the
        // next wake wants back.
        guard isActive else { return .mergeWithStored }
        // Same treatment while snapshots are latched and no window has opened
        // yet, which is what an app lock at wake looks like: the scene stays
        // active and persists keep landing, while cohort seeding waits behind
        // the unlock. There is nothing for `keepCohort` to hold, and a
        // live-only write would clear the very document the post-unlock
        // window seeds from.
        if hasPreservedSnapshots, !isWindowOpen { return .mergeWithStored }
        return hasCohortEntries ? .keepCohort : .liveOnly
    }
}
