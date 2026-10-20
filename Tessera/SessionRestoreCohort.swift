import Foundation
import TesseraSessionCore

// Apple adapter over the shared foreground-restore decision.
//
// The rules — the 4ms `activeSessions` lag, mosh's `.connected`-across-loss
// behaviour, the `.ask` retirement carve-out, the backstop's precedence over
// settling, and the persist-mode ladder — and the comments that record why
// each exists now live in `TesseraSessionCore/ForegroundRestoreCohort.swift`.
// This file only maps the app's `SessionState` and `SessionRestoreSnapshot`
// onto the portable candidate/live-state pair and back again.

typealias ForegroundRestoreVerdict = TesseraSessionCore.ForegroundRestoreVerdict

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

    /// Projection onto the portable five-bucket state the core reasons about.
    /// `.failed`'s payload is deliberately dropped: the reason never changes
    /// the verdict, and it is the one part of `SessionState` that can carry a
    /// host address (see `SessionState.diagnosticName`).
    var coreLiveState: ForegroundRestoreLiveState {
        let coreState: RestoreLiveState
        switch state {
        case .idle:         coreState = .idle
        case .connecting:   coreState = .connecting
        case .connected:    coreState = .connected
        case .disconnected: coreState = .disconnected
        case .failed:       coreState = .failed
        }
        return ForegroundRestoreLiveState(
            liveSessionID: liveSessionID,
            persistedHostID: persistedHostID,
            state: coreState,
            transportConfirmed: transportConfirmed
        )
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
    typealias WindowClosure = TesseraSessionCore.ForegroundRestoreCohort.WindowClosure
    typealias PersistMode = TesseraSessionCore.ForegroundRestoreCohort.PersistMode

    static func verdict(
        for snapshot: SessionRestoreSnapshot,
        live: ForegroundRestoreLiveSession?,
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval
    ) -> ForegroundRestoreVerdict {
        TesseraSessionCore.ForegroundRestoreCohort.verdict(
            for: candidate(for: snapshot),
            live: live?.coreLiveState,
            elapsedSinceWindowOpened: elapsedSinceWindowOpened,
            aliveFloorSeconds: aliveFloorSeconds
        )
    }

    /// Classify a whole cohort in one pass.
    ///
    /// The core answers in cohort positions; this maps them straight back onto
    /// the snapshots it was handed, so a repeated `liveSessionID` cannot
    /// silently collapse two entries into one.
    static func evaluate(
        cohort: [SessionRestoreSnapshot],
        live: [ForegroundRestoreLiveSession],
        elapsedSinceWindowOpened: TimeInterval,
        aliveFloorSeconds: TimeInterval,
        retiresDeadImmediately: Bool
    ) -> ForegroundRestoreEvaluation {
        let evaluation = TesseraSessionCore.ForegroundRestoreCohort.evaluate(
            cohort: cohort.map(candidate(for:)),
            live: live.map(\.coreLiveState),
            elapsedSinceWindowOpened: elapsedSinceWindowOpened,
            aliveFloorSeconds: aliveFloorSeconds,
            retiresDeadImmediately: retiresDeadImmediately
        )
        return ForegroundRestoreEvaluation(
            dead: evaluation.deadIndices.map { cohort[$0] },
            retiredIDs: evaluation.retiredIDs
        )
    }

    static func windowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpened: TimeInterval,
        maxWindowSeconds: TimeInterval,
        hasUnansweredPrompt: Bool
    ) -> WindowClosure {
        TesseraSessionCore.ForegroundRestoreCohort.windowClosure(
            remainingCohortCount: remainingCohortCount,
            elapsedSinceWindowOpened: elapsedSinceWindowOpened,
            maxWindowSeconds: maxWindowSeconds,
            hasUnansweredPrompt: hasUnansweredPrompt
        )
    }

    static func chargeDelta(
        now: Date,
        lastChargeAt: Date?,
        isPrompting: Bool,
        maxTick: TimeInterval
    ) -> TimeInterval {
        TesseraSessionCore.ForegroundRestoreCohort.chargeDelta(
            now: now,
            lastChargeAt: lastChargeAt,
            isPrompting: isPrompting,
            maxTick: maxTick
        )
    }

    static func persistMode(
        isActive: Bool,
        hasPreservedSnapshots: Bool,
        isWindowOpen: Bool,
        hasCohortEntries: Bool
    ) -> PersistMode {
        TesseraSessionCore.ForegroundRestoreCohort.persistMode(
            isActive: isActive,
            hasPreservedSnapshots: hasPreservedSnapshots,
            isWindowOpen: isWindowOpen,
            hasCohortEntries: hasCohortEntries
        )
    }

    private static func candidate(
        for snapshot: SessionRestoreSnapshot
    ) -> ForegroundRestoreCandidate {
        ForegroundRestoreCandidate(
            liveSessionID: snapshot.liveSessionID,
            persistedHostID: snapshot.persistedHostID
        )
    }
}
