import Foundation

public struct TmuxRenderedPaneState: Equatable, Sendable {
    public let paneId: PaneId
    public let cursorX: Int
    public let cursorY: Int
    public let paneTitle: String?
    public let paneTitleIsDefault: Bool
    public let windowName: String?
    public let paneInAltScreen: Bool
    public let historySize: Int?
    public let scrollRegionUpper: Int?
    public let scrollRegionLower: Int?
    public let cursorVisible: Bool?
    public let insertMode: Bool?
    public let keypadCursor: Bool?
    public let keypadApplication: Bool?
    public let wrapMode: Bool?
    public let mouseStandard: Bool?
    public let mouseButton: Bool?
    public let mouseAll: Bool?
    public let mouseSgr: Bool?
    public let originMode: Bool?
    public let altSavedX: Int?
    public let altSavedY: Int?
    /// The pane's grid when this state was read. Nil in legacy replies.
    public let paneWidth: Int?
    public let paneHeight: Int?

    public init(paneId: PaneId, cursorX: Int, cursorY: Int, paneTitle: String?,
        paneTitleIsDefault: Bool, windowName: String?, paneInAltScreen: Bool,
        historySize: Int?, scrollRegionUpper: Int?, scrollRegionLower: Int?,
        cursorVisible: Bool?, insertMode: Bool?, keypadCursor: Bool?,
        keypadApplication: Bool?, wrapMode: Bool?, mouseStandard: Bool?,
        mouseButton: Bool?, mouseAll: Bool?, mouseSgr: Bool?, originMode: Bool?,
        altSavedX: Int?, altSavedY: Int?, paneWidth: Int? = nil,
        paneHeight: Int? = nil) {
        self.paneId = paneId
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.paneTitle = paneTitle
        self.paneTitleIsDefault = paneTitleIsDefault
        self.windowName = windowName
        self.paneInAltScreen = paneInAltScreen
        self.historySize = historySize
        self.scrollRegionUpper = scrollRegionUpper
        self.scrollRegionLower = scrollRegionLower
        self.cursorVisible = cursorVisible
        self.insertMode = insertMode
        self.keypadCursor = keypadCursor
        self.keypadApplication = keypadApplication
        self.wrapMode = wrapMode
        self.mouseStandard = mouseStandard
        self.mouseButton = mouseButton
        self.mouseAll = mouseAll
        self.mouseSgr = mouseSgr
        self.originMode = originMode
        self.altSavedX = altSavedX
        self.altSavedY = altSavedY
        self.paneWidth = paneWidth
        self.paneHeight = paneHeight
    }

    public var isMouseReporting: Bool {
        mouseStandard == true || mouseButton == true || mouseAll == true
    }
}

/// Pure parser for the fixed rendered-pane metadata query. It accepts the
/// seven-field legacy prefix and the full modern response. A compatibility
/// path also recovers numeric state when a remote tmux build replaces every
/// tab separator with a single other character.
public enum TmuxRenderedPaneStateParser {
    public static func parse(_ line: String) -> TmuxRenderedPaneState? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        if let state = parse(fields: parts) { return state }
        return parseSeparatorMangled(line)
    }

    private static func parseSeparatorMangled(_ line: String) -> TmuxRenderedPaneState? {
        guard line.hasPrefix("%") else { return nil }
        let afterAnchor = line.dropFirst().drop(while: { ("0"..."9").contains($0) })
        guard let separator = afterAnchor.first,
              separator != "\t",
              afterAnchor.startIndex != line.index(after: line.startIndex)
        else { return nil }
        let parts = line.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 22 else { return nil }
        // Current replies end with eighteen numeric fields (the pane's grid
        // last); replies to the older query end with sixteen.
        let numericCount = parts.count >= 24
            && parts.suffix(18).allSatisfy({ Int($0) != nil }) ? 18 : 16
        let tail = Array(parts.suffix(numericCount))
        guard tail.allSatisfy({ Int($0) != nil }) else { return nil }
        var fields = Array(parts.prefix(3))
        if parts.count == numericCount + 6 {
            fields.append(contentsOf: parts[3..<6])
        } else {
            // A separator inside a string makes those three fields
            // unattributable. Rendering can still safely use the anchored
            // pane id and sixteen numeric fields.
            fields.append(contentsOf: [Substring(), Substring(), Substring()])
        }
        fields.append(contentsOf: tail)
        return parse(fields: fields)
    }

    private static func parse(fields parts: [Substring]) -> TmuxRenderedPaneState? {
        guard parts.count >= 3,
              let paneId = parsePaneID(String(parts[0])),
              let cursorX = Int(parts[1]),
              let cursorY = Int(parts[2])
        else { return nil }
        let title = parts.count >= 4 ? nonEmpty(String(parts[3])) : nil
        let host = parts.count >= 6 ? nonEmpty(String(parts[5])) : nil
        return TmuxRenderedPaneState(
            paneId: paneId,
            cursorX: cursorX,
            cursorY: cursorY,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host),
            windowName: parts.count >= 5 ? nonEmpty(String(parts[4])) : nil,
            paneInAltScreen: optionalFlag(parts, 6) ?? false,
            historySize: optionalInt(parts, 7),
            scrollRegionUpper: optionalInt(parts, 8),
            scrollRegionLower: optionalInt(parts, 9),
            cursorVisible: optionalFlag(parts, 10),
            insertMode: optionalFlag(parts, 11),
            keypadCursor: optionalFlag(parts, 12),
            keypadApplication: optionalFlag(parts, 13),
            wrapMode: optionalFlag(parts, 14),
            mouseStandard: optionalFlag(parts, 15),
            mouseButton: optionalFlag(parts, 16),
            mouseAll: optionalFlag(parts, 17),
            mouseSgr: optionalFlag(parts, 18),
            originMode: optionalFlag(parts, 19),
            altSavedX: optionalCoordinate(parts, 20),
            altSavedY: optionalCoordinate(parts, 21),
            paneWidth: optionalDimension(parts, 22),
            paneHeight: optionalDimension(parts, 23)
        )
    }

    private static func optionalInt(_ parts: [Substring], _ index: Int) -> Int? {
        guard parts.indices.contains(index), !parts[index].isEmpty else { return nil }
        return Int(parts[index])
    }

    private static func optionalCoordinate(_ parts: [Substring], _ index: Int) -> Int? {
        guard let value = optionalInt(parts, index), (0...32767).contains(value) else {
            return nil
        }
        return value
    }

    private static func optionalDimension(_ parts: [Substring], _ index: Int) -> Int? {
        guard let value = optionalInt(parts, index), (1...32767).contains(value) else {
            return nil
        }
        return value
    }

    private static func optionalFlag(_ parts: [Substring], _ index: Int) -> Bool? {
        optionalInt(parts, index).map { $0 != 0 }
    }

    private static func parsePaneID(_ string: String) -> PaneId? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("%"), let raw = Int(trimmed.dropFirst()) else { return nil }
        return PaneId(raw)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func isDefaultPaneTitle(_ title: String?, host: String?) -> Bool {
        guard let title = nonEmpty(title), let host = nonEmpty(host) else { return false }
        return title == host
    }
}

public enum TmuxRepaintAssembly {
    public static func assemble(
        state: TmuxRenderedPaneState,
        captureLines: [String],
        historyLines: [String],
        savedPrimaryLines: [String],
        altScreenLines: [String]?,
        terminalIsInAltScreen: Bool,
        clientRows: Int?,
        paneRows: Int? = nil,
        preservePrimaryDuringAltRefresh: Bool = false
    ) -> [UInt8] {
        // Rows the surface has below the pane's last one, when the surface
        // is taller than the pane (its grid not yet resized to a new
        // layout). Painted from the top, the capture would end that many
        // rows short of the bottom, leaving as many history rows on screen
        // above the pane's first row, where tmux's absolute cursor positions
        // do not point and a later erase-display loses them. Linefeeds past
        // the pane's last row scroll those rows into scrollback instead.
        let surplusRows = clientRows.flatMap { rows in
            paneRows.map { max(0, rows - $0) }
        } ?? 0
        var bytes: [UInt8] = []
        appendEscape("\u{1B}[?2026l", to: &bytes)
        if terminalIsInAltScreen && !preservePrimaryDuringAltRefresh {
            appendEscape("\u{1B}[?1049l", to: &bytes)
        }
        appendEscape("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l", to: &bytes)
        appendEscape("\u{1B}[?6l\u{1B}[?7h\u{1B}[4l\u{1B}[r", to: &bytes)
        appendEscape("\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[?25h", to: &bytes)

        // `capture-pane -J` implies `-T`, which drops trailing colored blank
        // cells used by TUIs for full-row backgrounds; CRLF-joining the raw
        // `-e -N` rows preserves those blank rows without needing CSI 3 J.
        if state.paneInAltScreen {
            if preservePrimaryDuringAltRefresh {
                // The terminal and tmux are already showing this pane's
                // alternate buffer. Repaint that buffer directly; toggling
                // 1049 here would clear the saved primary screen because a
                // viewport-only capture intentionally has no primary payload.
                appendLines(altScreenLines ?? captureLines, to: &bytes)
            } else {
                appendLines(historyLines, to: &bytes)
                // Each capture-pane response tracks SGR state independently
                // and only closes attributes where trailing blanks exist, so
                // a fully-colored final cell leaves its SGR open — reset at
                // every segment seam or the tail attributes of one capture
                // bleed into the head of the next. The reset must come BEFORE
                // the seam CRLF: a linefeed on the bottom row scrolls, and the
                // scrolled-in line is filled with the current background (BCE),
                // planting a stale colored row if the pen were still open.
                appendEscape("\u{1B}[0m", to: &bytes)
                if !historyLines.isEmpty && !savedPrimaryLines.isEmpty {
                    appendCRLF(to: &bytes)
                }
                appendLines(savedPrimaryLines, to: &bytes)
                if surplusRows > 0 {
                    appendEscape("\u{1B}[0m", to: &bytes)
                    appendLinefeeds(surplusRows, to: &bytes)
                }
                // This CUP before ?1049h seeds the saved-primary cursor that a
                // later live ?1049l restores — semantically required, not a
                // workaround (the fork's old savedY-zeroing bug is fixed as of
                // d34c15f).
                let savedRow = max(1, (state.altSavedY ?? 0) + 1)
                let savedCol = max(1, (state.altSavedX ?? 0) + 1)
                appendEscape("\u{1B}[\(savedRow);\(savedCol)H", to: &bytes)
                appendEscape("\u{1B}[0m\u{1B}[?1049h\u{1B}[H", to: &bytes)
                appendLines(altScreenLines ?? captureLines, to: &bytes)
            }
        } else {
            appendLines(captureLines, to: &bytes)
        }

        // Close any SGR the capture left open. `capture-pane -e` only resets
        // attributes on rows that have trailing blank cells; a full-width
        // colored final row (e.g. the gray full-row input box a TUI like Codex
        // paints) leaves the background pen open. Because one shared terminal is
        // repainted across tmux windows, the live `%output` that resumes after
        // this repaint would otherwise inherit that background and paint
        // default-attribute text onto it — the cross-window "gray block" bleed.
        // The leading `\e[0m` (above) guards the head of the repaint; this
        // guards the tail. Mirrors the per-seam resets in the alt-screen branch.
        appendEscape("\u{1B}[0m", to: &bytes)
        if !state.paneInAltScreen {
            appendLinefeeds(surplusRows, to: &bytes)
        }

        appendScrollRegionRestore(for: state, clientRows: clientRows, to: &bytes)
        appendModeRestore(for: state, to: &bytes)

        appendEscape(state.cursorVisible ?? true ? "\u{1B}[?25h" : "\u{1B}[?25l", to: &bytes)
        let row = max(1, state.cursorY + 1)
        let col = max(1, state.cursorX + 1)
        appendEscape("\u{1B}[\(row);\(col)H", to: &bytes)
        if state.originMode == true {
            appendEscape("\u{1B}[?6h", to: &bytes)
        }

        return bytes
    }

    private static func appendScrollRegionRestore(
        for state: TmuxRenderedPaneState,
        clientRows: Int?,
        to bytes: inout [UInt8]
    ) {
        guard let upper = state.scrollRegionUpper,
              let lower = state.scrollRegionLower,
              upper >= 0,
              lower >= upper
        else { return }
        if upper == 0,
           let rows = clientRows,
           lower >= rows - 1 {
            return
        }
        appendEscape("\u{1B}[\(upper + 1);\(lower + 1)r", to: &bytes)
    }

    private static func appendModeRestore(for state: TmuxRenderedPaneState, to bytes: inout [UInt8]) {
        if state.insertMode == true {
            appendEscape("\u{1B}[4h", to: &bytes)
        }
        if state.wrapMode == false {
            appendEscape("\u{1B}[?7l", to: &bytes)
        }
        // Some servers retain more than one flag after a program requests
        // 1000, 1002, then 1003. Preserve its fullest motion request.
        if state.mouseAll == true {
            appendEscape("\u{1B}[?1003h", to: &bytes)
        } else if state.mouseButton == true {
            appendEscape("\u{1B}[?1002h", to: &bytes)
        } else if state.mouseStandard == true {
            appendEscape("\u{1B}[?1000h", to: &bytes)
        }
        if state.mouseSgr == true {
            appendEscape("\u{1B}[?1006h", to: &bytes)
        }
        if let keypadApplication = state.keypadApplication {
            appendEscape(keypadApplication ? "\u{1B}=" : "\u{1B}>", to: &bytes)
        }
        if let keypadCursor = state.keypadCursor {
            appendEscape(keypadCursor ? "\u{1B}[?1h" : "\u{1B}[?1l", to: &bytes)
        }
    }

    /// Diagnostic: walks the SGR sequences in `lines` (which carry cumulative
    /// attribute state across rows, exactly as `capture-pane -e` emits them) and
    /// reports whether a non-default background is still active at the end of the
    /// last row. `true` is the precondition for the cross-window "gray block"
    /// bleed: the next bytes fed after this content would land on a colored
    /// background. The assembler now appends a trailing reset so this can no
    /// longer actually bleed — this stays as a repro/observability signal.
    ///
    /// Recognizes the background SGR forms tmux emits: `0`/empty (full reset),
    /// `49` (default bg), `40`–`47` / `100`–`107` (indexed), and `48;5;n` /
    /// `48;2;r;g;b` / `48:5:n` / `48:2::r:g:b` (extended). Foreground (`38…`)
    /// params are skipped without disturbing background state.
    public static func backgroundLeftOpen(in lines: [String]) -> Bool {
        var pen = BackgroundPen()
        for line in lines {
            pen.consume(line)
        }
        return pen.activePayload != nil
    }

    /// Cumulative SGR background state across capture rows. `activePayload` is
    /// the raw SGR parameter string that re-establishes the current background
    /// (e.g. `"100"`, `"48;5;236"`, `"48:2::64:64:64"`), or nil when the
    /// background is default.
    struct BackgroundPen {
        private(set) var activePayload: String? = nil

        mutating func consume(_ line: String) {
            let bytes = Array(line.utf8)
            var i = 0
            while i < bytes.count {
                // Find an SGR introducer: ESC '['
                guard bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") else {
                    i += 1
                    continue
                }
                var j = i + 2
                while j < bytes.count, bytes[j] != UInt8(ascii: "m") {
                    // Bail out of any non-SGR CSI (final byte other than 'm').
                    let b = bytes[j]
                    let isParam = (b >= 0x30 && b <= 0x3F) // digits, ';', ':', and other param/intermediate bytes
                    if !isParam { break }
                    j += 1
                }
                guard j < bytes.count, bytes[j] == UInt8(ascii: "m") else {
                    i += 1
                    continue
                }
                apply(String(decoding: bytes[(i + 2)..<j], as: UTF8.self))
                i = j + 1
            }
        }

        /// Fold one SGR payload's effect on the background pen. Parameters are
        /// `;`-separated; a parameter may carry `:` sub-parameters (ITU form),
        /// which make it self-contained. Legacy `38`/`48`/`58` extended colors
        /// consume their `;`-separated operands so color components aren't
        /// misread as background selects (`38;2;100;107;42`).
        private mutating func apply(_ payload: String) {
            let groups = payload.components(separatedBy: ";")
            var k = 0
            while k < groups.count {
                let group = groups[k]
                if group.isEmpty {
                    // Empty parameter == `0` == full reset.
                    activePayload = nil
                    k += 1
                    continue
                }
                if group.contains(":") {
                    // ITU sub-parameter form, self-contained in one group.
                    let head = Int(group.prefix(while: { $0.isNumber })) ?? -1
                    if head == 48 {
                        activePayload = group
                    }
                    k += 1
                    continue
                }
                guard let code = Int(group) else {
                    k += 1
                    continue
                }
                switch code {
                case 0, 49:
                    activePayload = nil
                case 40...47, 100...107:
                    activePayload = group
                case 38, 48, 58:
                    var span = 1
                    if k + 1 < groups.count, let mode = Int(groups[k + 1]) {
                        span += (mode == 2) ? 4 : (mode == 5) ? 2 : 0
                    }
                    let end = min(k + span, groups.count)
                    if code == 48 {
                        activePayload = groups[k..<end].joined(separator: ";")
                    }
                    k = end - 1
                default:
                    break
                }
                k += 1
            }
        }
    }

    /// Diagnostic: visible column count of a captured line — the number of
    /// printable cells, ignoring CSI/OSC escape sequences and UTF-8
    /// continuation bytes. Used to detect a tmux-pane-width vs terminal-width
    /// mismatch at capture time (the "half-width gray box" signature): if the
    /// widest captured row is far narrower than the client column count we last
    /// pushed to tmux, the capture was taken at a stale/smaller grid.
    public static func visibleColumns(in line: String) -> Int {
        let bytes = Array(line.utf8)
        var i = 0
        var cols = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B, i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == UInt8(ascii: "[") {
                    // CSI: ESC [ params... <final 0x40...0x7E>
                    var j = i + 2
                    while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) { j += 1 }
                    i = (j < bytes.count) ? j + 1 : bytes.count
                    continue
                }
                if next == UInt8(ascii: "]") {
                    // OSC: ESC ] ... (BEL or ST = ESC \)
                    var j = i + 2
                    while j < bytes.count, bytes[j] != 0x07,
                          !(bytes[j] == 0x1B && j + 1 < bytes.count && bytes[j + 1] == UInt8(ascii: "\\")) {
                        j += 1
                    }
                    if j < bytes.count, bytes[j] == 0x1B { j += 1 }
                    i = (j < bytes.count) ? j + 1 : bytes.count
                    continue
                }
                // Other ESC <single byte> sequence.
                i += 2
                continue
            }
            // Count UTF-8 lead bytes only (skip continuation bytes 0x80...0xBF).
            if b & 0xC0 != 0x80 { cols += 1 }
            i += 1
        }
        return cols
    }

    private static func appendEscape(_ sequence: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: sequence.utf8)
    }

    /// Joins capture rows with CRLF, neutralizing the background pen at every
    /// seam. `capture-pane -e` carries cumulative SGR state across rows and
    /// only closes attributes where a row has trailing blank cells, so a
    /// full-width colored row leaves its background open across the CRLF. A
    /// linefeed executed on the bottom row scrolls, and the scrolled-in line
    /// is filled with the *current* background (BCE) — planting a stale
    /// colored tail on the next row wherever its content is shorter than the
    /// full width. Those rows land in scrollback, out of reach of the
    /// visible-screen scrub. Closing the background before the CRLF and
    /// re-establishing it right after keeps the scroll fill default while
    /// preserving the inherited pen for the next row's cells.
    private static func appendLines(_ lines: [String], to bytes: inout [UInt8]) {
        var pen = BackgroundPen()
        for (index, line) in lines.enumerated() {
            bytes.append(contentsOf: line.utf8)
            if index < lines.count - 1 {
                pen.consume(line)
                if let background = pen.activePayload {
                    appendEscape("\u{1B}[49m", to: &bytes)
                    appendCRLF(to: &bytes)
                    appendEscape("\u{1B}[\(background)m", to: &bytes)
                } else {
                    appendCRLF(to: &bytes)
                }
            }
        }
    }

    private static func appendCRLF(to bytes: inout [UInt8]) {
        bytes.append(0x0D)
        bytes.append(0x0A)
    }

    private static func appendLinefeeds(_ count: Int, to bytes: inout [UInt8]) {
        for _ in 0..<max(0, count) {
            appendCRLF(to: &bytes)
        }
    }
}
