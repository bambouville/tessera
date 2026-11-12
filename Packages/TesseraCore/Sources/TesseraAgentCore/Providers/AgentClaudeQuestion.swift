import Foundation

/// The questions of Claude's AskUserQuestion calls while they wait. A pane
/// shorter than the dialog scrolls the question off and leaves only its
/// options on screen; the waiting call says which question those options are.
enum AgentClaudeQuestion {
    struct Asked: Equatable {
        struct Option: Equatable {
            let label: String
            let description: String
        }
        let header: String?
        let question: String
        let options: [Option]
        let multiSelect: Bool
    }

    struct Call: Equatable {
        /// The call's tool-use ID, which its hooks name too. Nil when the
        /// projector kept none: such a call cannot be told from another.
        let id: String?
        /// Nil when the input is incomplete: the projector cuts long previews short.
        let questions: [Asked]?
    }

    /// Claude's AskUserQuestion calls of the current turn that no result
    /// names yet, oldest first; Claude draws their dialogs in that order. The
    /// turn starts at the newest prompt the person sent: Claude reads one only
    /// once every call before it has its result, so an Ask left without one
    /// by a killed session is not waiting in the resumed turn. A slash command
    /// or a background task's notice starts a turn with no message (the
    /// projector makes it system content), so such an Ask waits on through
    /// that turn; the runtime counts it as closed once its hooks, an
    /// interrupt or the end of its process close it. An interrupt's marker
    /// is no prompt, so the call it stopped is still found. A result
    /// may land between a batch's calls, and a sibling's result names the
    /// sibling. A block without an ID could be any call's or result's, so
    /// then the question waits only as the newest batch's one call, with no
    /// result after it and no older question waiting that no result after it
    /// could close. A subagent's own prompt would end the turn early, but
    /// Claude's reader keeps the main chain only, so none reaches the head.
    /// An earlier process's messages wait none: those written before `since`,
    /// that SessionStart's time by the host's clock. A call the hooks opened
    /// since (`opened`) at or past the cut proves it wrong (a clock stepped
    /// back). So does a question past it written up to a minute before the
    /// start that may be a sibling of one before it, as it is neither in
    /// `named` (the calls the hooks opened or the runtime closed) nor
    /// answered: a step back between a batch's calls. An earlier run's
    /// question that no hook named, written longer before, is still cut.
    /// Without the cut the whole turn is read, and a batch's calls wait
    /// together.
    static func pendingCalls(in messages: [AgentMessage], since: Date? = nil, opened: [String] = [],
                             named: [String] = []) -> [Call] {
        let turn = Array(messages.reversed().prefix { !isPrompt($0) })
        let results = Set(turn.flatMap { $0.blocks.compactMap { if case .toolResult(_, _, let id) = $0 { return id }; return nil } })
        var end = turn.endIndex
        if let since, let cut = turn.firstIndex(where: { $0.displayTime.map { $0 < since } ?? false }) {
            let contradicted = holds(turn[cut...]) { _, id in id.map { opened.contains($0) } ?? false }
            let askedSince = holds(turn[..<cut]) { name, _ in name == "AskUserQuestion" }
            let lately = turn[cut...].lazy.filter { $0.displayTime.map { since.timeIntervalSince($0) <= clockStep } ?? false }
            let unclaimedLately = holds(lately) { name, id in
                name == "AskUserQuestion" && !(id.map { named.contains($0) || results.contains($0) } ?? false)
            }
            if !contradicted, !(askedSince && unclaimedLately) { end = cut }
        }
        var answered = Set<String>()
        var anonymous = false, resultAfter = false, batchEnded = false
        var newestBatch = 0
        // Settled: a result after the call names it, or names none and could.
        var calls: [(name: String, preview: String, id: String?, settled: Bool)] = []
        for message in turn[..<end] {
            for block in message.blocks.reversed() {
                switch block {
                case .toolResult(_, _, let id):
                    if calls.isEmpty { resultAfter = true } else { batchEnded = true }
                    if let id { answered.insert(id) } else { anonymous = true }
                case .toolCall(let name, let preview, let id):
                    if !batchEnded { newestBatch += 1 }
                    calls.append((name, preview, id, anonymous || id.map { answered.contains($0) } == true))
                default: continue
                }
            }
        }
        guard !anonymous, calls.allSatisfy({ $0.id != nil }) else {
            guard !resultAfter, newestBatch == 1, let call = calls.first, call.name == "AskUserQuestion",
                  !calls.dropFirst().contains(where: { $0.name == "AskUserQuestion" && !$0.settled }) else { return [] }
            return [Call(id: call.id, questions: asked(call.preview))]
        }
        return calls.reversed().filter { $0.name == "AskUserQuestion" && !answered.contains($0.id ?? "") }
            .map { Call(id: $0.id, questions: asked($0.preview)) }
    }

    /// The marker Claude writes for an interrupt, as the person's message.
    static func isInterruptMarker(_ message: AgentMessage) -> Bool {
        guard message.role == .user, message.blocks.count == 1, case .text(let text) = message.blocks[0] else { return false }
        return text == "[Request interrupted by user]" || text == "[Request interrupted by user for tool use]"
    }

    /// The largest step back of the host's clock between a batch's calls
    /// that the cut allows for.
    private static let clockStep: TimeInterval = 60

    /// Whether a message of `part` holds a tool call, by name and ID, that passes `test`.
    private static func holds<Part: Sequence>(_ part: Part, _ test: (String, String?) -> Bool) -> Bool
        where Part.Element == AgentMessage {
        part.contains { $0.blocks.contains { if case .toolCall(let name, _, let id) = $0 { return test(name, id) }; return false } }
    }

    /// A message the person sent: tool results reach Claude as user messages
    /// too, but the projector gives those the tool role.
    private static func isPrompt(_ message: AgentMessage) -> Bool {
        message.role == .user && !message.blocks.isEmpty && !isInterruptMarker(message)
            && !message.blocks.contains { if case .toolResult = $0 { return true }; return false }
    }

    /// Whether the call's own result follows it. A result that names no call
    /// could be any call's, so it counts: that errs toward the call being
    /// closed. A sibling call's result names that call.
    static func hasResult(_ id: String, in messages: [AgentMessage]) -> Bool {
        var called = false
        for message in messages {
            for block in message.blocks {
                switch block {
                case .toolCall(_, _, let callID) where callID == id: called = true
                case .toolResult(_, _, let answered) where called && (answered == nil || answered == id): return true
                default: continue
                }
            }
        }
        return false
    }

    static func asked(_ preview: String) -> [Asked]? {
        guard let input = try? JSONDecoder().decode(AgentJSONValue.self, from: Data(preview.utf8)).objectValue,
              let questions = input["questions"]?.arrayValue, !questions.isEmpty else { return nil }
        var result: [Asked] = []
        for value in questions {
            guard let object = value.objectValue, let question = object["question"]?.stringValue,
                  let options = object["options"]?.arrayValue, !options.isEmpty else { return nil }
            let parsed = options.compactMap { option in
                option.objectValue.flatMap { option in
                    option["label"]?.stringValue.map { Asked.Option(label: $0, description: option["description"]?.stringValue ?? "") }
                }
            }
            guard parsed.count == options.count else { return nil }
            result.append(.init(header: object["header"]?.stringValue, question: question, options: parsed,
                                multiSelect: object["multiSelect"]?.boolValue ?? false))
        }
        return result
    }

    /// Whether the choices drawn on screen, Claude's own text rows left out,
    /// are this question's options.
    static func matches(_ asked: Asked, choices: [AgentPromptMacroOption], multiSelect: Bool) -> Bool {
        asked.multiSelect == multiSelect && asked.options.count == choices.count
            && zip(asked.options, choices).allSatisfy { drawn($0, as: $1) }
    }

    /// Claude draws each option's label, then its description under it. A
    /// label wider than the pane wraps onto the indented rows below, at a
    /// space or, for a word wider than the row, inside it; the description
    /// follows on rows of its own. So the drawn row starts the label and,
    /// read without its wrapping, the option's text is the label then the
    /// description, exactly. The display bound cuts a very long one short.
    private static func drawn(_ option: Asked.Option, as choice: AgentPromptMacroOption) -> Bool {
        let label = unwrapped(option.label), shown = unwrapped(choice.label)
        guard !shown.isEmpty, label.hasPrefix(shown) else { return false }
        let whole = label + unwrapped(option.description), seen = shown + unwrapped(choice.detail ?? "")
        return whole == seen || (choice.detail?.count ?? 0) >= AgentPromptMacroOption.detailBound && whole.hasPrefix(seen)
    }

    private static func unwrapped(_ text: String) -> String {
        String(AgentDisplayText.sanitize(text).unicodeScalars.filter { !$0.properties.isWhitespace })
    }
}
