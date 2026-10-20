import Foundation
@preconcurrency import UserNotifications
import TesseraCore

enum AppleAgentNotificationPreviewMode: Equatable, Sendable {
    /// Default: no host, provider, project, path, task, tool, or transcript
    /// content reaches the lock screen.
    case contentFree
    /// Explicit opt-in. The caller provides already-safe display text; this
    /// policy still strips controls/bidi and bounds it before scheduling.
    case boundedPreview(maximumCharacters: Int)
}

struct AppleAgentNotificationPresentation: Equatable, Sendable {
    var preview: String?
    var mode: AppleAgentNotificationPreviewMode

    init(preview: String? = nil, mode: AppleAgentNotificationPreviewMode = .contentFree) {
        self.preview = preview
        self.mode = mode
    }
}

struct AppleAgentNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let userInfo: [String: String]
}

enum AppleAgentNotificationPolicy {
    static let kindKey = "tessera.agent-v2.kind"
    static let routeTokenKey = "tessera.agent-v2.route-token"
    static let generationKey = "tessera.agent-v2.generation"
    static let attentionKey = "tessera.agent-v2.attention"
    static let kind = "agent-center-v2"

    static func content(
        for event: AgentAttentionEvent,
        presentation: AppleAgentNotificationPresentation
    ) -> AppleAgentNotificationContent {
        let title: String
        switch event.attention {
        case .needsYou: title = String(localized: "agent needs input")
        case .unreadCompletion: title = String(localized: "agent finished")
        case .none: title = String(localized: "agent activity")
        }
        let contentFreeBody = String(localized: "Open Tessera to continue.")
        let body: String
        switch presentation.mode {
        case .contentFree:
            body = contentFreeBody
        case .boundedPreview(let maximumCharacters):
            body = boundedPreview(
                presentation.preview ?? contentFreeBody,
                maximumCharacters: maximumCharacters
            )
        }
        return AppleAgentNotificationContent(
            title: title,
            body: body,
            userInfo: [
                kindKey: kind,
                routeTokenKey: event.routeToken.rawValue.uuidString,
                generationKey: String(event.deliveryGeneration),
                attentionKey: event.attention.rawValue,
            ]
        )
    }

    static func route(from userInfo: [AnyHashable: Any]) -> AppleAgentNotificationRoute? {
        guard userInfo[kindKey] as? String == kind,
              let rawToken = userInfo[routeTokenKey] as? String,
              let token = UUID(uuidString: rawToken),
              let rawGeneration = userInfo[generationKey] as? String,
              let generation = UInt64(rawGeneration)
        else { return nil }
        return .init(token: AgentRouteToken(rawValue: token), generation: generation)
    }

    static func identifier(for token: AgentRouteToken) -> String {
        "agent-v2-\(token.rawValue.uuidString.lowercased())"
    }

    static func boundedPreview(_ value: String, maximumCharacters: Int) -> String {
        let maximum = min(max(1, maximumCharacters), 180)
        let scalars = value.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
            guard scalar.value >= 0x20,
                  scalar.value != 0x7F,
                  !(0x202A...0x202E).contains(scalar.value),
                  !(0x2066...0x2069).contains(scalar.value)
            else { return nil }
            return scalar
        }
        let normalized = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximum else { return normalized }
        return String(normalized.prefix(maximum - 1)) + "…"
    }
}

/// Process-local cold-start handoff. It is bounded and holds only opaque
/// route material; no notification text, host identity, or transcript data.
struct AppleAgentNotificationRoute: Equatable, Sendable {
    let token: AgentRouteToken
    let generation: UInt64
}

@MainActor
final class AppleAgentNotificationInbox {
    static let shared = AppleAgentNotificationInbox()
    private var routes: [AppleAgentNotificationRoute] = []

    func enqueue(_ route: AppleAgentNotificationRoute) {
        routes.removeAll { $0.token == route.token && $0.generation <= route.generation }
        routes.append(route)
        if routes.count > 8 { routes.removeFirst(routes.count - 8) }
    }

    func consumeAll() -> [AppleAgentNotificationRoute] {
        defer { routes.removeAll() }
        return routes
    }
}

/// Platform-owned notification delivery. Every scheduled request is fenced by
/// both the runtime event generation and this adapter's disable generation.
@MainActor
final class AppleAgentNotificationAdapter {
    enum ScheduleResult: Equatable {
        case scheduled
        case suppressed
        case stale
        case unauthorized
        case failed
    }

    private let center: UNUserNotificationCenter
    private var disableGeneration: UInt64 = 0
    private var routeGenerations: [AgentRouteToken: UInt64] = [:]
    /// The attention epoch each route last alerted for. The generation moves
    /// on every frame; the epoch moves only on entering attention, so one
    /// finish or one request for input alerts once.
    private var alertedEpochs: [AgentRouteToken: UInt64] = [:]

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestPermissionIfNeeded() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus
        }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        return (await center.notificationSettings()).authorizationStatus
    }

    func schedule(
        _ event: AgentAttentionEvent,
        presentation: AppleAgentNotificationPresentation = .init(),
        sceneAllowsDelivery: Bool
    ) async -> ScheduleResult {
        guard sceneAllowsDelivery, event.attention != .none else { return .suppressed }
        let routeToken = event.routeToken
        if let previous = routeGenerations[routeToken], previous >= event.deliveryGeneration {
            return .stale
        }
        routeGenerations[routeToken] = event.deliveryGeneration
        let capturedDisableGeneration = disableGeneration
        let status = await requestPermissionIfNeeded()
        guard isAuthorized(status) else { return .unauthorized }
        guard disableGeneration == capturedDisableGeneration,
              routeGenerations[routeToken] == event.deliveryGeneration
        else { return .stale }

        let resolved = AppleAgentNotificationPolicy.content(for: event, presentation: presentation)
        let content = UNMutableNotificationContent()
        content.title = resolved.title
        content.body = resolved.body
        content.sound = nil
        content.userInfo = resolved.userInfo.reduce(into: [AnyHashable: Any]()) {
            $0[AnyHashable($1.key)] = $1.value
        }
        let identifier = AppleAgentNotificationPolicy.identifier(for: routeToken)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        do {
            try await center.add(.init(identifier: identifier, content: content, trigger: nil))
        } catch {
            return .failed
        }
        guard disableGeneration == capturedDisableGeneration,
              routeGenerations[routeToken] == event.deliveryGeneration
        else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return .stale
        }
        alertedEpochs[routeToken] = event.attentionEpoch
        return .scheduled
    }

    /// False once this event's attention epoch has alerted. Checked before
    /// the caller commits a new tap fence, so a repeat of the same attention
    /// leaves the delivered notification's fence valid.
    func needsAlert(_ event: AgentAttentionEvent) -> Bool {
        event.attentionEpoch == 0 || alertedEpochs[event.routeToken] != event.attentionEpoch
    }

    func invalidate(_ event: AgentAttentionEvent) {
        let routeToken = event.routeToken
        routeGenerations[routeToken] = max(
            routeGenerations[routeToken] ?? 0,
            event.deliveryGeneration &+ 1
        )
        withdrawRequests(routeTokens: [routeToken])
    }

    func disable(routeTokens: [AgentRouteToken]) {
        disableGeneration &+= 1
        routeGenerations.removeAll()
        alertedEpochs.removeAll()
        withdrawRequests(routeTokens: routeTokens)
    }

    func withdraw(routeTokens: [AgentRouteToken]) {
        withdrawRequests(routeTokens: routeTokens)
    }

    private func withdrawRequests(routeTokens: [AgentRouteToken]) {
        let identifiers = routeTokens.map(AppleAgentNotificationPolicy.identifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }
}

/// V2 notification taps carry only an opaque token. The app resolves the
/// stable thread via `AppleAgentMetadataRepository`, then asks the runtime to
/// obtain a fresh live binding after foregrounding.
@MainActor
final class AppleAgentNotificationRouter {
    var pendingRoute: AppleAgentNotificationRoute?
    var onRoute: ((AppleAgentNotificationRoute) -> Void)?

    func receive(userInfo: [AnyHashable: Any]) {
        guard let route = AppleAgentNotificationPolicy.route(from: userInfo) else { return }
        if let onRoute { onRoute(route) } else { pendingRoute = route }
    }

    func consume() -> AppleAgentNotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}

/// One explicit cutover operation for the Experimental toggle. The caller is
/// still responsible for cancelling runtime data tasks and clearing runtime
/// memory; this service clears only durable metadata and OS notifications.
@MainActor
struct AppleAgentExperimentDisableCleanup {
    let metadata: AppleAgentMetadataRepository
    let notifications: AppleAgentNotificationAdapter

    func perform() async {
        let tokens = await metadata.allRouteTokens()
        notifications.disable(routeTokens: tokens)
        await metadata.removeAll()
    }
}
