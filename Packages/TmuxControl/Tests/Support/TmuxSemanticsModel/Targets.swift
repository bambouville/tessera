import Foundation

// Target resolution: cmd-find.c.

enum FindType {
    case session, window, pane
}

struct FindFlags: OptionSet {
    let rawValue: Int
    static let quiet = FindFlags(rawValue: 1 << 0)
    static let canFail = FindFlags(rawValue: 1 << 1)
    static let preferUnattached = FindFlags(rawValue: 1 << 2)
}

enum FindResult {
    case found(FindState)
    case failed(String?)
}

extension TmuxServerModel {
    /// cmd_find_session_better / cmd_find_best_session (cmd-find.c:133-172):
    /// the session with the newest `activity_time`; ties keep the first in
    /// name order (`timercmp >` is strict).
    func bestSession(_ candidates: [SessionState], preferUnattached: Bool = false) -> SessionState? {
        var best: SessionState?
        for session in candidates.sorted(by: { $0.name < $1.name }) {
            guard let current = best else { best = session; continue }
            if preferUnattached {
                let currentAttached = attachedCount(current) != 0
                if currentAttached && attachedCount(session) == 0 { best = session; continue }
                if !currentAttached && attachedCount(session) != 0 { continue }
            }
            if session.activityTime > current.activityTime { best = session }
        }
        return best
    }

    /// cmd_find_best_session_with_window (cmd-find.c:175-202): a bare `@W`
    /// resolves to the most recently active session *containing* W, which is
    /// not necessarily the issuer's (W2), with the lookup's flags, so
    /// attach-session's PREFER_UNATTACHED applies (cmd-find.c:193), then
    /// cmd_find_best_winlink_with_window (cmd-find.c:208-231): that session's
    /// current winlink if it shows W, else its lowest-index winlink of W.
    func bestSessionWithWindow(_ windowID: Int, flags: FindFlags = []) -> FindState? {
        let candidates = sessions.values.filter { sessionHas($0, window: windowID) }
        guard let session = bestSession(candidates, preferUnattached: flags.contains(.preferUnattached)) else { return nil }
        return bestWinlink(session: session, window: windowID)
    }

    func bestWinlink(session: SessionState, window windowID: Int) -> FindState? {
        let index: Int
        if session.currentWindowID == windowID {
            index = session.currentIndex
        } else if let first = session.sortedIndexes.first(where: { session.winlinks[$0] == windowID }) {
            index = first
        } else {
            return nil
        }
        return FindState(session: session.id, winlinkIndex: index, window: windowID, pane: windowState(windowID).paneID)
    }

    /// cmd_find_from_session (cmd-find.c:723-...): the session's current
    /// winlink and active pane.
    func findState(session: SessionState) -> FindState {
        let windowID = session.currentWindowID!
        return FindState(session: session.id, winlinkIndex: session.currentIndex, window: windowID, pane: windowState(windowID).paneID)
    }

    /// cmd_find_from_client (cmd-find.c:859-916): an attached client's
    /// session and current window; otherwise cmd_find_from_nothing
    /// (cmd-find.c:819-836), the best session of all under the lookup's flags.
    func findState(fromClient client: ClientState?, flags: FindFlags = []) -> FindState? {
        if let client, let session = session(of: client) {
            return findState(session: session)
        }
        guard let session = bestSession(Array(sessions.values), preferUnattached: flags.contains(.preferUnattached)) else { return nil }
        return findState(session: session)
    }

    /// cmd_find_target (cmd-find.c:922-1239), the subset the model supports:
    /// empty target = current; `$id`, names, client names; `@id`, indexes and
    /// window names; `%id`; `S:W` and `S:` forms. The current state comes from
    /// the command list's state when a previous command set it (for example
    /// `select-window`, cmd-select-window.c:139-140), else from the issuing
    /// client (cmd-find.c:974-985).
    func findTarget(_ target: String?, type: FindType, flags: FindFlags, client: ClientState, state: CommandState) -> FindResult {
        let quiet = flags.contains(.quiet) || flags.contains(.canFail)
        func fail(_ message: String?) -> FindResult {
            if flags.contains(.canFail) { return .found(FindState()) }
            return .failed(quiet ? nil : message)
        }
        let current: FindState
        if let stateCurrent = state.current, stateCurrent.isValid {
            current = stateCurrent
        } else if let fromClient = findState(fromClient: client, flags: flags) {
            current = fromClient
        } else {
            return fail("no current target")
        }
        guard let target, !target.isEmpty else { return .found(current) }

        // Split into session, window and pane parts (cmd-find.c:1034-1082).
        var session: String?
        var window: String?
        var pane: String?
        var windowOnly = false
        var paneOnly = false
        if let colon = target.firstIndex(of: ":") {
            session = String(target[..<colon])
            let rest = String(target[target.index(after: colon)...])
            if let period = rest.firstIndex(of: ".") {
                window = String(rest[..<period])
                pane = String(rest[rest.index(after: period)...])
                paneOnly = true
            } else {
                window = rest
            }
            windowOnly = true
        } else if let period = target.firstIndex(of: ".") {
            window = String(target[..<period])
            pane = String(target[target.index(after: period)...])
            paneOnly = true
        } else if target.hasPrefix("$") {
            session = target
        } else if target.hasPrefix("@") {
            window = target
        } else if target.hasPrefix("%") {
            pane = target
        } else {
            switch type {
            case .session: session = target
            case .window: window = target
            case .pane: pane = target
            }
        }
        var exactSession = false
        var exactWindow = false
        if let value = session, value.hasPrefix("=") { session = String(value.dropFirst()); exactSession = true }
        if let value = window, value.hasPrefix("=") { window = String(value.dropFirst()); exactWindow = true }
        if session?.isEmpty == true { session = nil }
        if window?.isEmpty == true { window = nil }
        if pane?.isEmpty == true { pane = nil }
        // Nothing left (for example `-t :`): the current target (cmd-find.c:1202-1207).
        if session == nil, window == nil, pane == nil { return .found(current) }

        // cmd-find.c:1128-1200.
        if let sessionName = session {
            guard let found = lookupSession(sessionName, exact: exactSession) else {
                return fail("can't find session: \(sessionName)")
            }
            switch (window, pane) {
            case (nil, nil):
                return .found(findState(session: found))
            case (let windowName?, nil):
                return lookupWindow(windowName, in: found, exact: exactWindow).map { .found($0) }
                    ?? fail("can't find window: \(windowName)")
            case (nil, let paneName?):
                // cmd_find_get_pane_with_session (cmd-find.c:537-557).
                if paneName.hasPrefix("%") {
                    guard let id = Int(paneName.dropFirst()), let window = windows.values.first(where: { $0.paneID == id }),
                          let state = bestWinlink(session: found, window: window.id)
                    else { return fail("can't find pane: \(paneName)") }
                    return .found(state)
                }
                return paneInWindow(paneName, findState(session: found)).map { .found($0) } ?? fail("can't find pane: \(paneName)")
            case (let windowName?, let paneName?):
                guard let state = lookupWindow(windowName, in: found, exact: exactWindow) else {
                    return fail("can't find window: \(windowName)")
                }
                return paneInWindow(paneName, state).map { .found($0) } ?? fail("can't find pane: \(paneName)")
            }
        }
        if let windowName = window {
            guard let state = getWindow(windowName, only: windowOnly, exact: exactWindow, current: current, flags: flags) else {
                return fail("can't find window: \(windowName)")
            }
            guard let paneName = pane else { return .found(state) }
            return paneInWindow(paneName, state).map { .found($0) } ?? fail("can't find pane: \(paneName)")
        }
        let paneName = pane!
        return getPane(paneName, only: paneOnly, current: current, flags: flags).map { .found($0) } ?? fail("can't find pane: \(paneName)")
    }

    /// cmd_find_get_window (cmd-find.c:311-341): `@id` anywhere (best
    /// session holding it), else a window of the current session, else
    /// (unless window-only) a session's current window.
    func getWindow(_ name: String, only: Bool, exact: Bool, current: FindState, flags: FindFlags) -> FindState? {
        if name.hasPrefix("@") {
            guard let id = Int(name.dropFirst()), windows[id] != nil else { return nil }
            return bestSessionWithWindow(id, flags: flags)
        }
        if let session = current.session.flatMap({ sessions[$0] }),
           let state = lookupWindow(name, in: session, exact: exact) {
            return state
        }
        if !only, let found = lookupSession(name, exact: false) {
            return findState(session: found)
        }
        return nil
    }

    /// cmd_find_get_pane (cmd-find.c:500-530): `%id` anywhere; otherwise a
    /// pane of the current window, then (unless pane-only) a window or a
    /// session of that name.
    func getPane(_ name: String, only: Bool, current: FindState, flags: FindFlags) -> FindState? {
        if name.hasPrefix("%") {
            guard let id = Int(name.dropFirst()), let window = windows.values.first(where: { $0.paneID == id }) else { return nil }
            return bestSessionWithWindow(window.id, flags: flags)
        }
        if let state = paneInWindow(name, current) { return state }
        if !only, let state = getWindow(name, only: false, exact: false, current: current, flags: flags) {
            return state
        }
        return nil
    }

    /// cmd_find_get_pane_with_window (cmd-find.c:564-640) for single-pane
    /// windows: the pane's own `%id`, or index 0 (pane-base-index 0).
    func paneInWindow(_ name: String, _ state: FindState) -> FindState? {
        guard let windowID = state.window else { return nil }
        let paneID = windowState(windowID).paneID
        if name.hasPrefix("%") {
            return Int(name.dropFirst()) == paneID ? state : nil
        }
        if name == "0" || name == "+0" { return state }
        return nil
    }

    /// cmd_find_get_session (cmd-find.c:247-308): `$id`, exact name, a
    /// client's session by client name, then a unique name prefix (fnmatch
    /// patterns are not modelled).
    func lookupSession(_ name: String, exact: Bool) -> SessionState? {
        if name.hasPrefix("$") {
            return Int(name.dropFirst()).flatMap { sessions[$0] }
        }
        if let session = sessions.values.first(where: { $0.name == name }) { return session }
        if let client = clients.first(where: { $0.name == name }), let session = session(of: client) { return session }
        if exact { return nil }
        let prefixed = sessions.values.filter { $0.name.hasPrefix(name) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// cmd_find_get_window_with_session (cmd-find.c:347-497): `@id` must be
    /// in the session (else "can't find window"), then an index, then an
    /// exact window name, then (unless `=`) a unique name prefix. Offsets,
    /// `!`, `^`, `$` and fnmatch patterns are not modelled.
    func lookupWindow(_ name: String, in session: SessionState, exact: Bool = false) -> FindState? {
        func state(_ index: Int) -> FindState {
            let windowID = session.winlinks[index]!
            return FindState(session: session.id, winlinkIndex: index, window: windowID, pane: windowState(windowID).paneID)
        }
        if name.hasPrefix("@") {
            guard let id = Int(name.dropFirst()), sessionHas(session, window: id) else { return nil }
            return bestWinlink(session: session, window: id)
        }
        if !name.hasPrefix("+"), !name.hasPrefix("-"), let index = Int(name), session.winlinks[index] != nil {
            return state(index)
        }
        let named = session.sortedIndexes.filter { windowState(session.winlinks[$0]!).name == name }
        if named.count == 1 { return state(named[0]) }
        if named.count > 1 || exact { return nil }
        let prefixed = session.sortedIndexes.filter { windowState(session.winlinks[$0]!).name.hasPrefix(name) }
        return prefixed.count == 1 ? state(prefixed[0]) : nil
    }

    /// cmd_find_client (cmd-find.c:1274-...) for an explicit client name, or
    /// cmd_find_current_client (cmd-find.c:1243-1271) without one: the issuer
    /// when attached, else the most recently active client of the best
    /// session.
    func findClient(_ name: String?, issuer: ClientState) -> ClientState? {
        if let name {
            // Only attached clients are candidates (cmd-find.c:1291-1305).
            return clients.first { $0.sessionID != nil && $0.name == name }
        }
        if issuer.sessionID != nil { return issuer }
        guard let session = bestSession(Array(sessions.values)) else { return nil }
        return bestClient(of: session)
    }

    /// cmd_find_best_client (cmd-find.c:112-130).
    func bestClient(of session: SessionState?) -> ClientState? {
        let scope = session.flatMap { attachedCount($0) == 0 ? nil : $0 }
        var best: ClientState?
        for client in clients where client.sessionID != nil {
            if let scope, client.sessionID != scope.id { continue }
            if best == nil || client.activityTime > best!.activityTime { best = client }
        }
        return best
    }
}
