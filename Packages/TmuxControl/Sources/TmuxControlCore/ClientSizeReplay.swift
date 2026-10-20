import Foundation

/// The commands a sizing participant sends when it advertises its grid over a
/// tmux control client.
///
/// `refresh-client -C` records the client's size, but under `window-size
/// latest` tmux applies it only while this client is the window's *latest*
/// client — and *latest* is taken by any client that attaches or types, even
/// one attached with `ignore-size`, which tmux then refuses to size from. From
/// that moment every replay is answered with "no size change" and the window
/// freezes at whatever grid it last had while this client renders its newer
/// one (verified against tmux 3.4 and 3.6a: `w->latest` is set in
/// `server_client_set_session`, the key path, `MSG_RESIZE` and
/// `cmd_select_window_exec`, never by `refresh-client`). A no-op
/// `select-window` on the window that is already current is the one
/// control-mode command that does make this client latest (it ends with
/// `latest = c` and a recalculation), so the inline path fences every replay
/// with it. The mosh side channel's visible client is `ignore-size` and
/// steals *latest* on every key or SSP resize, so that path uses the same
/// targetless fence inside `TmuxWindowSizeReplay`'s resize/fence/unset list.
/// This advertisement must precede that list: unset must recalculate from
/// the control client's newest stored grid.
///
/// The fence names no window. Without `-t`, tmux resolves `select-window` to
/// the client's current window *when the command executes* — after the
/// refresh queued ahead of it — so it is always a no-op on the window that is
/// current then, and can never switch every attached client to a window a
/// peer has already left, which an explicit target built from this client's
/// mirror could. Each command is its own control-mode reply block (`;`
/// chaining still yields one block per command, probed on tmux 3.4), so the
/// fence is one extra FIFO entry per replay. A take-back claim sends its own
/// fence with its confirmation on top; a replay that belongs to a claim adds
/// none.
///
/// Shared by both platforms so the replay sequence cannot drift.
public enum TmuxClientSizeReplay {
    public enum Path: Equatable, Sendable {
        /// The `-CC` client is this device's only client in the session.
        case inline
        /// The `-CC` client sizes on behalf of an `ignore-size` mosh client.
        case sideChannel
    }

    /// The fence: a targetless `select-window`, resolved by tmux to the
    /// current window at execution.
    public static let latestFenceCommand = "select-window"

    /// Commands in send order, or empty for a grid tmux would reject.
    /// `belongsToClaim` marks the replay a take-back claim issues: the claim
    /// acks it and fences it itself, so the refresh goes out alone.
    ///
    /// `sizeAlreadyAdvertised` (P6) drops the refresh when this connection
    /// already holds exactly this grid. The inline fence still goes out on
    /// its own: `cmd_select_window_exec` makes this client the window's
    /// `latest` and then calls `recalculate_sizes()`, which sizes the window
    /// from the latest client's *stored* tty size — the one the earlier `-C`
    /// set — and resizes only if that differs (`recalculate_size`'s
    /// "no size change" test, which `-C`'s `recalculate_sizes_now(1)`
    /// bypasses). So the fence alone returns the window to our grid after a
    /// peer took `latest`, and costs no resize when nothing moved. A claim's
    /// replay with an advertised size sends nothing; its own fence follows.
    public static func commands(
        columns: Int,
        rows: Int,
        path: Path,
        belongsToClaim: Bool = false,
        sizeAlreadyAdvertised: Bool = false
    ) -> [String] {
        guard columns >= 1, rows >= 1,
              columns <= TmuxClientGeometry.maximumDimension,
              rows <= TmuxClientGeometry.maximumDimension
        else { return [] }
        var commands = sizeAlreadyAdvertised ? [] : ["refresh-client -C \(columns),\(rows)"]
        if path == .inline, !belongsToClaim { commands.append(latestFenceCommand) }
        return commands
    }
}
