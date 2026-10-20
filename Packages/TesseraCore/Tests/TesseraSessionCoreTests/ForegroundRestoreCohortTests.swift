import XCTest
@testable import TesseraSessionCore

/// Covers the decision that governs which sessions reconnect at wake.
///
/// The cases below are not hypotheticals: the first two encode the 2026-08-17
/// field failures this logic was written to fix, and the mosh cases are ported
/// from Android's `ForegroundRestoreContinuityTest` so both platforms are
/// pinned against one definition.
final class ForegroundRestoreCohortTests: XCTestCase {
    private let floor: TimeInterval = 5
    private let maxWindow: TimeInterval = 60

    // MARK: - The field repro (the 4 ms race)

    /// Two SSH transports died 4ms apart. The live-session list still reported
    /// the second as connected when the first was already dead, and the
    /// shipped code restored only the one it could see, closed the window, and
    /// deleted the other's snapshot. Inside the floor the stale one must read
    /// `pending` — never `alive` — so it stays in the cohort to be caught a
    /// moment later.
    func test_fourMillisecondRace_staleConnectedPeerIsPendingInsideTheFloor_notAlive() {
        let dead = candidate()
        let stale = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [dead, stale],
            live: [
                liveState(dead, state: .disconnected),
                liveState(stale, state: .connected),
            ],
            elapsedSinceWindowOpened: 0.1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertEqual(evaluation.deadIDs, [dead.liveSessionID])
        XCTAssertEqual(evaluation.deadIndices, [0])
        XCTAssertEqual(evaluation.retiredIDs, [dead.liveSessionID])
    }

    /// A moment later the lag resolves and the peer reports too. It is still in
    /// the cohort, so it is restored rather than stranded.
    func test_fourMillisecondRace_lateReportingPeerIsStillRestored() {
        let stale = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [stale],
            live: [liveState(stale, state: .disconnected)],
            elapsedSinceWindowOpened: 0.2,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertEqual(evaluation.deadIDs, [stale.liveSessionID])
    }

    // MARK: - Verdicts

    func test_missingLiveSessionIsDead() {
        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: candidate(),
                live: nil,
                elapsedSinceWindowOpened: 0,
                aliveFloorSeconds: floor
            ),
            .dead
        )
    }

    /// A recycled `liveSessionID` pointing at a different host is not this
    /// session, so the entry must not be treated as alive.
    func test_hostMismatchIsDead() {
        let entry = candidate()
        let impostor = ForegroundRestoreLiveState(
            liveSessionID: entry.liveSessionID,
            persistedHostID: UUID(),
            state: .connected
        )

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: impostor,
                elapsedSinceWindowOpened: 3600,
                aliveFloorSeconds: floor
            ),
            .dead
        )
    }

    func test_failedIsDead() {
        let entry = candidate()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: liveState(entry, state: .failed),
                elapsedSinceWindowOpened: 0,
                aliveFloorSeconds: floor
            ),
            .dead
        )
    }

    /// A wedged handshake has reached no verdict — it must not be believed
    /// alive however long it sits there. The backstop is what bounds it.
    func test_connectingStaysPendingIndefinitely() {
        let entry = candidate()

        for elapsed in [0.0, floor, 3600.0] {
            XCTAssertEqual(
                ForegroundRestoreCohort.verdict(
                    for: entry,
                    live: liveState(entry, state: .connecting),
                    elapsedSinceWindowOpened: elapsed,
                    aliveFloorSeconds: floor
                ),
                .pending,
                "elapsed \(elapsed) should not resolve a wedged handshake"
            )
        }
    }

    func test_idleStaysPending() {
        let entry = candidate()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: liveState(entry, state: .idle),
                elapsedSinceWindowOpened: 3600,
                aliveFloorSeconds: floor
            ),
            .pending
        )
    }

    func test_connectedBecomesAliveOnlyAtTheFloor() {
        let entry = candidate()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: liveState(entry, state: .connected),
                elapsedSinceWindowOpened: floor - 0.001,
                aliveFloorSeconds: floor
            ),
            .pending
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: liveState(entry, state: .connected),
                elapsedSinceWindowOpened: floor,
                aliveFloorSeconds: floor
            ),
            .alive
        )
    }

    // MARK: - Mosh: connected but unreachable

    /// Mosh keeps its session state connected across network loss, so a zombie
    /// looks identical to a healthy session by state alone. Reachability is the
    /// only signal, and an unconfirmed transport must never read alive.
    ///
    /// Ported from Android `moshNeedsReachabilityBeforeConnectedCanRetire`.
    func test_moshConnectedButUnreachableStaysPendingDespiteConnectedState() {
        let entry = candidate()
        let zombie = ForegroundRestoreLiveState(
            liveSessionID: entry.liveSessionID,
            persistedHostID: entry.persistedHostID,
            state: .connected,
            transportConfirmed: false
        )

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: zombie,
                elapsedSinceWindowOpened: 3600,
                aliveFloorSeconds: floor
            ),
            .pending
        )
    }

    func test_moshWithConfirmedTransportIsAliveAtTheFloor() {
        let entry = candidate()
        let healthy = ForegroundRestoreLiveState(
            liveSessionID: entry.liveSessionID,
            persistedHostID: entry.persistedHostID,
            state: .connected,
            transportConfirmed: true
        )

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: healthy,
                elapsedSinceWindowOpened: floor,
                aliveFloorSeconds: floor
            ),
            .alive
        )
    }

    /// A mosh zombie that finally declares death is still in the cohort, so it
    /// reconnects. This is the case the pre-cohort code lost outright.
    func test_moshZombieThatReportsDeathIsRestored() {
        let entry = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [entry],
            live: [
                ForegroundRestoreLiveState(
                    liveSessionID: entry.liveSessionID,
                    persistedHostID: entry.persistedHostID,
                    state: .disconnected,
                    transportConfirmed: false
                )
            ],
            elapsedSinceWindowOpened: 8,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertEqual(evaluation.deadIDs, [entry.liveSessionID])
    }

    // MARK: - .ask keeps dead entries until answered

    /// Retiring at the moment the sheet is raised would strip the entry's
    /// snapshot protection before the user has answered, and the replacement's
    /// new id means the entry could never match again.
    func test_askOffersDeadEntriesWithoutRetiringThem() {
        let entry = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [entry],
            live: [],
            elapsedSinceWindowOpened: 1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: false
        )

        XCTAssertEqual(evaluation.deadIDs, [entry.liveSessionID])
        XCTAssertTrue(evaluation.retiredIDs.isEmpty)
        XCTAssertTrue(evaluation.hasWork)
    }

    /// Confirmed-alive entries retire under `.ask` too — only the dead ones
    /// wait on the user. Ported from Android
    /// `askOffersDeadWithoutRetiringItsCrashSafeSnapshot`.
    func test_askStillRetiresConfirmedAliveEntries() {
        let alive = candidate()
        let dead = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [alive, dead],
            live: [liveState(alive, state: .connected)],
            elapsedSinceWindowOpened: floor,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: false
        )

        XCTAssertEqual(evaluation.deadIDs, [dead.liveSessionID])
        XCTAssertEqual(evaluation.deadIndices, [1])
        XCTAssertEqual(evaluation.retiredIDs, [alive.liveSessionID])
    }

    /// Positions, not identifiers, are what the platform maps back through —
    /// two cohort rows that happen to share a `liveSessionID` must stay two
    /// rows rather than collapsing into one.
    func test_deadIndicesTrackCohortPositionsNotIdentity() {
        let shared = candidate()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [shared, shared],
            live: [],
            elapsedSinceWindowOpened: 1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: false
        )

        XCTAssertEqual(evaluation.deadIndices, [0, 1])
    }

    func test_emptyEvaluationHasNoWork() {
        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [],
            live: [],
            elapsedSinceWindowOpened: 1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertFalse(evaluation.hasWork)
    }

    // MARK: - Window closure

    func test_windowStaysOpenWhileAnyEntryIsUnresolved() {
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 1,
                elapsedSinceWindowOpened: 1,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: false
            ),
            .open
        )
    }

    func test_windowSettlesWhenTheCohortEmpties() {
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 0,
                elapsedSinceWindowOpened: 1,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: false
            ),
            .settled
        )
    }

    /// The backstop outranks settling: reporting `settled` at the deadline
    /// would claim verdicts that were never reached.
    func test_backstopOutranksSettlingAtTheDeadline() {
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 0,
                elapsedSinceWindowOpened: maxWindow,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: false
            ),
            .backstop
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 3,
                elapsedSinceWindowOpened: maxWindow + 1,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: false
            ),
            .backstop
        )
    }

    /// An unanswered restore sheet is a verdict in progress. Backstopping
    /// under it would empty the cohort — and with it the snapshot protection —
    /// while the sheet is still offering those exact sessions. Ported from
    /// Android `promptPausesWindowAndBackstopDoesNotPretendItSettled`.
    func test_unansweredPromptDefersTheBackstop() {
        for elapsed in [maxWindow, maxWindow + 600] {
            XCTAssertEqual(
                ForegroundRestoreCohort.windowClosure(
                    remainingCohortCount: 2,
                    elapsedSinceWindowOpened: elapsed,
                    maxWindowSeconds: maxWindow,
                    hasUnansweredPrompt: true
                ),
                .open,
                "elapsed \(elapsed) must not end a window the user is answering"
            )
        }
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 0,
                elapsedSinceWindowOpened: maxWindow,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: true
            ),
            .open
        )
    }

    /// The deferral is the prompt's alone: without one the backstop still
    /// fires on time, so a wedged entry cannot hold the window forever.
    func test_backstopStillFiresWithoutAPrompt() {
        XCTAssertEqual(
            ForegroundRestoreCohort.windowClosure(
                remainingCohortCount: 2,
                elapsedSinceWindowOpened: maxWindow,
                maxWindowSeconds: maxWindow,
                hasUnansweredPrompt: false
            ),
            .backstop
        )
    }

    // MARK: - The window clock

    func test_chargeDeltaAccruesElapsedTime() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                now: start.addingTimeInterval(0.5),
                lastChargeAt: start,
                isPrompting: false,
                maxTick: 2
            ),
            0.5,
            accuracy: 0.0001
        )
    }

    /// A suspended process is not a stalled wake: the same clamp the handshake
    /// watchdog uses keeps a sleep gap from spending the whole window at once.
    func test_chargeDeltaClampsALongGap() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                now: start.addingTimeInterval(3600),
                lastChargeAt: start,
                isPrompting: false,
                maxTick: 2
            ),
            2,
            accuracy: 0.0001
        )
    }

    /// A clock that went backwards must not refund time already charged.
    func test_chargeDeltaFloorsAtZeroForABackwardsClock() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                now: start.addingTimeInterval(-30),
                lastChargeAt: start,
                isPrompting: false,
                maxTick: 2
            ),
            0
        )
    }

    /// The handshake budget stops while a prompt owns the connect path, so the
    /// backstop derived from that budget has to stop with it.
    func test_chargeDeltaPausesWhilePrompting() {
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                now: start.addingTimeInterval(1),
                lastChargeAt: start,
                isPrompting: true,
                maxTick: 2
            ),
            0
        )
    }

    func test_chargeDeltaIsZeroBeforeTheFirstCharge() {
        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                now: Date(),
                lastChargeAt: nil,
                isPrompting: false,
                maxTick: 2
            ),
            0
        )
    }

    /// The seconds-valued spelling is the same rule; Android's millisecond
    /// clock converts at the adapter edge. These are the Kotlin case's numbers
    /// (20s / 1s / 2s tick) restated in the core's units.
    func test_chargeDeltaSecondsOverloadMatchesTheDateForm() {
        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                nowSeconds: 20,
                lastChargeAtSeconds: 1,
                isPrompting: true,
                maxTickSeconds: 2
            ),
            0
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                nowSeconds: 20,
                lastChargeAtSeconds: 1,
                isPrompting: false,
                maxTickSeconds: 2
            ),
            2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.chargeDelta(
                nowSeconds: 20,
                lastChargeAtSeconds: nil,
                isPrompting: false,
                maxTickSeconds: 2
            ),
            0
        )
    }

    // MARK: - Persist mode

    /// The background edge is the only write that sees a session's dying
    /// state, so it must never replace what the store already holds.
    func test_inactivePersistMergesWithTheStoredDocument() {
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: false,
                hasPreservedSnapshots: false,
                isWindowOpen: false,
                hasCohortEntries: false
            ),
            .mergeWithStored
        )
    }

    /// A write can observe the inactive phase while the window state is still
    /// standing — the phase-change handler clears it, but a session-state
    /// persist can land first. The background edge outranks the open window:
    /// anything else drops every stored session that is neither live nor
    /// still in the cohort.
    func test_backgroundEdgeOutranksAnOpenWindow() {
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: false,
                hasPreservedSnapshots: true,
                isWindowOpen: true,
                hasCohortEntries: true
            ),
            .mergeWithStored
        )
    }

    /// The app-lock wake: the scene is active and persists keep landing, but
    /// cohort seeding is still waiting on the unlock. A live-only write here
    /// deletes the snapshots the post-unlock window has to seed from.
    func test_latchedButUnopenedWindowMergesRatherThanWritingLiveOnly() {
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: true,
                hasPreservedSnapshots: true,
                isWindowOpen: false,
                hasCohortEntries: false
            ),
            .mergeWithStored
        )
    }

    func test_openWindowKeepsTheCohort() {
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: true,
                hasPreservedSnapshots: true,
                isWindowOpen: true,
                hasCohortEntries: true
            ),
            .keepCohort
        )
    }

    /// Nothing latched and nothing awaiting a verdict: the live set is the
    /// whole truth, and stale entries must not be resurrected by a merge.
    func test_ordinaryForegroundPersistWritesLiveOnly() {
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: true,
                hasPreservedSnapshots: false,
                isWindowOpen: false,
                hasCohortEntries: false
            ),
            .liveOnly
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.persistMode(
                isActive: true,
                hasPreservedSnapshots: true,
                isWindowOpen: true,
                hasCohortEntries: false
            ),
            .liveOnly
        )
    }

    // MARK: - Document rules

    func test_documentRulesAcceptAWellFormedDocument() {
        let ids = [UUID(), UUID(), UUID()]

        XCTAssertTrue(
            ForegroundRestoreDocumentRules.isValid(
                schemaVersion: ForegroundRestoreDocumentRules.currentSchemaVersion,
                sessionIDs: ids,
                selectedSessionID: ids[1]
            )
        )
    }

    /// A document from a schema we do not know describes sessions whose
    /// reconnect semantics we cannot honour — it is discarded, not migrated.
    func test_documentRulesRejectAForeignSchemaVersion() {
        XCTAssertEqual(
            ForegroundRestoreDocumentRules.violations(
                schemaVersion: 2,
                sessionIDs: [UUID()],
                selectedSessionID: nil
            ),
            [.unsupportedSchemaVersion(2)]
        )
    }

    func test_documentRulesRejectAnEmptyDocument() {
        XCTAssertEqual(
            ForegroundRestoreDocumentRules.violations(
                schemaVersion: 1,
                sessionIDs: [],
                selectedSessionID: nil
            ),
            [.noSnapshots]
        )
    }

    func test_documentRulesBoundTheSnapshotCountAtSixtyFour() {
        XCTAssertEqual(ForegroundRestoreDocumentRules.maxSnapshots, 64)

        let atCap = (0..<64).map { _ in UUID() }
        XCTAssertTrue(
            ForegroundRestoreDocumentRules.isValid(
                schemaVersion: 1,
                sessionIDs: atCap,
                selectedSessionID: nil
            )
        )

        let overCap = atCap + [UUID()]
        XCTAssertEqual(
            ForegroundRestoreDocumentRules.violations(
                schemaVersion: 1,
                sessionIDs: overCap,
                selectedSessionID: nil
            ),
            [.tooManySnapshots(65)]
        )
    }

    /// Two rows claiming the same session id would restore one session twice
    /// and lose the other's place in the cohort.
    func test_documentRulesRejectDuplicateSessionIDs() {
        let repeated = UUID()

        XCTAssertEqual(
            ForegroundRestoreDocumentRules.violations(
                schemaVersion: 1,
                sessionIDs: [repeated, UUID(), repeated],
                selectedSessionID: nil
            ),
            [.duplicateSessionID(repeated)]
        )
    }

    func test_documentRulesRejectASelectionThatIsNotPresent() {
        let dangling = UUID()

        XCTAssertEqual(
            ForegroundRestoreDocumentRules.violations(
                schemaVersion: 1,
                sessionIDs: [UUID()],
                selectedSessionID: dangling
            ),
            [.selectedSessionNotPresent(dangling)]
        )
    }

    /// The selection is the one violation both platforms repair rather than
    /// reject: the sessions still restore, only the highlight is stale.
    func test_normalizedSelectionDropsADanglingSelectionAndKeepsAPresentOne() {
        let ids = [UUID(), UUID()]

        XCTAssertNil(
            ForegroundRestoreDocumentRules.normalizedSelection(
                sessionIDs: ids,
                selectedSessionID: UUID()
            )
        )
        XCTAssertNil(
            ForegroundRestoreDocumentRules.normalizedSelection(
                sessionIDs: ids,
                selectedSessionID: nil
            )
        )
        XCTAssertEqual(
            ForegroundRestoreDocumentRules.normalizedSelection(
                sessionIDs: ids,
                selectedSessionID: ids[0]
            ),
            ids[0]
        )
    }

    // MARK: - Helpers

    private func candidate(hostID: UUID = UUID()) -> ForegroundRestoreCandidate {
        ForegroundRestoreCandidate(liveSessionID: UUID(), persistedHostID: hostID)
    }

    private func liveState(
        _ candidate: ForegroundRestoreCandidate,
        state: RestoreLiveState
    ) -> ForegroundRestoreLiveState {
        ForegroundRestoreLiveState(
            liveSessionID: candidate.liveSessionID,
            persistedHostID: candidate.persistedHostID,
            state: state
        )
    }
}
