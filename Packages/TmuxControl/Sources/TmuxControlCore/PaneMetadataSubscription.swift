import Foundation

/// One `%subscription-changed` payload from the live pane-metadata feed.
public struct TmuxPaneMetadataUpdate: Equatable, Sendable {
    public let windowID: WindowId
    public let paneID: PaneId
    public let isActive: Bool
    public let contentRect: CellRect?
    public let currentCommand: String?
    public let paneTitle: String?
    /// True when `paneTitle` is still tmux's `#{host}` default, which names the
    /// machine rather than the pane and so is never a visible label.
    public let paneTitleIsDefault: Bool
    public let windowName: String?
    public let currentPath: String?
    public let agentStateJSON: String?
    /// `#{alternate_on}`, `#{mouse_any_flag}` and `#{mouse_sgr_flag}`: what
    /// the pane's own program asked of its terminal. mosh never relays the
    /// alternate screen, so a mosh+tmux client learns a pane is running a
    /// full-screen program only from here. Nil when an older payload lacks
    /// the field.
    public let isAlternateScreen: Bool?
    public let isMouseReporting: Bool?
    public let isSgrMouse: Bool?

    public init(
        windowID: WindowId,
        paneID: PaneId,
        isActive: Bool,
        contentRect: CellRect?,
        currentCommand: String?,
        paneTitle: String?,
        paneTitleIsDefault: Bool,
        windowName: String?,
        currentPath: String?,
        agentStateJSON: String?,
        isAlternateScreen: Bool? = nil,
        isMouseReporting: Bool? = nil,
        isSgrMouse: Bool? = nil
    ) {
        self.windowID = windowID
        self.paneID = paneID
        self.isActive = isActive
        self.contentRect = contentRect
        self.currentCommand = currentCommand
        self.paneTitle = paneTitle
        self.paneTitleIsDefault = paneTitleIsDefault
        self.windowName = windowName
        self.currentPath = currentPath
        self.agentStateJSON = agentStateJSON
        self.isAlternateScreen = isAlternateScreen
        self.isMouseReporting = isMouseReporting
        self.isSgrMouse = isSgrMouse
    }
}

/// The live feed of per-pane titles, geometry and command state.
///
/// tmux control mode announces window *renames* but never pane title changes,
/// and a pane title is what a shell, editor or agent actually sets — so without
/// this subscription a client's tab labels freeze at whatever `#{window_name}`
/// said when it attached. Name, format and parser live here so a client cannot
/// subscribe with one field order and parse with another, and so every platform
/// gets the feed by asking for it rather than by reimplementing it.
public enum TmuxPaneMetadataSubscription {
    public static let name = "tessera-pane-meta"

    /// Free text with every tab replaced by a space, so a value can never be
    /// mistaken for a field separator.
    ///
    /// Fields are tab-separated, and tmux does *not* escape a tab that lives
    /// inside a value: captured from a live server, a pane whose directory is
    /// `/tmp/esc<TAB>dir` arrives with that tab raw and indistinguishable from
    /// a separator, shifting every later field. Backslashes *are* escaped, so
    /// only the tab is ambiguous — and tmux's own `s///` substitution removes
    /// it before it ever reaches the wire. Verified on tmux 3.4 and 3.6a.
    ///
    /// `pane_current_path` is the field that actually reaches this state: tmux
    /// strips tabs from OSC-set pane titles and stores them escaped in window
    /// names, but a directory name carries whatever the filesystem allows. The
    /// rest are wrapped for the same reason a seatbelt is worn on a short trip.
    private static func tabSafe(_ variable: String) -> String {
        "#{s/\t/ /:\(variable)}"
    }

    public static let format = [
        "#{window_id}",
        "#{pane_id}",
        "#{pane_active}",
        "#{pane_left}",
        "#{pane_top}",
        "#{pane_width}",
        "#{pane_height}",
        tabSafe("pane_current_command"),
        tabSafe("pane_title"),
        tabSafe("window_name"),
        "#{host}",
        tabSafe("pane_current_path"),
        tabSafe("@tessera_agent_state"),
        "#{alternate_on}",
        "#{mouse_any_flag}",
        "#{mouse_sgr_flag}",
    ].joined(separator: "\t")

    /// Parse one subscription value. `fallback*` identify the pane tmux
    /// attributed the event to, used when the payload's own ids are missing —
    /// an old server, or a value whose leading fields were mangled.
    ///
    /// Tolerates the short pre-geometry layout: when the four geometry fields
    /// are absent the remaining fields shift down by four.
    public static func parse(
        _ value: String,
        fallbackWindowID: WindowId,
        fallbackPaneID: PaneId
    ) -> TmuxPaneMetadataUpdate? {
        let line = decodeControlEscapes(value)
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        let windowID = parts.first
            .flatMap { WindowId(wireValue: String($0)) }
            ?? fallbackWindowID
        let paneID = parts.count >= 2
            ? (PaneId(wireValue: String(parts[1])) ?? fallbackPaneID)
            : fallbackPaneID
        let active = parts.count >= 3 ? String(parts[2]) == "1" : false
        let contentRect: CellRect?
        let currentCommandIndex: Int
        if parts.count >= 11,
           let left = Int(parts[3]),
           let top = Int(parts[4]),
           let width = Int(parts[5]),
           let height = Int(parts[6]) {
            contentRect = CellRect(width: width, height: height, x: left, y: top)
            currentCommandIndex = 7
        } else {
            contentRect = nil
            currentCommandIndex = 3
        }
        func field(_ offset: Int) -> String? {
            let index = currentCommandIndex + offset
            return parts.count > index ? nonEmpty(String(parts[index])) : nil
        }
        func flag(_ offset: Int) -> Bool? {
            switch field(offset) {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        let title = field(1)
        let host = field(3)
        return TmuxPaneMetadataUpdate(
            windowID: windowID,
            paneID: paneID,
            isActive: active,
            contentRect: contentRect,
            currentCommand: field(0),
            paneTitle: title,
            paneTitleIsDefault: title != nil && host != nil && title == host,
            windowName: field(2),
            currentPath: field(4),
            agentStateJSON: field(5),
            isAlternateScreen: flag(6),
            isMouseReporting: flag(7),
            isSgrMouse: flag(8)
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    /// tmux escapes control bytes in subscription payloads as `\t`, `\r`, `\n`,
    /// `\\` and three-digit octal. A title or path is arbitrary remote text, so
    /// an unrecognised escape is passed through rather than dropped.
    static func decodeControlEscapes(_ value: String) -> String {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0

        while i < input.count {
            guard input[i] == 0x5C /* \ */ else {
                output.append(input[i])
                i += 1
                continue
            }

            if i + 1 < input.count {
                switch input[i + 1] {
                case 0x74: // t
                    output.append(0x09)
                    i += 2
                    continue
                case 0x72: // r
                    output.append(0x0D)
                    i += 2
                    continue
                case 0x6E: // n
                    output.append(0x0A)
                    i += 2
                    continue
                case 0x5C: // \
                    output.append(0x5C)
                    i += 2
                    continue
                default:
                    break
                }
            }

            if i + 3 < input.count,
               isOctalDigit(input[i + 1]),
               isOctalDigit(input[i + 2]),
               isOctalDigit(input[i + 3])
            {
                let decoded = Int(input[i + 1] - 0x30) << 6
                    | Int(input[i + 2] - 0x30) << 3
                    | Int(input[i + 3] - 0x30)
                if decoded < 256 {
                    output.append(UInt8(decoded))
                    i += 4
                    continue
                }
            }

            output.append(input[i])
            i += 1
        }

        return String(decoding: output, as: UTF8.self)
    }

    private static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37
    }
}
