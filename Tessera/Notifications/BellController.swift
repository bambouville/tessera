import SwiftUI
import AVFoundation
import AudioToolbox
@preconcurrency import UserNotifications

public enum BellSource: Equatable, Hashable {
    case session(UUID)
    case tmuxWindow(sessionID: UUID, windowID: Int)
}

@MainActor
@Observable
final class BellController {
    private(set) var lastBellAt: Date?
    private(set) var lastBellSource: BellSource?
    private let appearance: AppearancePreferences
    private let appPhase: AppPhase
    private let limiter = BellRateLimiter()
    private var agentNotificationGeneration: UInt64 = 0
    private var agentNotificationGenerations: [AgentInstanceID: UInt64] = [:]
    #if DEBUG
    private(set) var agentNotificationVerification = "idle"
    #endif

    init(appearance: AppearancePreferences, appPhase: AppPhase) {
        self.appearance = appearance
        self.appPhase = appPhase

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    public func ring(source: BellSource, isOriginOnScreen: Bool, hostDisplayName: String, paneTitle: String?) {
        Task {
            await ringAsync(
                source: source,
                isOriginOnScreen: isOriginOnScreen,
                hostDisplayName: hostDisplayName,
                paneTitle: paneTitle
            )
        }
    }

    /// Provider lifecycle attention has its own precise preference and never
    /// reuses the terminal-bell limiter. AgentCenter already deduplicates each
    /// semantic transition; this method owns only the background iOS channel.
    func agentAttention(_ attention: AgentAttention, agent: AgentInstance) {
        let generation = agentNotificationGeneration
        let itemGeneration = (agentNotificationGenerations[agent.id] ?? 0) &+ 1
        agentNotificationGenerations[agent.id] = itemGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sid = String(agent.id.sessionID.uuidString.prefix(8))
            let pane = agent.location.paneID.map(String.init) ?? "raw"
            let kind = String(describing: attention.kind)
            let eventAgeMs = max(
                0,
                Int(Date.now.timeIntervalSince(attention.occurredAt) * 1_000)
            )
            guard self.appearance.agentCenterEnabled,
                  self.appearance.agentCenterNotificationsEnabled,
                  self.agentNotificationGeneration == generation,
                  self.agentNotificationGenerations[agent.id] == itemGeneration else {
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=suppressed reason=settings-or-generation phase=\(self.appPhase.state.rawValue) eventAgeMs=\(eventAgeMs) featureEnabled=\(self.appearance.agentCenterEnabled) preciseEnabled=\(self.appearance.agentCenterNotificationsEnabled) generationCurrent=\(self.agentNotificationGeneration == generation) itemCurrent=\(self.agentNotificationGenerations[agent.id] == itemGeneration)"
                )
                AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                    reason: "settings-or-generation"
                )
                return
            }

            let sceneDecision = await self.awaitAgentNotificationSceneDecision()
            guard sceneDecision == .deliver else {
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=suppressed reason=\(self.sceneSuppressionReason(sceneDecision)) phase=\(self.appPhase.state.rawValue) direction=\(self.appPhase.inactiveDirection.rawValue) eventAgeMs=\(eventAgeMs) \(AgentAttentionBackgroundKeepAlive.shared.diagnosticSnapshot())"
                )
                AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                    reason: self.sceneSuppressionReason(sceneDecision)
                )
                return
            }

            let status = await self.requestPermissionIfNeeded()
            guard self.appearance.agentCenterEnabled,
                  self.appearance.agentCenterNotificationsEnabled,
                  self.agentNotificationGeneration == generation,
                  self.agentNotificationGenerations[agent.id] == itemGeneration,
                  self.appPhase.agentNotificationDecision == .deliver,
                  status == .authorized || status == .provisional || status == .ephemeral
            else {
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=suppressed reason=authorization-or-state status=\(status.rawValue) phase=\(self.appPhase.state.rawValue) direction=\(self.appPhase.inactiveDirection.rawValue) eventAgeMs=\(eventAgeMs) featureEnabled=\(self.appearance.agentCenterEnabled) preciseEnabled=\(self.appearance.agentCenterNotificationsEnabled) generationCurrent=\(self.agentNotificationGeneration == generation) itemCurrent=\(self.agentNotificationGenerations[agent.id] == itemGeneration) \(AgentAttentionBackgroundKeepAlive.shared.diagnosticSnapshot())"
                )
                AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                    reason: "authorization-or-state"
                )
                return
            }

            let content = UNMutableNotificationContent()
            let window = agent.location.windowName
            content.title = window.map { "\(agent.location.hostName) · \($0)" }
                ?? agent.location.hostName
            switch attention.kind {
            case .needsInput:
                content.body = "\(agent.name) needs input"
            case .justFinished:
                content.body = "\(agent.name) just finished"
            }
            content.sound = nil
            content.userInfo = [
                TesseraNotificationDelegate.kindKey: TesseraNotificationDelegate.agentKind,
                TesseraNotificationDelegate.sessionIDKey: agent.id.sessionID.uuidString,
                TesseraNotificationDelegate.paneIDKey: agent.location.paneID ?? -1,
                TesseraNotificationDelegate.agentGenerationKey: String(generation),
            ]

            let identifier = Self.agentNotificationIdentifier(agent.id)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                // No trigger means immediate delivery. Avoid a second timer
                // racing the scene's background→foreground transition.
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                let nsError = error as NSError
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=failed domain=\(nsError.domain) code=\(nsError.code)"
                )
                AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                    reason: "schedule-failed"
                )
                return
            }
            if !self.appearance.agentCenterEnabled
                || !self.appearance.agentCenterNotificationsEnabled
                || self.agentNotificationGeneration != generation
                || self.agentNotificationGenerations[agent.id] != itemGeneration
                || self.appPhase.agentNotificationDecision != .deliver {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=withdrawn reason=state-changed-before-delivery phase=\(self.appPhase.state.rawValue) eventAgeMs=\(eventAgeMs)"
                )
                AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                    reason: "withdrawn"
                )
                return
            }
            DiagnosticLogStore.appendAgentCenter(
                "attention-ios sid=\(sid) pane=\(pane) kind=\(kind) result=scheduled immediate=true phase=\(self.appPhase.state.rawValue) eventAgeMs=\(eventAgeMs) \(AgentAttentionBackgroundKeepAlive.shared.diagnosticSnapshot())"
            )
            self.verifyAgentNotificationDelivery(
                center: center,
                identifier: identifier,
                agentID: agent.id,
                generation: generation,
                itemGeneration: itemGeneration,
                sid: sid,
                pane: pane,
                kind: kind
            )
        }
    }

    private func awaitAgentNotificationSceneDecision() async -> AppPhase.AgentNotificationDecision {
        // `.inactive` is ambiguous: it is emitted both before backgrounding
        // and while returning from the background. AppPhase records direction;
        // only the outward edge waits for the definitive background state.
        for _ in 0..<40 {
            let decision = appPhase.agentNotificationDecision
            guard decision == .awaitBackground else { return decision }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return .suppressForeground
            }
        }
        return appPhase.agentNotificationDecision
    }

    private func sceneSuppressionReason(
        _ decision: AppPhase.AgentNotificationDecision
    ) -> String {
        switch decision {
        case .deliver: "none"
        case .awaitBackground: "inactive-timeout"
        case .suppressForeground: "foreground"
        case .suppressForegrounding: "foregrounding-retained-event"
        }
    }

    private func verifyAgentNotificationDelivery(
        center: UNUserNotificationCenter,
        identifier: String,
        agentID: AgentInstanceID,
        generation: UInt64,
        itemGeneration: UInt64,
        sid: String,
        pane: String,
        kind: String
    ) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard let self else { return }
            guard self.agentNotificationGeneration == generation,
                  self.agentNotificationGenerations[agentID] == itemGeneration
            else {
                DiagnosticLogStore.appendAgentCenter(
                    "attention-ios-verify sid=\(sid) pane=\(pane) kind=\(kind) result=cancelled-before-check"
                )
                return
            }
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            let pendingMatch = pending.contains { $0.identifier == identifier }
            let deliveredMatch = delivered.contains {
                $0.request.identifier == identifier
            }
            DiagnosticLogStore.appendAgentCenter(
                "attention-ios-verify sid=\(sid) pane=\(pane) kind=\(kind) delivered=\(deliveredMatch) pending=\(pendingMatch) phase=\(self.appPhase.state.rawValue) \(AgentAttentionBackgroundKeepAlive.shared.diagnosticSnapshot())"
            )
            #if DEBUG
            self.agentNotificationVerification =
                "delivered=\(deliveredMatch) pending=\(pendingMatch)"
            #endif
            AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                reason: "verified"
            )
        }
    }

    #if DEBUG
    func resetAgentNotificationVerification() {
        agentNotificationVerification = "armed"
    }
    #endif

    func cancelAgentNotification(for agentID: AgentInstanceID) {
        agentNotificationGenerations[agentID] =
            (agentNotificationGenerations[agentID] ?? 0) &+ 1
        let identifier = Self.agentNotificationIdentifier(agentID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        DiagnosticLogStore.appendAgentCenter(
            "attention-ios-cancel sid=\(String(agentID.sessionID.uuidString.prefix(8))) pane=\(agentID.paneID.map(String.init) ?? "raw") scope=agent"
        )
    }

    private static func agentNotificationIdentifier(_ id: AgentInstanceID) -> String {
        "agent-\(id.sessionID.uuidString)-\(id.paneID.map(String.init) ?? "raw")"
    }

    /// Turning the experimental Agent Center off should also withdraw any
    /// attention it already queued; terminal-bell notifications are separate
    /// and remain untouched.
    func cancelAgentNotifications() {
        agentNotificationGeneration &+= 1
        agentNotificationGenerations.removeAll()
        DiagnosticLogStore.appendAgentCenter(
            "attention-ios-cancel scope=all generation=\(agentNotificationGeneration)"
        )
        let currentGeneration = String(agentNotificationGeneration)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids: [String] = requests.compactMap { request in
                let info = request.content.userInfo
                guard info[TesseraNotificationDelegate.kindKey] as? String
                        == TesseraNotificationDelegate.agentKind,
                      info[TesseraNotificationDelegate.agentGenerationKey] as? String
                        != currentGeneration
                else { return nil }
                return request.identifier
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { notifications in
            let ids: [String] = notifications.compactMap { notification in
                let info = notification.request.content.userInfo
                guard info[TesseraNotificationDelegate.kindKey] as? String
                        == TesseraNotificationDelegate.agentKind,
                      info[TesseraNotificationDelegate.agentGenerationKey] as? String
                        != currentGeneration
                else { return nil }
                return notification.request.identifier
            }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    public func shouldGlow(forWindowID windowID: Int?, sessionID: UUID) -> Bool {
        guard let lastBellAt, Date.now.timeIntervalSince(lastBellAt) <= 0.6 else {
            return false
        }

        switch lastBellSource {
        case .session(let sourceSessionID):
            return sourceSessionID == sessionID && windowID == nil
        case .tmuxWindow(let sourceSessionID, let sourceWindowID):
            return sourceSessionID == sessionID && sourceWindowID == windowID
        case .none:
            return false
        }
    }

    public func requestPermissionIfNeeded() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus
        }

        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        return (await center.notificationSettings()).authorizationStatus
    }

    private func ringAsync(source: BellSource, isOriginOnScreen: Bool, hostDisplayName: String, paneTitle: String?) async {
        let key: String
        switch source {
        case .session(let sessionID):
            key = "session:\(sessionID)"
        case .tmuxWindow(let sessionID, let windowID):
            key = "tmux:\(sessionID):\(windowID)"
        }

        guard await limiter.admit(key: key) else { return }

        let foreground = appPhase.isActive
        let onScreen = isOriginOnScreen
        let shouldSound = appearance.bellSoundEnabled && (!onScreen || !foreground)
        let shouldGlow = appearance.bellVisualEnabled && foreground && !onScreen
        let shouldNotify = appearance.bellNotificationEnabled && !foreground

        if shouldSound {
            AudioServicesPlaySystemSound(SystemSoundID(1057))
        }

        if shouldGlow {
            lastBellSource = source
            lastBellAt = .now
        }

        if shouldNotify {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized || status == .provisional || status == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = paneTitle.map { "\(hostDisplayName) · \($0)" } ?? hostDisplayName
            content.body = "rang a bell that needs attention"
            content.sound = nil

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "bell-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )

            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

extension Notification.Name {
    static let tesseraAgentNotificationTapped = Notification.Name(
        "Tessera.AgentNotificationTapped"
    )
}

@MainActor
final class AgentNotificationRouter {
    static let shared = AgentNotificationRouter()
    private(set) var pendingRoute: AgentInstanceID?
    var onRoute: ((AgentInstanceID) -> Void)?

    func receive(_ route: AgentInstanceID) {
        if let onRoute {
            onRoute(route)
        } else {
            pendingRoute = route
        }
    }

    func consume() -> AgentInstanceID? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}

final class TesseraNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TesseraNotificationDelegate()
    static let kindKey = "tessera.kind"
    static let agentKind = "agent-needs-input"
    static let sessionIDKey = "tessera.session-id"
    static let paneIDKey = "tessera.pane-id"
    static let agentGenerationKey = "tessera.agent-generation"

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Agent events are scheduled only in the background. If the app wins
        // the race back to foreground, its exact-pane banner owns presentation.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard info[Self.kindKey] as? String == Self.agentKind,
              let rawSessionID = info[Self.sessionIDKey] as? String,
              let sessionID = UUID(uuidString: rawSessionID)
        else { return }
        let rawPaneID = info[Self.paneIDKey] as? Int ?? -1
        let route = AgentInstanceID(
            sessionID: sessionID,
            paneID: rawPaneID >= 0 ? rawPaneID : nil
        )
        Task { @MainActor in
            AgentNotificationRouter.shared.receive(route)
        }
    }
}
