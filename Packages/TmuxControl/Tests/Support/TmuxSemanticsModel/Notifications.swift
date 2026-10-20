import Foundation

// Notifications: notify_add (notify.c:178-227) queues a callback on the
// global queue, so a notification reaches control clients only after the
// command list that caused it has finished (server_loop runs the global queue
// on its next pass, server.c:269-275). Delivery is control-notify.c.
// Subscriptions: control.c:841-1117, checked only from each control client's
// own one-second timer.

enum Notification {
    case windowLayoutChanged(window: Int)
    case sessionWindowChanged(session: Int)
    case clientSessionChanged(client: Int)
    case clientDetached(name: String)
    case sessionsChanged
    case windowLinked(session: Int, window: Int)
    case windowUnlinked(session: Int, window: Int)
}

enum SubscriptionKind: Equatable {
    case session
    case pane(Int)
    case allPanes
    case window(Int)
    case allWindows
}

/// `struct control_sub` with its per-pane / per-window last values.
final class Subscription {
    let name: String
    let kind: SubscriptionKind
    let format: String
    var last: String?
    var lastByKey: [String: String] = [:]

    init(name: String, kind: SubscriptionKind, format: String) {
        self.name = name
        self.kind = kind
        self.format = format
    }
}

extension TmuxServerModel {
    func enqueueNotification(_ notification: Notification) {
        if case .windowLayoutChanged(let id) = notification {
            windowState(id).layoutChangeNotifications += 1
        }
        globalQueue.append(QueueItem(kind: .notify(notification)))
    }

    var controlClients: [ClientState] {
        clients.filter(\.isControl)
    }

    /// notify_callback (notify.c:122-176) → control-notify.c.
    func deliver(_ notification: Notification) {
        switch notification {
        case .windowLayoutChanged(let windowID):
            // control_notify_window_layout_changed (control-notify.c:42-77):
            // every control client whose session contains the window, grouped
            // views included, at the window's size when the queue runs.
            guard let window = windows[windowID] else { return }
            for client in controlClients {
                guard let session = session(of: client),
                      let index = session.sortedIndexes.first(where: { session.winlinks[$0] == windowID })
                else { continue }
                let layout = layoutString(window)
                let flags = rawFlags(session: session, index: index, window: window)
                write(client, "%layout-change @\(windowID) \(layout) \(layout) \(flags)")
            }
        case .sessionWindowChanged(let sessionID):
            // control_notify_session_window_changed (control-notify.c:224-236):
            // every control client, whatever its session.
            guard let session = sessions[sessionID], let windowID = session.currentWindowID else { return }
            for client in controlClients {
                write(client, "%session-window-changed $\(sessionID) @\(windowID)")
            }
        case .clientSessionChanged(let index):
            // control_notify_client_session_changed (control-notify.c:150-172).
            guard let changed = client(index: index), let session = session(of: changed) else { return }
            for client in controlClients where client.sessionID != nil {
                if client === changed {
                    write(client, "%session-changed $\(session.id) \(session.name)")
                } else {
                    write(client, "%client-session-changed \(changed.name) $\(session.id) \(session.name)")
                }
            }
        case .clientDetached(let name):
            // control_notify_client_detached (control-notify.c:174-183): every
            // control client on the server, whatever its session.
            for client in controlClients {
                write(client, "%client-detached \(name)")
            }
        case .sessionsChanged:
            for client in controlClients {
                write(client, "%sessions-changed")
            }
        case .windowLinked(_, let windowID):
            // control_notify_window_linked (control-notify.c:111-127).
            for client in controlClients {
                guard let session = session(of: client) else { continue }
                write(client, sessionHas(session, window: windowID) ? "%window-add @\(windowID)" : "%unlinked-window-add @\(windowID)")
            }
        case .windowUnlinked(_, let windowID):
            // control_notify_window_unlinked (control-notify.c:93-109).
            for client in controlClients {
                guard let session = session(of: client) else { continue }
                write(client, sessionHas(session, window: windowID) ? "%window-close @\(windowID)" : "%unlinked-window-close @\(windowID)")
            }
        }
    }

    // MARK: Subscriptions

    /// cmd_refresh_client_update_subscription (cmd-refresh-client.c:45-78):
    /// `name:what:format` adds or replaces, `name` alone removes, and a value
    /// with one colon is ignored. `what` is `%*` (every pane), `%N`, `@*`
    /// (every window), `@N`, or anything else for a session subscription.
    func updateSubscription(_ client: ClientState, _ value: String) {
        guard let firstColon = value.firstIndex(of: ":") else {
            removeSubscription(client, value)
            return
        }
        let name = String(value[..<firstColon])
        let rest = value[value.index(after: firstColon)...]
        guard let secondColon = rest.firstIndex(of: ":") else { return }
        let what = String(rest[..<secondColon])
        let format = String(rest[rest.index(after: secondColon)...])
        addSubscription(client, Subscription(name: name, kind: Self.subscriptionKind(what), format: format))
    }

    /// The selector rules of cmd-refresh-client.c:63-73: `%*`, then
    /// `sscanf("%%%d") == 1 && >= 0` (so trailing text after the number is
    /// ignored), `@*`, `sscanf("@%d")`, else the session.
    static func subscriptionKind(_ what: String) -> SubscriptionKind {
        func number(after prefix: String) -> Int? {
            guard what.hasPrefix(prefix) else { return nil }
            var scanner = ScanfScanner(String(what.dropFirst(prefix.count)))
            guard let value = scanner.signed(), value >= 0 else { return nil }
            return Int(value)
        }
        if what == "%*" { return .allPanes }
        if let id = number(after: "%") { return .pane(id) }
        if what == "@*" { return .allWindows }
        if let id = number(after: "@") { return .window(id) }
        return .session
    }

    /// control_add_sub (control.c:1077-1103): replacing a subscription drops
    /// its remembered values; the client's timer is armed for one second
    /// only if it is not already pending.
    func addSubscription(_ client: ClientState, _ subscription: Subscription) {
        client.subscriptions[subscription.name] = subscription
        if client.subscriptionTimer == nil {
            client.subscriptionTimer = now + 1_000_000
        }
    }

    /// control_remove_sub (control.c:1106-1117).
    func removeSubscription(_ client: ClientState, _ name: String) {
        client.subscriptions[name] = nil
        if client.subscriptions.isEmpty { client.subscriptionTimer = nil }
    }

    /// Fires due timers in time order (ties by client order).
    func fireTimers(until limit: Int64) {
        while true {
            let due = clients
                .filter { $0.isControl && ($0.subscriptionTimer ?? .max) <= limit }
                .min { ($0.subscriptionTimer!, $0.index) < ($1.subscriptionTimer!, $1.index) }
            guard let client = due, let deadline = client.subscriptionTimer else { return }
            if deadline > now { now = deadline }
            checkSubscriptions(client)
            runServerLoop()
        }
    }

    /// control_check_subs_timer (control.c:1045-1074): re-arm for one second,
    /// then check every subscription in name order. Each check writes only
    /// values that changed since its last write.
    func checkSubscriptions(_ client: ClientState) {
        client.subscriptionTimer = now + 1_000_000
        guard let session = session(of: client) else { return }
        for name in client.subscriptions.keys.sorted() {
            let subscription = client.subscriptions[name]!
            switch subscription.kind {
            case .session:
                // control_check_subs_session (control.c:843-862).
                let value = expandFormat(subscription.format, formatContext(client: client, session: session, winlinkIndex: nil, window: nil))
                if subscription.last == value { continue }
                write(client, "%subscription-changed \(name) $\(session.id) - - - : \(value)")
                subscription.last = value
            case .allPanes, .pane:
                // control_check_subs_pane / _all_panes (control.c:866-954):
                // only winlinks of the subscriber's own session.
                for index in session.sortedIndexes {
                    let window = windowState(session.winlinks[index]!)
                    if case .pane(let id) = subscription.kind, id != window.paneID { continue }
                    let value = expandFormat(subscription.format, formatContext(client: client, session: session, winlinkIndex: index, window: window))
                    let key = "\(window.paneID):\(index)"
                    if subscription.lastByKey[key] == value { continue }
                    write(client, "%subscription-changed \(name) $\(session.id) @\(window.id) \(index) %\(window.paneID) : \(value)")
                    subscription.lastByKey[key] = value
                }
            case .allWindows, .window:
                // control_check_subs_window / _all_windows (control.c:958-1041).
                for index in session.sortedIndexes {
                    let window = windowState(session.winlinks[index]!)
                    if case .window(let id) = subscription.kind, id != window.id { continue }
                    let value = expandFormat(subscription.format, formatContext(client: client, session: session, winlinkIndex: index, window: window))
                    let key = "\(window.id):\(index)"
                    if subscription.lastByKey[key] == value { continue }
                    write(client, "%subscription-changed \(name) $\(session.id) @\(window.id) \(index) - : \(value)")
                    subscription.lastByKey[key] = value
                }
            }
        }
    }
}
