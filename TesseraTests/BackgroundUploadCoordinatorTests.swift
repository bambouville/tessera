import Foundation
import Observation
import UIKit
import XCTest
@testable import Tessera

final class BackgroundUploadCoordinatorTests: XCTestCase {
    @available(iOS 26.0, *)
    @MainActor
    func test_continuedUploadRegistersExactIdentifierBeforeSubmittingIt() {
        let scheduler = RecordingContinuedScheduler()
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let fixture = makeExecution(displayName: "report.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))

        let identifier = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        XCTAssertEqual(scheduler.events, [.register(identifier), .submit(identifier)])
        XCTAssertEqual(scheduler.requests.map(\.identifier), [identifier])
        XCTAssertFalse(identifier.contains("*"))
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 1)
        XCTAssertTrue(legacy.started.isEmpty)
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_registrationFailureFallsBackWithoutSubmitting() {
        let scheduler = RecordingContinuedScheduler()
        scheduler.registrationSucceeds = false
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let fixture = makeExecution(displayName: "register.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))

        let identifier = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        XCTAssertEqual(scheduler.events, [.register(identifier)])
        XCTAssertTrue(scheduler.requests.isEmpty)
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 0)
        XCTAssertEqual(legacy.started.map(\.name), ["Upload register.txt"])
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_submissionFailureCleansRoutingAndFallsBack() {
        let scheduler = RecordingContinuedScheduler()
        scheduler.submissionError = TestSchedulerError.rejected
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let fixture = makeExecution(displayName: "submit.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))

        let identifier = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        XCTAssertEqual(scheduler.events, [.register(identifier), .submit(identifier)])
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 0)
        XCTAssertEqual(legacy.started.map(\.name), ["Upload submit.txt"])
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_repeatedActiveSchedulingDoesNotRegisterOrSubmitTwice() {
        let scheduler = RecordingContinuedScheduler()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: RecordingLegacyBackgroundTimeProvider()
        )
        let fixture = makeExecution(displayName: "once.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        XCTAssertTrue(coordinator.continueUpload(fixture.execution))

        let identifier = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        XCTAssertEqual(scheduler.events, [.register(identifier), .submit(identifier)])
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 1)
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_concurrentTasksRouteProgressExpirationCompletionAndCleanupIndependently() async {
        let scheduler = RecordingContinuedScheduler()
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let first = makeExecution(displayName: "first.bin")
        let second = makeExecution(displayName: "second.bin")

        XCTAssertTrue(coordinator.continueUpload(first.execution))
        XCTAssertTrue(coordinator.continueUpload(second.execution))
        let firstID = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(first.execution.id.uuidString)"
        let secondID = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(second.execution.id.uuidString)"
        let firstTask = RecordingContinuedTask(identifier: firstID)
        let secondTask = RecordingContinuedTask(identifier: secondID)

        scheduler.launch(firstTask, for: firstID)
        scheduler.launch(secondTask, for: secondID)
        first.item.phase = .running(fraction: 0.25)
        second.item.phase = .running(fraction: 0.8)
        await assertEventually {
            firstTask.progress.completedUnitCount == 250
                && secondTask.progress.completedUnitCount == 800
        }

        firstTask.expire()
        await assertEventually { firstTask.completions == [false] }
        XCTAssertEqual(first.queue.cancellations.count, 1)
        XCTAssertTrue(first.queue.cancellations[0].item === first.item)
        XCTAssertEqual(first.queue.cancellations[0].reason, .backgroundTimeExpired)
        XCTAssertTrue(second.queue.cancellations.isEmpty)
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 1)

        second.item.phase = .completed
        await assertEventually { secondTask.completions == [true] }
        XCTAssertEqual(secondTask.progress.completedUnitCount, 1_000)
        XCTAssertNil(secondTask.expirationHandler)
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 0)
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_handlerRejectsMismatchedTaskIdentifierWithoutStealingExecution() {
        let scheduler = RecordingContinuedScheduler()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: RecordingLegacyBackgroundTimeProvider()
        )
        let fixture = makeExecution(displayName: "route.txt")
        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        let registeredID = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        let wrongTask = RecordingContinuedTask(identifier: "\(registeredID).wrong")

        scheduler.launch(wrongTask, for: registeredID)

        XCTAssertEqual(wrongTask.completions, [false])
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 1)
        XCTAssertTrue(fixture.queue.cancellations.isEmpty)
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_userCancellationCompletesFailureAndCleansHandlerState() async {
        let scheduler = RecordingContinuedScheduler()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: RecordingLegacyBackgroundTimeProvider()
        )
        let fixture = makeExecution(displayName: "cancel.txt")
        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        let identifier = "\(BackgroundUploadCoordinator.continuedIdentifierPrefix).\(fixture.execution.id.uuidString)"
        let task = RecordingContinuedTask(identifier: identifier)
        scheduler.launch(task, for: identifier)

        XCTAssertTrue(fixture.queue.cancel(fixture.item, reason: .user))

        await assertEventually { task.completions == [false] }
        XCTAssertNil(task.expirationHandler)
        XCTAssertEqual(coordinator.activeContinuedExecutionCount, 0)
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_repeatedLegacyFallbackReusesAndEndsOneAssertion() async {
        let scheduler = RecordingContinuedScheduler()
        scheduler.registrationSucceeds = false
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let fixture = makeExecution(displayName: "legacy-once.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        XCTAssertEqual(legacy.started.count, 1)

        fixture.item.phase = .completed
        await assertEventually { legacy.ended == [legacy.started[0].identifier] }
    }

    @available(iOS 26.0, *)
    @MainActor
    func test_legacyExpirationCancelsAndEndsOwnedAssertionOnce() async {
        let scheduler = RecordingContinuedScheduler()
        scheduler.registrationSucceeds = false
        let legacy = RecordingLegacyBackgroundTimeProvider()
        let coordinator = BackgroundUploadCoordinator(
            continuedScheduler: scheduler,
            legacyBackgroundTime: legacy
        )
        let fixture = makeExecution(displayName: "legacy-expire.txt")

        XCTAssertTrue(coordinator.continueUpload(fixture.execution))
        legacy.started[0].expirationHandler()

        await assertEventually { fixture.queue.cancellations.count == 1 }
        XCTAssertEqual(fixture.queue.cancellations[0].reason, .backgroundTimeExpired)
        XCTAssertEqual(legacy.ended, [legacy.started[0].identifier])
        fixture.item.phase = .completed
        await Task.yield()
        XCTAssertEqual(legacy.ended, [legacy.started[0].identifier])
    }

    @MainActor
    private func makeExecution(displayName: String) -> ExecutionFixture {
        let item = TransferItem(
            direction: .upload,
            displayName: displayName,
            remotePath: "/tmp/\(displayName)",
            localURL: URL(fileURLWithPath: "/tmp/\(displayName)")
        )
        let queue = RecordingTransferQueue(item: item)
        return ExecutionFixture(
            execution: UploadExecution(
                item: item,
                queue: queue,
                hostID: UUID(),
                displayName: displayName,
                stagedURL: URL(fileURLWithPath: "/tmp/\(displayName)"),
                pastePath: false
            ),
            item: item,
            queue: queue
        )
    }

    @MainActor
    private func assertEventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private struct ExecutionFixture {
    let execution: UploadExecution
    let item: TransferItem
    let queue: RecordingTransferQueue
}

private enum TestSchedulerError: Error {
    case rejected
}

@MainActor
private final class RecordingContinuedScheduler: ContinuedProcessingScheduling {
    enum Event: Equatable {
        case register(String)
        case submit(String)
    }

    typealias LaunchHandler = @MainActor (any ContinuedProcessingTasking) -> Void

    var registrationSucceeds = true
    var submissionError: Error?
    private(set) var events: [Event] = []
    private(set) var requests: [ContinuedProcessingRequest] = []
    private var handlers: [String: LaunchHandler] = [:]

    func register(identifier: String, launchHandler: @escaping LaunchHandler) -> Bool {
        events.append(.register(identifier))
        guard registrationSucceeds else { return false }
        handlers[identifier] = launchHandler
        return true
    }

    func submit(_ request: ContinuedProcessingRequest) throws {
        events.append(.submit(request.identifier))
        requests.append(request)
        if let submissionError { throw submissionError }
    }

    func launch(_ task: any ContinuedProcessingTasking, for registeredIdentifier: String) {
        handlers[registeredIdentifier]?(task)
    }
}

@MainActor
private final class RecordingContinuedTask: ContinuedProcessingTasking {
    let identifier: String
    let progress = Progress(totalUnitCount: 0)
    private(set) var completions: [Bool] = []
    var expirationHandler: (@MainActor () -> Void)?

    init(identifier: String) {
        self.identifier = identifier
    }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        expirationHandler = handler
    }

    func clearExpirationHandler() {
        expirationHandler = nil
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

@MainActor
private final class RecordingLegacyBackgroundTimeProvider: LegacyBackgroundTimeProviding {
    struct Started {
        let identifier: UIBackgroundTaskIdentifier
        let name: String
        let expirationHandler: @MainActor () -> Void
    }

    private(set) var started: [Started] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    var nextIdentifier = UIBackgroundTaskIdentifier(rawValue: 41)

    func begin(
        name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        let identifier = nextIdentifier
        started.append(Started(
            identifier: identifier,
            name: name,
            expirationHandler: expirationHandler
        ))
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }
}

@Observable
@MainActor
private final class RecordingTransferQueue: TransferQueueing {
    struct Cancellation {
        let item: TransferItem
        let reason: TransferCancellationReason
    }

    var items: [TransferItem]
    var backgroundAttention: BackgroundTransferAttention = .none
    private(set) var cancellations: [Cancellation] = []

    init(item: TransferItem) {
        items = [item]
    }

    var hasActive: Bool {
        items.contains { item in
            switch item.phase {
            case .queued, .running, .cancelling: true
            case .completed, .failed, .cancelled: false
            }
        }
    }

    func enqueueDownload(remotePath: String, displayName: String, to localURL: URL) -> TransferItem {
        fatalError("unused")
    }

    func enqueueUpload(localURL: URL, toDirectory remoteDirectory: String) -> TransferItem {
        fatalError("unused")
    }

    func enqueuePasteUpload(localURL: URL) -> TransferItem {
        fatalError("unused")
    }

    func cancel(_ item: TransferItem, reason: TransferCancellationReason) -> Bool {
        cancellations.append(Cancellation(item: item, reason: reason))
        item.cancellationReason = reason
        item.phase = .cancelled
        return true
    }

    func markContinuedInBackground(_ item: TransferItem) {}
    func acknowledgeBackgroundAttention() {}
    func clearFinished() {}
    func scheduleReaperIfNeeded(freshConnect: Bool) {}
}
