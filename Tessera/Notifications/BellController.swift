import SwiftUI
import AVFoundation
import AudioToolbox
import UserNotifications

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
