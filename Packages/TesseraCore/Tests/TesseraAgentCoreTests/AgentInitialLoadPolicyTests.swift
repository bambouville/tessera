import XCTest
@testable import TesseraAgentCore

final class AgentInitialLoadPolicyTests: XCTestCase {
    func testNewestPageIsRequiredBeforeExactlyTwoOlderPages() {
        XCTAssertEqual(AgentInitialLoadPolicy.initialPageCount, 3)
        XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: 0, hasOlder: true))
        XCTAssertTrue(AgentInitialLoadPolicy.shouldPrefetch(completedPages: 1, hasOlder: true))
        XCTAssertTrue(AgentInitialLoadPolicy.shouldPrefetch(completedPages: 2, hasOlder: true))
        XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: 3, hasOlder: true))
        XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: Int.max, hasOlder: true))
    }

    func testShortHistoryRetirementAndForegroundWorkStopPrefetch() {
        for completed in 1...2 {
            XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: completed, hasOlder: false))
            XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: completed, hasOlder: true, isCurrent: false))
            XCTAssertFalse(AgentInitialLoadPolicy.shouldPrefetch(completedPages: completed, hasOlder: true, hasPriorityDemand: true))
        }
    }

    func testActiveReadRetriesBackOffWithoutADeadEnd() {
        XCTAssertEqual([0, 1, 2, 3, 4, 5, Int.max].map {
            AgentIngestionReadRetryPolicy.delayMilliseconds(consecutiveFailures: $0)
        }, [1000, 1000, 2000, 4000, 8000, 15000, 15000])
    }
}
