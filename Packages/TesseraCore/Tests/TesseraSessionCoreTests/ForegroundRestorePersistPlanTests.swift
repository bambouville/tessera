import XCTest
@testable import TesseraSessionCore

/// What each persist mode actually writes.
///
/// Choosing the mode was already shared; what the mode does was not, and both
/// platforms carried their own copy — iOS inline in `ContentView`, pinned by a
/// comment and recorded as a debt in the review that shipped it.
final class ForegroundRestorePersistPlanTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func test_liveOnlyMirrorsTheTabList() {
        XCTAssertEqual(ids(.liveOnly, current: [a, b], cohort: [c], stored: [c]), [a, b])
    }

    func test_keepCohortAddsEntriesWhoseTabIsGone() {
        // A write landing mid-window must not delete what is about to be
        // restored.
        XCTAssertEqual(ids(.keepCohort, current: [a], cohort: [a, b], stored: []), [a, b])
    }

    func test_keepCohortNeverDuplicatesASessionThatIsStillLive() {
        let entries = ForegroundRestorePersistPlan.entries(
            mode: .keepCohort,
            currentSessionIDs: [a],
            cohortSessionIDs: [a],
            storedSessionIDs: [],
            maxSnapshots: 64
        )
        XCTAssertEqual(entries.map(\.sessionID), [a])
        XCTAssertEqual(entries.map(\.source), [.current])
    }

    func test_mergeKeepsStoredOrderAndLetsCurrentWin() {
        let entries = ForegroundRestorePersistPlan.entries(
            mode: .mergeWithStored,
            currentSessionIDs: [b, c],
            cohortSessionIDs: [],
            storedSessionIDs: [a, b],
            maxSnapshots: 64
        )
        // Stored order leads, so the arrangement the user had survives; the new
        // session is appended; b is taken from the live copy, not the stale one.
        XCTAssertEqual(entries.map(\.sessionID), [a, b, c])
        XCTAssertEqual(entries.map(\.source), [.stored, .current, .current])
    }

    func test_aMergeKeepsASessionThatIsNoLongerLive() {
        // The background edge writes this, and the dead session it carries
        // forward is exactly what the next launch wants back.
        let entries = ForegroundRestorePersistPlan.entries(
            mode: .mergeWithStored,
            currentSessionIDs: [],
            cohortSessionIDs: [],
            storedSessionIDs: [a],
            maxSnapshots: 64
        )
        XCTAssertEqual(entries.map(\.sessionID), [a])
        XCTAssertEqual(entries.map(\.source), [.stored])
    }

    func test_theWriteIsBounded() {
        XCTAssertEqual(ids(.liveOnly, current: [a, b, c], cohort: [], stored: [], max: 2), [a, b])
    }

    // MARK: - selection

    func test_whatIsOnScreenWinsWhenItIsInTheDocument() {
        XCTAssertEqual(
            ForegroundRestorePersistPlan.selection(
                mode: .mergeWithStored, preferred: b, writtenSessionIDs: [a, b], storedSelection: a
            ),
            b
        )
    }

    func test_aMergeFallsBackToTheStoredSelection() {
        // Mid-wake the session the user was last looking at is reconnecting and
        // momentarily has no tab, so nothing is preferred.
        XCTAssertEqual(
            ForegroundRestorePersistPlan.selection(
                mode: .mergeWithStored, preferred: nil, writtenSessionIDs: [a, b], storedSelection: a
            ),
            a
        )
    }

    func test_aStoredSelectionThatIsNotWrittenIsDropped() {
        XCTAssertNil(
            ForegroundRestorePersistPlan.selection(
                mode: .mergeWithStored, preferred: nil, writtenSessionIDs: [b], storedSelection: a
            )
        )
    }

    func test_aLiveOnlyWriteNeverResurrectsASelection() {
        // Nothing is at risk in this state, so a stored selection here would
        // outlive the session it names.
        XCTAssertNil(
            ForegroundRestorePersistPlan.selection(
                mode: .liveOnly, preferred: nil, writtenSessionIDs: [a], storedSelection: a
            )
        )
    }

    func test_aPreferredSessionThatWasNotWrittenIsNotSelected() {
        XCTAssertNil(
            ForegroundRestorePersistPlan.selection(
                mode: .keepCohort, preferred: c, writtenSessionIDs: [a, b], storedSelection: nil
            )
        )
    }

    private func ids(
        _ mode: ForegroundRestoreCohort.PersistMode,
        current: [UUID],
        cohort: [UUID],
        stored: [UUID],
        max: Int = 64
    ) -> [UUID] {
        ForegroundRestorePersistPlan.entries(
            mode: mode,
            currentSessionIDs: current,
            cohortSessionIDs: cohort,
            storedSessionIDs: stored,
            maxSnapshots: max
        ).map(\.sessionID)
    }
}
