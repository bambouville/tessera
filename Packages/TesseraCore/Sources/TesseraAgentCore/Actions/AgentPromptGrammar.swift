import Foundation

/// What a live provider prompt asks for. Every kind is read from the exact
/// terminal screen; transcript records never become one.
public enum AgentPromptKind: String, Codable, Sendable {
    /// An approval menu: run a command, write a file, leave plan mode.
    case permission
    /// A single-choice question (Claude/Kimi AskUserQuestion, Codex
    /// request_user_input and its async panel).
    case question
    /// A question whose options are check boxes.
    case multiSelect
    /// "Ready to submit your answers?" after a multi-question flow.
    case review
    /// A question that takes only typed text.
    case textEntry
    /// Codex's collapsed async summary: questions wait while the turn keeps
    /// working. It never blocks the composer.
    case deferred
}

public enum AgentPromptOptionRole: String, Codable, Sendable {
    case choice
    /// The row that takes typed text ("Type something.", "Other", "None of the above").
    case freeform
    /// Claude's "Chat about this": declines the questions and returns to the composer.
    case chat
}

public enum AgentPromptControlKind: String, Codable, Sendable, CaseIterable {
    /// Expand Codex's collapsed async questions (Shift+←).
    case open
    /// Leave a multi-select question (Claude's "Next" row, Kimi's Tab).
    case next
    /// Skip the current async question (Codex, Ctrl+]).
    case skip
    /// Dismiss the question dialog (Esc) where the TUI advertises it.
    case cancel
}

public struct AgentPromptControl: Equatable, Codable, Sendable {
    public let kind: AgentPromptControlKind
    public let label: String
    public let isSelected: Bool
    public init(kind: AgentPromptControlKind, label: String, isSelected: Bool = false) {
        self.kind = kind; self.label = String(label.prefix(128)); self.isSelected = isSelected
    }
}

/// How the answer planner reaches a question's text field.
public enum AgentPromptTextFocus: String, Codable, Sendable {
    /// The field already has focus: a text-only question.
    case focused
    /// The freeform option's own key opens its inline field.
    case optionKey
    /// Select the freeform option with the arrow keys, then Tab opens its
    /// notes (Codex request_user_input; its digits submit immediately).
    case selectThenTab
}

/// The text field that has focus right now.
public struct AgentPromptEntry: Equatable, Codable, Sendable {
    /// The option whose inline field has focus; nil for a text-only question.
    public let optionID: String?
    /// What the field shows; empty while it shows its placeholder.
    public let text: String
    public init(optionID: String?, text: String) {
        self.optionID = optionID; self.text = String(text.prefix(2_048))
    }
}

/// Canonical, provider-pinned prompt observation. Macros are opaque terminal
/// response bytes expressed as bounded UTF-8 text; clients must not infer them
/// from a display label.
public struct AgentPromptMacroOption: Equatable, Codable, Sendable {
    public let id: String
    public let label: String
    public let responseMacro: String
    /// The row carries the TUI's selection marker.
    public let isDefault: Bool
    public let detail: String?
    public let role: AgentPromptOptionRole
    /// Check-box state of a multi-select row; nil for other rows.
    public let isChecked: Bool?
    /// Typed text can answer through this row.
    public let acceptsText: Bool

    public init?(id: String, label: String, responseMacro: String, isDefault: Bool, detail: String? = nil,
                 role: AgentPromptOptionRole = .choice, isChecked: Bool? = nil, acceptsText: Bool = false) {
        guard !id.isEmpty, id.utf8.count <= 64, !label.isEmpty, label.utf8.count <= 512,
              !responseMacro.isEmpty, responseMacro.utf8.count <= 64 else { return nil }
        self.id = id; self.label = label; self.responseMacro = responseMacro; self.isDefault = isDefault
        self.detail = detail.map { String($0.prefix(1_024)) }.flatMap { $0.isEmpty ? nil : $0 }
        self.role = role; self.isChecked = isChecked; self.acceptsText = acceptsText
    }

    private enum CodingKeys: String, CodingKey { case id, label, responseMacro, isDefault, detail, role, isChecked, acceptsText }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let option = Self(id: try values.decode(String.self, forKey: .id),
                                label: try values.decode(String.self, forKey: .label),
                                responseMacro: try values.decode(String.self, forKey: .responseMacro),
                                isDefault: try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
                                detail: try values.decodeIfPresent(String.self, forKey: .detail),
                                role: try values.decodeIfPresent(AgentPromptOptionRole.self, forKey: .role) ?? .choice,
                                isChecked: try values.decodeIfPresent(Bool.self, forKey: .isChecked),
                                acceptsText: try values.decodeIfPresent(Bool.self, forKey: .acceptsText) ?? false)
        else { throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "invalid prompt option") }
        self = option
    }
}

public struct AgentPromptObservationRequest: Equatable, Codable, Sendable {
    public let providerID: AgentProviderID
    public let visibleText: String
    public let currentCursorLine: String?
    public init?(providerID: AgentProviderID, visibleText: String, currentCursorLine: String?) {
        guard !visibleText.isEmpty, visibleText.utf8.count <= 16_384,
              currentCursorLine.map({ $0.utf8.count <= 2_048 }) ?? true else { return nil }
        self.providerID = providerID; self.visibleText = visibleText; self.currentCursorLine = currentCursorLine
    }
}

public struct AgentPromptObservationResult: Equatable, Codable, Sendable {
    /// Selection-neutral identity of the exact screen the person answers.
    public let signature: String
    public let options: [AgentPromptMacroOption]
    public let kind: AgentPromptKind
    /// The question across its own answer steps: unchanged by the selection
    /// marker, check boxes and the text being typed into it.
    public let identity: String
    /// The agent is stopped until this prompt is answered.
    public let isBlocking: Bool
    public let title: String?
    public let question: String?
    public let detail: String?
    /// "1 of 2", "Question 1/1", or the question tabs.
    public let progress: String?
    public let controls: [AgentPromptControl]
    public let entry: AgentPromptEntry?
    public let textFocus: AgentPromptTextFocus?
    /// Codex's collapsed async summary: how many questions wait.
    public let pendingCount: Int?

    public init?(signature: String, options: [AgentPromptMacroOption], kind: AgentPromptKind = .permission,
                 identity: String? = nil, isBlocking: Bool = true, title: String? = nil, question: String? = nil,
                 detail: String? = nil, progress: String? = nil, controls: [AgentPromptControl] = [],
                 entry: AgentPromptEntry? = nil, textFocus: AgentPromptTextFocus? = nil, pendingCount: Int? = nil) {
        guard !signature.isEmpty, signature.utf8.count <= 1_024, options.count <= 9,
              !options.isEmpty || kind == .textEntry || kind == .deferred else { return nil }
        self.signature = signature; self.options = options; self.kind = kind
        self.identity = String((identity ?? signature).prefix(1_024))
        self.isBlocking = isBlocking
        func bounded(_ value: String?, _ limit: Int) -> String? {
            value.map { String($0.prefix(limit)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.title = bounded(title, 512); self.question = bounded(question, 2_048)
        self.detail = bounded(detail, 8_192); self.progress = bounded(progress, 256)
        self.controls = controls; self.entry = entry; self.textFocus = textFocus; self.pendingCount = pendingCount
    }

    private enum CodingKeys: String, CodingKey {
        case signature, options, kind, identity, isBlocking, title, question, detail, progress, controls, entry, textFocus, pendingCount
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let result = Self(
            signature: try values.decode(String.self, forKey: .signature),
            options: try values.decode([AgentPromptMacroOption].self, forKey: .options),
            kind: try values.decodeIfPresent(AgentPromptKind.self, forKey: .kind) ?? .permission,
            identity: try values.decodeIfPresent(String.self, forKey: .identity),
            isBlocking: try values.decodeIfPresent(Bool.self, forKey: .isBlocking) ?? true,
            title: try values.decodeIfPresent(String.self, forKey: .title),
            question: try values.decodeIfPresent(String.self, forKey: .question),
            detail: try values.decodeIfPresent(String.self, forKey: .detail),
            progress: try values.decodeIfPresent(String.self, forKey: .progress),
            controls: try values.decodeIfPresent([AgentPromptControl].self, forKey: .controls) ?? [],
            entry: try values.decodeIfPresent(AgentPromptEntry.self, forKey: .entry),
            textFocus: try values.decodeIfPresent(AgentPromptTextFocus.self, forKey: .textFocus),
            pendingCount: try values.decodeIfPresent(Int.self, forKey: .pendingCount)
        ) else { throw DecodingError.dataCorruptedError(forKey: .signature, in: values, debugDescription: "invalid prompt") }
        self = result
    }

    public var selectedOptionID: String? { options.first(where: \.isDefault)?.id }
    public var freeformOption: AgentPromptMacroOption? { options.first(where: \.acceptsText) }
    /// The composer is replaced by this prompt; typing would land in it.
    public var blocksComposer: Bool { kind != .deferred }
}

public enum AgentPromptGrammar {
    public static func actionToken(for signature: String) -> AgentActionToken {
        // This is a display identity, never permission to send input. Native
        // adapters still verify the complete fresh signature before answering.
        let hash = signature.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return AgentActionToken("live-prompt-\(String(hash, radix: 16))")!
    }

    /// Reads the provider's live prompt from the bottom of the exact screen.
    ///
    /// Every structural parser is anchored at the screen's last rows: a TUI
    /// dialog replaces the composer there, while a menu merely printed as
    /// output sits above a composer or status line and is never actionable.
    /// Cursor-owned numbered menus remain a fallback for approval screens the
    /// structural parsers do not know.
    public static func observe(_ request: AgentPromptObservationRequest) -> AgentPromptObservationResult? {
        let rows = screenRows(request.visibleText)
        switch request.providerID {
        case .claude: return AgentPromptScreens.claude(rows) ?? legacyObserve(request)
        case .codex:
            return AgentPromptScreens.codexRequestUserInput(rows)
                ?? AgentPromptScreens.codexAsyncPanel(rows)
                ?? AgentPromptScreens.codexDeferred(rows)
                ?? legacyObserve(request)
        case .kimi: return AgentPromptScreens.kimi(rows)
        default: return nil
        }
    }

    /// A pane capture as an observation request carries it: no escape
    /// sequences, and the bottom whole rows within `limit` UTF-8 bytes.
    /// Both platforms capture tmux panes with `capture-pane -e` (composer
    /// evidence reads DIM), so SGR and OSC 8 links arrive in the text, and
    /// they can outweigh the cells they style; bound the rows after removing them.
    public static func promptText(fromCapture capture: String, limit: Int = 16_384) -> String {
        var kept: [Substring] = []
        var bytes = 0
        for row in withoutEscapes(capture).split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = row.utf8.count + (kept.isEmpty ? 0 : 1)
            guard bytes + cost <= limit else { break }
            kept.append(row)
            bytes += cost
        }
        return kept.reversed().joined(separator: "\n")
    }

    /// Removes CSI, OSC/DCS strings and two-byte escapes; their bytes occupy
    /// no cells, and ESC alone would leave their parameters behind as text. A
    /// sequence broken by a newline ends there, keeping the row structure.
    static func withoutEscapes(_ value: String) -> String {
        guard value.unicodeScalars.contains("\u{1b}") else { return value }
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\u{1b}" else { result.append(scalar); continue }
            guard index < scalars.count else { break }
            let kind = scalars[index]
            index += 1
            switch kind {
            case "[":
                while index < scalars.count, (0x20...0x3f).contains(scalars[index].value) { index += 1 }
                if index < scalars.count, (0x40...0x7e).contains(scalars[index].value) { index += 1 }
            case "]", "P", "X", "^", "_":
                // Ends at BEL or ST (`ESC \`); another ESC starts a new sequence.
                while index < scalars.count, scalars[index] != "\n" {
                    if scalars[index] == "\u{7}" { index += 1; break }
                    if scalars[index] == "\u{1b}" {
                        if index + 1 < scalars.count, scalars[index + 1] == "\\" { index += 2 }
                        break
                    }
                    index += 1
                }
            default:
                // `ESC ( B` designates a character set; `ESC 7` and `ESC =` stand alone.
                if (0x20...0x2f).contains(kind.value) {
                    while index < scalars.count, (0x20...0x2f).contains(scalars[index].value) { index += 1 }
                    if index < scalars.count, (0x30...0x7e).contains(scalars[index].value) { index += 1 }
                } else if !(0x30...0x7e).contains(kind.value) {
                    // Not an escape: keep the newline, glyph or ESC that follows.
                    index -= 1
                }
            }
        }
        return String(result)
    }

    /// Visible rows with escape sequences and control characters removed and
    /// trailing blanks trimmed.
    static func screenRows(_ value: String) -> [String] {
        let clean = String(withoutEscapes(value).prefix(16_384)).unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value == 10 || scalar.value >= 32 && !(0x7f...0x9f).contains(scalar.value) {
                result.unicodeScalars.append(scalar)
            } else if scalar.value == 9 {
                result.unicodeScalars.append(" ")
            }
        }
        return clean.components(separatedBy: "\n").map { row in
            var row = Substring(row)
            while row.last?.isWhitespace == true { row.removeLast() }
            return String(row)
        }
    }

    /// Returns nil unless the *current cursor row* proves that the visible
    /// numbered menu is blocking and actionable. A stale viewport menu cannot
    /// produce a response macro.
    private static func legacyObserve(_ request: AgentPromptObservationRequest) -> AgentPromptObservationResult? {
        guard request.providerID == .claude || request.providerID == .codex,
              let cursor = request.currentCursorLine.map(withoutEscapes)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty,
              cursorOwnsPrompt(cursor, provider: request.providerID)
        else { return nil }
        let text = sanitize(request.visibleText)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let start = lines.lastIndex(where: { isBlocking($0, provider: request.providerID) }) else { return nil }
        let menu = lines[start...]
        var options: [AgentPromptMacroOption] = []
        for line in menu.prefix(16) {
            // A numbered row with an unknown Codex shortcut is not a menu we
            // can safely answer.  In particular, terminal text is never an
            // authority for arbitrary response bytes.
            if looksLikeOption(line), parseOption(line, provider: request.providerID) == nil {
                return nil
            }
            guard let parsed = parseOption(line, provider: request.providerID) else { continue }
            options.append(parsed)
            if options.count == 9 { break }
        }
        guard !options.isEmpty else { return nil }
        // Preserve the legacy parser's selection-neutral identity: moving the
        // highlighted marker must not make an old modal look new, while the
        // preceding command context still distinguishes two generic prompts.
        let preceding = lines[..<start]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)
        let stableSegment = lines[start...].prefix(16).map(selectionNeutralLine)
        let signature = (Array(preceding) + stableSegment)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{1f}")
        guard !signature.isEmpty else { return nil }
        let header = lines[start].trimmingCharacters(in: .whitespaces)
        return .init(signature: String(signature.prefix(1_024)), options: options, kind: .permission,
                     question: looksLikeOption(header) ? nil : header,
                     detail: preceding.suffix(4).joined(separator: "\n"))
    }

    private static func sanitize(_ value: String) -> String {
        String(withoutEscapes(value).prefix(16_384)).unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value == 10 || scalar.value == 9 || scalar.value >= 32 { result.unicodeScalars.append(scalar) }
        }
    }
    private static func isBlocking(_ line: String, provider: AgentProviderID) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        switch provider {
        case .claude: return lower == "quick safety check:" || lower == "do you want to proceed?"
        case .codex:
            return lower == "would you like to run the following command?" ||
                lower.contains("do you trust the contents of this directory") ||
                lower == "approaching rate limits" ||
                lower.range(of: #"^[›❯>]?\s*1\.\s*yes,\s+(implement (this|the) plan|start implementing)\b"#, options: .regularExpression) != nil
        default: return false
        }
    }
    private static func cursorOwnsPrompt(_ line: String, provider: AgentProviderID) -> Bool {
        isBlocking(line, provider: provider) || line.range(of: #"^[›❯>]?\s*\d+\.\s+"#, options: .regularExpression) != nil || line.lowercased().contains("press enter") || line.lowercased().contains("esc to")
    }
    private static func parseOption(_ line: String, provider: AgentProviderID) -> AgentPromptMacroOption? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([›❯>]?)\s*(\d+)\.\s+(.+?)(?:\s+\(([^()]*)\))?\s*$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let indexRange = Range(match.range(at: 2), in: line), let labelRange = Range(match.range(at: 3), in: line) else { return nil }
        let index = String(line[indexRange]); let shortcutRange = match.range(at: 4)
        let shortcut = shortcutRange.location == NSNotFound ? "" : String(line[Range(shortcutRange, in: line)!]).lowercased()
        guard let macro = responseMacro(provider: provider, index: index, shortcut: shortcut) else { return nil }
        var label = String(line[labelRange]).trimmingCharacters(in: .whitespaces)
        if !shortcut.isEmpty, label.lowercased().hasSuffix("(\(shortcut))") {
            label = String(label.dropLast(shortcut.count + 2)).trimmingCharacters(in: .whitespaces)
        }
        return .init(id: index, label: label, responseMacro: macro, isDefault: match.range(at: 1).length > 0)
    }
    /// Compiled response vocabulary shared with legacy presentation adapters.
    /// Terminal captures can select a known key; they can never author bytes.
    ///
    /// A digit alone answers: Claude, Kimi and Codex act on it immediately.
    /// A trailing Enter would reach whatever the answer revealed — the
    /// composer, with a draft in it, or the next question. Codex rows that
    /// require explicit confirmation only move the selection; the answer
    /// planner then sends Enter after seeing that same menu still open.
    public static func responseMacro(provider: AgentProviderID, index: String, shortcut: String) -> String? {
        guard let numeric = Int(index), (1...9).contains(numeric) else { return nil }
        switch provider {
        case .claude, .kimi: return "\(numeric)"
        case .codex: return shortcut.isEmpty ? "\(numeric)" : codexResponseMacros[shortcut]
        default: return nil
        }
    }

    private static func looksLikeOption(_ line: String) -> Bool {
        line.range(of: #"^\s*[›❯>]?\s*\d+\.\s+"#, options: .regularExpression) != nil
    }
    /// Keep this mapping literal: it is the complete set of bytes that a
    /// visible Codex menu may cause this parser to emit.
    private static let codexResponseMacros: [String: String] = [
        "y": "y", "n": "n", "p": "p", "esc": "\u{1b}", "enter": "\r"
    ]
    private static func selectionNeutralLine(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^\s*[›❯>]\s*(\d+\.)"#,
            with: "$1",
            options: .regularExpression
        )
    }
}
