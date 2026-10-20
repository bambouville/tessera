import Foundation
import XCTest
import TesseraAgentCore
@testable import TesseraCoreABI

final class AgentIntegrationCheckPolicyABITests: XCTestCase {
    func testExportUsesSharedPolicyForEveryRetryStageAndCapacityContract() throws {
        for failures: UInt32 in [0, 1, 2, 3, 4, 5, UInt32.max] {
            let count = tesseraAgentIntegrationCheckPolicy(consecutiveFailures: failures, outputBytes: nil, outputCapacity: 0)
            XCTAssertGreaterThan(count, 0)
            var output = [UInt8](repeating: 0, count: Int(count))
            let written = output.withUnsafeMutableBufferPointer {
                tesseraAgentIntegrationCheckPolicy(consecutiveFailures: failures, outputBytes: $0.baseAddress, outputCapacity: $0.count)
            }
            XCTAssertEqual(written, count)
            let value = try JSONDecoder().decode([String: UInt64].self, from: Data(output))
            XCTAssertEqual(value["nextCheckDelayMilliseconds"], AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: Int(failures)))
            XCTAssertEqual(value["currentInstallationFreshnessMilliseconds"], AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(.current))
            XCTAssertEqual(value["otherInstallationFreshnessMilliseconds"], AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(.missing))
            XCTAssertEqual(value["activityThrottleMilliseconds"], AgentIntegrationCheckPolicy.activityThrottleMilliseconds)
            let rejected = output.withUnsafeMutableBufferPointer {
                tesseraAgentIntegrationCheckPolicy(consecutiveFailures: failures, outputBytes: $0.baseAddress, outputCapacity: $0.count - 1)
            }
            XCTAssertEqual(rejected, -1)
        }
    }
}
