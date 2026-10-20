import Foundation

// A deterministic model of the tmux server behaviours that Tessera's grid
// authority protocol depends on. Every rule cites the tmux function it models,
// with its file:line in the tmux 3.4 sources unless another version is named.
// The model is single-threaded and has no wall clock: time moves only through
// `advance(seconds:)` (and one microsecond per external event, so two events
// never share an activity timestamp).

/// The tmux releases whose differences the model encodes.
public enum TmuxVersion: String, CaseIterable, Comparable, Sendable {
    case v3_2 = "3.2"
    case v3_3a = "3.3a"
    case v3_4 = "3.4"
    case v3_6a = "3.6a"

    private var ordinal: Int {
        switch self {
        case .v3_2: 0
        case .v3_3a: 1
        case .v3_4: 2
        case .v3_6a: 3
        }
    }

    public static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    /// `server_client_attached_lost` (server-client.c:328-357) hands `latest`
    /// to the remaining client with the newest activity. 3.2's
    /// `server_client_lost` (3.2 server-client.c:296-300) has no handoff, so
    /// `w->latest` keeps pointing at the lost client.
    public var handsOffLatestOnLostClient: Bool { self >= .v3_3a }

    /// `refresh-client -C @W:WxH` (cmd-refresh-client.c:89-114, present from
    /// 3.3a; 3.2 cmd-refresh-client.c:208 parses only `WxH`/`W,H`).
    public var hasPerWindowClientSize: Bool { self >= .v3_3a }

    /// `list-clients -f` (cmd-list-clients.c:44 "F:f:t:"; 3.2 and 3.3a accept
    /// only "F:t:").
    public var hasListClientsFilter: Bool { self >= .v3_4 }

    /// 3.3a+ `server_client_set_session` (server-client.c:375-380) runs
    /// `recalculate_sizes()` *before* `latest = c`; 3.2's attach
    /// (3.2 cmd-attach-session.c:137, 168, 175) sets `latest` first and
    /// recalculates afterwards.
    public var recalculatesBeforeSettingLatestOnAttach: Bool { self >= .v3_3a }

    /// 3.3a+ manual windows keep `manual_sx/sy` and size through
    /// `clients_calculate_size` (resize.c:130-133, 251-253); 3.2 returns "no
    /// size" for manual windows (3.2 resize.c:119-121) and `resize-window`
    /// resizes directly (3.2 cmd-resize-window.c:111).
    public var manualSizeThroughRecalculation: Bool { self >= .v3_3a }

    /// server_client_set_session ends with server_check_unattached from 3.3a
    /// (server-client.c:388); 3.2 checks only when a client is lost (3.2
    /// server-client.c:347), so a 3.2 switch leaves the old session alive
    /// until some client disconnects.
    public var checksUnattachedOnSessionChange: Bool { self >= .v3_3a }

    /// `refresh-client -f '!read-only'` cannot clear read-only from 3.3a
    /// (server-client.c:3147-3152; 3.3a :3089-3094); 3.2 clears it (3.2
    /// server-client.c:2380-2383).
    public var keepsReadOnlyOnNegatedFlag: Bool { self >= .v3_3a }

    /// 3.2 `args_parse` reports every parse failure as a usage line; 3.3a+
    /// name the bad flag (cmd.c:516-525).
    public var namesBadFlags: Bool { self >= .v3_3a }

    /// The model version for a `tmux -V` string, or nil for an unknown one.
    /// Releases between the modelled ones map to the newest modelled release
    /// that precedes them (for example 3.5a → 3.4); the caller should report
    /// that mapping as unverified.
    public static func forServerVersion(_ text: String) -> (version: TmuxVersion, exact: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("tmux ") ? String(trimmed.dropFirst(5)) : trimmed
        if let exact = TmuxVersion(rawValue: raw) { return (exact, true) }
        let digits = raw.prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let major = parts[0], minor = parts[1]
        switch (major, minor) {
        case (3, 2): return (.v3_2, false)
        case (3, 3): return (.v3_3a, false)
        case (3, 4), (3, 5): return (.v3_4, false)
        case (3, 6...), (4..., _): return (.v3_6a, false)
        default: return nil
        }
    }
}

/// A terminal or window size in cells.
public struct CellSize: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var columns: Int
    public var rows: Int

    public init(_ columns: Int, _ rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public var description: String { "\(columns)x\(rows)" }

    /// Parses `WxH` or `W,H`.
    public static func parse(_ text: String) -> CellSize? {
        for separator in ["x", ","] {
            let parts = text.split(separator: Character(separator), omittingEmptySubsequences: false)
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                return CellSize(w, h)
            }
        }
        return nil
    }
}

/// `WINDOW_MINIMUM`/`WINDOW_MAXIMUM` (tmux.h:98-99).
enum WindowLimits {
    static let minimum = 1
    static let maximum = 10000

    static func clamp(_ value: Int) -> Int {
        min(max(value, minimum), maximum)
    }
}

/// A client created through the scripting API.
public struct ClientHandle: Hashable, Sendable, CustomStringConvertible {
    public let index: Int
    public let name: String
    public var description: String { name }
}

/// A session; its description is the `$N` id usable in command targets.
public struct SessionHandle: Hashable, Sendable, CustomStringConvertible {
    public let id: Int
    public var description: String { "$\(id)" }
}

/// A window; its description is the `@N` id usable in command targets.
public struct WindowHandle: Hashable, Sendable, CustomStringConvertible {
    public let id: Int
    public var description: String { "@\(id)" }
}

/// Who a window's `w->latest` points at.
public enum LatestClient: Equatable, Sendable, CustomStringConvertible {
    /// Never set (a window created detached: spawn.c:165 with no client).
    case none
    /// A live client.
    case client(String)
    /// A client that has gone: 3.2 never clears the pointer, and 3.3a+ keeps
    /// it when no remaining client has the window current.
    case dangling(String)

    public var description: String {
        switch self {
        case .none: "none"
        case .client(let name): name
        case .dangling(let name): "dangling(\(name))"
        }
    }
}

/// `window-size` choices (options-table.c `options_table_window_size_list`).
public enum WindowSizePolicy: String, CaseIterable, Sendable {
    case largest, smallest, manual, latest
}

/// One line a control client received, with the model time it was written.
public struct ControlLine: Equatable, Sendable {
    public let time: Int64
    public let text: String
}
