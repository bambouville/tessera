import Foundation
import TesseraAppleContinuity
import TesseraProtocolCore
import XCTest

@MainActor
final class AppleContinuationActivityPublisherTests: XCTestCase {
    func testPublishesReleasedActivityContractAndExactDescriptorBytes() throws {
        let bytes = try canonicalDescriptorBytes()
        let publisher = AppleContinuationActivityPublisher()
        let publication = AppleContinuationPublication(
            descriptorData: bytes,
            title: "production — continue session",
            targetContentIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )

        try publisher.publish(publication)

        let activity = try XCTUnwrap(publisher.currentUserActivity)
        XCTAssertEqual(
            AppleContinuationActivityContract.activityType,
            "com.bambouville.tessera.session"
        )
        XCTAssertEqual(AppleContinuationActivityContract.descriptorKey, "descriptor")
        XCTAssertEqual(activity.activityType, "com.bambouville.tessera.session")
        XCTAssertEqual(activity.title, publication.title)
        XCTAssertEqual(
            activity.userInfo?["descriptor"] as? Data,
            bytes
        )
        XCTAssertEqual(activity.requiredUserInfoKeys, ["descriptor"])
        XCTAssertEqual(
            activity.targetContentIdentifier,
            publication.targetContentIdentifier
        )
        XCTAssertTrue(activity.isEligibleForHandoff)
        XCTAssertFalse(activity.isEligibleForSearch)
        XCTAssertFalse(activity.isEligibleForPublicIndexing)
        XCTAssertFalse(activity.supportsContinuationStreams)
        XCTAssertTrue(publisher.isPublishing)
        XCTAssertEqual(publisher.publicationGeneration, 1)

        try publisher.publish(publication)
        XCTAssertTrue(publisher.currentUserActivity === activity)
        XCTAssertEqual(publisher.publicationGeneration, 1)
    }

    func testLockAndLifecycleInvalidationRetainRequestedPublication() throws {
        let publisher = AppleContinuationActivityPublisher()
        let publication = AppleContinuationPublication(
            descriptorData: try canonicalDescriptorBytes(),
            title: "production — continue session",
            targetContentIdentifier: "host"
        )
        try publisher.publish(publication)

        publisher.setLocked(true)
        XCTAssertFalse(publisher.isPublishing)
        XCTAssertNil(publisher.currentUserActivity)
        XCTAssertEqual(publisher.requestedPublication, publication)

        publisher.setLocked(false)
        XCTAssertTrue(publisher.isPublishing)
        XCTAssertEqual(publisher.publicationGeneration, 2)

        publisher.invalidateCurrentActivity()
        XCTAssertNil(publisher.currentUserActivity)
        XCTAssertEqual(publisher.requestedPublication, publication)
        publisher.setApplicationActive(false)
        publisher.setApplicationActive(true)
        XCTAssertTrue(publisher.isPublishing)
        XCTAssertEqual(publisher.publicationGeneration, 3)

        publisher.clearPublication()
        XCTAssertNil(publisher.requestedPublication)
        XCTAssertNil(publisher.currentUserActivity)
        XCTAssertFalse(publisher.isPublishing)
    }

    func testStreamHandlerReplacesActivityAndAdvertisesStreams() throws {
        let publisher = AppleContinuationActivityPublisher()
        let publication = AppleContinuationPublication(
            descriptorData: try canonicalDescriptorBytes(),
            title: "production",
            targetContentIdentifier: "host"
        )
        try publisher.publish(publication)
        let withoutStreams = try XCTUnwrap(publisher.currentUserActivity)

        publisher.onContinuationStreams = { _, _ in }

        let withStreams = try XCTUnwrap(publisher.currentUserActivity)
        XCTAssertFalse(withoutStreams === withStreams)
        XCTAssertTrue(withStreams.supportsContinuationStreams)
        XCTAssertEqual(publisher.publicationGeneration, 2)
        XCTAssertEqual(
            withStreams.userInfo?["descriptor"] as? Data,
            publication.descriptorData
        )
    }

    func testAtomicConfigurationCannotRepublishRetainedRequestBeforeDisablingGate() throws {
        let publisher = AppleContinuationActivityPublisher()
        let publication = AppleContinuationPublication(
            descriptorData: try canonicalDescriptorBytes(),
            title: "production",
            targetContentIdentifier: "host"
        )
        try publisher.publish(publication)
        let initialGeneration = publisher.publicationGeneration
        publisher.invalidateCurrentActivity()

        publisher.configure(
            enabled: false,
            applicationActive: true,
            locked: false,
            onContinuationStreams: { _, _ in }
        )

        XCTAssertFalse(publisher.isPublishing)
        XCTAssertNil(publisher.currentUserActivity)
        XCTAssertEqual(publisher.requestedPublication, publication)
        XCTAssertEqual(publisher.publicationGeneration, initialGeneration)

        publisher.configure(
            enabled: true,
            applicationActive: true,
            locked: false,
            onContinuationStreams: { _, _ in }
        )
        XCTAssertTrue(publisher.isPublishing)
        XCTAssertTrue(publisher.currentUserActivity?.supportsContinuationStreams == true)
        XCTAssertEqual(publisher.publicationGeneration, initialGeneration + 1)
    }

    func testRejectsInvalidFrozenDescriptorWithoutPublishing() throws {
        let invalid = try vectorBytes(named: "invalid-schema-version.json")
        let publisher = AppleContinuationActivityPublisher()

        XCTAssertThrowsError(
            try publisher.publish(
                AppleContinuationPublication(
                    descriptorData: invalid,
                    title: "invalid",
                    targetContentIdentifier: "host"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ContinuationDescriptorError,
                .unsupportedSchemaVersion(2)
            )
        }
        XCTAssertNil(publisher.requestedPublication)
        XCTAssertNil(publisher.currentUserActivity)
        XCTAssertFalse(publisher.isPublishing)
    }

    private func canonicalDescriptorBytes() throws -> Data {
        try vectorBytes(named: "canonical.json")
    }

    private func vectorBytes(named name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(
            contentsOf: root
                .appendingPathComponent("ProtocolVectors/continuation/v1")
                .appendingPathComponent(name)
        )
    }
}
