import XCTest
import TesseraCrossDeviceCore
import TesseraPairingCore
import TesseraProtocolCore

final class SetupFlowPresentationTests: XCTestCase {
    typealias Flow = SetupFlowPresentationV1
    let host = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let jump = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let other = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    func testPurposeAwareStagesAndEveryPhaseBelongsToItsFlow() {
        let cases: [(PairingPurpose, [Flow.Stage])] = [
            (.bootstrap, [.scan, .verify, .choose, .transfer]),
            (.continueSession, [.scan, .verify, .connect]),
            (.setUpAndContinue, [.scan, .verify, .choose, .transfer, .connect]),
            (.enroll, [.scan, .verify, .choose, .transfer])
        ]
        let phases: [Flow.Phase] = [.entry, .connecting, .compareCode, .waitingForPeerCode, .preparingKey,
            .choosing, .waitingForSelection, .reviewingImport, .authorizing, .transferring, .importing,
            .waitingForGrant, .granting, .recordingAccess, .awaitingConnection, .completed, .failed, .rejecting]
        for (purpose, stages) in cases {
            for phase in phases {
                let output = Flow.project(.init(purpose: purpose, phase: phase))
                XCTAssertEqual(output.stages, stages)
                XCTAssertTrue(stages.contains(output.currentStage), "\(purpose) \(phase)")
            }
        }
        XCTAssertEqual(Flow.project(.init(entry: .nearby, phase: .entry)).stages.first, .discover)
    }

    func testCopySelectionIncludesRequiredRoutesButNotUnselectedHosts() {
        let result = Flow.project(.init(phase: .choosing, selection: .init(mode: .copy,
            allHostIDs: [host, jump, other], selectedHostIDs: [host], grantEligibleHostIDs: [host],
            jumpLinks: [.init(hostID: host, jumpHostID: jump)])))
        XCTAssertEqual(Set(result.copiedHostIDs), [host, jump])
        XCTAssertEqual(result.grantedHostIDs, [host])
        XCTAssertEqual(result.requiredRouteHostIDs, [jump])
    }

    func testNearbyCopiesAllButGrantsOnlyExplicitEligibleSelection() {
        let result = Flow.project(.init(phase: .choosing, supportedActions: [.approve], selection: .init(mode: .grants,
            allHostIDs: [host, jump, other], selectedHostIDs: [host, other], grantEligibleHostIDs: [host, jump])))
        XCTAssertEqual(Set(result.copiedHostIDs), [host, jump, other])
        XCTAssertEqual(result.grantedHostIDs, [host])
        XCTAssertTrue(result.allows(.approve))
    }

    func testEmptyCopyDisabledButZeroGrantNearbyAllowedAndStaleActionsRefused() {
        for mode in [Flow.SelectionMode.copy, .grants] {
            let selection = Flow.Selection(mode: mode, allHostIDs: [host], selectedHostIDs: [], grantEligibleHostIDs: [host])
            XCTAssertEqual(Flow.project(.init(phase: .choosing, supportedActions: [.approve], selection: selection)).allows(.approve), mode == .grants)
        }
        XCTAssertFalse(Flow.project(.init(phase: .waitingForPeerCode, supportedActions: [.confirmCode])).allows(.confirmCode))
        XCTAssertFalse(Flow.project(.init(phase: .failed, supportedActions: [.approve, .importSetup])).allows(.importSetup))
        XCTAssertFalse(Flow.project(.init(phase: .completed)).allows(.configureLater))
    }

    func testFailureDoesNotJumpToSuccessAndRetryStartsFresh() {
        XCTAssertEqual(Flow.project(.init(phase: .failed, stoppedAt: .verify)).currentStage, .verify)
        XCTAssertEqual(Flow.project(.init(phase: .failed)).currentStage, .scan)
        XCTAssertEqual(Flow.project(.init(phase: .entry)).currentStage, .scan)
        XCTAssertEqual(Flow.project(.init(phase: .failed, failureCode: "expired")).failureReason, .expired)
        XCTAssertEqual(Flow.failureReason("peerDisconnected"), .disconnected)
        XCTAssertEqual(Flow.failureReason("future-code"), .other)
    }

    func testReceiptNeverTurnsCopiedOrDeclinedIntoAuthorized() {
        let pairs: [(Flow.Access, Flow.Outcome)] = [(.unknown, .configurationCopied), (.installed, .authorized),
            (.alreadyInstalled, .alreadyAuthorized), (.failed, .failed), (.uncertain, .uncertain),
            (.skipped, .skipped), (.notSelected, .notSelected), (.excluded, .excluded)]
        for (access, outcome) in pairs {
            XCTAssertEqual(Flow.outcome(.init(id: host, access: access)), outcome)
            XCTAssertEqual(Flow.outcome(.init(id: host, access: access, wasAccepted: false)), .notImported)
        }
        XCTAssertEqual(Flow.outcome(.init(id: host, access: .skipped, passwordNeeded: true)), .passwordNeeded)
        XCTAssertEqual(Flow.outcome(.init(id: host, access: .failed, passwordNeeded: true)), .failed)
    }
}
