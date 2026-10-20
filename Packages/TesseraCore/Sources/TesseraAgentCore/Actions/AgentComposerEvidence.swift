import Foundation

/// Display evidence only: callers must still prove the exact live route, require
/// a fresh before/after capture, and never replay an ambiguous terminal write.
public enum AgentComposerEvidence {
    public enum Safety: Equatable { case readyReturn, readyTab, blocked, occupied, unavailable }

    /// Codex uses the double chevron for ultra effort; max keeps the single
    /// chevron, including while its ignition particles animate around it.
    private static func isPromptMarker(_ scalar: Unicode.Scalar, provider: String) -> Bool {
        provider == "codex" ? scalar == "›" || scalar == "»" : scalar == "❯"
    }

    private static func isPromptLine(_ line: String, provider: String) -> Bool {
        guard let first = line.unicodeScalars.first, isPromptMarker(first, provider: provider) else { return false }
        return line.count == 1 || line.dropFirst().first?.isWhitespace == true
    }

    /// Check the input surface, not the draft's rendering or configurable footer.
    /// Cursor visibility is the VT mode, never the cursor's blink phase.
    /// `literalImagePathsOnly` is an opt-in after the normal image wait: the
    /// entire Claude draft must still match as plain text, without markers.
    public static func safety(provider: String, visibleText: String, cursorRow: Int?, cursorColumn: Int? = nil, cursorVisible: Bool?, requireEmpty: Bool, queueWhenWorking: Bool, text: String? = nil, screen: TerminalScreenEvidence? = nil, literalImagePathsOnly: Bool = false) -> Safety {
        let capturedRows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]?
        let capturedText: String
        if let screen {
            guard screen.cursorRow == cursorRow, screen.cursorColumn == cursorColumn,
                  screen.cursorVisible == cursorVisible, let rows = screen.styledRows else { return .unavailable }
            capturedRows = rows
            capturedText = rows.map { String(String.UnicodeScalarView($0.map(\.scalar))) }.joined(separator: "\n")
        } else {
            capturedRows = nil
            capturedText = visibleText
        }
        guard ["codex", "claude"].contains(provider), capturedText.utf8.count <= 65_536,
              let visible = plain(capturedText), let cursorRow, let cursorVisible else { return .unavailable }
        guard cursorVisible || (provider == "claude" && claudeSoftwareCursor(capturedText,
            cursorRow: cursorRow, cursorColumn: cursorColumn, requireEmpty: requireEmpty, text: text,
            screen: screen, capturedRows: capturedRows)) else { return .blocked }
        var lines = visible.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var codexPlaceholder = false
        if provider == "codex", requireEmpty,
           let empty = codexDimPlaceholderLines(capturedText, cursorRow: cursorRow, cursorColumn: cursorColumn, capturedRows: capturedRows) {
            lines = empty
            codexPlaceholder = true
        }
        if provider == "claude", requireEmpty, let cursorColumn,
           let empty = claudeDimPlaceholderLines(capturedText, cursorRow: cursorRow, cursorColumn: cursorColumn, capturedRows: capturedRows) { lines = empty }
        guard lines.indices.contains(cursorRow) else { return .unavailable }
        if let id = AgentProviderID(rawValue: provider),
           let request = AgentPromptObservationRequest(providerID: id, visibleText: visible, currentCursorLine: lines[cursorRow]),
           AgentPromptGrammar.observe(request)?.blocksComposer == true { return .blocked }
        guard let start = lines[...cursorRow].lastIndex(where: { isPromptLine($0, provider: provider) }),
              cursorRow - start < 128 else { return .unavailable }
        let first = String(lines[start].dropFirst()).trimmingCharacters(in: .whitespaces)
        if !requireEmpty, let text, let images = AgentTextInsertion.codexImages(provider: provider, text: text) {
            let rendered = images.submittedText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            guard matches(provider: provider, visibleText: capturedText, cursorLine: lines[cursorRow],
                text: rendered, cursorRow: cursorRow) else { return .unavailable }
        }
        if !requireEmpty, let text, provider == "claude", let images = AgentTextInsertion.images(provider: provider, text: text) {
            guard presence(provider: provider, visibleText: capturedText, cursorLine: lines[cursorRow],
                text: text, cursorRow: cursorRow, literalImagePathsOnly: literalImagePathsOnly) == .present else { return .unavailable }
            // After the full upload wait, callers may explicitly require the
            // unchanged literal draft. Disable marker normalization so a
            // partial conversion can never earn this fallback.
            if !literalImagePathsOnly {
                // Presence also recognizes an unconverted path. Only a complete
                // marker rendering may authorize the separate submission key.
                let draft = (start...cursorRow).map { index in
                    index == start ? String(lines[index].dropFirst()) : lines[index]
                }.joined().filter { !$0.isWhitespace }
                guard images.claudeRenderedText(matching: draft, ignoringWhitespace: true) != nil else { return .unavailable }
            }
        }
        if requireEmpty {
            guard cursorRow == start, first.isEmpty else { return .occupied }
            let following = lines.dropFirst(start + 1)
            if provider == "claude" {
                guard let rule = following.firstIndex(where: { $0.count >= 3 && $0.allSatisfy { "─━".contains($0) } }) else { return .unavailable }
                guard lines[(start + 1)..<rule].allSatisfy(\.isEmpty) else { return .occupied }
            } else if codexPlaceholder, let last = following.lastIndex(where: { !$0.isEmpty }) {
                // Codex paints its placeholder only over an empty input. Its
                // footer may be custom, so up to two bottom rows under a blank
                // row may be footer; anything between must still be blank.
                let footer = codexFooterStart(lines) ??
                    (last >= 2 && !lines[last - 1].isEmpty && lines[last - 2].isEmpty ? last - 1 : last)
                guard footer > start + 1, lines[(start + 1)..<footer].allSatisfy(\.isEmpty) else { return .occupied }
            } else if !codexPlaceholder, let last = following.lastIndex(where: { !$0.isEmpty }) {
                let footer = codexFooterStart(lines) ?? last
                guard footer > start + 1, lines[(start + 1)..<footer].allSatisfy(\.isEmpty) else { return .occupied }
            }
        }
        // Preserve queue intent even if the output stream has not redrawn the
        // queue hint yet. Never turn a Queue action into an Enter/steer action.
        if provider == "codex", queueWhenWorking { return .readyTab }
        return .readyReturn
    }
    public enum Presence { case present, absent, unavailable }

    /// Content-free layout facts for a refused input surface: row indices and
    /// flags only, never cell text, so a field log can say which rule failed.
    public static func diagnosticShape(provider: String, visibleText: String, cursorRow: Int?, cursorColumn: Int?,
                                       cursorVisible: Bool?, screen: TerminalScreenEvidence? = nil) -> String {
        guard let visible = plain(visibleText) else { return "escapes=unparsed" }
        let lines = visible.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let markerRow = lines.lastIndex { isPromptLine($0, provider: provider) }
        let rule = markerRow.flatMap { start in
            lines.indices.dropFirst(start + 1).first { lines[$0].count >= 3 && lines[$0].allSatisfy { "─━".contains($0) } }
        }
        let markerEmpty = markerRow.map { lines[$0].dropFirst().trimmingCharacters(in: .whitespaces).isEmpty }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "nil" }
        let screenCursor = screen.map { $0.cursorRow == cursorRow && $0.cursorColumn == cursorColumn && $0.cursorVisible == cursorVisible }
        return "rows=\(lines.count) cursor=\(cursorRow ?? -1):\(cursorColumn ?? -1) cursorVisible=\(flag(cursorVisible)) " +
            "marker=\(markerRow ?? -1) markerEmpty=\(flag(markerEmpty)) rule=\(rule ?? -1) screen=\(flag(screenCursor))"
    }

    /// Accept only captured SGR, never cursor motion, erase commands or an
    /// unknown attribute. Color parameters are not style attributes.
    private static func dimStyledRows(_ value: String) -> [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]? {
        let scalars = Array(value.unicodeScalars)
        var rows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]] = [[]]
        var dim = false
        var inverse = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 27 {
                if index + 1 < scalars.count, scalars[index + 1] == "]" {
                    // tmux captures OSC 8 links; their labels alone occupy cells.
                    let start = index
                    guard index + 3 < scalars.count, scalars[index + 2] == "8", scalars[index + 3] == ";" else { return nil }
                    index += 4
                    var hasURISeparator = false
                    var terminated = false
                    while index < scalars.count, index - start < 4_096 {
                        let body = scalars[index]
                        if body == "\u{7}" {
                            guard hasURISeparator else { return nil }
                            index += 1
                            terminated = true
                            break
                        }
                        if body.value == 27 {
                            guard hasURISeparator, index + 1 < scalars.count, scalars[index + 1] == "\\",
                                  index + 1 - start < 4_096 else { return nil }
                            index += 2
                            terminated = true
                            break
                        }
                        guard !CharacterSet.controlCharacters.contains(body) else { return nil }
                        if body == ";" { hasURISeparator = true }
                        index += 1
                    }
                    guard terminated else { return nil }
                    continue
                }
                index += 1
                guard index < scalars.count, scalars[index] == "[" else { return nil }
                index += 1
                var parameters = ""
                while index < scalars.count, scalars[index] != "m" {
                    guard parameters.count < 96, (48...57).contains(scalars[index].value) || scalars[index] == ";" else { return nil }
                    parameters.unicodeScalars.append(scalars[index]); index += 1
                }
                guard index < scalars.count else { return nil }
                let fields = parameters.isEmpty ? [0] : parameters.split(separator: ";", omittingEmptySubsequences: false).compactMap { Int($0) }
                guard parameters.isEmpty || fields.count == parameters.split(separator: ";", omittingEmptySubsequences: false).count else { return nil }
                var field = 0
                while field < fields.count {
                    switch fields[field] {
                    case 0: dim = false; inverse = false
                    case 22: dim = false
                    case 2: dim = true
                    case 7: inverse = true
                    case 27: inverse = false
                    case 38, 48:
                        // The 2 in truecolor is a color mode, not DIM.
                        guard field + 1 < fields.count else { return nil }
                        let count = fields[field + 1] == 2 ? 3 : fields[field + 1] == 5 ? 1 : 0
                        guard count > 0, field + 1 + count < fields.count,
                              fields[(field + 2)...(field + 1 + count)].allSatisfy({ (0...255).contains($0) }) else { return nil }
                        field += count + 1
                    case 1, 3, 4, 9, 23, 24, 29, 30...37, 39, 40...47, 49, 90...97, 100...107: break
                    default: return nil
                    }
                    field += 1
                }
            } else if scalar == "\n" { rows.append([]) }
            else if scalar != "\r" { rows[rows.count - 1].append((scalar, dim, inverse)) }
            index += 1
        }
        return rows
    }

    /// Claude's focused input paints one inverse cell and deliberately hides
    /// the hardware cursor. An arbitrary hidden cursor is still blocked.
    /// Empty-input proof below must independently find the DIM suggestion;
    /// post-insertion proof must still match the complete requested payload.
    private static func claudeSoftwareCursor(_ value: String, cursorRow: Int, cursorColumn: Int?,
        requireEmpty: Bool, text: String?, screen: TerminalScreenEvidence?,
        capturedRows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]?) -> Bool {
        guard let cursorColumn, cursorColumn >= 0 else { return false }
        if let screen {
            guard screen.cells.indices.contains(cursorRow), screen.cells[cursorRow].indices.contains(cursorColumn) else { return false }
            let row = screen.cells[cursorRow]
            let caret = row[cursorColumn]
            return caret.width > 0 && caret.text.count == 1 && caret.style & 8 != 0 && caret.style & 16 == 0 &&
                row.filter({ $0.width > 0 && $0.style & 8 != 0 }).count == 1
        }
        guard let rows = capturedRows ?? dimStyledRows(value), rows.indices.contains(cursorRow) else { return false }
        let row = rows[cursorRow]
        guard let start = row.firstIndex(where: \.inverse),
              let glyph = String(String.UnicodeScalarView(row.dropFirst(start).map(\.scalar))).first else { return false }
        let end = start + glyph.unicodeScalars.count
        guard row[start..<end].allSatisfy(\.inverse), row[end...].allSatisfy({ !$0.inverse }) else { return false }
        // These prefixes have an exact one-cell representation. Never guess
        // Unicode display widths from an ANSI capture; native grids already
        // carry physical columns. For wrapped Unicode text, exact complete
        // payload presence plus the sole painted caret provides the proof.
        if row[..<start].allSatisfy({ (32...126).contains($0.scalar.value) || $0.scalar == "❯" || $0.scalar == "\u{00a0}" }) {
            return cursorColumn == start
        }
        guard !requireEmpty, let text else { return false }
        let line = String(String.UnicodeScalarView(row.map(\.scalar)))
        return presence(provider: "claude", visibleText: value, cursorLine: line, text: text, cursorRow: cursorRow) == .present
    }

    /// Claude's empty placeholder is DIM. The focused cursor can repaint its
    /// first glyph without DIM, including a reverse-video software cursor. A
    /// fresh physical cursor at the input origin plus DIM evidence beyond that
    /// glyph distinguishes a suggestion from a typed draft or inline completion.
    /// Missing style/column evidence remains occupied rather than being erased.
    private static func claudeDimPlaceholderLines(_ value: String, cursorRow: Int, cursorColumn: Int, capturedRows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]? = nil) -> [String]? {
        guard let rows = capturedRows ?? dimStyledRows(value), rows.indices.contains(cursorRow) else { return nil }
        var result = rows.map { String(String.UnicodeScalarView($0.map(\.scalar))).trimmingCharacters(in: .whitespaces) }
        let row = rows[cursorRow]
        func padding(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\u{00a0}" }
        let marker = row.prefix(while: { padding($0.scalar) }).count
        let origin = marker + 2
        guard origin < row.count, row[marker].scalar == "❯", padding(row[marker + 1].scalar),
              cursorColumn == origin,
              let rule = result.indices.dropFirst(cursorRow + 1).first(where: {
                  result[$0].count >= 3 && result[$0].allSatisfy { "─━".contains($0) }
              }), rule - cursorRow < 128 else { return nil }
        // Columns before the suggestion contain only one-cell padding/prompt.
        // Its first grapheme may itself span multiple cells or Unicode scalars.
        guard let firstGlyph = String(String.UnicodeScalarView(row.dropFirst(origin).map(\.scalar))).first else { return nil }
        let cursorGlyphEnd = origin + firstGlyph.unicodeScalars.count
        let cursorGlyphIsDim = row[origin..<cursorGlyphEnd].allSatisfy(\.dim)
        var hasDimGlyph = false
        for index in cursorRow..<rule {
            let start = index == cursorRow ? origin : 0
            for column in start..<rows[index].count {
                let cell = rows[index][column]
                guard cell.scalar.value >= 32, cell.scalar.value != 127 else { return nil }
                if cell.scalar.properties.isWhitespace { continue }
                if cell.dim {
                    if index != cursorRow || column >= cursorGlyphEnd || cursorGlyphIsDim { hasDimGlyph = true }
                    continue
                }
                guard index == cursorRow, column < cursorGlyphEnd else { return nil }
            }
        }
        guard hasDimGlyph else { return nil }
        result[cursorRow] = "❯"
        for index in (cursorRow + 1)..<rule { result[index] = "" }
        return result
    }

    /// Codex paints its empty placeholder DIM and can overlay braille particles
    /// in the surrounding padding. Never discard braille from arbitrary input:
    /// prove the placeholder is DIM before normalizing its decoration. Codex
    /// releases word it differently ("Ask Codex to do anything", rotating
    /// prompts such as "Implement {feature}"); typed drafts are never DIM, so
    /// any wording counts once the cursor is proven at the input origin.
    /// Without column evidence only the long-standing literal does.
    /// Raw/colorless captures remain conservative when animation obscures them.
    private static func codexDimPlaceholderLines(_ value: String, cursorRow: Int, cursorColumn: Int?, capturedRows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]? = nil) -> [String]? {
        guard let rows = capturedRows ?? dimStyledRows(value) else { return nil }
        guard rows.indices.contains(cursorRow) else { return nil }
        func particle(_ scalar: Unicode.Scalar) -> Bool { (0x2800...0x28ff).contains(scalar.value) }
        let row = rows[cursorRow].map { (scalar: particle($0.scalar) ? Unicode.Scalar(32)! : $0.scalar, dim: $0.dim) }
        func padding(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\u{00a0}" }
        let marker = row.prefix(while: { padding($0.scalar) }).count
        guard marker + 2 < row.count, isPromptMarker(row[marker].scalar, provider: "codex"), padding(row[marker + 1].scalar),
              cursorColumn == nil || cursorColumn == marker + 2 else { return nil }
        var candidate = row.dropFirst(marker + 2)
        while candidate.first?.scalar.properties.isWhitespace == true { candidate = candidate.dropFirst() }
        while candidate.last?.scalar.properties.isWhitespace == true { candidate = candidate.dropLast() }
        let wording = String(String.UnicodeScalarView(candidate.map(\.scalar)))
        guard !candidate.isEmpty, candidate.allSatisfy({ $0.dim && $0.scalar.value >= 32 && $0.scalar.value != 127 }),
              wording == "Ask Codex to do anything" || cursorColumn == marker + 2 else { return nil }
        var result = rows.map { String(String.UnicodeScalarView($0.map(\.scalar))).trimmingCharacters(in: .whitespaces) }
        result[cursorRow] = String(row[marker].scalar)
        for row in (cursorRow + 1)..<rows.count {
            if rows[row].allSatisfy({ $0.scalar.properties.isWhitespace || particle($0.scalar) }) { result[row] = "" }
        }
        return result
    }
    public enum SubmissionKey { case `return`, tab }

    /// The busy Codex composer advertises Tab for queueing; Enter would steer
    /// the active turn. Select the key only from a complete, matching composer.
    public static func submissionKey(provider: String, visibleText: String, cursorLine: String?, text: String, queueWhenWorking: Bool, cursorRow: Int? = nil) -> SubmissionKey? {
        guard presence(provider: provider, visibleText: visibleText, cursorLine: cursorLine, text: text, cursorRow: cursorRow) == .present else { return nil }
        if provider == "codex", queueWhenWorking, let visible = plain(visibleText) {
            let rows = visible.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let footer = rows.last(where: { !$0.isEmpty }), isCodexQueueFooter(footer) { return .tab }
            // A turn still on screen ("• Working (12s • esc to interrupt)")
            // without its queue hint is a frame in flux: Return would steer
            // that turn, so select no key. Output that merely quotes the
            // phrase is not the status row.
            if rows.contains(where: {
                $0.range(of: #"^• [^()]*\([^()]*esc to interrupt\)"#, options: .regularExpression) != nil
            }) { return nil }
        }
        return .return
    }

    public static func matches(provider: String, visibleText: String, cursorLine: String?, text: String, cursorRow: Int? = nil) -> Bool {
        presence(provider: provider, visibleText: visibleText, cursorLine: cursorLine, text: text, cursorRow: cursorRow) == .present
    }

    /// Absence is meaningful only within a complete, recognized composer.
    /// Unknown layouts and partial captures must not confirm submission.
    public static func presence(provider: String, visibleText: String, cursorLine: String?, text: String, cursorRow: Int? = nil, literalImagePathsOnly: Bool = false) -> Presence {
        guard text.utf8.count <= 32_768, !text.isEmpty,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && !($0.value == 10 && cursorRow != nil)) || $0.value == 127 }),
              visibleText.utf8.count <= 65_536,
              let cursorLine, cursorLine.utf8.count <= 4_096,
              let visible = plain(visibleText), let cursor = plain(cursorLine)
        else { return .unavailable }
        // Terminal captures trim row padding, so leading/trailing draft spaces
        // cannot be distinguished from display margins. Compare the visible
        // content without changing the bytes the caller sends. Interior text
        // remains exact, and whitespace-only/control-character drafts fail.
        var text = text.trimmingCharacters(in: .whitespaces)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
        let current = cursor.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty || cursorRow != nil else { return .unavailable }
        let rawLines = visible.components(separatedBy: "\n")
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        switch provider {
        case "codex", "claude": break
        // Providers without a wrapped-composer grammar retain their existing
        // exact cursor-row evidence; do not impose Codex/Claude footer rules.
        default: return current.contains(text) ? .present : .absent
        }
        // Claude renders a nonbreaking space after its prompt glyph. Treat
        // horizontal whitespace as a structural separator, not payload text.
        guard let start = lines.lastIndex(where: { isPromptLine($0, provider: provider) }),
              let last = lines.lastIndex(where: { !$0.isEmpty }), last >= start else { return .unavailable }
        let footer: Int
        if provider == "codex" {
            // The footer is bottom-anchored; an arbitrary last line cannot
            // establish the composer's boundary. Without a recognized footer
            // a complete capture may end at the cursor-owned composer. The
            // exact payload and no-content-after-cursor checks below still
            // reject extra draft text and unknown trailing UI.
            footer = codexFooterStart(lines) ?? lines.count
        } else {
            guard last > start else { return .unavailable }
            guard let separator = lines[(start + 1)...last].lastIndex(where: {
                $0.count >= 3 && $0.allSatisfy { "─━-".contains($0) }
            }), separator < last, last - separator <= 4,
            lines[(separator + 1)...last].allSatisfy(isClaudeFooterLine) else { return .unavailable }
            footer = separator
        }
        let cursorRows: [Int]
        if let cursorRow {
            guard (start..<footer).contains(cursorRow), lines.indices.contains(cursorRow), lines[cursorRow] == current else { return .unavailable }
            cursorRows = [cursorRow]
        } else {
            cursorRows = (start..<footer).filter { lines[$0] == current }
        }
        guard cursorRows.count == 1, let end = cursorRows.first, end - start < 128,
              lines[(end + 1)..<footer].allSatisfy(\.isEmpty)
        else { return .unavailable }
        let chunks = (start...end).map { index in
            index == start ? String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces) : lines[index]
        }
        if !literalImagePathsOnly, provider == "claude", let images = AgentTextInsertion.images(provider: provider, text: text) {
            let draft = chunks.joined().filter { !$0.isWhitespace }
            if let rendered = images.claudeRenderedText(matching: draft, ignoringWhitespace: true) {
                text = rendered.trimmingCharacters(in: .whitespaces)
            } else if draft.contains("[Image#") {
                // An incomplete or changed image draft is not departure.
                return .unavailable
            }
        }
        // A retained payload with added prefix/suffix is not departure. Ignore
        // whitespace conservatively here so visual wraps cannot hide retention.
        let compactDraft = chunks.joined().filter { !$0.isWhitespace }
        let compactText = text.filter { !$0.isWhitespace }
        let mismatch: Presence = compactDraft.contains(compactText) ? .unavailable : .absent
        var remaining = text[...]
        for (offset, chunk) in chunks.enumerated() {
            // A visual wrap can consume spaces or split a word. Only at that
            // boundary may padding differ; all characters inside a row stay exact.
            if offset > 0 {
                while remaining.first == " " { remaining = remaining.dropFirst() }
                if cursorRow != nil, remaining.first == "\n" { remaining = remaining.dropFirst() }
                // A payload that fills the wrap width parks the cursor alone
                // on the next row. Only a row reaching the right edge proves
                // that wrap; after a short row it is a typed newline.
                else if chunk.isEmpty, !(cursorRow != nil && remaining.isEmpty && offset == chunks.count - 1 &&
                    reachesRightEdge(rawLines, row: end - 1)) { return .unavailable }
                if !remaining.hasPrefix(chunk) {
                    while remaining.first == " " { remaining = remaining.dropFirst() }
                }
            }
            guard remaining.hasPrefix(chunk) else { return mismatch }
            remaining = remaining.dropFirst(chunk.count)
        }
        return remaining.isEmpty ? .present : mismatch
    }

    /// Title and preview use only, never send evidence: whether the cursor
    /// row names nothing the user wrote. Plain text recognizes a bare prompt
    /// glyph and Codex's placeholder literal. With styled evidence for that
    /// same row (`screen`, or SGR retained in `visibleText` plus `cursorRow`)
    /// any text the provider paints DIM after the glyph counts too, whatever
    /// wording this release uses. Claude repaints the first glyph as its
    /// software cursor, so only the rest must be DIM. Typed drafts are never
    /// DIM. The send-safety paths above deliberately keep refusing an unstyled
    /// literal; never route a send decision through here.
    public static func isPlaceholderTitleLine(provider: String, line: String, visibleText: String? = nil,
                                              cursorRow: Int? = nil, screen: TerminalScreenEvidence? = nil) -> Bool {
        func particle(_ scalar: Unicode.Scalar) -> Bool { (0x2800...0x28ff).contains(scalar.value) }
        func body(_ scalars: [Unicode.Scalar]) -> Substring {
            // Particles sit in padding and over spaces; whitespace runs are layout.
            let words = String(String.UnicodeScalarView(scalars.map { particle($0) ? " " : $0 }))
                .split(whereSeparator: \.isWhitespace)
            var body = Substring(words.joined(separator: " "))
            if let marker = body.first, marker == "›" || marker == "❯" || (provider == "codex" && marker == "»") {
                body = body.dropFirst().drop(while: \.isWhitespace)
            }
            return body
        }
        let plain = body(Array(line.unicodeScalars))
        if plain.isEmpty { return true }
        if provider == "codex", plain == "Ask Codex to do anything" { return true }
        guard provider == "codex" || provider == "claude" else { return false }
        let rows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]?
        let row: Int?
        if let screen {
            rows = screen.styledRows
            row = screen.cursorRow
        } else if let visibleText, visibleText.utf8.count <= 65_536 {
            rows = dimStyledRows(visibleText)
            row = cursorRow
        } else {
            rows = nil
            row = nil
        }
        // Only the row the line came from may vouch for it.
        guard let rows, let row, rows.indices.contains(row),
              body(rows[row].map(\.scalar)).filter({ !$0.isWhitespace }) == plain.filter({ !$0.isWhitespace })
        else { return false }
        var cells = rows[row].drop(while: { $0.scalar.properties.isWhitespace || particle($0.scalar) })
        if let first = cells.first?.scalar, isPromptMarker(first, provider: provider) { cells = cells.dropFirst() }
        var glyphs = cells.filter { !$0.scalar.properties.isWhitespace && !particle($0.scalar) }
        if provider == "claude", let first = String(String.UnicodeScalarView(glyphs.map(\.scalar))).first {
            glyphs.removeFirst(first.unicodeScalars.count)
        }
        return !glyphs.isEmpty && glyphs.allSatisfy(\.dim)
    }

    /// Within four cells of the capture's widest row: tmux keeps each row's
    /// trailing blanks, and the TUIs reserve up to a gutter at the right.
    private static func reachesRightEdge(_ rows: [String], row: Int) -> Bool {
        guard rows.indices.contains(row), let width = rows.map(\.count).max() else { return false }
        var content = Substring(rows[row])
        while content.last?.isWhitespace == true { content = content.dropLast() }
        return content.count >= width - 4
    }

    private static let codexFooterIndicators = #"(?: +(?:100|[1-9]?[0-9])% context left)?(?: +⚠ [0-9]{1,4}(?: warnings?)? · f2(?: to view)?)?"#

    /// Claude Code 2.1.302 puts the permission mode and optional idle hints
    /// at the left, with effort/Ultracode at the right. Typing hides the idle
    /// hints. Only these provider-owned labels bound the input, never an
    /// arbitrary line below the rule.
    private static func isClaudeFooterLine(_ line: String) -> Bool {
        if line.isEmpty || line.hasPrefix("ctx:") ||
            (line.hasPrefix("⏵") && line.contains("shift+tab")) || line == "? for shortcuts" ||
            line.range(of: #"^ctrl\+g to edit in [A-Za-z0-9 ._-]{1,64}$"#, options: .regularExpression) != nil { return true }
        let mode = #"(?:⏸ (?:manual|plan) mode|⏵⏵ (?:accept edits|bypass permissions|don't ask|auto mode))(?: on)?"#
        // A running turn replaces the shortcut hint with "esc to interrupt"
        // (2.1.302), which is when a submitted image draft must prove departure.
        let hints = #"(?:\? for shortcuts(?: · ← for agents)?|esc to interrupt)"#
        let effort = #"(?:○ low|◐ medium|● high|◉ xhigh|◈ max|effort: (?:low|medium|high|xhigh|max))(?: · ultracode)? · /effort"#
        return line.range(of: "^(?:(?:" + mode + ")(?: · " + hints + ")?|" + hints + ")(?: +" + effort + ")?$|^" + effort + "$",
            options: .regularExpression) != nil
    }

    private static func isCodexQueueFooter(_ line: String) -> Bool {
        line.range(of: "^tab to queue message" + codexFooterIndicators + "$", options: .regularExpression) != nil
    }

    /// Codex's bottom hint row: "? for shortcuts" while idle, the queue hint
    /// while typing during a turn, or nothing; then the context and warning
    /// indicators it right-aligns. Typing clears the hint but keeps them.
    private static func isCodexHintLine(_ line: String) -> Bool {
        !line.isEmpty && (" " + line).range(of: "^(?: \\? for shortcuts| tab to queue message)?" + codexFooterIndicators + "$",
            options: .regularExpression) != nil
    }

    /// Codex bottom-anchors its footer below the composer's blank padding row:
    /// a recognized hint row, optionally under one user-configured status
    /// line (items joined by " · "), or a lone model-led status line (older
    /// releases, or a hint row that typing emptied). Nil when the bottom rows
    /// are not that footer.
    private static func codexFooterStart(_ lines: [String]) -> Int? {
        guard let last = lines.lastIndex(where: { !$0.isEmpty }) else { return nil }
        if isCodexHintLine(lines[last]) {
            if last >= 2, lines[last - 1].contains(" · "), lines[last - 2].isEmpty { return last - 1 }
            return last
        }
        if lines[last].range(of: #"^(?:gpt-|codex-|o[1-9])\S*.* · .+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return last
        }
        return nil
    }

    private static func plain(_ value: String) -> String? {
        let stripped = value
            .replacingOccurrences(of: "\u{1b}\\][^\u{7}\u{1b}]*(?:\u{7}|\u{1b}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        return stripped.contains("\u{1b}") ? nil : stripped
    }
}
