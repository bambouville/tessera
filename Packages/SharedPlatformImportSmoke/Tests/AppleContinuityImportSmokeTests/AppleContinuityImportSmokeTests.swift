import AppleContinuityImportSmoke
import XCTest

@MainActor
final class AppleContinuityImportSmokeTests: XCTestCase {
    func testMacTargetComposesAppleContinuityAndEnrollmentCore() async throws {
        let result = try await AppleContinuityImportProbe.run()

        XCTAssertEqual(result.activityType, "com.bambouville.tessera.session")
        XCTAssertEqual(result.descriptorKey, "descriptor")
        XCTAssertTrue(result.publisherInitiallyIdle)
        XCTAssertTrue(result.streamUsesAppleAccountBinding)
        XCTAssertTrue(result.enrollmentFrameRoundTrips)
        XCTAssertTrue(result.enrollmentStateMachineReachedRejected)
    }
}
