import XCTest
import TesseraContinuityCore
@testable import Tessera

@MainActor
final class ContinuityLifecycleTests: XCTestCase {
    func test_lockedContinuationStashesThenReplaysAndConsumesExactPendingItem() throws {
        let coordinator = ContinuationCoordinator()
        let descriptor = makeDescriptor()

        XCTAssertTrue(
            coordinator.receive(
                data: try descriptor.handoffData(),
                isLocked: true
            )
        )
        XCTAssertNil(coordinator.ready)
        let stashed = try XCTUnwrap(coordinator.stashedWhileLocked)
        XCTAssertEqual(stashed.descriptor, descriptor)
        XCTAssertNil(coordinator.lastFailure)

        coordinator.replayAfterUnlock()

        XCTAssertNil(coordinator.stashedWhileLocked)
        let ready = try XCTUnwrap(coordinator.ready)
        XCTAssertEqual(ready.id, stashed.id)
        XCTAssertEqual(ready.descriptor, descriptor)

        coordinator.consume(UUID())
        XCTAssertEqual(coordinator.ready?.id, ready.id)

        coordinator.consume(ready.id)
        XCTAssertNil(coordinator.ready)
        XCTAssertEqual(coordinator.active?.id, ready.id)

        XCTAssertFalse(
            coordinator.receive(
                data: try descriptor.handoffData(),
                isLocked: false
            )
        )
        XCTAssertEqual(coordinator.active?.id, ready.id)

        coordinator.finishActive()
        XCTAssertNil(coordinator.active)
        XCTAssertTrue(
            coordinator.receive(
                data: try descriptor.handoffData(),
                isLocked: false
            )
        )
    }

    func test_cancelClearsReadyAndLockedContinuations() throws {
        let coordinator = ContinuationCoordinator()
        let data = try makeDescriptor().handoffData()

        XCTAssertTrue(coordinator.receive(data: data, isLocked: false))
        XCTAssertNotNil(coordinator.ready)
        let readyID = try XCTUnwrap(coordinator.ready?.id)
        coordinator.cancel()
        XCTAssertNil(coordinator.ready)
        XCTAssertNil(coordinator.stashedWhileLocked)
        XCTAssertNil(coordinator.active)
        XCTAssertEqual(coordinator.sharedState, .cancelled(readyID))

        XCTAssertTrue(coordinator.receive(data: data, isLocked: true))
        XCTAssertNotNil(coordinator.stashedWhileLocked)
        let stashedID = try XCTUnwrap(coordinator.stashedWhileLocked?.id)
        coordinator.cancel()
        XCTAssertNil(coordinator.ready)
        XCTAssertNil(coordinator.stashedWhileLocked)
        XCTAssertNil(coordinator.active)
        XCTAssertEqual(coordinator.sharedState, .cancelled(stashedID))
    }

    func test_applicationLockRestashesOnlyUnhandledActivity() throws {
        let coordinator = ContinuationCoordinator()
        let data = try makeDescriptor().handoffData()

        XCTAssertTrue(coordinator.receive(data: data, isLocked: false))
        let pending = try XCTUnwrap(coordinator.ready)
        coordinator.applicationDidLock()

        XCTAssertNil(coordinator.ready)
        XCTAssertEqual(coordinator.stashedWhileLocked?.id, pending.id)
        guard case .stashedBehindLock(let sharedStash) = coordinator.sharedState else {
            return XCTFail("shared ready activity was not restashed")
        }
        XCTAssertEqual(sharedStash.id, pending.id)

        coordinator.replayAfterUnlock()
        coordinator.consume(pending.id)
        XCTAssertEqual(coordinator.active?.id, pending.id)
        guard case .resolving(let activeBeforeLock) = coordinator.sharedState else {
            return XCTFail("shared continuation was not active before lock")
        }
        coordinator.applicationDidLock()

        XCTAssertEqual(coordinator.active?.id, pending.id)
        XCTAssertNil(coordinator.stashedWhileLocked)
        XCTAssertEqual(coordinator.sharedState, .resolving(activeBeforeLock))
    }

    func test_appleCoordinatorAdaptsWholeSharedContinuationLifecycle() throws {
        let coordinator = ContinuationCoordinator()
        let descriptor = makeDescriptor()
        XCTAssertTrue(coordinator.receive(
            data: try descriptor.handoffData(),
            isLocked: false
        ))
        let pending = try XCTUnwrap(coordinator.ready)
        guard case .ready = coordinator.sharedState else {
            return XCTFail("shared receive state was \(coordinator.sharedState)")
        }

        coordinator.consume(pending.id)
        let resolution = coordinator.resolve(
            pending.id,
            among: [],
            hasSavedHost: { _ in false }
        )
        XCTAssertEqual(resolution, .prefill(descriptor))
        guard case .needsHostAdmission(_, let insertionPlan) = coordinator.sharedState else {
            return XCTFail("shared resolution state was \(coordinator.sharedState)")
        }

        XCTAssertTrue(coordinator.hostAdmissionCompleted(
            continuationID: pending.id,
            admittedHostID: descriptor.hostID,
            insertedHostIDs: insertionPlan.insertedHostIDs
        ))
        guard case .needsCredential = coordinator.sharedState else {
            return XCTFail("shared admission state was \(coordinator.sharedState)")
        }
        XCTAssertTrue(coordinator.credentialEnrollmentCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID
        ))
        guard case .connecting = coordinator.sharedState else {
            return XCTFail("shared credential state was \(coordinator.sharedState)")
        }
        XCTAssertTrue(coordinator.connectionCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID
        ))
        guard case .completed(let receipt) = coordinator.sharedState else {
            return XCTFail("shared completion state was \(coordinator.sharedState)")
        }
        XCTAssertEqual(receipt.continuationID, pending.id)
        XCTAssertEqual(receipt.hostID, descriptor.hostID)
        XCTAssertEqual(coordinator.active?.id, pending.id)
    }

    func test_appleCoordinatorLocalizesStructuredDescriptorFailure() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeDescriptor().handoffData())
                as? [String: Any]
        )
        object["port"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: object)

        let coordinator = ContinuationCoordinator()
        XCTAssertFalse(coordinator.receive(data: invalid, isLocked: false))
        XCTAssertEqual(
            coordinator.lastFailure,
            "Continuation endpoint has invalid port 0."
        )
        XCTAssertEqual(
            coordinator.sharedLastFailure,
            .invalidDescriptor(.invalidPort(0))
        )
        XCTAssertEqual(coordinator.sharedState, .failed(nil, .invalidDescriptor))

        // The malformed receipt remains terminal until its UI consumes the
        // error, then releases because it never acquired stream authority.
        XCTAssertFalse(coordinator.receive(
            data: try makeDescriptor().handoffData(),
            isLocked: false
        ))
        coordinator.clearLastFailure()
        XCTAssertEqual(coordinator.sharedState, .idle)
        XCTAssertTrue(coordinator.receive(
            data: try makeDescriptor().handoffData(),
            isLocked: false
        ))
    }

    func test_securityPolicyChangePreservesSharedTerminalAuthority() throws {
        let coordinator = ContinuationCoordinator()
        XCTAssertTrue(coordinator.receive(
            data: try makeDescriptor().handoffData(),
            isLocked: false
        ))
        let pending = try XCTUnwrap(coordinator.ready)

        coordinator.securityPolicyChanged()

        XCTAssertNil(coordinator.ready)
        XCTAssertNil(coordinator.active)
        XCTAssertEqual(
            coordinator.sharedState,
            .failed(pending.id, .policyInvalidated)
        )
        XCTAssertEqual(coordinator.sharedLastFailure, .stalePolicy)
        XCTAssertEqual(
            coordinator.lastFailure,
            "The continuation is no longer current."
        )
    }

    func test_continuationDraftRecoveryMarkerTracksOnlyRowsCreatedByDraft() throws {
        let suite = "ContinuityLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContinuationDraftRecoveryStore(
            defaults: defaults,
            storageKey: "draft"
        )
        let hosts = Set([UUID(), UUID()])
        let identity = UUID()

        store.stage(hostIDs: hosts)
        store.registerCreatedIdentity(identity)
        store.registerCreatedIdentity(identity)

        let record = try XCTUnwrap(store.load())
        XCTAssertEqual(Set(record.hostIDs), hosts)
        XCTAssertEqual(record.identityIDs, [identity])

        store.clear()
        XCTAssertNil(store.load())
    }

    func test_busyCoordinatorRejectsNewActivityWithoutDiscardingValidPendingContinuation() throws {
        let coordinator = ContinuationCoordinator()
        XCTAssertTrue(
            coordinator.receive(
                data: try makeDescriptor().handoffData(),
                isLocked: true
            )
        )

        let wrongType = NSUserActivity(activityType: "example.not-tessera")
        XCTAssertFalse(coordinator.receive(wrongType, isLocked: false))
        XCTAssertNotNil(coordinator.stashedWhileLocked)

        let activity = NSUserActivity(activityType: ActivityBroadcaster.activityType)
        activity.userInfo = [ActivityBroadcaster.descriptorKey: Data("{}".utf8)]
        XCTAssertFalse(coordinator.receive(activity, isLocked: false))
        XCTAssertNil(coordinator.ready)
        XCTAssertNotNil(coordinator.stashedWhileLocked)
        XCTAssertEqual(
            coordinator.lastFailure,
            "Finish the current continuation before opening another."
        )
        coordinator.clearLastFailure()
        XCTAssertNil(coordinator.lastFailure)
    }

    func test_busyCoordinatorRetainsOriginalEnrollmentStreamAuthority() throws {
        let coordinator = ContinuationCoordinator()
        let descriptorData = try makeDescriptor().handoffData()
        let originalActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        originalActivity.userInfo = [
            ActivityBroadcaster.descriptorKey: descriptorData
        ]
        XCTAssertTrue(coordinator.receive(originalActivity, isLocked: false))
        XCTAssertTrue(coordinator.enrollmentActivity === originalActivity)

        let missingDescriptorActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        XCTAssertFalse(coordinator.receive(missingDescriptorActivity, isLocked: false))
        XCTAssertTrue(coordinator.enrollmentActivity === originalActivity)

        let duplicateActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        duplicateActivity.userInfo = [
            ActivityBroadcaster.descriptorKey: descriptorData
        ]
        XCTAssertFalse(coordinator.receive(duplicateActivity, isLocked: false))
        XCTAssertTrue(coordinator.enrollmentActivity === originalActivity)
    }

    func test_terminalAcceptedActivityRetainsStreamAuthorityUntilFinishActive() throws {
        let coordinator = ContinuationCoordinator()
        let descriptor = makeDescriptor()
        let originalActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        originalActivity.userInfo = [
            ActivityBroadcaster.descriptorKey: try descriptor.handoffData()
        ]
        XCTAssertTrue(coordinator.receive(originalActivity, isLocked: false))
        let pending = try XCTUnwrap(coordinator.ready)
        coordinator.consume(pending.id)
        XCTAssertEqual(
            coordinator.resolve(
                pending.id,
                among: [],
                hasSavedHost: { _ in false }
            ),
            .prefill(descriptor)
        )
        guard case .needsHostAdmission(_, let plan) = coordinator.sharedState else {
            return XCTFail("expected host admission")
        }
        XCTAssertTrue(coordinator.hostAdmissionCompleted(
            continuationID: pending.id,
            admittedHostID: descriptor.hostID,
            insertedHostIDs: plan.insertedHostIDs
        ))
        coordinator.credentialEnrollmentFailed()
        XCTAssertEqual(
            coordinator.sharedState,
            .failed(pending.id, .credentialEnrollmentFailed)
        )

        let malformedSecondActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        XCTAssertFalse(
            coordinator.receive(malformedSecondActivity, isLocked: false)
        )
        XCTAssertTrue(coordinator.enrollmentActivity === originalActivity)
        XCTAssertEqual(
            coordinator.sharedState,
            .failed(pending.id, .credentialEnrollmentFailed)
        )

        coordinator.finishActive()
        let nextActivity = NSUserActivity(
            activityType: ActivityBroadcaster.activityType
        )
        nextActivity.userInfo = [
            ActivityBroadcaster.descriptorKey: try descriptor.handoffData()
        ]
        XCTAssertTrue(coordinator.receive(nextActivity, isLocked: false))
        XCTAssertTrue(coordinator.enrollmentActivity === nextActivity)
    }

    func test_broadcastInvalidatesAndReconcilesAcrossEveryLifecycleGate() throws {
        let broadcaster = ActivityBroadcaster()
        let descriptor = makeDescriptor()

        broadcaster.publish(descriptor)
        XCTAssertTrue(broadcaster.isBroadcasting)
        XCTAssertNil(broadcaster.lastFailure)
        XCTAssertEqual(ActivityBroadcaster.title(for: descriptor), "zeus — continue session")
        let firstGeneration = broadcaster.publicationGeneration

        // Byte-identical refreshes retain the same activity so an in-flight
        // continuation-stream request cannot be orphaned by harmless state events.
        broadcaster.publish(descriptor)
        XCTAssertTrue(broadcaster.isBroadcasting)
        XCTAssertEqual(broadcaster.publicationGeneration, firstGeneration)

        broadcaster.onContinuationStreams = { input, output in
            input.close()
            output.close()
        }
        broadcaster.publish(descriptor)
        XCTAssertEqual(broadcaster.publicationGeneration, firstGeneration + 1)

        broadcaster.setLocked(true)
        XCTAssertFalse(broadcaster.isBroadcasting)
        broadcaster.setLocked(false)
        XCTAssertTrue(broadcaster.isBroadcasting)

        broadcaster.setApplicationActive(false)
        XCTAssertFalse(broadcaster.isBroadcasting)
        broadcaster.setApplicationActive(true)
        XCTAssertTrue(broadcaster.isBroadcasting)

        broadcaster.setEnabled(false)
        XCTAssertFalse(broadcaster.isBroadcasting)
        broadcaster.setEnabled(true)
        XCTAssertTrue(broadcaster.isBroadcasting)

        // A disconnected focused session is represented by publishing nil.
        broadcaster.publish(nil)
        XCTAssertFalse(broadcaster.isBroadcasting)

        broadcaster.publish(descriptor)
        XCTAssertTrue(broadcaster.isBroadcasting)
        broadcaster.invalidate()
        XCTAssertFalse(broadcaster.isBroadcasting)
    }

    func test_broadcastFailureCanBeClearedAndReportedAgain() {
        let broadcaster = ActivityBroadcaster()
        let descriptor = makeDescriptor()

        broadcaster.publish(descriptor)
        let generationBeforeFailure = broadcaster.publicationGeneration

        broadcaster.reportFailure("Route is unavailable.")
        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(broadcaster.lastFailure, "Route is unavailable.")

        broadcaster.setApplicationActive(false)
        broadcaster.setApplicationActive(true)
        XCTAssertFalse(
            broadcaster.isBroadcasting,
            "a lifecycle reconcile must not republish the descriptor that failed"
        )
        XCTAssertEqual(broadcaster.publicationGeneration, generationBeforeFailure)

        broadcaster.clearLastFailure()
        XCTAssertNil(broadcaster.lastFailure)

        broadcaster.reportFailure("Route is unavailable.")
        XCTAssertEqual(broadcaster.lastFailure, "Route is unavailable.")
    }

    func test_broadcastClearAfterExplicitInvalidationNeverRepublishesRetainedRequest() {
        let broadcaster = ActivityBroadcaster()
        broadcaster.publish(makeDescriptor())
        let publishedGeneration = broadcaster.publicationGeneration

        broadcaster.invalidate()
        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(broadcaster.publicationGeneration, publishedGeneration)

        broadcaster.publish(nil)
        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(
            broadcaster.publicationGeneration,
            publishedGeneration,
            "clearing an invalidated activity must not momentarily republish it"
        )

        broadcaster.setApplicationActive(false)
        broadcaster.setApplicationActive(true)
        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(broadcaster.publicationGeneration, publishedGeneration)
    }

    func test_broadcastAtomicGateConfigurationDoesNotRepublishInvalidatedDescriptor() {
        let broadcaster = ActivityBroadcaster()
        broadcaster.publish(makeDescriptor())
        let publishedGeneration = broadcaster.publicationGeneration

        broadcaster.invalidate()
        broadcaster.onContinuationStreams = { input, output in
            input.close()
            output.close()
        }
        broadcaster.setLocked(true)

        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(
            broadcaster.publicationGeneration,
            publishedGeneration + 1,
            "changing streams while still enabled legitimately republishes before lock"
        )

        let lockedGeneration = broadcaster.publicationGeneration
        broadcaster.invalidate()
        broadcaster.onContinuationStreams = nil
        XCTAssertFalse(broadcaster.isBroadcasting)
        XCTAssertEqual(
            broadcaster.publicationGeneration,
            lockedGeneration,
            "the publisher must apply the retained locked gate before stream changes"
        )
    }

    private func makeDescriptor() -> SessionActivityDescriptor {
        SessionActivityDescriptor(
            endpoint: SessionActivityEndpoint(
                hostID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "zeus",
                user: "operator",
                address: "zeus.example.invalid",
                port: 22,
                transport: .mosh,
                hostKeyFingerprint: "SHA256:destination"
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            via: [
                SessionActivityEndpoint(
                    hostID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                    name: "atlas",
                    user: "operator",
                    address: "atlas.example.invalid",
                    port: 2_222,
                    transport: .ssh,
                    hostKeyFingerprint: "SHA256:bastion"
                )
            ]
        )
    }
}
