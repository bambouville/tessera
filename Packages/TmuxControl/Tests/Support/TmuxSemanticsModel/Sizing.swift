import Foundation

// Window sizing: resize.c. `recalculate_sizes()` is the deferred pass
// (`now` = 0); `recalculate_sizes_now(1)` is the forced pass that
// `refresh-client -C` uses.

extension TmuxServerModel {
    /// ignore_client_size (resize.c:68-96):
    /// - an unattached client never sizes;
    /// - an `ignore-size` client is ignored whenever any attached client
    ///   without `ignore-size` exists (resize.c:77-90), even one that is itself
    ///   ignored, such as a control client that never sent a size;
    /// - a control client is ignored until `refresh-client -C` gives it a size
    ///   (CLIENT_SIZECHANGED) or, from 3.3a, a per-window size
    ///   (CLIENT_WINDOWSIZECHANGED) (resize.c:91-94; 3.2 resize.c:90).
    func ignoreClientSize(_ client: ClientState) -> Bool {
        guard client.sessionID != nil else { return true }
        if !client.flags.isDisjoint(with: .noSizeFlags) { return true }
        if client.flags.contains(.ignoreSize) {
            for loop in clients {
                guard loop.sessionID != nil, loop.flags.isDisjoint(with: .noSizeFlags) else { continue }
                if !loop.flags.contains(.ignoreSize) { return true }
            }
        }
        if client.isControl {
            let sized = client.flags.contains(.sizeChanged)
                || (version.hasPerWindowClientSize && client.flags.contains(.windowSizeChanged))
            if !sized { return true }
        }
        return false
    }

    /// clients_with_window (resize.c:98-111): sizing clients whose session
    /// contains the window, counted up to two.
    func clientsWithWindow(_ window: WindowState) -> Int {
        var n = 0
        for loop in clients {
            guard !ignoreClientSize(loop), let session = session(of: loop), sessionHas(session, window: window.id) else { continue }
            n += 1
            if n > 1 { break }
        }
        return n
    }

    /// status_line_size: 0 for a control client or one with CLIENT_STATUSOFF,
    /// otherwise the session's status lines. CLIENT_STATUSOFF is refreshed by
    /// recalculate_sizes_now (resize.c:458-461). (status.c is not in the
    /// verified source subset; the rule is the one resize.c relies on.)
    func statusLineSize(_ client: ClientState) -> Int {
        if client.isControl || client.flags.contains(.statusOff) { return 0 }
        guard let session = session(of: client) else { return statusLines(nil) }
        return statusLines(session)
    }

    /// recalculate_size_skip_client (resize.c:343-357).
    func recalculateSkip(_ loop: ClientState, current aggressive: Bool, window: WindowState) -> Bool {
        guard let session = session(of: loop), let currentWindow = session.currentWindowID else { return true }
        if aggressive { return currentWindow != window.id }
        return !sessionHas(session, window: window.id)
    }

    /// clients_calculate_size (resize.c:113-264) for `recalculate_size`
    /// (no creating client). Under `latest` with more than one sizing client
    /// on the window, only `w->latest` may size it (resize.c:144-170): if
    /// `latest` is an ignored client (an `ignore-size` mosh terminal, an
    /// unsized control client) or a lost one, no client qualifies; then,
    /// unless a per-window client size caps both dimensions
    /// (resize.c:217-244), the result is "no size" (resize.c:263) and the
    /// window keeps its current size.
    func clientsCalculateSize(policy: WindowSizePolicy, aggressive: Bool, window: WindowState) -> CellSize? {
        let maximum = Int(UInt32.max)
        var sx: Int, sy: Int
        switch policy {
        case .largest:
            (sx, sy) = (0, 0)
        case .manual:
            guard version.manualSizeThroughRecalculation else { return nil }
            (sx, sy) = (window.manualSize.columns, window.manualSize.rows)
        case .smallest, .latest:
            (sx, sy) = (maximum, maximum)
        }
        let n = policy == .latest ? clientsWithWindow(window) : 0
        if policy != .manual {
            for loop in clients {
                if ignoreClientSize(loop) { continue }
                if recalculateSkip(loop, current: aggressive, window: window) { continue }
                if policy == .latest, n > 1, loop.index != window.latest { continue }
                let cx: Int, cy: Int
                if version.hasPerWindowClientSize, let cw = loop.windowSizes[window.id], cw.columns != 0, cw.rows != 0 {
                    (cx, cy) = (cw.columns, cw.rows)
                } else {
                    (cx, cy) = (loop.tty.columns, loop.tty.rows - statusLineSize(loop))
                }
                if policy == .largest {
                    sx = max(sx, cx)
                    sy = max(sy, cy)
                } else {
                    sx = min(sx, cx)
                    sy = min(sy, cy)
                }
            }
        }
        // resize.c:217-244: never exceed a per-window client size (3.3a+).
        if version.hasPerWindowClientSize {
            for loop in clients {
                if ignoreClientSize(loop) || recalculateSkip(loop, current: aggressive, window: window) { continue }
                guard loop.flags.contains(.windowSizeChanged), let cw = loop.windowSizes[window.id] else { continue }
                if cw.columns != 0, sx > cw.columns { sx = cw.columns }
                if cw.rows != 0, sy > cw.rows { sy = cw.rows }
            }
        }
        switch policy {
        case .manual: return CellSize(sx, sy)
        case .largest: return sx != 0 && sy != 0 ? CellSize(sx, sy) : nil
        case .smallest, .latest: return sx != maximum && sy != maximum ? CellSize(sx, sy) : nil
        }
    }

    /// recalculate_size (resize.c:359-424). Unless `now` is set, an unchanged
    /// size is not a change (resize.c:385-395): no resize and no
    /// `%layout-change`. With `now`, or for a manual window, the resize is
    /// immediate (resize.c:413-414); otherwise WINDOW_RESIZE is set
    /// (resize.c:415-423) and server_client_loop applies it
    /// (server-client.c:2106-2114) once an attached session shows the window
    /// (server_client_check_window_resize, server-client.c:2144-2159).
    func recalculateSize(_ window: WindowState, now forced: Bool) {
        recalculationPasses += 1
        let policy = windowSizePolicy(window)
        let aggressive = flagOption(windowOptionValue(window, "aggressive-resize"))
        guard var size = clientsCalculateSize(policy: policy, aggressive: aggressive, window: window) else {
            return
        }
        if !forced {
            let reference = window.pendingResize ?? window.size
            if reference == size { return }
        }
        size = CellSize(size.columns, size.rows)
        if forced || policy == .manual {
            resizeWindow(window, to: size)
        } else {
            window.pendingResize = size
        }
    }

    /// recalculate_sizes / recalculate_sizes_now (resize.c:426-467): refresh
    /// each sizing client's CLIENT_STATUSOFF, then every window.
    func recalculateSizes(now forced: Bool = false) {
        for client in clients {
            guard client.sessionID != nil, !ignoreClientSize(client) else { continue }
            let lines = statusLines(session(of: client))
            if client.tty.rows <= lines || client.isControl {
                client.flags.insert(.statusOff)
            } else {
                client.flags.remove(.statusOff)
            }
        }
        for window in windowsInOrder {
            recalculateSize(window, now: forced)
        }
    }

    /// resize_window (resize.c:25-66): clamp, resize the layout (the single
    /// pane follows the window, queueing a pane resize only when its size
    /// changes, window.c:1066-1074), redraw every client showing the window,
    /// and notify window-layout-changed, even when nothing changed (W10).
    /// Clears WINDOW_RESIZE. A one-pane window is never zoomed (window_zoom
    /// refuses it, window.c:656-657), so the unzoom/rezoom path does not arise.
    func resizeWindow(_ window: WindowState, to requested: CellSize) {
        let size = CellSize(WindowLimits.clamp(requested.columns), WindowLimits.clamp(requested.rows))
        if window.size != size { window.paneResizes += 1 }
        window.size = size
        window.resizeCount += 1
        redrawWindow(window)
        enqueueNotification(.windowLayoutChanged(window: window.id))
        window.pendingResize = nil
    }

    func windowSizePolicy(_ window: WindowState) -> WindowSizePolicy {
        WindowSizePolicy(rawValue: windowOptionValue(window, "window-size") ?? "latest") ?? .latest
    }

    /// `status` as a line count (off = 0, on = 1, 2-5).
    func statusLines(_ session: SessionState?) -> Int {
        let value = session.flatMap { sessionOptionValue($0, "status") } ?? globalSessionOptions["status"] ?? "on"
        switch value {
        case "off": return 0
        case "on": return 1
        default: return Int(value) ?? 1
        }
    }
}
