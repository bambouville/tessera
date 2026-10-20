import XCTest
@testable import TesseraSessionCore

/// The cold-start decision.
///
/// The first case is not hypothetical: it is the 2026-09-11 Android field
/// defect, where a launch that raced Room's first emission read every stored
/// snapshot as naming a host the device no longer had, spent its single
/// cold-start pass, and cleared the document without logging anything.
final class ForegroundRestoreStartupTests: XCTestCase {
    private let hostA = UUID()
    private let hostB = UUID()
    private lazy var sessionA = ForegroundRestoreStartupCandidate(sessionID: UUID(), hostID: hostA)
    private lazy var sessionB = ForegroundRestoreStartupCandidate(sessionID: UUID(), hostID: hostB)

    // MARK: - the field defect

    func test_anEmptyHostListIsNotProofTheHostsAreGone() {
        XCTAssertEqual(
            action(candidates: [sessionA, sessionB], availableHostIDs: []),
            .wait(.hostListEmpty)
        )
    }

    func test_hostsStillLoadingWaits() {
        XCTAssertEqual(
            action(candidates: [sessionA], hostsLoaded: false, availableHostIDs: []),
            .wait(.hostsNotLoaded)
        )
    }

    func test_waitingOutranksTurningRestoreOff() {
        // `never` clears the store. Doing that on a question the caller cannot
        // yet answer would destroy the document over a race.
        XCTAssertEqual(
            action(candidates: [sessionA], availableHostIDs: [], policy: .never),
            .wait(.hostListEmpty)
        )
    }

    // MARK: - what a plan contains

    func test_restoresEveryEntryWhoseHostIsPresent() {
        let result = action(candidates: [sessionA, sessionB], availableHostIDs: [hostA, hostB])
        XCTAssertEqual(
            result,
            .restore(
                ForegroundRestoreStartupPlan(
                    sessionIDs: [sessionA.sessionID, sessionB.sessionID],
                    selectedSessionID: nil,
                    skippedCount: 0
                )
            )
        )
    }

    func test_anEntryWhoseHostIsGoneIsSkippedAndCounted() {
        // One unrestorable entry says nothing about the others — a rule this
        // series has had to relearn on both platforms.
        let result = action(candidates: [sessionA, sessionB], availableHostIDs: [hostA])
        guard case .restore(let plan) = result else { return XCTFail("expected a restore") }
        XCTAssertEqual(plan.sessionIDs, [sessionA.sessionID])
        XCTAssertEqual(plan.skippedCount, 1)
    }

    func test_aHostAlreadyOnScreenIsExcludedWithoutAbandoningTheRest() {
        // Giving up whenever any tab existed is how a share target, a
        // direct-share shortcut or an agent notification took restore with it.
        let result = action(
            candidates: [sessionA, sessionB],
            availableHostIDs: [hostA, hostB],
            liveHostIDs: [hostA]
        )
        guard case .restore(let plan) = result else { return XCTFail("expected a restore") }
        XCTAssertEqual(plan.sessionIDs, [sessionB.sessionID])
    }

    func test_everyEntryAlreadyOnScreenIsNothingToRestore() {
        XCTAssertEqual(
            action(
                candidates: [sessionA],
                availableHostIDs: [hostA],
                liveHostIDs: [hostA]
            ),
            .skip(.nothingRestorable)
        )
    }

    func test_theStoredSelectionSurvivesOnlyIfItIsInThePlan() {
        let kept = action(
            candidates: [sessionA, sessionB],
            availableHostIDs: [hostA, hostB],
            selectedSessionID: sessionB.sessionID
        )
        guard case .restore(let keptPlan) = kept else { return XCTFail("expected a restore") }
        XCTAssertEqual(keptPlan.selectedSessionID, sessionB.sessionID)

        // Writing a selection the plan does not contain lands the user on the
        // host list instead of the session they left.
        let dropped = action(
            candidates: [sessionA, sessionB],
            availableHostIDs: [hostA],
            selectedSessionID: sessionB.sessionID
        )
        guard case .restore(let droppedPlan) = dropped else { return XCTFail("expected a restore") }
        XCTAssertNil(droppedPlan.selectedSessionID)
    }

    // MARK: - policy

    func test_askOffersRatherThanRestores() {
        guard case .offer = action(
            candidates: [sessionA],
            availableHostIDs: [hostA],
            policy: .ask
        ) else { return XCTFail("ask must offer") }
    }

    func test_neverSkips() {
        XCTAssertEqual(
            action(candidates: [sessionA], availableHostIDs: [hostA], policy: .never),
            .skip(.policyNever)
        )
    }

    func test_anEmptyDocumentIsNothingToDo() {
        XCTAssertEqual(action(candidates: [], availableHostIDs: [hostA]), .skip(.noDocument))
        XCTAssertEqual(
            action(candidates: [sessionA], hasDocument: false, availableHostIDs: [hostA]),
            .skip(.noDocument)
        )
    }

    // MARK: - compact coercion

    func test_compactWidthTreatsAskAsAlwaysWithoutChangingTheStoredPreference() {
        XCTAssertEqual(
            ForegroundRestorePresentation.effectivePolicy(stored: .ask, usesCompactShell: true),
            .always
        )
        XCTAssertEqual(
            ForegroundRestorePresentation.effectivePolicy(stored: .ask, usesCompactShell: false),
            .ask
        )
        for policy in [ForegroundRestorePolicy.always, .never] {
            XCTAssertEqual(
                ForegroundRestorePresentation.effectivePolicy(stored: policy, usesCompactShell: true),
                policy
            )
        }
    }

    private func action(
        candidates: [ForegroundRestoreStartupCandidate],
        hasDocument: Bool = true,
        hostsLoaded: Bool = true,
        availableHostIDs: Set<UUID>,
        liveHostIDs: Set<UUID> = [],
        selectedSessionID: UUID? = nil,
        policy: ForegroundRestorePolicy = .always
    ) -> ForegroundRestoreStartupAction {
        ForegroundRestoreStartup.action(
            candidates: candidates,
            hasDocument: hasDocument,
            hostsLoaded: hostsLoaded,
            availableHostIDs: availableHostIDs,
            liveHostIDs: liveHostIDs,
            selectedSessionID: selectedSessionID,
            policy: policy
        )
    }
}
