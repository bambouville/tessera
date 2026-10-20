import Foundation

public enum AgentActionKind: String, Codable, Sendable {
    case send
    case queue
    case interrupt
    case answerPrompt
    case spawn
    case fork
    case openTerminal
}

public struct AgentActionLease: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public let token: UUID
    public let binding: AgentTerminalBinding
    /// Optional only for decoding ABI-v1 leases emitted before action-kind
    /// correlation existed. Newly acquired leases always populate it.
    public let action: AgentActionKind?

    public init(threadID: AgentThreadID, token: UUID = UUID(), binding: AgentTerminalBinding, action: AgentActionKind? = nil) {
        self.threadID = threadID
        self.token = token
        self.binding = binding
        self.action = action
    }
}

/// Typed action material carried across the ABI. Exactly one field is valid
/// for the requested action; a platform must execute this plan, never infer a
/// command from a display string.
public struct AgentABIActionPayload: Equatable, Codable, Sendable {
    public let text: AgentTextSendRequest?
    public let promptAnswer: AgentPromptAnswerRequest?
    public let targetBinding: AgentTerminalBinding?

    public init(text: AgentTextSendRequest? = nil, promptAnswer: AgentPromptAnswerRequest? = nil, targetBinding: AgentTerminalBinding? = nil) {
        self.text = text; self.promptAnswer = promptAnswer; self.targetBinding = targetBinding
    }

    public func isValid(for action: AgentActionKind, threadID: AgentThreadID, binding: AgentTerminalBinding) -> Bool {
        switch action {
        case .send: return validatedText == text && text?.threadID == threadID && text?.binding == binding && text?.queueWhenWorking == false && promptAnswer == nil && targetBinding == nil
        case .queue: return validatedText == text && text?.threadID == threadID && text?.binding == binding && text?.queueWhenWorking == true && promptAnswer == nil && targetBinding == nil
        case .answerPrompt: return validatedPromptAnswer == promptAnswer && promptAnswer?.threadID == threadID && promptAnswer?.binding == binding && text == nil && targetBinding == nil
        case .interrupt, .openTerminal: return targetBinding == binding && text == nil && promptAnswer == nil
        case .spawn, .fork: return false
        }
    }

    private var validatedText: AgentTextSendRequest? {
        guard let text else { return nil }
        return AgentTextSendRequest(threadID: text.threadID, binding: text.binding, text: text.text,
            queueWhenWorking: text.queueWhenWorking, composerVerification: text.composerVerification)
    }

    private var validatedPromptAnswer: AgentPromptAnswerRequest? {
        guard let promptAnswer else { return nil }
        return AgentPromptAnswerRequest(
            threadID: promptAnswer.threadID,
            binding: promptAnswer.binding,
            actionToken: promptAnswer.actionToken,
            expectedSignature: promptAnswer.expectedSignature,
            optionID: promptAnswer.optionID,
            text: promptAnswer.text,
            control: promptAnswer.control
        )
    }
}

/// `notSent` is a platform's proof that no byte reached the terminal: the
/// input surface was refused before the write, so nothing can be pending.
public enum AgentActionResultStatus: String, Codable, Sendable { case verified, failed, staleBinding, cancelled, notSent }
public struct AgentActionResultOutcome: Equatable, Codable, Sendable {
    public let status: AgentActionResultStatus
    public let action: AgentActionKind
    public let verification: String?
    public init?(status: AgentActionResultStatus, action: AgentActionKind, verification: String? = nil) {
        // Results cross a privacy boundary.  Keep only a compact, redacted
        // platform evidence code; terminal output, paths, prompts, and server
        // error text are not admissible here.
        let validVerification = verification.map {
            !$0.isEmpty && $0.utf8.count <= 64 &&
                $0.utf8.allSatisfy {
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                        ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
                }
        } ?? false
        switch status {
        case .verified:
            guard validVerification else { return nil }
        case .failed, .staleBinding, .cancelled:
            guard verification == nil else { return nil }
        case .notSent:
            // Only text input has a draft to return.
            guard verification == nil, action == .send || action == .queue else { return nil }
        }
        self.status = status; self.action = action; self.verification = verification
    }

    private enum CodingKeys: String, CodingKey { case status, action, verification }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(AgentActionResultStatus.self, forKey: .status)
        let action = try container.decode(AgentActionKind.self, forKey: .action)
        let verification = try container.decodeIfPresent(String.self, forKey: .verification)
        guard let validated = Self(status: status, action: action, verification: verification) else {
            throw DecodingError.dataCorruptedError(forKey: .verification, in: container, debugDescription: "Invalid action result outcome")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(verification, forKey: .verification)
    }
}

public enum AgentActionError: String, Error, Equatable, Sendable {
    case unavailable
    case actionInFlight
    case staleBinding
    case invalidLaunch
    case stalePrompt
    case verificationFailed
    case cancelled
    /// Refused before any write: the agent's input was not ready (a dialog,
    /// a redraw, or a capture that never settled).
    case inputNotReady
    /// Refused before any write: the terminal's own composer holds a draft.
    case terminalDraft
}

public protocol AgentTerminalObservationPort: Sendable {
    func observe(binding: AgentTerminalBinding) async throws -> AgentTerminalObservation
}

public struct AgentTerminalObservation: Equatable, Sendable {
    public let binding: AgentTerminalBinding
    public let liveTail: String
    public let prompt: AgentAuthoritativePrompt?
    public init(binding: AgentTerminalBinding, liveTail: String, prompt: AgentAuthoritativePrompt? = nil) {
        self.binding = binding
        self.liveTail = String(liveTail.prefix(16_384))
        self.prompt = prompt
    }
}

public struct AgentAuthoritativePrompt: Equatable, Codable, Sendable {
    public let signature: String
    public let options: [AgentPromptOption]
    public let cursorOwned: Bool
    public let visiblyBlocking: Bool

    public init?(signature: String, options: [AgentPromptOption], cursorOwned: Bool, visiblyBlocking: Bool) {
        guard !signature.isEmpty, signature.utf8.count <= 1_024, options.count <= 9 else { return nil }
        self.signature = signature
        self.options = options
        self.cursorOwned = cursorOwned
        self.visiblyBlocking = visiblyBlocking
    }
}

public struct AgentPromptAnswerRequest: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public let binding: AgentTerminalBinding
    public let actionToken: AgentActionToken
    public let expectedSignature: String
    /// The chosen option; for a typed answer the text row's option (or
    /// "text" for a text-only question), for a control its kind.
    public let optionID: String
    /// A typed answer. Mutually exclusive with `control`.
    public let text: String?
    public let control: AgentPromptControlKind?

    public init?(
        threadID: AgentThreadID,
        binding: AgentTerminalBinding,
        actionToken: AgentActionToken,
        expectedSignature: String,
        optionID: String,
        text: String? = nil,
        control: AgentPromptControlKind? = nil
    ) {
        guard !expectedSignature.isEmpty,
              expectedSignature.utf8.count <= 1_024,
              !optionID.isEmpty,
              optionID.utf8.count <= 64,
              text == nil || control == nil,
              text.map({ $0.utf8.count <= 8_192 && !AgentPromptAnswerPlanner.sanitizedText($0).isEmpty }) ?? true
        else { return nil }
        self.threadID = threadID
        self.binding = binding
        self.actionToken = actionToken
        self.expectedSignature = expectedSignature
        self.optionID = optionID
        self.text = text
        self.control = control
    }

    /// What the answer planner drives the terminal toward.
    public var goal: AgentPromptAnswerGoal {
        if let control { return .control(control) }
        if let text { return .text(text) }
        return .option(optionID)
    }
}

/// A one-action user choice about display evidence, never terminal authority.
/// Both modes keep the normal action lease, process proof, transcript parsing,
/// and outgoing receipt lifecycle. No preference persists this override.
public enum AgentComposerVerification: String, Codable, Sendable {
    case required
    case userOverride
}

public struct AgentTextSendRequest: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public let binding: AgentTerminalBinding
    public let text: String
    public let queueWhenWorking: Bool
    public let composerVerification: AgentComposerVerification

    public init?(threadID: AgentThreadID, binding: AgentTerminalBinding, text: String, queueWhenWorking: Bool) {
        self.init(threadID: threadID, binding: binding, text: text, queueWhenWorking: queueWhenWorking, composerVerification: .required)
    }

    public init?(threadID: AgentThreadID, binding: AgentTerminalBinding, text: String, queueWhenWorking: Bool,
                 composerVerification: AgentComposerVerification) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty, normalized.utf8.count <= 32_768,
              !normalized.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }),
              composerVerification == .required || threadID.providerID == .codex || threadID.providerID == .claude else { return nil }
        self.threadID = threadID
        self.binding = binding
        self.text = normalized
        self.queueWhenWorking = queueWhenWorking
        self.composerVerification = composerVerification
    }

    /// The user explicitly chose to submit without reading the composer.
    /// Preserve Queue intent: Codex's Return steers, while Tab queues.
    public var userOverrideSubmissionKey: AgentComposerEvidence.SubmissionKey? {
        guard composerVerification == .userOverride else { return nil }
        return threadID.providerID == .codex && queueWhenWorking ? .tab : .return
    }

    private enum CodingKeys: String, CodingKey {
        case threadID, binding, text, queueWhenWorking, composerVerification
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let threadID = try values.decode(AgentThreadID.self, forKey: .threadID)
        let binding = try values.decode(AgentTerminalBinding.self, forKey: .binding)
        let text = try values.decode(String.self, forKey: .text)
        let queue = try values.decode(Bool.self, forKey: .queueWhenWorking)
        let verification = try values.decodeIfPresent(AgentComposerVerification.self, forKey: .composerVerification) ?? .required
        guard let request = Self(threadID: threadID, binding: binding, text: text, queueWhenWorking: queue,
                                 composerVerification: verification), request.text == text else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: values, debugDescription: "Invalid terminal text request")
        }
        self = request
    }
}

/// One non-replayed insertion stream; the caller must still verify the complete
/// visible draft before sending its separate submission key.
public enum AgentTextInsertion {
    /// Agent Center uploads append one JSON-quoted absolute path per line.
    /// Image recognition requires the entire paste event to be one path.
    public struct Images: Equatable, Sendable {
        public let paths: [String]
        public let submittedText: String
        fileprivate let pastes: [Paste]

        /// Claude's image IDs are session-global. Capture only the generated
        /// markers; marker-looking prose remains literal and must also match.
        func claudeRenderedText(matching value: String, ignoringWhitespace: Bool = false) -> String? {
            func comparable(_ text: String) -> String {
                ignoringWhitespace ? text.filter { !$0.isWhitespace } : text
            }
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = pastes.enumerated().map { index, event -> String in
                switch event {
                case .text(let text):
                    var text = text[...]
                    if index == 0 { text = text.drop(while: \.isWhitespace) }
                    if index == pastes.count - 1 { while text.last?.isWhitespace == true { text = text.dropLast() } }
                    return NSRegularExpression.escapedPattern(for: comparable(String(text)))
                case .image: return ignoringWhitespace ? #"\[Image#([1-9][0-9]*)\]"# : #"\[Image #([1-9][0-9]*)\]"#
                }
            }.joined()
            guard let regex = try? NSRegularExpression(pattern: "\\A" + pattern + "\\z"),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  match.numberOfRanges == paths.count + 1 else { return nil }
            var numbers: [Int] = []
            for index in 1...paths.count {
                guard let range = Range(match.range(at: index), in: value), let number = Int(value[range]),
                      numbers.last.map({ $0 < Int.max && number == $0 + 1 }) ?? true else { return nil }
                numbers.append(number)
            }
            var index = 0
            return pastes.map { event in
                switch event {
                case .text(let text): return text
                case .image:
                    defer { index += 1 }
                    return "[Image #\(numbers[index])]"
                }
            }.joined()
        }
    }
    public typealias CodexImages = Images
    fileprivate enum Paste: Equatable, Sendable { case text(String), image(String) }

    public static func matchesReceipt(provider: String, text: String, blocks: [AgentBlock]) -> Bool {
        func matchesText() -> Bool {
            return blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }; return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let images = images(provider: provider, text: text) else { return matchesText() }
        if provider == "claude" {
            if blocks.count == images.paths.count + 1, case .text(let rendered) = blocks.first,
               images.claudeRenderedText(matching: rendered) != nil,
               blocks.dropFirst().allSatisfy({ $0 == .attachment(name: "Image", mediaType: "image") }) { return true }
            return matchesText()
        }
        // Codex persists the actual image inputs before its transformed prose.
        // A marker typed as ordinary text is never enough to acknowledge one.
        guard blocks.count == images.paths.count * 3 + 1 else { return false }
        for (index, path) in images.paths.enumerated() {
            guard blocks[index * 3] == .text("<image name=[Image #\(index + 1)] path=\"\(path)\">"),
                  blocks[index * 3 + 2] == .text("</image>") else { return false }
            switch blocks[index * 3 + 1] {
            case .attachment(name: "Image", mediaType: "image"): break
            default: return false
            }
        }
        return blocks.last == .text(images.submittedText)
    }

    public static func codexImages(provider: String, text: String) -> CodexImages? {
        guard provider == "codex" else { return nil }
        return images(provider: provider, text: text)
    }

    public static func images(provider: String, text: String) -> Images? {
        guard ["codex", "claude"].contains(provider), !text.isEmpty, text.utf8.count <= 32_768,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else { return nil }
        var paths: [String] = [], pastes: [Paste] = [], submitted = "", prose = ""
        func flush() {
            if !prose.isEmpty { pastes.append(.text(prose)); prose = "" }
        }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let quoted = line.trimmingCharacters(in: .whitespaces)
            if let data = quoted.data(using: .utf8),
               let path = try? JSONDecoder().decode(String.self, from: data),
               (path.hasPrefix("/") || path.hasPrefix("\\\\") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil), path.utf8.count <= 2_048,
               !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
               ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString).pathExtension.lowercased()) {
                flush()
                paths.append(path)
                // Shell quoting is consumed by Codex, never executed by a shell.
                let windows = path.hasPrefix("\\\\") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
                pastes.append(.image(provider == "claude" ? quoted : windows ? "\"" + path + "\"" : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"))
                submitted += "[Image #\(paths.count)]" + (provider == "codex" ? " " : "")
            } else {
                prose += line; submitted += line
            }
            if index + 1 < lines.count { prose += "\n"; submitted += "\n" }
        }
        flush()
        guard !paths.isEmpty else { return nil }
        return Images(paths: paths, submittedText: provider == "codex" ? submitted.trimmingCharacters(in: .whitespacesAndNewlines) : submitted, pastes: pastes)
    }

    public static func bytes(provider: String, text: String, bracketedPasteEnabled: Bool) -> Data? {
        guard !text.isEmpty, text.utf8.count <= 32_768,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else { return nil }
        let multiline = text.contains("\n")
        guard !multiline || bracketedPasteEnabled || ["codex", "claude"].contains(provider) else { return nil }
        guard bracketedPasteEnabled || multiline || ["codex", "claude"].contains(provider) else { return Data(text.utf8) }
        func paste(_ value: String) -> Data { Data(("\u{1b}[200~" + value + "\u{1b}[201~").utf8) }
        if let images = images(provider: provider, text: text) {
            // Every image remains a separate event even when all bytes travel
            // in one acknowledged transport write. Never replay that write.
            var output = Data()
            for event in images.pastes {
                switch event {
                case .image(let path):
                    guard path.unicodeScalars.count <= 1_000 else { return nil }
                    output.append(paste(path))
                case .text(let prose):
                    // Keep prose expanded, too: the complete transformed draft
                    // must be visible before an image submission is authorized.
                    var part = ""
                    for scalar in prose.unicodeScalars {
                        part.unicodeScalars.append(scalar)
                        if scalar.value == 10 || part.utf8.count >= 256 {
                            output.append(paste(part)); part = ""
                        }
                    }
                    if !part.isEmpty { output.append(paste(part)) }
                }
            }
            return output.count <= 262_144 ? output : nil
        }
        guard provider == "claude" else { return paste(text) }
        // Claude folds a large/multiline paste into an opaque badge. Disjoint
        // small paste events preserve every byte once while keeping the draft
        // visible for the same shared verification used by every transport.
        var output = Data()
        var part = ""
        for scalar in text.unicodeScalars {
            part.unicodeScalars.append(scalar)
            if scalar.value == 10 || part.utf8.count >= 256 {
                output.append(paste(part)); part = ""
                guard output.count <= 262_144 else { return nil }
            }
        }
        if !part.isEmpty { output.append(paste(part)) }
        return output.count <= 262_144 ? output : nil
    }
}

public protocol AgentTerminalActionPort: Sendable {
    func answer(_ request: AgentPromptAnswerRequest, freshObservation: AgentTerminalObservation) async throws
    func sendText(_ request: AgentTextSendRequest) async throws
    func sendReturn(binding: AgentTerminalBinding) async throws
    func verifySubmission(threadID: AgentThreadID, binding: AgentTerminalBinding) async throws
    func interrupt(binding: AgentTerminalBinding) async throws
    func openTerminal(binding: AgentTerminalBinding) async throws
}

public protocol AgentIntegrationPort: Sendable {
    func probe(binding: AgentTerminalBinding) async -> AgentIntegrationState
    func install(binding: AgentTerminalBinding) async throws
}

public enum AgentIntegrationState: String, Codable, Sendable { case current, outdated, missing, unavailable }

public protocol AgentLaunchPort: Sendable {
    func execute(_ plan: AgentLaunchPlan) async throws -> AgentLaunchReceipt
}

public enum AgentLaunchKind: Equatable, Codable, Sendable {
    case spawn(name: String?)
    case fork(source: AgentForkSource, name: String?)
}

public struct AgentForkSource: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public let turnID: String?
    public let recordID: String?
    public init(threadID: AgentThreadID, turnID: String? = nil, recordID: String? = nil) {
        self.threadID = threadID
        self.turnID = turnID
        self.recordID = recordID
    }
}

public enum AgentSplitAxis: String, Codable, Sendable { case right, down }
public enum AgentPlacement: Equatable, Codable, Sendable {
    case newWindow(name: String?)
    case split(windowID: String, paneID: String?, axis: AgentSplitAxis)
}
public enum AgentIsolation: Equatable, Codable, Sendable {
    case currentWorktree
    case newWorktree(branch: String)
}

public struct AgentRemotePath: Equatable, Codable, Sendable {
    public let value: String
    public init?(_ value: String) {
        guard (value.hasPrefix("/") || value.hasPrefix("~/")), value.utf8.count <= 2_048,
              !value.contains("\0"), !value.split(separator: "/").contains("..")
        else { return nil }
        self.value = value
    }
}

public struct AgentLaunchIntent: Equatable, Codable, Sendable {
    public let kind: AgentLaunchKind
    public let liveSessionID: UUID
    public let providerID: AgentProviderID
    public let workingDirectory: AgentRemotePath
    public let task: String
    public let placement: AgentPlacement
    public let isolation: AgentIsolation

    public init?(kind: AgentLaunchKind, liveSessionID: UUID, providerID: AgentProviderID, workingDirectory: AgentRemotePath, task: String, placement: AgentPlacement, isolation: AgentIsolation) {
        let normalized = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 16_384 else { return nil }
        self.kind = kind
        self.liveSessionID = liveSessionID
        self.providerID = providerID
        self.workingDirectory = workingDirectory
        self.task = normalized
        self.placement = placement
        self.isolation = isolation
    }
}

public struct AgentLaunchPlan: Equatable, Codable, Sendable {
    /// Correlates a platform receipt with this immutable plan. Optional keeps
    /// plans emitted by pre-correlation ABI clients decodable.
    public let requestID: UUID?
    public let intent: AgentLaunchIntent
    public let providerArguments: [String]
    public let humanReadableSummary: String

    public init?(requestID: UUID? = nil, intent: AgentLaunchIntent, providerArguments: [String], humanReadableSummary: String) {
        guard !providerArguments.isEmpty,
              providerArguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32_768 }),
              !humanReadableSummary.isEmpty,
              humanReadableSummary.utf8.count <= 2_048
        else { return nil }
        self.requestID = requestID
        self.intent = intent
        self.providerArguments = providerArguments
        self.humanReadableSummary = humanReadableSummary
    }
}

public struct AgentLaunchReceipt: Equatable, Codable, Sendable {
    /// Legacy opaque value retained for existing Apple launch paths.
    public let value: String
    public let requestID: UUID?
    public let providerSessionID: String?
    public let windowID: String?
    public let paneID: String?
    public let createdWorktree: Bool?

    public init?(
        value: String,
        requestID: UUID? = nil,
        providerSessionID: String? = nil,
        windowID: String? = nil,
        paneID: String? = nil,
        createdWorktree: Bool? = nil
    ) {
        guard !value.isEmpty, value.utf8.count <= 512 else { return nil }
        guard [providerSessionID, windowID, paneID].allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? true }) else { return nil }
        self.value = value
        self.requestID = requestID
        self.providerSessionID = providerSessionID
        self.windowID = windowID
        self.paneID = paneID
        self.createdWorktree = createdWorktree
    }

    /// A receipt can be trusted for a structured plan only when it carries the
    /// exact correlation ID. Legacy receipts remain displayable but unproven.
    public func verifies(_ plan: AgentLaunchPlan) -> Bool {
        guard AgentLaunchReceipt(value: value, requestID: requestID, providerSessionID: providerSessionID, windowID: windowID, paneID: paneID, createdWorktree: createdWorktree) == self,
              let requestID, requestID == plan.requestID,
              paneID != nil || windowID != nil else { return false }
        switch plan.intent.placement {
        case .newWindow:
            // The launcher selects the new tmux window ID, so the receipt can
            // only prove that an exact, nonempty target was observed.
            guard windowID != nil else { return false }
        case .split(let expectedWindow, let expectedPane, _):
            guard windowID == expectedWindow,
                  expectedPane.map({ paneID == $0 }) ?? true else { return false }
        }
        switch plan.intent.isolation {
        case .currentWorktree:
            guard createdWorktree != true else { return false }
        case .newWorktree:
            guard createdWorktree == true else { return false }
        }
        return true
    }
}

public struct AgentLaunchValidator: Sendable {
    public let registry: AgentProviderRegistry
    public init(registry: AgentProviderRegistry) { self.registry = registry }

    public func validate(_ intent: AgentLaunchIntent, binding: AgentTerminalBinding?) -> Result<Void, AgentActionError> {
        guard let binding, binding.liveSessionID == intent.liveSessionID, binding.hasCurrentTmuxTarget else {
            return .failure(.staleBinding)
        }
        guard AgentRemotePath(intent.workingDirectory.value) == intent.workingDirectory,
              Self.validName(intent.kind.name), Self.validName(intent.placement.name) else { return .failure(.invalidLaunch) }
        if case .split(let windowID, let paneID, _) = intent.placement {
            guard !windowID.isEmpty, windowID.utf8.count <= 128,
                  paneID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
            else { return .failure(.invalidLaunch) }
        }
        if case .newWorktree(let branch) = intent.isolation {
            guard Self.validBranch(branch) else { return .failure(.invalidLaunch) }
        }
        guard let manifest = registry.manifest(for: intent.providerID) else { return .failure(.unavailable) }
        let capability: AgentActionCapability = {
            if case .fork = intent.kind { return .fork }
            return .spawn
        }()
        return manifest.actions.contains(capability) ? .success(()) : .failure(.unavailable)
    }

    public func plan(_ intent: AgentLaunchIntent, binding: AgentTerminalBinding?) -> Result<AgentLaunchPlan, AgentActionError> {
        if case .failure(let error) = validate(intent, binding: binding) { return .failure(error) }
        guard let manifest = registry.manifest(for: intent.providerID) else { return .failure(.unavailable) }
        var arguments = [intent.providerID.rawValue]
        if case .fork(let source, _) = intent.kind {
            guard intent.providerID == .claude else { return .failure(.unavailable) }
            arguments += ["--resume", source.threadID.providerSessionID, "--fork-session"]
        }
        arguments.append(intent.task)
        let placement: String
        switch intent.placement {
        case .newWindow: placement = "new window"
        case .split(_, _, let axis): placement = axis == .right ? "split right" : "split down"
        }
        guard manifest.actions.contains(intent.kind.isFork ? .fork : .spawn),
              let plan = AgentLaunchPlan(requestID: UUID(), intent: intent, providerArguments: arguments, humanReadableSummary: "Launch \(manifest.displayName) in \(placement)")
        else { return .failure(.unavailable) }
        return .success(plan)
    }

    /// Public so platform UIs can pre-validate the branch field and show a
    /// field-level message instead of an opaque `invalidLaunch` from the
    /// shared launch path. This is the ONE branch grammar — ASCII-only
    /// (`isLetterOrDigit`-style Unicode acceptance on a platform side has
    /// already diverged from it once), bounded in UTF-8 bytes.
    public static func isValidBranch(_ value: String) -> Bool {
        validBranch(value)
    }

    private static func validBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.hasPrefix("-"), !value.hasPrefix("."), !value.hasSuffix("."),
              !value.contains(".."), !value.contains("//"), !value.contains("@{"), !value.contains("\\")
        else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private extension AgentLaunchKind {
    var isFork: Bool { if case .fork = self { true } else { false } }
    var name: String? {
        switch self { case .spawn(let name), .fork(_, let name): return name }
    }
}

private extension AgentPlacement {
    var name: String? { if case .newWindow(let name) = self { name } else { nil } }
}

private extension AgentLaunchValidator {
    static func validName(_ value: String?) -> Bool {
        value.map { !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) } ?? true
    }
}
