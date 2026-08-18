import XCTest
@testable import Tessera

/// Covers the decision that governs which sessions reconnect at wake.
///
/// The cases below are not hypotheticals: the first two encode the 2026-08-17
/// field failures this logic was written to fix.
final class ForegroundRestoreCohortTests: XCTestCase {
    private let floor: TimeInterval = 5
    private let maxWindow: TimeInterval = 60

    // MARK: - The field repro

    /// Two SSH transports died 4ms apart. `activeSessions` still reported the
    /// second as connected when the first was already dead, and the shipped
    /// code restored only the one it could see, closed the window, and deleted
    /// the other's snapshot. Inside the floor the stale one must read `pending`
    /// — never `alive` — so it stays in the cohort to be caught a moment later.
    func test_staleConnectedPeerIsPendingInsideTheFloor_notAlive() {
        let dead = snapshot()
        let stale = snapshot()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [dead, stale],
            live: [
                live(dead, state: .disconnected),
                live(stale, state: .connected),
            ],
            elapsedSinceWindowOpened: 0.1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertEqual(evaluation.dead.map(\.liveSessionID), [dead.liveSessionID])
        XCTAssertEqual(evaluation.retiredIDs, [dead.liveSessionID])
    }

    /// A moment later the lag resolves and the peer reports too. It is still in
    /// the cohort, so it is restored rather than stranded.
    func test_lateReportingPeerIsStillRestored() {
        let stale = snapshot()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [stale],
            live: [live(stale, state: .disconnected)],
            elapsedSinceWindowOpened: 0.2,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: true
        )

        XCTAssertEqual(evaluation.dead.map(\.liveSessionID), [stale.liveSessionID])
    }

    // MARK: - Verdicts

    func test_missingLiveSessionIsDead() {
        let gone = snapshot()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: gone,
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
        let entry = snapshot()
        let impostor = ForegroundRestoreLiveSession(
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
        let entry = snapshot()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: live(entry, state: .failed("nope")),
                elapsedSinceWindowOpened: 0,
                aliveFloorSeconds: floor
            ),
            .dead
        )
    }

    /// A wedged handshake has reached no verdict — it must not be believed
    /// alive however long it sits there. The backstop is what bounds it.
    func test_connectingStaysPendingIndefinitely() {
        let entry = snapshot()

        for elapsed in [0.0, floor, 3600.0] {
            XCTAssertEqual(
                ForegroundRestoreCohort.verdict(
                    for: entry,
                    live: live(entry, state: .connecting),
                    elapsedSinceWindowOpened: elapsed,
                    aliveFloorSeconds: floor
                ),
                .pending,
                "elapsed \(elapsed) should not resolve a wedged handshake"
            )
        }
    }

    func test_connectedBecomesAliveOnlyAtTheFloor() {
        let entry = snapshot()

        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: live(entry, state: .connected),
                elapsedSinceWindowOpened: floor - 0.001,
                aliveFloorSeconds: floor
            ),
            .pending
        )
        XCTAssertEqual(
            ForegroundRestoreCohort.verdict(
                for: entry,
                live: live(entry, state: .connected),
                elapsedSinceWindowOpened: floor,
                aliveFloorSeconds: floor
            ),
            .alive
        )
    }

    // MARK: - Mosh

    /// Mosh keeps `SessionState` connected across network loss, so a zombie
    /// looks identical to a healthy session by state alone. Reachability is the
    /// only signal, and an unconfirmed transport must never read alive.
    func test_moshZombieStaysPendingDespiteConnectedState() {
        let entry = snapshot()
        let zombie = ForegroundRestoreLiveSession(
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
        let entry = snapshot()
        let healthy = ForegroundRestoreLiveSession(
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
        let entry = snapshot()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [entry],
            live: [
                ForegroundRestoreLiveSession(
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

        XCTAssertEqual(evaluation.dead.map(\.liveSessionID), [entry.liveSessionID])
    }

    // MARK: - .ask keeps dead entries until answered

    /// Retiring at the moment the sheet is raised would strip the entry's
    /// snapshot protection before the user has answered, and the replacement's
    /// new id means the entry could never match again.
    func test_askOffersDeadEntriesWithoutRetiringThem() {
        let entry = snapshot()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [entry],
            live: [],
            elapsedSinceWindowOpened: 1,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: false
        )

        XCTAssertEqual(evaluation.dead.map(\.liveSessionID), [entry.liveSessionID])
        XCTAssertTrue(evaluation.retiredIDs.isEmpty)
    }

    /// Confirmed-alive entries retire under `.ask` too — only the dead ones
    /// wait on the user.
    func test_askStillRetiresConfirmedAliveEntries() {
        let alive = snapshot()
        let dead = snapshot()

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: [alive, dead],
            live: [live(alive, state: .connected)],
            elapsedSinceWindowOpened: floor,
            aliveFloorSeconds: floor,
            retiresDeadImmediately: false
        )

        XCTAssertEqual(evaluation.dead.map(\.liveSessionID), [dead.liveSessionID])
        XCTAssertEqual(evaluation.retiredIDs, [alive.liveSessionID])
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
    /// while the sheet is still offering those exact sessions.
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

    /// The backstop must outlive the SSH handshake budget, or a wedged connect
    /// loses its cohort place before the watchdog can rule on it — which is
    /// exactly the drop this whole mechanism exists to prevent.
    func test_backstopOutlivesTheSSHHandshakeBudget() {
        XCTAssertGreaterThan(
            ContentView.foregroundRestoreWindowMaxSecondsForTesting,
            SSHSession.handshakeBudgetSeconds
        )
    }

    // MARK: - Helpers

    private func snapshot(hostID: UUID = UUID()) -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            liveSessionID: UUID(),
            persistedHostID: hostID,
            displayName: "host",
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func live(
        _ snapshot: SessionRestoreSnapshot,
        state: SessionState
    ) -> ForegroundRestoreLiveSession {
        ForegroundRestoreLiveSession(
            liveSessionID: snapshot.liveSessionID,
            persistedHostID: snapshot.persistedHostID,
            state: state
        )
    }
}
