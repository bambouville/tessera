import Foundation

enum RepaintAssembly {
    static func assemble(
        state: TmuxController.RenderedPaneState,
        captureLines: [String],
        historyLines: [String],
        savedPrimaryLines: [String],
        altScreenLines: [String]?,
        terminalIsInAltScreen: Bool,
        clientRows: Int?
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        appendEscape("\u{1B}[?2026l", to: &bytes)
        if terminalIsInAltScreen {
            appendEscape("\u{1B}[?1049l", to: &bytes)
        }
        appendEscape("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l", to: &bytes)
        appendEscape("\u{1B}[?6l\u{1B}[?7h\u{1B}[4l\u{1B}[r", to: &bytes)
        appendEscape("\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[?25h", to: &bytes)

        // `capture-pane -J` implies `-T`, which drops trailing colored blank
        // cells used by TUIs for full-row backgrounds; CRLF-joining the raw
        // `-e -N` rows preserves those blank rows without needing CSI 3 J.
        if state.paneInAltScreen {
            appendLines(historyLines, to: &bytes)
            if !historyLines.isEmpty && !savedPrimaryLines.isEmpty {
                appendCRLF(to: &bytes)
            }
            // Each capture-pane response tracks SGR state independently
            // and only closes attributes where trailing blanks exist, so
            // a fully-colored final cell leaves its SGR open — reset at
            // every segment seam or the tail attributes of one capture
            // bleed into the head of the next.
            appendEscape("\u{1B}[0m", to: &bytes)
            appendLines(savedPrimaryLines, to: &bytes)
            // This CUP before ?1049h seeds the saved-primary cursor that a
            // later live ?1049l restores — semantically required, not a
            // workaround (the fork's old savedY-zeroing bug is fixed as of
            // d34c15f).
            let savedRow = max(1, (state.altSavedY ?? 0) + 1)
            let savedCol = max(1, (state.altSavedX ?? 0) + 1)
            appendEscape("\u{1B}[\(savedRow);\(savedCol)H", to: &bytes)
            appendEscape("\u{1B}[0m\u{1B}[?1049h\u{1B}[H", to: &bytes)
            appendLines(altScreenLines ?? captureLines, to: &bytes)
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
        for state: TmuxController.RenderedPaneState,
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

    private static func appendModeRestore(for state: TmuxController.RenderedPaneState, to bytes: inout [UInt8]) {
        if state.insertMode == true {
            appendEscape("\u{1B}[4h", to: &bytes)
        }
        if state.wrapMode == false {
            appendEscape("\u{1B}[?7l", to: &bytes)
        }
        if state.mouseStandard == true {
            appendEscape("\u{1B}[?1000h", to: &bytes)
        } else if state.mouseButton == true {
            appendEscape("\u{1B}[?1002h", to: &bytes)
        } else if state.mouseAll == true {
            appendEscape("\u{1B}[?1003h", to: &bytes)
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
    static func backgroundLeftOpen(in lines: [String]) -> Bool {
        var backgroundActive = false
        for line in lines {
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
                let paramBytes = bytes[(i + 2)..<j]
                applySGR(String(decoding: paramBytes, as: UTF8.self), backgroundActive: &backgroundActive)
                i = j + 1
            }
        }
        return backgroundActive
    }

    /// Diagnostic: visible column count of a captured line — the number of
    /// printable cells, ignoring CSI/OSC escape sequences and UTF-8
    /// continuation bytes. Used to detect a tmux-pane-width vs terminal-width
    /// mismatch at capture time (the "half-width gray box" signature): if the
    /// widest captured row is far narrower than the client column count we last
    /// pushed to tmux, the capture was taken at a stale/smaller grid.
    static func visibleColumns(in line: String) -> Int {
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

    /// Fold one SGR payload's effect on background state. Tokens may be `;`- or
    /// `:`-separated; extended `48` colors consume their trailing tokens.
    private static func applySGR(_ payload: String, backgroundActive: inout Bool) {
        // Treat ':' (sub-parameter) and ';' alike for scanning purposes.
        let tokens = payload.split(whereSeparator: { $0 == ";" || $0 == ":" }).map(String.init)
        if tokens.isEmpty {
            // Empty payload == `0` == full reset.
            backgroundActive = false
            return
        }
        var k = 0
        while k < tokens.count {
            guard let code = Int(tokens[k]) else { k += 1; continue }
            switch code {
            case 0:
                backgroundActive = false
            case 49:
                backgroundActive = false
            case 40...47, 100...107:
                backgroundActive = true
            case 48:
                // Extended background: `48;5;n` or `48;2;r;g;b` (sub-param
                // variants collapse to the same token stream here). Any
                // extended background select turns the background on; consume
                // the mode + its operands so they aren't misread as resets.
                backgroundActive = true
                if k + 1 < tokens.count, let mode = Int(tokens[k + 1]) {
                    k += (mode == 2) ? 4 : 2
                }
            default:
                break
            }
            k += 1
        }
    }

    private static func appendEscape(_ sequence: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: sequence.utf8)
    }

    private static func appendLines(_ lines: [String], to bytes: inout [UInt8]) {
        for (index, line) in lines.enumerated() {
            bytes.append(contentsOf: line.utf8)
            if index < lines.count - 1 {
                appendCRLF(to: &bytes)
            }
        }
    }

    private static func appendCRLF(to bytes: inout [UInt8]) {
        bytes.append(0x0D)
        bytes.append(0x0A)
    }
}
