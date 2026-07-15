import SwiftUI
import UIKit

@MainActor
@Observable
final class AppPhase {
    enum State: String, Sendable {
        case active
        case inactive
        case background
    }

    enum InactiveDirection: String, Sendable {
        case leavingForeground
        case returningToForeground
        case unknown
    }

    private(set) var state: State = .active
    private(set) var inactiveDirection: InactiveDirection = .unknown

    var isActive: Bool { state == .active }

    func update(_ phase: ScenePhase) {
        let nextState: State
        switch phase {
        case .active: nextState = .active
        case .inactive: nextState = .inactive
        case .background: nextState = .background
        @unknown default: nextState = .inactive
        }

        if nextState == .inactive {
            switch state {
            case .active:
                inactiveDirection = .leavingForeground
            case .background:
                inactiveDirection = .returningToForeground
            case .inactive:
                break
            }
        } else {
            inactiveDirection = .unknown
        }
        state = nextState
    }

    enum AgentNotificationDecision: Equatable, Sendable {
        case deliver
        case awaitBackground
        case suppressForeground
        case suppressForegrounding
    }

    var agentNotificationDecision: AgentNotificationDecision {
        switch state {
        case .background:
            return .deliver
        case .active:
            return .suppressForeground
        case .inactive:
            return inactiveDirection == .returningToForeground
                ? .suppressForegrounding
                : .awaitBackground
        }
    }
}

/// When a user backgrounds Tessera during a provider turn, start a finite UIKit
/// completion assertion on the inactive edge (before the scene is actually in
/// the background). This keeps the client alive long enough to receive and
/// turn the final lifecycle event into a local notification; it is not a
/// promise of indefinite background execution.
@MainActor
final class AgentAttentionBackgroundKeepAlive {
    static let shared = AgentAttentionBackgroundKeepAlive()

    enum AssertionAction: Equatable, Sendable {
        case begin
        case keep
        case end
    }

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var beganAt: Date?
    private var beganState: AppPhase.State?
    private var lastExpiredAt: Date?
    private var latestWorkingCount = 0
    private var lastUpdateSignature: UpdateSignature?

    private struct UpdateSignature: Equatable {
        let enabled: Bool
        let workingCount: Int
        let state: AppPhase.State
        let inactiveDirection: AppPhase.InactiveDirection
        let assertionActive: Bool
        let action: AssertionAction
    }

    private init() {}

    static func assertionAction(
        enabled: Bool,
        workingCount: Int,
        state: AppPhase.State,
        inactiveDirection: AppPhase.InactiveDirection,
        assertionActive: Bool
    ) -> AssertionAction {
        guard enabled else { return .end }

        if assertionActive {
            // Once the app starts leaving the foreground, retain the assertion
            // through notification submission even if the Stop event has
            // already changed the last working agent to just-finished.
            return state == .active ? .end : .keep
        }

        guard workingCount > 0 else { return .end }
        guard state != .active else { return .end }
        if state == .inactive,
           inactiveDirection == .returningToForeground {
            // A retained Stop can be recovered while the scene is on its way
            // back to active. Starting a new assertion here cannot recover the
            // already-missed background interval and obscures diagnostics.
            return .end
        }
        return .begin
    }

    func update(
        enabled: Bool,
        workingCount: Int,
        appPhase: AppPhase,
        reason: String
    ) {
        latestWorkingCount = workingCount
        let action = Self.assertionAction(
            enabled: enabled,
            workingCount: workingCount,
            state: appPhase.state,
            inactiveDirection: appPhase.inactiveDirection,
            assertionActive: taskID != .invalid
        )
        let signature = UpdateSignature(
            enabled: enabled,
            workingCount: workingCount,
            state: appPhase.state,
            inactiveDirection: appPhase.inactiveDirection,
            assertionActive: taskID != .invalid,
            action: action
        )
        if signature != lastUpdateSignature {
            lastUpdateSignature = signature
            DiagnosticLogStore.appendAgentCenter(
                "attention-background update reason=\(reason) action=\(String(describing: action)) phase=\(appPhase.state.rawValue) direction=\(appPhase.inactiveDirection.rawValue) working=\(workingCount) task=\(describe(taskID)) remaining=\(remainingTime())"
            )
        }

        switch action {
        case .begin:
            begin(state: appPhase.state, reason: reason)
        case .keep:
            break
        case .end:
            end(reason: reason)
        }
    }

    func notificationProcessingFinished(reason: String) {
        guard taskID != .invalid else { return }
        guard latestWorkingCount == 0 else {
            DiagnosticLogStore.appendAgentCenter(
                "attention-background retain reason=other-agents-working after=\(reason) working=\(latestWorkingCount)"
            )
            return
        }
        end(reason: "notification-\(reason)")
    }

    func diagnosticSnapshot() -> String {
        let age: String
        if let beganAt {
            age = String(max(0, Int(Date.now.timeIntervalSince(beganAt) * 1_000)))
        } else {
            age = "none"
        }
        let expiredAgo: String
        if let lastExpiredAt {
            expiredAgo = String(max(0, Int(Date.now.timeIntervalSince(lastExpiredAt) * 1_000)))
        } else {
            expiredAgo = "none"
        }
        return "task=\(describe(taskID)) beganPhase=\(beganState?.rawValue ?? "none") ageMs=\(age) lastExpiredAgoMs=\(expiredAgo) remaining=\(remainingTime())"
    }

    private func begin(state: AppPhase.State, reason: String) {
        guard taskID == .invalid else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Tessera agent attention"
        ) { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        guard identifier != .invalid else {
            DiagnosticLogStore.appendAgentCenter(
                "attention-background begin-failed reason=\(reason) phase=\(state.rawValue) remaining=\(remainingTime())"
            )
            return
        }
        taskID = identifier
        beganAt = .now
        beganState = state
        DiagnosticLogStore.appendAgentCenter(
            "attention-background begin task=\(describe(identifier)) reason=\(reason) phase=\(state.rawValue) remaining=\(remainingTime())"
        )
    }

    private func expire() {
        lastExpiredAt = .now
        DiagnosticLogStore.appendAgentCenter(
            "attention-background expiration task=\(describe(taskID)) beganPhase=\(beganState?.rawValue ?? "none") remaining=\(remainingTime())"
        )
        end(reason: "expiration")
    }

    private func end(reason: String) {
        guard taskID != .invalid else { return }
        let endingTaskID = taskID
        taskID = .invalid
        beganAt = nil
        beganState = nil
        UIApplication.shared.endBackgroundTask(endingTaskID)
        DiagnosticLogStore.appendAgentCenter(
            "attention-background end task=\(describe(endingTaskID)) reason=\(reason)"
        )
    }

    private func describe(_ identifier: UIBackgroundTaskIdentifier) -> String {
        identifier == .invalid ? "invalid" : String(describing: identifier)
    }

    private func remainingTime() -> String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining.isFinite, remaining < 1_000_000 else { return "infinite" }
        return String(format: "%.1fs", remaining)
    }
}
