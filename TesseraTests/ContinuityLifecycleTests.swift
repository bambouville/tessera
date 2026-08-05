import XCTest
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
        coordinator.cancel()
        XCTAssertNil(coordinator.ready)
        XCTAssertNil(coordinator.stashedWhileLocked)
        XCTAssertNil(coordinator.active)

        XCTAssertTrue(coordinator.receive(data: data, isLocked: true))
        XCTAssertNotNil(coordinator.stashedWhileLocked)
        coordinator.cancel()
        XCTAssertNil(coordinator.ready)
        XCTAssertNil(coordinator.stashedWhileLocked)
        XCTAssertNil(coordinator.active)
    }

    func test_applicationLockRestashesOnlyUnhandledActivity() throws {
        let coordinator = ContinuationCoordinator()
        let data = try makeDescriptor().handoffData()

        XCTAssertTrue(coordinator.receive(data: data, isLocked: false))
        let pending = try XCTUnwrap(coordinator.ready)
        coordinator.applicationDidLock()

        XCTAssertNil(coordinator.ready)
        XCTAssertEqual(coordinator.stashedWhileLocked?.id, pending.id)

        coordinator.replayAfterUnlock()
        coordinator.consume(pending.id)
        XCTAssertEqual(coordinator.active?.id, pending.id)
        coordinator.applicationDidLock()

        XCTAssertEqual(coordinator.active?.id, pending.id)
        XCTAssertNil(coordinator.stashedWhileLocked)
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
