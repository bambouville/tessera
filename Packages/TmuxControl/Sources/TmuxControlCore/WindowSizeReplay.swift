import Foundation

/// Reconciles a Mosh side channel's requested grid with a tmux window.
/// Authority admission and attempt identities belong to the transport adapter.
public enum TmuxWindowSizeReplay {
    public enum Decision: Int32, Equatable, Sendable {
        /// The observed layout fits. This does not retire an outstanding attempt:
        /// resize-window can match temporarily before unsetting window-size.
        case fitting = 0
        /// This grid was already requested; wait for its tagged confirmation.
        case waiting = 1
        case replay = 2
    }

    public static let confirmationTag = "tessera-window-size"
    public static let maximumIdentityBytes = 256
    public static let maximumInventoryBytes = 65_536

    public static func decision(
        requested: TmuxClientGeometry,
        observed: TmuxClientGeometry?,
        lastAttempt: TmuxClientGeometry?
    ) -> Decision {
        if observed == requested { return .fitting }
        if lastAttempt == requested { return .waiting }
        return .replay
    }

    /// First advertise the control client grid, then send the three mutations
    /// and wait for all successful replies; only
    /// then send the final query in a separate transmission. tmux schedules
    /// sizing after unset, so a query batched with the mutations can observe the
    /// temporary manual grid. Only the final query's successful reply may
    /// confirm an attempt, under the adapter's token and transport generation.
    /// Ordinary matching layout notifications must leave its attempt intact.
    public static func commands(
        windowID: WindowId,
        requested: TmuxClientGeometry
    ) -> [String] {
        guard windowID.rawValue >= 0, isValid(requested) else { return [] }
        let target = windowID.description
        return [
            "resize-window -x \(requested.columns) -y \(requested.rows) -t \(target)",
            // With no target, tmux fences only this client's current window
            // in its own session (cmd_find_target, cmd_select_window_exec).
            // A bare @W could select a grouped sibling instead (W2). So for a
            // window that is not current here the fence leaves `latest` to
            // whichever client last selected or typed in it, and the unset
            // may hand the window back to that client: such a window is
            // sized when this device shows it (its `select-window -t` makes
            // this client latest), never by switching windows from here.
            "select-window",
            "set-option -w -u -t \(target) window-size",
            sizeQuery(windowID: windowID),
        ]
    }

    /// The tagged size read: the confirmation `commands` ends with, and the
    /// take-back claim's settle probe (§6.10 rule 5), written after its
    /// fence was acknowledged. Either way it must go in its own write: tmux
    /// applies a deferred resize after the command batch.
    public static func sizeQuery(windowID: WindowId) -> String {
        "display-message -p -t \(windowID.description) '\(confirmationTag)\t#{window_id}\t#{window_width}\t#{window_height}'"
    }

    /// The grid a tagged size read reports for `windowID`, or nil for a reply
    /// that names another window or is malformed. One wire line terminator
    /// is accepted; additional lines or fields are not.
    public static func reportedGeometry(windowID: WindowId, reply: String) -> TmuxClientGeometry? {
        guard windowID.rawValue >= 0 else { return nil }
        var line = reply
        // "\r\n" is one Character in Swift, so one removal covers both.
        if line.hasSuffix("\n") || line.hasSuffix("\r\n") { line.removeLast() }
        let fields = line.components(separatedBy: "\t")
        guard fields.count == 4,
              fields[0] == confirmationTag,
              fields[1] == windowID.description,
              let columns = Int(fields[2]), String(columns) == fields[2],
              let rows = Int(fields[3]), String(rows) == fields[3],
              let geometry = try? TmuxClientGeometry(columns: columns, rows: rows)
        else { return nil }
        return geometry
    }

    /// A fresh post-command reply must name the expected window and both axes.
    /// Accept one wire line terminator, but never additional lines or fields.
    public static func confirms(
        windowID: WindowId,
        requested: TmuxClientGeometry,
        reply: String
    ) -> Bool {
        guard windowID.rawValue >= 0, isValid(requested) else { return false }
        let expected = "\(confirmationTag)\t\(windowID.description)\t\(requested.columns)\t\(requested.rows)"
        return reply == expected || reply == expected + "\n" || reply == expected + "\r\n"
    }

    /// Proves that the requested physical window has exactly our two clients.
    /// Validate the entire server inventory before filtering: an ambiguous or
    /// malformed record cannot establish authority to repair a remote grid.
    public static func provesExclusiveOwnership(
        windowID: WindowId,
        controlIdentity: String,
        visibleIdentity: String,
        inventory: String
    ) -> Bool {
        guard windowID.rawValue >= 0,
              let control = canonicalIdentity(controlIdentity),
              let visible = canonicalIdentity(visibleIdentity),
              control != visible,
              !inventory.isEmpty,
              inventory.utf8.count <= maximumInventoryBytes
        else { return false }

        var lines = inventory.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var identities = Set<Data>()
        var windowClients = Set<Data>()
        for line in lines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 4,
                  fields[0].first == "@",
                  let recordWindowID = Int(fields[0].dropFirst()), recordWindowID >= 0,
                  fields[0] == "@\(recordWindowID)",
                  let identity = canonicalIdentity(fields[1...3].joined(separator: "|")),
                  identities.insert(identity).inserted
            else { return false }
            if recordWindowID == windowID.rawValue { windowClients.insert(identity) }
        }
        return windowClients == Set([control, visible])
    }

    private static func canonicalIdentity(_ identity: String) -> Data? {
        guard !identity.isEmpty, identity.utf8.count <= maximumIdentityBytes else { return nil }
        let fields = identity.components(separatedBy: "|")
        guard fields.count == 3, !fields[0].isEmpty,
              fields[0].unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let pid = UInt64(fields[1]), pid > 0, fields[1] == String(pid),
              let created = UInt64(fields[2]), created > 0, fields[2] == String(created)
        else { return nil }
        // Client names are opaque wire identities. Swift String equality would
        // equate differently encoded Unicode names, so compare their UTF-8.
        return Data(identity.utf8)
    }

    private static func isValid(_ geometry: TmuxClientGeometry) -> Bool {
        (1...TmuxClientGeometry.maximumDimension).contains(geometry.columns)
            && (1...TmuxClientGeometry.maximumDimension).contains(geometry.rows)
    }
}
