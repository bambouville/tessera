import Foundation

/// Pure decision logic for the foreground restore window.
///
/// At wake, Tessera has to work out which preserved sessions died while the app
/// was inactive and reconnect exactly those. The hard part is not the
/// reconnect — it is knowing when the answer is complete. Two facts make that
/// non-obvious, and both are load-bearing here:
///
///  1. The live-session list lags a session's published state. In the
///     2026-08-17 repro two SSH transports died 4ms apart and the summary
///     logged one millisecond later still reported both as connected. So
///     "looks connected" is not evidence of life until enough time has passed
///     for a report to have arrived — hence `aliveFloorSeconds`.
///  2. Mosh keeps its session state at `.connected` across network loss by
///     design and only reports death on its own timeout. Its reachability
///     signal lives in the transport state, surfaced here as
///     `transportConfirmed`.
///
/// This type is deliberately free of UI frameworks, persistence, and clocks so
/// the window's behaviour is testable directly. The platform shell owns the
/// state and supplies elapsed time (iOS: `ContentView`; Android: the lifecycle
/// observer).
public enum ForegroundRestoreVerdict: String, Equatable, Sendable, CaseIterable {
    /// Reported dead, or its tab is gone. Reconnect it.
    case dead
    /// Believed alive, and enough time has passed to believe it.
    case alive
    /// No verdict yet.
    case pending
}

/// The five lifecycle buckets a transport projects itself into, restated
/// portably so the restore decision does not depend on either platform's own
/// session-state type. The iOS adapter maps `SessionState`; the Android
/// adapter maps `ForegroundRestoreConnectionState`.
public enum RestoreLiveState: String, Equatable, Sendable, CaseIterable, Codable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed
}

/// One entry of the restore cohort, reduced to the two facts a verdict needs.
///
/// The platform keeps the full snapshot (display name, launch mode, created-at)
/// and maps back to it from `liveSessionID` once the evaluation returns.
public struct ForegroundRestoreCandidate: Equatable, Hashable, Sendable {
    public let liveSessionID: UUID
    public let persistedHostID: UUID?

    public init(liveSessionID: UUID, persistedHostID: UUID?) {
        self.liveSessionID = liveSessionID
        self.persistedHostID = persistedHostID
    }
}

/// The live-session facts a verdict depends on, lifted out of the running
/// session so the decision can be exercised without one.
public struct ForegroundRestoreLiveState: Equatable, Sendable {
    public let liveSessionID: UUID
    public let persistedHostID: UUID?
    public let state: RestoreLiveState
    /// Transport-level reachability where the transport has such a signal.
    /// `nil` means the transport offers none (SSH), so `state` is all there is.
    public let transportConfirmed: Bool?

    public init(
        liveSessionID: UUID,
        persistedHostID: UUID?,
        state: RestoreLiveState,
        transportConfirmed: Bool? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.persistedHostID = persistedHostID
        self.state = state
        self.transportConfirmed = transportConfirmed
    }
}

/// The outcome of one classification pass, expressed in identifiers so the
/// core never has to know what a platform's snapshot type looks like.
public struct ForegroundRestoreEvaluation: Equatable, Sendable {
    /// Entries to reconnect now, in cohort order.
    public var deadIDs: [UUID] = []
    /// The positions in the supplied cohort that `deadIDs` came from, so a
    /// caller holding a parallel array of snapshots can map back without a
    /// dictionary — and without assuming `liveSessionID` is unique.
    public var deadIndices: [Int] = []
    /// Entries that have reached a verdict and must leave the cohort.
    public var retiredIDs: [UUID] = []

    public init(
        deadIDs: [UUID] = [],
        deadIndices: [Int] = [],
        retiredIDs: [UUID] = []
    ) {
        self.deadIDs = deadIDs
        self.deadIndices = deadIndices
        self.retiredIDs = retiredIDs
    }

    public var hasWork: Bool { !deadIDs.isEmpty || !retiredIDs.isEmpty }
}

public enum ForegroundRestoreCohort {
    public static func verdict(
        for candidate: ForegroundRestoreCandidate,
        live: ForegroundRestoreLiveState?,
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval
    ) -> ForegroundRestoreVerdict {
        guard let live, live.persistedHostID == candidate.persistedHostID else {
            // The tab is gone. The session-ended callback removes it for a
            // transport death and for a clean remote `exit` alike, and the two
            // are indistinguishable here — so this reconnects in both cases.
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
    public static func evaluate(
        cohort: [ForegroundRestoreCandidate],
        live: [ForegroundRestoreLiveState],
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval,
        retiresDeadImmediately: Bool
    ) -> ForegroundRestoreEvaluation {
        var liveByID: [UUID: ForegroundRestoreLiveState] = [:]
        for session in live {
            liveByID[session.liveSessionID] = session
        }

        var evaluation = ForegroundRestoreEvaluation()
        for (index, candidate) in cohort.enumerated() {
            switch verdict(
                for: candidate,
                live: liveByID[candidate.liveSessionID],
                elapsedSinceWindowOpened: elapsedSinceWindowOpened,
                aliveFloorSeconds: aliveFloorSeconds
            ) {
            case .dead:
                evaluation.deadIDs.append(candidate.liveSessionID)
                evaluation.deadIndices.append(index)
                if retiresDeadImmediately {
                    evaluation.retiredIDs.append(candidate.liveSessionID)
                }
            case .alive:
                evaluation.retiredIDs.append(candidate.liveSessionID)
            case .pending:
                break
            }
        }
        return evaluation
    }

    public enum WindowClosure: String, Equatable, Sendable, CaseIterable {
        /// Every entry reached a verdict.
        case settled
        /// Time ran out with entries unresolved.
        case backstop
        /// Keep waiting.
        case open
    }

    public static func windowClosure(
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
    public static func chargeDelta(
        now: Date,
        lastChargeAt: Date?,
        isPrompting: Bool,
        maxTick: TimeInterval
    ) -> TimeInterval {
        guard let lastChargeAt, !isPrompting else { return 0 }
        return max(0, min(now.timeIntervalSince(lastChargeAt), maxTick))
    }

    /// Seconds-valued spelling of `chargeDelta` for callers that carry an
    /// epoch rather than a `Date`. Kotlin's millisecond clock converts at the
    /// adapter edge, per the core's unit rule: seconds as `Double`.
    public static func chargeDelta(
        nowSeconds: TimeInterval,
        lastChargeAtSeconds: TimeInterval?,
        isPrompting: Bool,
        maxTickSeconds: TimeInterval
    ) -> TimeInterval {
        guard let lastChargeAtSeconds, !isPrompting else { return 0 }
        return max(0, min(nowSeconds - lastChargeAtSeconds, maxTickSeconds))
    }

    /// What a snapshot write may do to the document already in the store.
    ///
    /// A write that mirrors the live session list deletes everything it cannot
    /// see, and the sessions worth restoring are exactly the ones that are no
    /// longer there — so the choice of mode is what decides whether a wake
    /// still has something to restore from.
    public enum PersistMode: String, Equatable, Sendable, CaseIterable, Codable {
        /// Nothing is at risk: write exactly what is live.
        case liveOnly
        /// The window is open — entries awaiting a verdict keep their
        /// snapshots even once their tab is gone.
        case keepCohort
        /// Merge over the stored document instead of replacing it.
        case mergeWithStored
    }

    public static func persistMode(
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

/// The portable half of the restore document's contract.
///
/// The bytes and the secure store stay on each platform — iOS keeps its
/// `SessionRestoreStore`, Android its DataStore — but the rules that decide
/// whether a document is *worth* keeping are the same on both, and a
/// divergence there is a silently lost session rather than a crash. They are
/// stated here so both sides can be pinned against one definition.
public enum ForegroundRestoreDocumentRules {
    /// A document written by a different schema is discarded rather than
    /// migrated: it describes sessions whose reconnect semantics we no longer
    /// know, and a wrong restore is worse than none.
    public static let currentSchemaVersion = 1

    /// Upper bound on a single document. It exists to keep a runaway writer
    /// from growing an unbounded blob in a secure store, not to limit real
    /// use — 64 concurrent sessions is far past what any window shows.
    public static let maxSnapshots = 64

    public enum Violation: Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
        case noSnapshots
        case tooManySnapshots(Int)
        case duplicateSessionID(UUID)
        case selectedSessionNotPresent(UUID)
    }

    /// Every rule that must hold of a document before it is written or after
    /// it is read back. Returns the violations in a fixed order so a caller
    /// can report the first one deterministically.
    public static func violations(
        schemaVersion: Int,
        sessionIDs: [UUID],
        selectedSessionID: UUID?
    ) -> [Violation] {
        var found: [Violation] = []

        if schemaVersion != currentSchemaVersion {
            found.append(.unsupportedSchemaVersion(schemaVersion))
        }
        if sessionIDs.isEmpty {
            found.append(.noSnapshots)
        }
        if sessionIDs.count > maxSnapshots {
            found.append(.tooManySnapshots(sessionIDs.count))
        }

        var seen: Set<UUID> = []
        for id in sessionIDs where !seen.insert(id).inserted {
            found.append(.duplicateSessionID(id))
            break
        }

        if let selectedSessionID, !sessionIDs.contains(selectedSessionID) {
            found.append(.selectedSessionNotPresent(selectedSessionID))
        }

        return found
    }

    public static func isValid(
        schemaVersion: Int,
        sessionIDs: [UUID],
        selectedSessionID: UUID?
    ) -> Bool {
        violations(
            schemaVersion: schemaVersion,
            sessionIDs: sessionIDs,
            selectedSessionID: selectedSessionID
        ).isEmpty
    }

    /// The selection rule on its own, because a dangling selection is the one
    /// violation both platforms repair rather than reject: the sessions are
    /// still restorable, only the highlight is stale.
    public static func normalizedSelection(
        sessionIDs: [UUID],
        selectedSessionID: UUID?
    ) -> UUID? {
        guard let selectedSessionID,
              sessionIDs.contains(selectedSessionID)
        else { return nil }
        return selectedSessionID
    }
}
