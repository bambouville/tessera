import Foundation

/// What the person chose in a live prompt card.
public struct AgentPromptAnswerGoal: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case option, text, control }
    public let kind: Kind
    public let optionID: String?
    public let text: String?
    public let control: AgentPromptControlKind?

    public static func option(_ id: String) -> Self { .init(kind: .option, optionID: id, text: nil, control: nil) }
    public static func text(_ value: String) -> Self { .init(kind: .text, optionID: nil, text: value, control: nil) }
    public static func control(_ kind: AgentPromptControlKind) -> Self { .init(kind: .control, optionID: nil, text: nil, control: kind) }

    private init(kind: Kind, optionID: String?, text: String?, control: AgentPromptControlKind?) {
        self.kind = kind; self.optionID = optionID; self.text = text; self.control = control
    }

    /// Exactly the field its kind names is set, within the prompt bounds.
    public var isValid: Bool {
        switch kind {
        case .option: return optionID.map { !$0.isEmpty && $0.utf8.count <= 64 } == true && text == nil && control == nil
        case .text: return text.map { !AgentPromptAnswerPlanner.sanitizedText($0).isEmpty && $0.utf8.count <= 8_192 } == true
            && optionID == nil && control == nil
        case .control: return control != nil && optionID == nil && text == nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, optionID, text, control }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind),
                  optionID: try values.decodeIfPresent(String.self, forKey: .optionID),
                  text: try values.decodeIfPresent(String.self, forKey: .text),
                  control: try values.decodeIfPresent(AgentPromptControlKind.self, forKey: .control))
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "invalid answer goal") }
    }
}

/// The prompt as it was when the answer started. Later steps compare fresh
/// screens against it, never against a display label.
public struct AgentPromptAnswerAnchor: Equatable, Codable, Sendable {
    public let signature: String
    public let identity: String
    public let kind: AgentPromptKind
    public let selectedOptionID: String?
    public let freeformOptionID: String?
    public let textFocus: AgentPromptTextFocus?

    public init(_ observation: AgentPromptObservationResult) {
        signature = observation.signature
        identity = observation.identity
        kind = observation.kind
        selectedOptionID = observation.selectedOptionID
        freeformOptionID = observation.freeformOption?.id
        textFocus = observation.textFocus
    }
}

public enum AgentPromptAnswerPhase: String, Codable, Sendable {
    /// An option's own key.
    case select
    /// Enter after a select left the same menu open with that option selected.
    case confirm
    /// A key that opens a text field; it never answers.
    case focus
    /// An arrow key moving the selection toward the text row.
    case navigate
    /// The answer text itself.
    case type
    /// Enter after the typed text is visible.
    case submit
    case control
    /// No write: capture again after a short pause.
    case wait
}

/// Named tmux keys; raw carriers keep the same encoded bytes. This is
/// additive to the planner's byte output so older ABI consumers still work.
public enum AgentPromptAnswerKey: String, Codable, Sendable {
    case enter = "Enter", escape = "Escape", tab = "Tab", backTab = "BTab"
    case up = "Up", down = "Down", left = "Left", right = "Right"
    case shiftLeft = "S-Left", controlRightBracket = "C-]"

    public var bytes: String {
        switch self {
        case .enter: "\r"
        case .escape: "\u{1b}"
        case .tab: "\t"
        case .backTab: "\u{1b}[Z"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .left: "\u{1b}[D"
        case .right: "\u{1b}[C"
        case .shiftLeft: "\u{1b}[1;2D"
        case .controlRightBracket: "\u{1d}"
        }
    }

    public init?(bytes: String) {
        switch bytes {
        case "\r": self = .enter
        case "\u{1b}": self = .escape
        case "\t": self = .tab
        case "\u{1b}[Z": self = .backTab
        case "\u{1b}[A": self = .up
        case "\u{1b}[B": self = .down
        case "\u{1b}[D": self = .left
        case "\u{1b}[C": self = .right
        case "\u{1b}[1;2D": self = .shiftLeft
        case "\u{1d}": self = .controlRightBracket
        default: return nil
        }
    }
}

public struct AgentPromptAnswerStep: Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case send, wait, done, refuse }
    public enum Refusal: String, Codable, Sendable {
        /// The screen is not the prompt the person answered.
        case stalePrompt
        /// The prompt does not offer this answer.
        case unsupported
        /// A write did not produce the screen it should have.
        case verificationFailed
        /// The prompt's text field already holds other text.
        case occupied
    }
    public let action: Action
    /// Exact terminal bytes, from the fixed vocabulary or the sanitized text.
    public let bytes: String?
    /// Prefer this key on tmux. `bytes` remains available to raw carriers and
    /// Android consumers that have not yet adopted named prompt keys.
    public let semanticKey: AgentPromptAnswerKey?
    public let phase: AgentPromptAnswerPhase?
    public let refusal: Refusal?

    static func send(_ bytes: String, _ phase: AgentPromptAnswerPhase) -> Self {
        .init(action: .send, bytes: bytes, semanticKey: phase == .type ? nil : AgentPromptAnswerKey(bytes: bytes), phase: phase, refusal: nil)
    }
    static let wait = Self(action: .wait, bytes: nil, semanticKey: nil, phase: .wait, refusal: nil)
    static let done = Self(action: .done, bytes: nil, semanticKey: nil, phase: nil, refusal: nil)
    static func refuse(_ reason: Refusal) -> Self { .init(action: .refuse, bytes: nil, semanticKey: nil, phase: nil, refusal: reason) }
}

public struct AgentPromptAnswerPlan: Equatable, Codable, Sendable {
    public let step: AgentPromptAnswerStep
    /// Pass back unchanged with the next step's request.
    public let anchor: AgentPromptAnswerAnchor?
}

/// Plans one terminal write at a time for a live prompt answer.
///
/// Both platforms run the same bounded loop: settle a fresh capture of the
/// exact binding, parse it, call `next`, perform the step, and repeat with the
/// step's phase appended to `history` (a `wait` step appends `.wait`). The
/// first step refuses unless the screen still shows the prompt the person
/// answered. Every later write depends on what the screen showed after the
/// previous one, so a key never lands on a screen it was not planned for.
public enum AgentPromptAnswerPlanner {
    public static let maximumSteps = 24
    /// Consecutive captures a write may take to repaint before it fails.
    public static let maximumWaits = 6
    /// Pause before each capture after a write or wait.
    public static let settleDelayMilliseconds = 120

    public static func next(provider: AgentProviderID, goal: AgentPromptAnswerGoal, expectedSignature: String,
                            anchor: AgentPromptAnswerAnchor?, observation: AgentPromptObservationResult?,
                            history: [AgentPromptAnswerPhase]) -> AgentPromptAnswerPlan {
        guard goal.isValid else { return .init(step: .refuse(.unsupported), anchor: anchor) }
        let acted = history.filter { $0 != .wait }
        guard let anchor, !acted.isEmpty else {
            guard let observation, observation.signature == expectedSignature else {
                return .init(step: .refuse(.stalePrompt), anchor: nil)
            }
            let anchor = AgentPromptAnswerAnchor(observation)
            return .init(step: first(provider: provider, goal: goal, observation: observation, anchor: anchor), anchor: anchor)
        }
        guard history.count < maximumSteps else { return .init(step: .refuse(.verificationFailed), anchor: anchor) }
        return .init(step: following(provider: provider, goal: goal, anchor: anchor, observation: observation,
                                     history: history, acted: acted), anchor: anchor)
    }

    /// Typed answers are one line of printable text: these TUIs submit on
    /// Enter, and a control byte inside a field would act as a key.
    public static func sanitizedText(_ value: String) -> String {
        let lineBreaks: Set<UInt32> = [9, 10, 13, 0x2028, 0x2029]
        let scalars = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            lineBreaks.contains(scalar.value) ? " " : scalar
        }.filter { scalar -> Bool in
            let code = scalar.value
            return code >= 32 && !(0x7f...0x9f).contains(code)
        }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(2_000))
    }

    private static func first(provider: AgentProviderID, goal: AgentPromptAnswerGoal,
                              observation: AgentPromptObservationResult, anchor: AgentPromptAnswerAnchor) -> AgentPromptAnswerStep {
        switch goal.kind {
        case .option:
            // A text row's key only opens its field; answering through it
            // needs the text goal.
            guard let option = observation.options.first(where: { $0.id == goal.optionID }), !option.acceptsText else {
                return .refuse(.unsupported)
            }
            // A digit typed while a text field has focus lands in the field.
            // An arrow leaves an empty field; typed text belongs to someone.
            if let entry = observation.entry {
                guard entry.text.isEmpty, entry.optionID != nil else { return .refuse(.occupied) }
                return navigate(toward: option.id, observation: observation)
            }
            return .send(option.responseMacro, .select)
        case .text:
            let text = sanitizedText(goal.text ?? "")
            if let entry = observation.entry, anchor.textFocus == .focused || entry.optionID == anchor.freeformOptionID {
                return type(text, into: entry, acted: [], waits: 0)
            }
            guard let focus = anchor.textFocus, let freeform = observation.freeformOption else { return .refuse(.unsupported) }
            switch focus {
            case .focused: return .refuse(.unsupported)
            case .optionKey: return .send(freeform.responseMacro, .focus)
            case .selectThenTab: return navigate(toward: freeform.id, observation: observation)
            }
        case .control:
            guard let kind = goal.control, let control = observation.controls.first(where: { $0.kind == kind }) else {
                return .refuse(.unsupported)
            }
            return .send(controlBytes(kind, provider: provider, control: control), .control)
        }
    }

    private static func following(provider: AgentProviderID, goal: AgentPromptAnswerGoal, anchor: AgentPromptAnswerAnchor,
                                  observation: AgentPromptObservationResult?, history: [AgentPromptAnswerPhase],
                                  acted: [AgentPromptAnswerPhase]) -> AgentPromptAnswerStep {
        let waits = history.reversed().prefix { $0 == .wait }.count
        func settle() -> AgentPromptAnswerStep { waits < maximumWaits ? .wait : .refuse(.verificationFailed) }
        let last = acted.last!
        guard let observation, observation.identity == anchor.identity else {
            // The question left the screen: answered, advanced or dismissed.
            // Keys that only focus or navigate never do that themselves.
            switch last {
            case .select, .confirm, .submit, .control: return .done
            case .focus, .navigate, .type, .wait: return .refuse(.verificationFailed)
            }
        }
        switch goal.kind {
        case .option:
            if !acted.contains(.select) {
                // The arrow that left a text field has not repainted yet.
                if let entry = observation.entry { return entry.text.isEmpty ? settle() : .refuse(.occupied) }
                guard let option = observation.options.first(where: { $0.id == goal.optionID }), !option.acceptsText else {
                    return .refuse(.unsupported)
                }
                return .send(option.responseMacro, .select)
            }
            // A check box that toggled is the whole answer.
            if observation.signature != anchor.signature { return .done }
            // Claude and Kimi act on a digit at once: this frame predates it.
            // So do Codex's question panels and its letter-keyed approvals.
            guard provider == .codex, anchor.kind == .permission, let id = goal.optionID,
                  observation.options.first(where: { $0.id == id })?.responseMacro.allSatisfy(\.isNumber) == true
            else { return settle() }
            // A Codex list row that requires explicit confirmation only moves
            // the selection. Enter is safe once that same menu shows it
            // selected: the move itself, or a repaint window with nothing changed.
            if !acted.contains(.confirm), observation.selectedOptionID == id,
               anchor.selectedOptionID != id || waits >= 3 {
                return .send("\r", .confirm)
            }
            return settle()
        case .text:
            let text = sanitizedText(goal.text ?? "")
            if let entry = observation.entry, anchor.textFocus == .focused || entry.optionID == anchor.freeformOptionID {
                return type(text, into: entry, acted: acted, waits: waits)
            }
            if acted.contains(.type) || acted.contains(.submit) { return settle() }
            switch anchor.textFocus {
            case .selectThenTab:
                guard let target = anchor.freeformOptionID else { return .refuse(.unsupported) }
                if observation.selectedOptionID != target {
                    // One arrow per repaint: a second arrow sent before the
                    // first shows would overshoot the text row.
                    if last == .navigate, waits == 0 { return .wait }
                    guard acted.filter({ $0 == .navigate }).count < 9 else { return .refuse(.verificationFailed) }
                    return navigate(toward: target, observation: observation)
                }
                if acted.contains(.focus) { return settle() }
                return .send("\t", .focus)
            case .optionKey, .focused, .none:
                return settle()
            }
        case .control:
            // Claude leaves a multi-select through its Next row: Tab from the
            // text row lands there, and Enter on it advances.
            if goal.control == .next, provider == .claude,
               observation.controls.first(where: { $0.kind == .next })?.isSelected == true {
                return acted.filter({ $0 == .control }).count >= 2 ? settle() : .send("\r", .control)
            }
            if observation.signature != anchor.signature { return .done }
            return settle()
        }
    }

    private static func type(_ text: String, into entry: AgentPromptEntry, acted: [AgentPromptAnswerPhase], waits: Int) -> AgentPromptAnswerStep {
        func settle() -> AgentPromptAnswerStep { waits < maximumWaits ? .wait : .refuse(.verificationFailed) }
        guard !text.isEmpty else { return .refuse(.unsupported) }
        if entry.text.isEmpty {
            return acted.contains(.type) ? settle() : .send(text, .type)
        }
        if shows(entry.text, text) {
            return acted.contains(.submit) ? settle() : .send("\r", .submit)
        }
        // A partial repaint of what was typed, or someone else's text.
        return acted.contains(.type) && !acted.contains(.submit) ? settle() : .refuse(.occupied)
    }

    /// The field shows the typed text, allowing for a TUI that truncates or
    /// scrolls a long value within its row.
    static func shows(_ shown: String, _ text: String) -> Bool {
        let visible = AgentPromptScreens.collapse(shown).trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        let wanted = AgentPromptScreens.collapse(text)
        if visible == wanted { return true }
        guard !visible.isEmpty, visible.count >= min(wanted.count, 12) else { return false }
        return wanted.hasPrefix(visible) || wanted.hasSuffix(visible)
    }

    private static func navigate(toward target: String, observation: AgentPromptObservationResult) -> AgentPromptAnswerStep {
        guard let destination = Int(target), let current = observation.selectedOptionID.flatMap(Int.init) else {
            return .refuse(.unsupported)
        }
        return .send(destination > current ? "\u{1b}[B" : "\u{1b}[A", .navigate)
    }

    private static func controlBytes(_ kind: AgentPromptControlKind, provider: AgentProviderID, control: AgentPromptControl) -> String {
        switch kind {
        case .open: return "\u{1b}[1;2D"
        case .skip: return "\u{1d}"
        case .cancel: return "\u{1b}"
        case .next: return provider == .claude && control.isSelected ? "\r" : "\t"
        }
    }
}

/// One planner step requested through the Agent ABI with a fresh capture.
public struct AgentPromptAnswerPlanInput: Equatable, Codable, Sendable {
    public let goal: AgentPromptAnswerGoal
    public let expectedSignature: String
    public let anchor: AgentPromptAnswerAnchor?
    public let history: [AgentPromptAnswerPhase]

    public init(goal: AgentPromptAnswerGoal, expectedSignature: String, anchor: AgentPromptAnswerAnchor?, history: [AgentPromptAnswerPhase]) {
        self.goal = goal; self.expectedSignature = expectedSignature; self.anchor = anchor; self.history = history
    }

    public var isValid: Bool {
        goal.isValid && !expectedSignature.isEmpty && expectedSignature.utf8.count <= 1_024
            && history.count <= AgentPromptAnswerPlanner.maximumSteps
    }
}
