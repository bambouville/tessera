import XCTest
@testable import TesseraAgentCore

final class AgentIntegrationCheckPolicyTests: XCTestCase {
    func testMissingAndOutdatedInstallationExpireSoonerThanVerifiedCurrentFiles() {
        XCTAssertEqual(AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(.current), 30_000)
        XCTAssertEqual(AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(.missing), 5_000)
        XCTAssertEqual(AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(.outdated), 5_000)
    }

    func testRetryProgressionIsBoundedAndAValidObservationReturnsToFastChecks() {
        XCTAssertEqual((0...7).map { AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: $0) },
            [2_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000])
        XCTAssertEqual(AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: Int.max), 30_000)
        XCTAssertEqual(AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: 0), 2_000)
        XCTAssertEqual(AgentIntegrationCheckPolicy.activityThrottleMilliseconds, 2_000)
    }
}
