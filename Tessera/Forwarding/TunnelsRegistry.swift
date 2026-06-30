import Foundation
import Observation
import PortForwarding
import UIKit

/// Maps a connected host's UUID → its live `PortForwarderManager`.
/// Hosts not currently connected do not appear in this map.
@MainActor
@Observable
public final class TunnelsRegistry {
    public private(set) var managers: [UUID: PortForwarderManager] = [:]

    public init() {}

    /// SessionView calls this on `.onAppear` once it has a manager.
    public func register(host: UUID, manager: PortForwarderManager) {
        managers[host] = manager
    }

    /// SessionView calls this on `.onDisappear`.
    public func unregister(host: UUID) {
        managers.removeValue(forKey: host)
    }

    /// Total running listeners across every connected session — drives
    /// the sidebar `tunnels (N)` badge.
    public var globalRunningCount: Int {
        managers.values.reduce(0) { $0 + $1.runningCount }
    }

    /// True if any manager has at least one forwarder in error.
    public var hasError: Bool {
        managers.values.contains(where: { $0.hasError })
    }

    /// Look up the manager for a specific host (nil if not connected).
    public func manager(for host: UUID) -> PortForwarderManager? {
        managers[host]
    }
}

@MainActor
final class ForwardingBackgroundKeepAlive {
    static let shared = ForwardingBackgroundKeepAlive()

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var runningCountAtStart = 0

    private init() {}

    func update(isActive: Bool, runningCount: Int, reason: String) {
        DiagnosticLogStore.appendForwarding(
            "background update reason=\(reason) active=\(isActive) running=\(runningCount) task=\(describe(taskID)) remaining=\(remainingTime())"
        )

        if isActive || runningCount == 0 {
            end(reason: reason)
            return
        }

        beginIfNeeded(runningCount: runningCount, reason: reason)
    }

    private func beginIfNeeded(runningCount: Int, reason: String) {
        guard taskID == .invalid else {
            return
        }

        runningCountAtStart = runningCount
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Tessera forwarding") { [weak self] in
            Task { @MainActor in
                self?.expire()
            }
        }

        guard taskID != .invalid else {
            DiagnosticLogStore.appendForwarding("background begin-failed reason=\(reason) running=\(runningCount)")
            return
        }

        self.taskID = taskID
        DiagnosticLogStore.appendForwarding(
            "background begin task=\(describe(taskID)) reason=\(reason) running=\(runningCount) remaining=\(remainingTime())"
        )
    }

    private func expire() {
        DiagnosticLogStore.appendForwarding(
            "background expiration task=\(describe(taskID)) runningAtStart=\(runningCountAtStart) remaining=\(remainingTime())"
        )
        end(reason: "expiration")
    }

    private func end(reason: String) {
        guard taskID != .invalid else {
            return
        }

        let endingTaskID = taskID
        taskID = .invalid
        runningCountAtStart = 0
        UIApplication.shared.endBackgroundTask(endingTaskID)
        DiagnosticLogStore.appendForwarding("background end task=\(describe(endingTaskID)) reason=\(reason)")
    }

    private func describe(_ taskID: UIBackgroundTaskIdentifier) -> String {
        if taskID == .invalid {
            return "invalid"
        }

        return String(describing: taskID)
    }

    private func remainingTime() -> String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining.isFinite, remaining < 1_000_000 else {
            return "infinite"
        }

        return String(format: "%.1fs", remaining)
    }
}
