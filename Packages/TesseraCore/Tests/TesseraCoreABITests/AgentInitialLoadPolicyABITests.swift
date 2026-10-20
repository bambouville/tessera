import XCTest
import TesseraAgentCore
@testable import TesseraCoreABI

final class AgentInitialLoadPolicyABITests: XCTestCase {
    func testNativePolicyMatchesSwiftForEveryGate() {
        XCTAssertEqual(tesseraAgentProcessProofTimeoutMilliseconds(), AgentReadRecoveryPolicy.processProofTimeoutMilliseconds)
        XCTAssertEqual(tesseraAgentInitialLoadPageCount(), Int32(AgentInitialLoadPolicy.initialPageCount))
        for completed: Int32 in [-1, 0, 1, 2, 3, .max] {
            XCTAssertEqual(tesseraAgentReadRetryDelayMilliseconds(consecutiveFailures: completed),
                AgentIngestionReadRetryPolicy.delayMilliseconds(consecutiveFailures: Int(completed)))
            for flags: UInt32 in 0..<8 {
                XCTAssertEqual(tesseraAgentInitialLoadShouldPrefetch(completedPages: completed, flags: flags),
                    AgentInitialLoadPolicy.shouldPrefetch(completedPages: Int(completed),
                        hasOlder: flags & 1 != 0, isCurrent: flags & 2 != 0,
                        hasPriorityDemand: flags & 4 != 0) ? 1 : 0)
            }
        }
        XCTAssertEqual(tesseraAgentInitialLoadShouldPrefetch(completedPages: 1, flags: .max), 0)
    }

    func testOnlyTransientReadStatusesEndWhenTheirReaderCloses() throws {
        for state in AgentIngestionReadStatus.State.allCasesForRecoveryTest {
            let progress = state == .preparing || state == .verifying
            let status = try AgentIngestionReadStatus.decode(.object([
                "v": .number(1), "state": .string(state.rawValue), "domain": .string("source"),
                "recovery": .string(progress ? "continue" : "manual"), "code": .string("readPending"),
            ]))
            XCTAssertEqual(status.survivesReaderClosure, !progress)
        }
    }
}

private extension AgentIngestionReadStatus.State {
    static let allCasesForRecoveryTest: [Self] = [.preparing, .verifying, .retryable, .sourceChanged, .unsupported, .resourceLimited, .failed]
}
