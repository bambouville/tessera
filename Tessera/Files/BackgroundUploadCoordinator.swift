// Tessera/Files/BackgroundUploadCoordinator.swift
//
// Grants an explicitly backgrounded, user-initiated SFTP upload the best
// execution window the OS supports. iOS 26 continued-processing tasks expose
// system progress UI and can be cancelled by the user there. iOS 17-25 use a
// finite UIApplication background assertion; expiration cancels the bridge
// task so TransferTask can remove (or journal) its remote staging file.

import BackgroundTasks
import Foundation
import UIKit

@MainActor
protocol ContinuedProcessingTasking: AnyObject {
    var identifier: String { get }
    var progress: Progress { get }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func clearExpirationHandler()
    func setTaskCompleted(success: Bool)
}

struct ContinuedProcessingRequest: Equatable {
    let identifier: String
    let title: String
    let subtitle: String
}

@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTasking) -> Void
    ) -> Bool
    func submit(_ request: ContinuedProcessingRequest) throws
}

@MainActor
protocol LegacyBackgroundTimeProviding: AnyObject {
    func begin(
        name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedProcessingTask: ContinuedProcessingTasking {
    private let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
    }

    var identifier: String { task.identifier }
    var progress: Progress { task.progress }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        task.expirationHandler = {
            Task { @MainActor in handler() }
        }
    }

    func clearExpirationHandler() {
        task.expirationHandler = nil
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTasking) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                launchHandler(SystemContinuedProcessingTask(continuedTask))
            }
        }
    }

    func submit(_ request: ContinuedProcessingRequest) throws {
        let systemRequest = BGContinuedProcessingTaskRequest(
            identifier: request.identifier,
            title: request.title,
            subtitle: request.subtitle
        )
        systemRequest.strategy = .fail
        try BGTaskScheduler.shared.submit(systemRequest)
    }
}

@MainActor
private final class SystemLegacyBackgroundTimeProvider: LegacyBackgroundTimeProviding {
    func begin(
        name: String,
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in expirationHandler() }
        }
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class BackgroundUploadCoordinator {
    static let shared = BackgroundUploadCoordinator()

    static let continuedIdentifierPrefix = "com.bambouville.TesseraApp.upload"

    private var continuedExecutions: [String: UploadExecution] = [:]
    private var registeredContinuedIdentifiers: Set<String> = []
    private var legacyTaskIDs: [UUID: UIBackgroundTaskIdentifier] = [:]
    private let continuedScheduler: (any ContinuedProcessingScheduling)?
    private let legacyBackgroundTime: any LegacyBackgroundTimeProviding

    private init() {
        continuedScheduler = nil
        legacyBackgroundTime = SystemLegacyBackgroundTimeProvider()
    }

    init(
        continuedScheduler: (any ContinuedProcessingScheduling)?,
        legacyBackgroundTime: any LegacyBackgroundTimeProviding
    ) {
        self.continuedScheduler = continuedScheduler
        self.legacyBackgroundTime = legacyBackgroundTime
    }

    var activeContinuedExecutionCount: Int { continuedExecutions.count }

    @discardableResult
    func continueUpload(_ execution: UploadExecution) -> Bool {
        if #available(iOS 26.0, *), scheduleContinuedProcessing(execution) {
            return true
        }
        return beginLegacyBackgroundTime(execution)
    }

    @available(iOS 26.0, *)
    private func scheduleContinuedProcessing(_ execution: UploadExecution) -> Bool {
        let identifier = "\(Self.continuedIdentifierPrefix).\(execution.id.uuidString)"
        if continuedExecutions[identifier] != nil {
            return true
        }
        let scheduler = continuedScheduler ?? SystemContinuedProcessingScheduler()
        if !registeredContinuedIdentifiers.contains(identifier) {
            let registered = scheduler.register(identifier: identifier) { [weak self] task in
                self?.run(task)
            }
            guard registered else { return false }
            registeredContinuedIdentifiers.insert(identifier)
        }

        continuedExecutions[identifier] = execution
        let request = ContinuedProcessingRequest(
            identifier: identifier,
            title: String(localized: "Uploading \(execution.displayName)"),
            subtitle: String(localized: "Tessera file transfer")
        )
        do {
            try scheduler.submit(request)
            return true
        } catch {
            continuedExecutions.removeValue(forKey: identifier)
            DiagnosticLogStore.appendApp(
                "continued upload unavailable file=\(execution.displayName) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    @available(iOS 26.0, *)
    private func run(_ task: any ContinuedProcessingTasking) {
        guard let execution = continuedExecutions[task.identifier] else {
            task.setTaskCompleted(success: false)
            return
        }
        task.progress.totalUnitCount = 1_000
        update(task.progress, from: execution.item.phase)
        let taskIdentifier = task.identifier
        task.setExpirationHandler { [weak execution] in
            guard let execution else { return }
            execution.queue.cancel(execution.item, reason: .backgroundTimeExpired)
        }

        Task { @MainActor [weak self, weak execution] in
            guard let execution else {
                task.clearExpirationHandler()
                task.setTaskCompleted(success: false)
                self?.continuedExecutions.removeValue(forKey: taskIdentifier)
                return
            }
            await execution.item.awaitFinished { phase in
                self?.update(task.progress, from: phase)
            }
            let succeeded = execution.item.phase == .completed
            task.clearExpirationHandler()
            task.setTaskCompleted(success: succeeded)
            self?.continuedExecutions.removeValue(forKey: taskIdentifier)
        }
    }

    private func beginLegacyBackgroundTime(_ execution: UploadExecution) -> Bool {
        // `continueUpload` is a handoff API and may be delivered twice while
        // a sheet is dismissing. Reuse the finite assertion already owned by
        // this execution; overwriting its identifier would make the first
        // assertion impossible to end.
        if legacyTaskIDs[execution.id] != nil {
            return true
        }
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = legacyBackgroundTime.begin(
            name: String(localized: "Upload \(execution.displayName)")
        ) { [weak self, weak execution] in
            guard let execution else { return }
            execution.queue.cancel(execution.item, reason: .backgroundTimeExpired)
            self?.endLegacyTask(for: execution.id)
        }
        guard identifier != .invalid else {
            DiagnosticLogStore.appendApp(
                "legacy background time unavailable file=\(execution.displayName)"
            )
            return false
        }
        legacyTaskIDs[execution.id] = identifier

        Task { @MainActor [weak self, weak execution] in
            guard let execution else { return }
            await execution.item.awaitFinished()
            self?.endLegacyTask(for: execution.id)
        }
        return true
    }

    private func endLegacyTask(for executionID: UUID) {
        guard let identifier = legacyTaskIDs.removeValue(forKey: executionID),
              identifier != .invalid else { return }
        legacyBackgroundTime.end(identifier)
    }

    private func update(_ progress: Progress, from phase: TransferPhase) {
        let fraction: Double
        switch phase {
        case .queued:
            fraction = 0
        case .running(let value), .cancelling(let value):
            fraction = value ?? 0
        case .completed:
            fraction = 1
        case .failed, .cancelled:
            return
        }
        progress.completedUnitCount = Int64((fraction * 1_000).rounded())
    }
}
