import Foundation

// Who moves `w->latest`, and client lifecycle: server-client.c.
// `latest` is set only by attach (server_client_set_session), terminal key
// input and non-control MSG_RESIZE (server_client_update_latest),
// `select-window` (cmd-select-window.c:145-146), window creation by a client
// (spawn.c:165) and, from 3.3a, lost-client handoff. `refresh-client -C`
// never sets it.

extension TmuxServerModel {
    /// server_client_set_session (server-client.c:361-390): attach or switch.
    /// 3.3a+ recalculate *before* `latest = c` (server-client.c:375, 380), so
    /// the attach's own deferred pass still sizes from the previous `latest`;
    /// 3.2's attach-session sets `latest` first and recalculates at the end
    /// (3.2 cmd-attach-session.c:137, 168, 175). Session activity is updated
    /// (server-client.c:377); client activity is not.
    func setSession(_ client: ClientState, _ session: SessionState?) {
        let old = client.sessionID
        if let session, let old, old != session.id {
            client.lastSessionID = old
        } else if session == nil {
            client.lastSessionID = nil
        }
        client.sessionID = session?.id
        client.flags.insert(.focused)
        guard let session else {
            if version.checksUnattachedOnSessionChange { checkUnattached() }
            return
        }
        if version.recalculatesBeforeSettingLatestOnAttach {
            recalculateSizes()
        }
        updateSessionActivity(session, from: nil)
        if let windowID = session.currentWindowID {
            windowState(windowID).latest = client.index
        }
        if !version.recalculatesBeforeSettingLatestOnAttach {
            recalculateSizes()
        }
        enqueueNotification(.clientSessionChanged(client: client.index))
        redrawClient(client)
        if version.checksUnattachedOnSessionChange { checkUnattached() }
    }

    /// server_check_unattached (server-fn.c:456-484): every session with no
    /// attached client whose destroy-unattached allows it is destroyed, in
    /// name order. `on` always; `keep-last` only while another session shares
    /// its group; `keep-group` unless it is alone in its group. 3.2 and 3.3a
    /// test a flag (3.2 server-fn.c:469-482, 3.3a :453-466).
    func checkUnattached() {
        for session in sessionsInOrder where sessions[session.id] != nil && attachedCount(session) == 0 {
            let groupCount = session.groupName.flatMap { groups[$0]?.count }
            switch sessionOptionValue(session, "destroy-unattached") ?? "off" {
            case "on":
                break
            case "keep-last":
                guard let groupCount, groupCount > 1 else { continue }
            case "keep-group":
                if groupCount == 1 { continue }
            default:
                continue
            }
            destroySession(session)
        }
    }

    /// session_destroy (session.c:200-233) with notify: the session leaves the
    /// tree and notifies session-closed (`%sessions-changed` to every control
    /// client, control-notify.c:213-222), leaves its group (session.c:566-578;
    /// a group of one survives), then unlinks every window with
    /// window-unlinked, whose delivery tells a client whose session still
    /// links the window `%window-close` (control-notify.c:94-109). A window no
    /// session links any more is destroyed (winlink_remove, window.c:194-205;
    /// window_remove_ref, window.c:392-399). tmux unlinks from RB_ROOT, an
    /// order that depends on the tree's shape; the model unlinks in index
    /// order (a known gap for sessions with several windows).
    func destroySession(_ session: SessionState) {
        guard sessions[session.id] != nil else { return }
        sessions[session.id] = nil
        enqueueNotification(.sessionsChanged)
        if let name = session.groupName {
            groups[name]?.removeAll { $0 == session.id }
            if groups[name]?.isEmpty == true { groups[name] = nil }
        }
        session.lastWindows.removeAll()
        for index in session.sortedIndexes {
            guard let windowID = session.winlinks[index] else { continue }
            enqueueNotification(.windowUnlinked(session: session.id, window: windowID))
            session.winlinks[index] = nil
            if !sessions.values.contains(where: { sessionHas($0, window: windowID) }) {
                destroyWindow(windowState(windowID))
            }
        }
    }

    /// session_update_activity (session.c:271-298).
    func updateSessionActivity(_ session: SessionState, from time: Int64?) {
        session.lastActivityTime = session.activityTime
        session.activityTime = time ?? now
    }

    /// server_client_update_latest (server-client.c:1828-1844): make the
    /// client latest for its session's current window and, under `latest`,
    /// run a deferred recalculation of that window.
    func updateLatest(_ client: ClientState) {
        guard let session = session(of: client), let windowID = session.currentWindowID else { return }
        let window = windowState(windowID)
        if window.latest == client.index { return }
        window.latest = client.index
        if windowSizePolicy(window) == .latest {
            recalculateSize(window, now: false)
        }
    }

    /// server_client_key_callback (server-client.c:1851-2055): a terminal key
    /// updates the client's and its session's activity (server-client.c:1874-1876)
    /// and makes the client latest (server-client.c:2050-2052), even for an
    /// `ignore-size` client, which recalculate then refuses to size from.
    func keyCallback(_ client: ClientState) {
        guard let session = session(of: client), client.flags.isDisjoint(with: .noSizeFlags) else { return }
        client.activityTime = now
        updateSessionActivity(session, from: client.activityTime)
        updateLatest(client)
    }

    /// MSG_RESIZE (server-client.c:2763-2780): ignored for control clients;
    /// otherwise `latest` moves first (with the old size), then the tty size
    /// is read and a deferred recalculation runs.
    func handleResizeMessage(_ client: ClientState, newSize: CellSize) {
        guard !client.isControl else { return }
        updateLatest(client)
        client.tty = newSize
        recalculateSizes()
        redrawClient(client)
    }

    /// server_client_lost (server-client.c:394-470). The client leaves the
    /// list first (server-client.c:414); an attached client then hands
    /// `latest` off (3.3a+) and `client-detached` is broadcast
    /// (server-client.c:417-420); every loss ends with `recalculate_sizes()`
    /// and `server_check_unattached()` (server-client.c:467-468).
    func loseClient(_ client: ClientState) {
        client.flags.insert(.dead)
        client.windowSizes.removeAll()
        clients.removeAll { $0 === client }
        lostClients[client.index] = client
        if client.flags.contains(.attached) {
            if version.handsOffLatestOnLostClient {
                attachedLost(client)
            }
            enqueueNotification(.clientDetached(name: client.name))
        }
        // control_stop frees the subscriptions and their timer.
        client.subscriptions.removeAll()
        client.subscriptionTimer = nil
        recalculateSizes()
        // server-client.c:468 (3.2 server-client.c:347).
        checkUnattached()
    }

    /// server_client_attached_lost (server-client.c:328-357): for every
    /// window whose `latest` was the lost client, the remaining client with
    /// the newest `activity_time` among those whose session's *current*
    /// window is that window becomes latest. Neither `ignore-size` nor
    /// control mode excludes a candidate. With no candidate, `latest` keeps
    /// pointing at the lost client.
    func attachedLost(_ lost: ClientState) {
        for window in windowsInOrder where window.latest == lost.index {
            var found: ClientState?
            for loop in clients where loop !== lost {
                guard let session = session(of: loop), session.currentWindowID == window.id else { continue }
                if found == nil || loop.activityTime > found!.activityTime {
                    found = loop
                }
            }
            if let found {
                updateLatest(found)
            }
        }
    }

    /// server_client_set_flags (server-client.c:3121-3158): comma-separated,
    /// `!` clears, but from 3.3a never clears read-only
    /// (server-client.c:3147-3152). Control-only flags come from
    /// server_client_control_flags (server-client.c:3102-3117): `pause-after`
    /// (age 0) or `pause-after=%u` (the age times 1000, wrapping as a u_int);
    /// anything else that starts with pause-after is ignored. Setting a flag
    /// never recalculates.
    func setClientFlags(_ client: ClientState, _ text: String) {
        for raw in text.split(separator: ",", omittingEmptySubsequences: false) {
            var name = Substring(raw)
            let negate = name.hasPrefix("!")
            if negate { name = name.dropFirst() }
            var flag: ClientFlags = []
            if client.isControl {
                switch name {
                case "no-output": flag = .noOutput
                case "wait-exit": flag = .waitExit
                default:
                    if name == "pause-after" {
                        client.pauseAge = 0
                        flag = .pauseAfter
                    } else if name.hasPrefix("pause-after=") {
                        var scanner = ScanfScanner(String(name.dropFirst("pause-after=".count)))
                        if let age = scanner.unsigned() {
                            client.pauseAge = UInt32(truncatingIfNeeded: age) &* 1000
                            flag = .pauseAfter
                        }
                    }
                }
            }
            switch name {
            case "read-only": flag = .readOnly
            case "ignore-size": flag = .ignoreSize
            case "active-pane": flag = .activePane
            default: break
            }
            guard !flag.isEmpty else { continue }
            if negate {
                if version.keepsReadOnlyOnNegatedFlag, client.flags.contains(.readOnly) {
                    flag.remove(.readOnly)
                }
                client.flags.subtract(flag)
            } else {
                client.flags.formUnion(flag)
            }
        }
    }

    /// server_client_get_flags (server-client.c:3162-3196).
    func clientFlagsString(_ client: ClientState) -> String {
        var parts: [String] = []
        if client.flags.contains(.attached) { parts.append("attached") }
        if client.flags.contains(.focused) { parts.append("focused") }
        if client.isControl { parts.append("control-mode") }
        if client.flags.contains(.ignoreSize) { parts.append("ignore-size") }
        if client.flags.contains(.noOutput) { parts.append("no-output") }
        if client.flags.contains(.waitExit) { parts.append("wait-exit") }
        if client.flags.contains(.pauseAfter) { parts.append("pause-after=\(client.pauseAge / 1000)") }
        if client.flags.contains(.readOnly) { parts.append("read-only") }
        if client.flags.contains(.activePane) { parts.append("active-pane") }
        if client.flags.contains(.suspended) { parts.append("suspended") }
        return parts.joined(separator: ",")
    }

    /// session_set_current (session.c:489-511): 1 when already current; 0
    /// after switching, pushing the old window on the last-window stack and
    /// notifying session-window-changed.
    @discardableResult
    func setCurrentWindow(_ session: SessionState, index: Int) -> Int {
        guard let windowID = session.winlinks[index] else { return -1 }
        if index == session.currentIndex, session.winlinks[session.currentIndex] != nil { return 1 }
        session.lastWindows.removeAll { $0 == index }
        if session.winlinks[session.currentIndex] != nil {
            session.lastWindows.insert(session.currentIndex, at: 0)
        }
        session.currentIndex = index
        windowState(windowID).activityTime = now
        enqueueNotification(.sessionWindowChanged(session: session.id))
        return 0
    }
}
