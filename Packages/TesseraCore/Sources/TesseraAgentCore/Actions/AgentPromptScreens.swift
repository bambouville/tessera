import Foundation

/// Structural readers for the prompt screens of Claude Code, Codex and Kimi
/// Code, captured from their real TUIs (see the fixtures in
/// `AgentPromptScreenTests`). Each reader is anchored at the screen's last
/// rows: while a dialog is up it replaces the composer there, so a menu that
/// was merely printed as output — it sits above a composer or a status line —
/// never parses.
///
/// Readers return response macros only from the fixed key vocabulary in
/// `AgentPromptGrammar.responseMacro`; screen text never authors bytes.
enum AgentPromptScreens {
    // MARK: - Claude Code

    /// AskUserQuestion (single, multi-select, review) and permission dialogs.
    /// The panel starts under a full-width rule; its selection marker is ❯.
    static func claude(_ rows: [String]) -> AgentPromptObservationResult? {
        guard let last = rows.lastIndex(where: { !isBlank($0) }) else { return nil }
        var footer: String?
        var end = last
        if let hints = claudeFooter(rows, last: last) { footer = hints.text; end = hints.first - 1 }
        guard end >= 0 else { return nil }
        var start = end + 1
        var index = end
        while index >= 0 {
            let row = rows[index]
            if isBlank(row) || isRule(row) || claudeOption(row) != nil || claudeNextRow(row) != nil || indent(row) >= 3 {
                start = index; index -= 1; continue
            }
            break
        }
        guard start <= end, let firstOption = (start...end).first(where: { claudeOption(rows[$0]) != nil }) else { return nil }

        struct Parsed { var number: Int; var label: String; var selected: Bool; var checked: Bool?; var detail: [String] }
        var parsed: [Parsed] = []
        var next: Bool?
        var separatorAfter: Int?
        for row in rows[firstOption...end] {
            if isBlank(row) { continue }
            if isRule(row) { if separatorAfter == nil { separatorAfter = parsed.count }; continue }
            if let option = claudeOption(row) {
                parsed.append(.init(number: option.number, label: option.label, selected: option.selected, checked: option.checked, detail: []))
                continue
            }
            if let selected = claudeNextRow(row) { next = selected; continue }
            guard indent(row) >= 3, !parsed.isEmpty else { return nil }
            parsed[parsed.count - 1].detail.append(trimmed(row))
        }
        guard !parsed.isEmpty, parsed.count <= 9,
              parsed.enumerated().allSatisfy({ $0.offset + 1 == $0.element.number }) else { return nil }

        // A pane shorter than the dialog scrolls its top rule, and the tabs
        // or chip under it, off the screen, and a review of long questions
        // runs taller than the search for it. The key hints, or a review's
        // own last rows (it has no hints), still anchor it.
        let top: Int
        let anchoredByRule: Bool
        if let rule = (max(0, firstOption - 30)..<firstOption).last(where: { isRule(rows[$0]) }) {
            top = rule; anchoredByRule = true
        } else if footer != nil || isClaudeReviewTail(rows, firstOption: firstOption, labels: parsed.map(\.label)) {
            top = (0..<firstOption).last(where: { isRule(rows[$0]) }) ?? -1; anchoredByRule = false
        } else {
            return nil
        }
        // A long question is drawn behind a quote rail, "│ " on each row.
        let header = rows[(top + 1)..<firstOption].map { trimmed(withoutQuoteRail($0)) }.filter { !$0.isEmpty && !isBoxLine($0) }
        // Without its rule near, a dialog fills the rows above its options
        // with its question. Transcript output (⏺, ⎿) there is a printed
        // menu, and options alone could belong to any question. A row behind
        // the rail is the question's, whatever glyph it wraps onto.
        let transcript = rows[(top + 1)..<firstOption].contains {
            let row = trimmed($0)
            return row.hasPrefix("⏺") || row.hasPrefix("⎿")
        }
        if !anchoredByRule, header.isEmpty || transcript {
            return nil
        }
        let lower = header.map { $0.lowercased() }
        let tabBar = header.first(where: isClaudeTabBar)
        let chip = header.first { ($0.hasPrefix("☐") || $0.hasPrefix("☒")) && !isClaudeTabBar($0) }
        let chat = parsed.lastIndex { $0.label.lowercased() == "chat about this" }
        let placeholder = parsed.firstIndex { isClaudePlaceholder($0.label) }
        let kind: AgentPromptKind
        if lower.contains("review your answers") || lower.contains("ready to submit your answers?") {
            kind = .review
        } else if parsed.contains(where: { $0.checked != nil }) {
            kind = .multiSelect
        } else if tabBar != nil || chip != nil || chat != nil || placeholder != nil {
            kind = .question
        } else if header.contains(where: isClaudePermissionQuestion) {
            kind = .permission
        } else {
            return nil
        }

        var freeform: Int?
        if kind == .question || kind == .multiSelect {
            if let chat, let separatorAfter, separatorAfter == chat, chat > 0 { freeform = chat - 1 } else { freeform = placeholder }
        }
        let options: [AgentPromptMacroOption] = parsed.enumerated().compactMap { offset, option in
            let role: AgentPromptOptionRole = offset == freeform ? .freeform : offset == chat ? .chat : .choice
            // A single-choice text row shows what was typed in place of its
            // placeholder; `entry` carries that text, the label stays the row's.
            let label = role == .freeform && (option.label.isEmpty || kind == .question) ? "Type something." : option.label
            return AgentPromptMacroOption(id: "\(option.number)", label: label, responseMacro: "\(option.number)",
                isDefault: option.selected, detail: option.detail.joined(separator: " "), role: role,
                isChecked: option.checked, acceptsText: role == .freeform && kind == .question)
        }
        guard options.count == parsed.count else { return nil }
        var entry: AgentPromptEntry?
        if kind == .question, let freeform, parsed[freeform].selected {
            let text = parsed[freeform].label
            entry = .init(optionID: "\(parsed[freeform].number)", text: isClaudePlaceholder(text) ? "" : text)
        }

        var controls: [AgentPromptControl] = []
        if kind == .multiSelect, let next { controls.append(.init(kind: .next, label: "Next", isSelected: next)) }
        if kind == .question || kind == .multiSelect, footer?.lowercased().contains("esc to cancel") == true {
            controls.append(.init(kind: .cancel, label: "Cancel"))
        }

        let progress = tabBar.map { $0.replacingOccurrences(of: "←", with: "").replacingOccurrences(of: "→", with: "") }
            .map { collapse($0) }
        var title: String?
        var question: String?
        var detail: String?
        switch kind {
        case .question, .multiSelect:
            title = chip.map { collapse(String($0.dropFirst())) }
            question = header.filter { $0 != tabBar && $0 != chip && !$0.hasPrefix("⚠") }.joined(separator: " ")
        case .review:
            title = "Review your answers"
            question = header.last { $0.lowercased() == "ready to submit your answers?" } ?? "Ready to submit your answers?"
            detail = header.filter { $0 != tabBar && $0 != title && $0 != question }.joined(separator: "\n")
        default:
            question = header.last(where: isClaudePermissionQuestion)
            title = header.first.flatMap { $0 == question ? nil : $0 }
            detail = header.filter { $0 != title && $0 != question }.joined(separator: "\n")
        }

        let optionRows = options.map { "\($0.id). \(checkMark($0.isChecked))\($0.label) \($0.detail ?? "")" }
        let signature = compact(["claude", kind.rawValue] + header + optionRows + (next != nil ? ["Next"] : []) + [typed(entry)])
        let identity = compact(["claude", kind == .multiSelect ? "question" : kind.rawValue, question ?? title ?? "", detail ?? ""]
            + options.filter { $0.role != .freeform }.map(\.label))
        return .init(signature: signature, options: options, kind: kind, identity: identity, title: title,
                     question: question, detail: detail, progress: progress, controls: controls, entry: entry,
                     textFocus: kind == .question && freeform != nil ? .optionKey : nil)
    }

    private static func claudeOption(_ row: String) -> (selected: Bool, number: Int, label: String, checked: Bool?)? {
        guard let match = groups(claudeOptionPattern, row), let number = match[2].flatMap({ Int($0) }),
              let rest = match[3] else { return nil }
        if let box = groups(checkBoxPattern, rest), let mark = box[1] {
            return (match[1] != nil, number, box[2] ?? "", mark != " ")
        }
        return (match[1] != nil, number, rest, nil)
    }
    private static func claudeNextRow(_ row: String) -> Bool? {
        guard let match = groups(#"^\s*(❯)?\s+Next$"#, row) else { return nil }
        return match[1] != nil
    }
    private static func isClaudeFooter(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.contains("esc to cancel") || lower.contains("enter to select") || lower.contains("to navigate")
    }
    /// The key hints under a dialog. A phone-width pane wraps them at spaces
    /// over two or three rows ("… · Esc to" / "cancel"); every hint in a
    /// wrapped run still reads "<key> to <action>", a few words each.
    private static func claudeFooter(_ rows: [String], last: Int) -> (text: String, first: Int)? {
        var first = last
        while first > 0, last - first < 2 {
            let above = rows[first - 1]
            guard !isBlank(above), !isRule(above), claudeOption(above) == nil, claudeNextRow(above) == nil,
                  indent(above) < 3 else { break }
            first -= 1
        }
        while first < last {
            let text = collapse(rows[first...last].map(trimmed).joined(separator: " "))
            let hints = text.components(separatedBy: " · ")
            if isClaudeFooter(text), hints.allSatisfy({ groups(#"^\S+(?: \S+){0,2} to \S+(?: \S+){0,4}$"#, $0) != nil }) {
                return (text, first)
            }
            first += 1
        }
        return isClaudeFooter(rows[last]) ? (trimmed(rows[last]), last) : nil
    }
    /// Claude's review ends "Ready to submit your answers?" over exactly
    /// Submit answers and Cancel, and shows no key hints.
    private static func isClaudeReviewTail(_ rows: [String], firstOption: Int, labels: [String]) -> Bool {
        guard labels.map({ $0.lowercased() }) == ["submit answers", "cancel"],
              let above = previousNonBlank(rows, before: firstOption) else { return false }
        return trimmed(rows[above]).lowercased() == "ready to submit your answers?"
    }
    private static func withoutQuoteRail(_ row: String) -> String {
        let body = row.drop { $0 == " " }
        guard body.first == "│", body.dropFirst().first.map({ $0 == " " }) ?? true else { return row }
        return String(body.dropFirst())
    }
    private static func isClaudeTabBar(_ row: String) -> Bool {
        (row.contains("☐") || row.contains("☒")) && (row.contains("Submit") || row.contains("←"))
    }
    private static func isClaudePlaceholder(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower == "type something." || lower == "type something"
    }
    private static func isClaudePermissionQuestion(_ row: String) -> Bool {
        row.range(of: #"^(do you want to .+\?|would you like to .+\?|exit plan mode\?|quick safety check:?)$"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Codex

    /// Blocking `request_user_input` (Plan mode). Digits submit at once; notes
    /// open with Tab on the selected option.
    static func codexRequestUserInput(_ rows: [String]) -> AgentPromptObservationResult? {
        guard let last = rows.lastIndex(where: { !isBlank($0) }) else { return nil }
        let hints = codexFooter(rows, last: last)
        let footer = hints.text.lowercased()
        guard footer.contains("enter to submit answer") else { return nil }
        var index = previousNonBlank(rows, before: hints.first)
        var notes: String?
        if footer.contains("clear notes") {
            guard let row = index, let match = groups(#"^\s*›\s?(.*)$"#, rows[row]) else { return nil }
            let text = trimmed(match[1] ?? "")
            notes = text == "Add notes" ? "" : text
            index = previousNonBlank(rows, before: row)
        }
        guard let bottom = index, let block = codexOptionBlock(rows, bottom: bottom, splitDetail: true) else { return nil }
        var questionRows: [String] = []
        var progress: String?
        var cursor = block.top - 1
        while cursor >= 0, block.top - cursor <= 10 {
            let row = trimmed(rows[cursor])
            cursor -= 1
            if row.isEmpty { continue }
            if row.range(of: #"^Question \d+/\d+"#, options: .regularExpression) != nil { progress = row; break }
            questionRows.insert(row, at: 0)
        }
        guard let progress, !questionRows.isEmpty else { return nil }
        let freeform = block.options.lastIndex { $0.label.lowercased() == "none of the above" }
        let options: [AgentPromptMacroOption] = block.options.enumerated().compactMap { offset, option in
            AgentPromptMacroOption(id: "\(option.number)", label: option.label, responseMacro: "\(option.number)",
                isDefault: option.selected, detail: option.detail, role: offset == freeform ? .freeform : .choice,
                acceptsText: offset == freeform)
        }
        guard options.count == block.options.count else { return nil }
        let question = questionRows.joined(separator: " ")
        let entry = notes.map { AgentPromptEntry(optionID: options.first(where: \.isDefault)?.id, text: $0) }
        let signature = compact(["codex-request-user-input", progress, question]
            + options.map { "\($0.id). \($0.label) \($0.detail ?? "")" } + [typed(entry)])
        let identity = compact(["codex-request-user-input", question] + options.map(\.label))
        return .init(signature: signature, options: options, kind: .question, identity: identity, question: question,
                     progress: progress, entry: entry, textFocus: freeform != nil ? .selectThenTab : nil)
    }

    /// The expanded `request_user_input_async` panel. The turn keeps working
    /// behind it. Its last option is always the inline "Other" field.
    static func codexAsyncPanel(_ rows: [String]) -> AgentPromptObservationResult? {
        guard let last = rows.lastIndex(where: { !isBlank($0) }) else { return nil }
        let hints = codexFooter(rows, last: last)
        let footer = hints.text.lowercased()
        guard footer.hasPrefix("enter submit"), footer.contains("skip") || footer.contains("main prompt"),
              let bottom = previousNonBlank(rows, before: hints.first) else { return nil }
        var top = bottom
        while top > 0, !isBlank(rows[top - 1]) { top -= 1 }
        let block = codexOptionBlock(rows, bottom: bottom, splitDetail: false)
        let questionBottom: Int?
        if let block {
            guard block.top == top else { return nil }
            questionBottom = previousNonBlank(rows, before: block.top)
        } else {
            questionBottom = previousNonBlank(rows, before: top)
        }
        guard let questionBottom else { return nil }
        var questionRows: [String] = []
        var cursor = questionBottom
        while cursor >= 0, !isBlank(rows[cursor]), questionRows.count < 8 {
            let row = trimmed(rows[cursor])
            if row.hasPrefix("•") || row.hasPrefix("↳") { break }
            questionRows.insert(row, at: 0)
            cursor -= 1
        }
        var progress: String?
        if let first = questionRows.first, first.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil {
            progress = first; questionRows.removeFirst()
        }
        guard !questionRows.isEmpty else { return nil }
        let question = questionRows.joined(separator: " ")
        let controls = footer.contains("ctrl+] skip") ? [AgentPromptControl(kind: .skip, label: "Skip")] : []

        guard let block else {
            let text = rows[top...bottom].map(trimmed).joined(separator: " ")
            let entry = AgentPromptEntry(optionID: nil, text: text == "Type your answer" ? "" : text)
            let signature = compact(["codex-async", progress ?? "", question, typed(entry)])
            return .init(signature: signature, options: [], kind: .textEntry,
                         identity: compact(["codex-async", "text", question]), isBlocking: false,
                         question: question, progress: progress, controls: controls, entry: entry, textFocus: .focused)
        }
        let freeform = block.options.count - 1
        let options: [AgentPromptMacroOption] = block.options.enumerated().compactMap { offset, option in
            let isOther = offset == freeform
            let label = isOther ? "Other" : option.label
            return AgentPromptMacroOption(id: "\(option.number)", label: label, responseMacro: "\(option.number)",
                isDefault: option.selected, detail: option.detail, role: isOther ? .freeform : .choice, acceptsText: isOther)
        }
        guard options.count == block.options.count else { return nil }
        var entry: AgentPromptEntry?
        if block.options[freeform].selected {
            let text = block.options[freeform].label
            entry = .init(optionID: options[freeform].id, text: isCodexOtherPlaceholder(text) ? "" : text)
        }
        let signature = compact(["codex-async", progress ?? "", question] + options.map { "\($0.id). \($0.label)" } + [typed(entry)])
        let identity = compact(["codex-async", question] + options.dropLast().map(\.label))
        return .init(signature: signature, options: options, kind: .question, identity: identity, isBlocking: false,
                     question: question, progress: progress, controls: controls, entry: entry, textFocus: .optionKey)
    }

    /// Codex's collapsed async summary above its composer: "? 2 questions /
    /// shift+← to answer". The composer stays usable.
    static func codexDeferred(_ rows: [String]) -> AgentPromptObservationResult? {
        let filled = rows.indices.filter { !isBlank(rows[$0]) }
        for hint in filled.suffix(12).reversed() where trimmed(rows[hint]).lowercased().hasSuffix(" to answer") {
            guard let countRow = filled.last(where: { $0 < hint }),
                  let match = groups(#"^\?\s+(\d+)\s+questions?(?:\s+·\s+\d+[a-z]*)?$"#, trimmed(rows[countRow])),
                  let count = match[1].flatMap({ Int($0) }), count > 0 else { continue }
            let below = filled.filter { $0 > hint }
            guard let composer = below.prefix(3).first(where: {
                let row = trimmed(rows[$0])
                // Ultra effort changes the live composer glyph to »; the
                // numbered choices and notes field keep their own › marker.
                return (row.first == "›" || row.first == "»") &&
                    (row.count == 1 || row.dropFirst().first?.isWhitespace == true)
            }),
                  below.filter({ $0 > composer }).count <= 8 else { continue }
            let summary = count == 1 ? "1 question" : "\(count) questions"
            return .init(signature: "codex-deferred\u{1f}\(count)", options: [], kind: .deferred, identity: "codex-deferred",
                         isBlocking: false, question: summary, controls: [.init(kind: .open, label: "Answer")],
                         pendingCount: count)
        }
        return nil
    }

    /// The key hints under a Codex dialog. A phone-width pane wraps them,
    /// whole hints at a time, onto a second or third row at the same indent.
    private static func codexFooter(_ rows: [String], last: Int) -> (text: String, first: Int) {
        var first = last
        while first > 0, last - first < 2 {
            let above = rows[first - 1]
            guard !isBlank(above), indent(above) == indent(rows[last]), isCodexHintRow(above) else { break }
            first -= 1
        }
        return (collapse(rows[first...last].map(trimmed).joined(separator: " ")), first)
    }
    /// Hints only, "tab to add notes | enter to submit answer" or
    /// "enter submit   ctrl+] skip": a key, then a few words.
    private static func isCodexHintRow(_ row: String) -> Bool {
        let hints = trimmed(row).components(separatedBy: " | ")
            .flatMap { $0.components(separatedBy: "  ") }.map(trimmed).filter { !$0.isEmpty }
        return !hints.isEmpty && hints.allSatisfy {
            groups(#"^(?i:tab|enter|esc|space|ctrl\+\S+|shift\+\S+|alt\+\S+|\S*[←→↑↓]\S*)(?: to)? \S+(?: \S+){0,3}$"#, $0) != nil
        }
    }

    private struct CodexOption { var number: Int; var label: String; var selected: Bool; var detail: String? }
    /// Consecutive numbered rows ending at `bottom`; deeper-indented rows
    /// continue the option above them.
    private static func codexOptionBlock(_ rows: [String], bottom: Int, splitDetail: Bool) -> (top: Int, options: [CodexOption])? {
        var options: [CodexOption] = []
        var continuation: [String] = []
        var index = bottom
        var top = bottom
        while index >= 0, !isBlank(rows[index]) {
            let row = rows[index]
            if let match = groups(#"^\s*(›)?\s*(\d+)\.(?:\s+(.*))?$"#, row), let number = match[2].flatMap({ Int($0) }) {
                var label = trimmed(match[3] ?? "")
                var detail: [String] = []
                if splitDetail, let range = label.range(of: #"\s{2,}"#, options: .regularExpression) {
                    detail.append(trimmed(String(label[range.upperBound...])))
                    label = trimmed(String(label[..<range.lowerBound]))
                }
                detail += continuation.reversed()
                continuation = []
                options.insert(.init(number: number, label: label, selected: match[1] != nil,
                                     detail: detail.isEmpty ? nil : detail.joined(separator: " ")), at: 0)
                top = index
            } else if indent(row) >= 5 {
                continuation.append(trimmed(row))
            } else {
                break
            }
            index -= 1
        }
        guard !options.isEmpty, continuation.isEmpty, options.count <= 9,
              options.enumerated().allSatisfy({ $0.offset + 1 == $0.element.number }) else { return nil }
        return (top, options)
    }
    private static func isCodexOtherPlaceholder(_ label: String) -> Bool {
        label == "Other" || label == "Other (write an answer)"
    }

    // MARK: - Kimi Code

    /// AskUserQuestion (single, multi-select, review) and approvals. The panel
    /// sits between two rules above Kimi's status rows; its marker is → or ▶.
    static func kimi(_ rows: [String]) -> AgentPromptObservationResult? {
        let filled = rows.indices.filter { !isBlank(rows[$0]) }
        guard let rule = filled.suffix(5).last(where: { isRule(rows[$0]) }),
              filled.filter({ $0 > rule }).count <= 3,
              let footerRow = filled.last(where: { $0 < rule }) else { return nil }
        let footer = trimmed(rows[footerRow]).lowercased()
        let entryFooter = footer.contains("type answer") && footer.contains("save")
        guard entryFooter || footer.contains("select") && (footer.contains("choose") || footer.contains("toggle")),
              let bottom = previousNonBlank(rows, before: footerRow) else { return nil }

        struct Parsed { var number: Int?; var label: String; var selected: Bool; var checked: Bool?; var detail: [String] }
        var parsed: [Parsed] = []
        var pending: [String] = []
        var index = bottom
        while index >= 0 {
            let row = rows[index]
            if isBlank(row) { break }
            if let option = kimiOption(row) {
                parsed.insert(.init(number: option.number, label: option.label, selected: option.selected,
                                    checked: option.checked, detail: pending.reversed()), at: 0)
                pending = []
            } else if indent(row) >= 6 {
                pending.append(trimmed(row))
            } else {
                break
            }
            index -= 1
        }
        guard !parsed.isEmpty, pending.isEmpty, parsed.count <= 9 else { return nil }
        let checkBoxes = parsed.allSatisfy { $0.checked != nil }
        guard checkBoxes || parsed.allSatisfy({ $0.checked == nil }) else { return nil }
        if !checkBoxes {
            guard parsed.enumerated().allSatisfy({ $0.offset + 1 == $0.element.number }) else { return nil }
        }

        // The panel starts under its rule, however tall a review of long
        // questions runs. A pane shorter than the panel scrolls that rule off;
        // the bottom rule and key hints still anchor it. Kimi draws the
        // transcript's prompts (✨) and replies (●) one column in, where the
        // panel has only its labels, and wraps question text deeper: such a
        // row above the options is a printed panel.
        var header: [String] = []
        var top: Int?
        var cursor = index
        while cursor >= 0 {
            if isRule(rows[cursor]) { top = cursor; break }
            let row = trimmed(rows[cursor])
            if indent(rows[cursor]) <= 1, row.hasPrefix("✨") || row.hasPrefix("● ") { return nil }
            if !row.isEmpty { header.insert(row, at: 0) }
            cursor -= 1
        }
        if top == nil, header.isEmpty { return nil }
        let panelTop = top ?? -1
        let lower = header.map { $0.lowercased() }
        let questionRow = header.first { $0.hasPrefix("? ") }
        // A narrow pane wraps the question under its "? ", up to a blank row
        // or the text field's hint.
        var questionText = questionRow.map { String($0.dropFirst(2)) }
        if let start = rows.indices.first(where: { $0 > panelTop && $0 <= index && trimmed(rows[$0]).hasPrefix("? ") }) {
            var row = start + 1
            while row <= index, !isBlank(rows[row]), !trimmed(rows[row]).hasPrefix("Type your answer") {
                questionText = (questionText ?? "") + " " + trimmed(rows[row])
                row += 1
            }
        }
        let approvalRow = header.first { $0.hasPrefix("▶ ") && $0.hasSuffix("?") }
        let kind: AgentPromptKind
        if lower.contains("ready to submit your answers?") { kind = .review }
        else if checkBoxes { kind = .multiSelect }
        else if questionRow != nil { kind = .question }
        else if approvalRow != nil { kind = .permission }
        else { return nil }

        let freeform = kind == .question ? parsed.lastIndex { $0.label == "Other" || $0.label.hasPrefix("Other:") } : nil
        let options: [AgentPromptMacroOption] = parsed.enumerated().compactMap { offset, option in
            let number = option.number ?? offset + 1
            return AgentPromptMacroOption(id: "\(number)", label: offset == freeform ? "Other" : option.label,
                responseMacro: "\(number)", isDefault: option.selected, detail: option.detail.joined(separator: " "),
                role: offset == freeform ? .freeform : .choice, isChecked: option.checked, acceptsText: offset == freeform)
        }
        guard options.count == parsed.count else { return nil }
        var entry: AgentPromptEntry?
        if let freeform, parsed[freeform].selected, entryFooter || parsed[freeform].label.hasPrefix("Other:") {
            let label = parsed[freeform].label
            entry = .init(optionID: options[freeform].id,
                          text: label.hasPrefix("Other:") ? trimmed(String(label.dropFirst("Other:".count))) : "")
        }
        // A narrow pane elides the hints' tail ("←/→/tab switch ..."), where
        // every Kimi question keeps "tab switch  esc cancel"; the keys stay bound.
        let elided = footer.hasSuffix("...") || footer.hasSuffix("…")
        var controls: [AgentPromptControl] = []
        if kind == .multiSelect, footer.contains("tab switch") || elided { controls.append(.init(kind: .next, label: "Next")) }
        if kind != .permission, footer.contains("esc cancel") || elided { controls.append(.init(kind: .cancel, label: "Cancel")) }

        let tabBar = header.first { $0.hasSuffix("Submit") && !$0.hasPrefix("?") }
        let context = header.filter { $0 != "question" && $0 != tabBar && !$0.hasPrefix("Type your answer") }
        var title: String?
        var question: String?
        var detail: String?
        switch kind {
        case .question, .multiSelect:
            question = questionText
        case .review:
            title = header.first { $0.lowercased().hasPrefix("review your answer") }
            question = header.last { $0.lowercased() == "ready to submit your answers?" }
            detail = context.filter { $0 != title && $0 != question }.joined(separator: "\n")
        default:
            question = approvalRow.map { String($0.dropFirst(2)) }
            detail = context.filter { $0 != approvalRow }.joined(separator: "\n")
        }
        let signature = compact(["kimi", kind.rawValue] + context
            + options.map { "\($0.id). \(checkMark($0.isChecked))\($0.label) \($0.detail ?? "")" }
            + [typed(entry)])
        let identity = compact(["kimi", kind == .multiSelect ? "question" : kind.rawValue, question ?? "", detail ?? ""]
            + options.filter { $0.role != .freeform }.map(\.label))
        return .init(signature: signature, options: options, kind: kind, identity: identity, title: title,
                     question: question, detail: detail, progress: tabBar.map(collapse), controls: controls,
                     entry: entry, textFocus: freeform != nil ? .optionKey : nil)
    }

    private static func kimiOption(_ row: String) -> (number: Int?, label: String, selected: Bool, checked: Bool?)? {
        if let match = groups(#"^\s*(→|▶)?\s*\[(\d+)\]\s+(.+)$"#, row), let number = match[2].flatMap({ Int($0) }) {
            return (number, match[3] ?? "", match[1] != nil, nil)
        }
        if let match = groups(#"^\s*(→|▶)?\s*\[( |✓|x|X)\]\s+(.+)$"#, row) {
            return (nil, match[3] ?? "", match[1] != nil, match[2] != " ")
        }
        if let match = groups(#"^\s*(→|▶)?\s*(\d+)\.\s+(.+)$"#, row), let number = match[2].flatMap({ Int($0) }) {
            return (number, match[3] ?? "", match[1] != nil, nil)
        }
        return nil
    }

    // MARK: - Shared

    private static let claudeOptionPattern = #"^\s*(❯)?\s*(\d+)\.\s+(.*\S)\s*$"#
    private static let checkBoxPattern = #"^\[( |✔|✓|x|X)\]\s*(.*)$"#

    static func trimmed(_ row: String) -> String { row.trimmingCharacters(in: .whitespaces) }
    static func isBlank(_ row: String) -> Bool { row.allSatisfy(\.isWhitespace) }
    static func indent(_ row: String) -> Int { row.prefix { $0 == " " }.count }
    static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// A full-width horizontal rule (U+2500), as Claude and Kimi draw them
    /// around a dialog. Box-drawing dashes inside a diff are not rules.
    static func isRule(_ row: String) -> Bool {
        let body = trimmed(row)
        return body.count >= 20 && body.allSatisfy { $0 == "─" }
    }
    private static func isBoxLine(_ row: String) -> Bool {
        row.allSatisfy { "─━╌┄┈═".contains($0) }
    }
    private static func checkMark(_ checked: Bool?) -> String {
        switch checked { case .some(true): "[x] "; case .some(false): "[ ] "; case .none: "" }
    }
    private static func previousNonBlank(_ rows: [String], before index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            if !isBlank(rows[cursor]) { return cursor }
            cursor -= 1
        }
        return nil
    }

    /// Text typed into a field is part of the screen the person answers;
    /// focusing an empty field, like moving the selection, is not.
    private static func typed(_ entry: AgentPromptEntry?) -> String {
        entry.map { $0.text.isEmpty ? "" : "entry:\($0.text)" } ?? ""
    }

    /// Joins identity parts, keeping the result within the 1 KiB signature
    /// bound without losing distinctness: an over-long value keeps its head
    /// and a hash of the whole.
    static func compact(_ parts: [String]) -> String {
        let joined = parts.map(trimmed).filter { !$0.isEmpty }.joined(separator: "\u{1f}")
        guard joined.utf8.count > 1_024 else { return joined }
        let hash = joined.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        var head = ""
        var bytes = 0
        for character in joined {
            let size = String(character).utf8.count
            if bytes + size > 1_000 { break }
            head.append(character); bytes += size
        }
        return head + "#" + String(hash, radix: 16)
    }

    private static let regexCache = RegexCache()
    /// Capture groups of the first match; nil when the row does not match.
    static func groups(_ pattern: String, _ row: String) -> [String?]? {
        guard let regex = regexCache.regex(pattern),
              let match = regex.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: row).map { String(row[$0]) }
        }
    }

    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var compiled: [String: NSRegularExpression] = [:]
        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock(); defer { lock.unlock() }
            if let regex = compiled[pattern] { return regex }
            let regex = try? NSRegularExpression(pattern: pattern)
            compiled[pattern] = regex
            return regex
        }
    }
}
