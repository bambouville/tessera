import Foundation
import TesseraCore

/// A fresh, authoritative view of the exact agent surface.  The session-owned
/// implementation may use the rendered raw terminal or tmux capture-pane, but
/// must not substitute another pane after the binding was captured.
struct AppleAgentTerminalInspection: Sendable {
    let observation: AgentTerminalObservation
    let promptScreen: AgentPromptObservationResult?
    let composerText: String?
    let queueSupported: Bool
    let composerRow: Int?
    let composerColumn: Int?
    let composerVisibleText: String?
    let composerCursorVisible: Bool?
    let screenEvidence: TerminalScreenEvidence?
    let bracketedPasteEnabled: Bool

    init(observation: AgentTerminalObservation, promptScreen: AgentPromptObservationResult? = nil, composerText: String? = nil, queueSupported: Bool = false, composerRow: Int? = nil, composerColumn: Int? = nil, composerVisibleText: String? = nil, composerCursorVisible: Bool? = nil, screenEvidence: TerminalScreenEvidence? = nil, bracketedPasteEnabled: Bool = false) {
        self.observation = observation
        self.promptScreen = promptScreen
        self.composerText = composerText.map { String($0.prefix(32_768)) }
        self.queueSupported = queueSupported
        self.composerRow = composerRow
        self.composerColumn = composerColumn
        self.composerVisibleText = composerVisibleText
        self.composerCursorVisible = composerCursorVisible
        self.screenEvidence = screenEvidence
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }
}

enum AppleAgentTerminalKey: Sendable, Equatable { case `return`, tab, escape }

enum AppleAgentTerminalInputPurpose: Sendable { case composer, promptAnswer }

enum AppleAgentTerminalOpenResult: Sendable { case opened, inputNotReady, staleBinding }

enum AppleAgentTerminalInputPolicy {
    static func bytes(_ data: Data, purpose: AppleAgentTerminalInputPurpose, provider: String, bracketedPasteEnabled: Bool) -> Data? {
        switch purpose {
        case .promptAnswer:
            // Planner-approved keystrokes, including typed answers, pass through raw.
            return !data.isEmpty && data.count <= 32_768 ? data : nil
        case .composer:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return AgentTextInsertion.bytes(provider: provider, text: text, bracketedPasteEnabled: bracketedPasteEnabled)
        }
    }
}

/// All transport-specific work is injected from session-owned code.  Existing
/// `AppleSessionCommandFacade` routes raw SSH/mosh bytes and tmux keys through
/// their acknowledged paths; this adapter consequently has one action path
/// for all four carriers.
struct AppleAgentTerminalOperations: Sendable {
    let inspect: @MainActor @Sendable (AgentTerminalBinding) async throws -> AppleAgentTerminalInspection
    // Each write consumes its immediately preceding exact-binding inspection;
    // repeating those remote process/capture queries adds no new safety check.
    let sendText: @MainActor @Sendable (Data, AppleAgentTerminalInputPurpose, AgentTerminalBinding, AppleAgentTerminalInspection) async throws -> Bool
    let sendKey: @MainActor @Sendable (AppleAgentTerminalKey, AgentTerminalBinding, AppleAgentTerminalInspection) async throws -> Bool
    let verifySubmission: @MainActor @Sendable (AgentThreadID, String, AgentTerminalBinding) async throws -> Bool
    let openExactBinding: @MainActor @Sendable (AgentTerminalBinding) async throws -> AppleAgentTerminalOpenResult
}

/// A text send refused before its first byte: nothing reached the terminal,
/// so the caller can return the draft instead of waiting for a receipt.
/// `reason` and `shape` are content-free (codes, row indices and flags).
struct AppleAgentSendNotWritten: Error {
    let error: AgentActionError
    let reason: String
    let attempts: Int
    let shape: String?

    /// Only a composer observation that refused before its first byte may
    /// offer a deliberate override. Identity, dispatch and transport failures
    /// never earn permission to replay an action.
    var allowsSendAnyway: Bool {
        guard error == .inputNotReady || error == .terminalDraft else { return false }
        return ["capture-unavailable", "composer-occupied", "composer-unrecognized",
                "composer-blocked", "cursor-hidden", "prompt-visible"].contains(reason)
    }
}

/// The session could not produce a settled capture of the exact pane (for
/// example tmux's cursor moved during capture-pane). Unlike a stale binding
/// this is transient, so a send may inspect again.
enum AppleAgentInspectionUnavailable: Error { case capture }

/// Plans and applies terminal-side actions only after re-observing the exact
/// binding. It keeps text and its submission key as separate acknowledged
/// operations; Return/Tab is sent only after a fresh input-surface safety check.
actor AppleAgentTerminalAdapter: AgentTerminalObservationPort, AgentTerminalActionPort {
    private let fence: AppleAgentCarrierFence
    private let operations: AppleAgentTerminalOperations
    private var pendingSubmission: (request: AgentTextSendRequest, submitted: Bool, literalImagePathsOnly: Bool)?
    private let submissionVerificationWindow: Duration
    private let readinessWindow: Duration
    private let readinessInterval: Duration
    /// Claude turns a pasted path into a marker in about 100 ms.
    static let overrideImageWait: Duration = .seconds(2)

    /// An agent TUI redraws its composer while it animates, and a tmux capture
    /// is discarded when the cursor moves mid-capture. Send re-inspects for a
    /// short window instead of failing on the first unsettled frame.
    init(binding: AgentTerminalBinding, operations: AppleAgentTerminalOperations,
         readinessWindow: Duration = .seconds(2), readinessInterval: Duration = .milliseconds(150),
         submissionVerificationWindow: Duration = .seconds(10)) {
        fence = AppleAgentCarrierFence(binding: binding)
        self.operations = operations
        self.submissionVerificationWindow = submissionVerificationWindow
        self.readinessWindow = readinessWindow
        self.readinessInterval = readinessInterval
    }

    func replaceBinding(_ replacement: AgentTerminalBinding) async {
        pendingSubmission = nil
        await fence.replace(with: replacement)
    }

    func observe(binding: AgentTerminalBinding) async throws -> AgentTerminalObservation {
        let inspection = try await inspectSettled(binding, exhausted: .inputNotReady)
        return inspection.observation
    }

    func answer(_ request: AgentPromptAnswerRequest, freshObservation: AgentTerminalObservation) async throws {
        try Task.checkCancellation()
        guard freshObservation.binding == request.binding,
              request.binding.capabilities.contains(.promptAnswer)
        else { throw AgentActionError.staleBinding }
        var anchor: AgentPromptAnswerAnchor?
        var history: [AgentPromptAnswerPhase] = []
        for _ in 0...AgentPromptAnswerPlanner.maximumSteps {
            try Task.checkCancellation()
            let inspection = try await inspectSettled(request.binding,
                exhausted: history.isEmpty ? .inputNotReady : .verificationFailed)
            if history.isEmpty {
                guard let screen = inspection.promptScreen,
                      request.actionToken == AgentPromptGrammar.actionToken(for: screen.signature)
                else { throw AgentActionError.stalePrompt }
            }
            let plan = AgentPromptAnswerPlanner.next(provider: request.threadID.providerID,
                goal: request.goal, expectedSignature: request.expectedSignature,
                anchor: anchor, observation: inspection.promptScreen, history: history)
            anchor = plan.anchor
            switch plan.step.action {
            case .done: return
            case .refuse:
                switch plan.step.refusal {
                case .stalePrompt, .unsupported: throw AgentActionError.stalePrompt
                case .occupied: throw AgentActionError.terminalDraft
                case .verificationFailed, .none: throw AgentActionError.verificationFailed
                }
            case .wait:
                history.append(.wait)
            case .send:
                guard let bytes = plan.step.bytes, let phase = plan.step.phase else {
                    throw AgentActionError.verificationFailed
                }
                try await fence.requireCurrent(request.binding)
                let input = plan.step.semanticKey?.bytes ?? bytes
                guard try await operations.sendText(Data(input.utf8), .promptAnswer, request.binding, inspection) else {
                    if history.isEmpty, request.binding.transport == .ssh || request.binding.transport == .mosh {
                        throw AgentActionError.inputNotReady
                    }
                    throw AgentActionError.unavailable
                }
                history.append(phase)
            }
            try await Task.sleep(for: .milliseconds(AgentPromptAnswerPlanner.settleDelayMilliseconds))
        }
        throw AgentActionError.verificationFailed
    }

    func sendText(_ request: AgentTextSendRequest) async throws {
        try await sendText(request, beforeWrite: nil)
    }

    func sendText(_ request: AgentTextSendRequest, beforeWrite: (@Sendable () async throws -> Void)?) async throws {
        func notWritten(_ error: Error, _ reason: String, attempts: Int = 0, shape: String? = nil) -> AppleAgentSendNotWritten {
            if let refusal = error as? AppleAgentSendNotWritten { return refusal }
            // The carrier fence throws platform errors; a replaced binding
            // must read as "terminal changed", not "can't take input".
            let code: AgentActionError = switch error {
            case is CancellationError, AppleAgentPlatformError.cancelled: .cancelled
            case AppleAgentPlatformError.staleBinding, AppleAgentPlatformError.staleCarrierGeneration: .staleBinding
            default: (error as? AgentActionError) ?? .unavailable
            }
            return AppleAgentSendNotWritten(error: code, reason: reason, attempts: attempts, shape: shape)
        }
        do { try Task.checkCancellation() } catch { throw notWritten(error, "cancelled") }
        guard request.binding.capabilities.contains(.send) else { throw notWritten(AgentActionError.staleBinding, "capability") }
        var before = try await inspectForSend(request, window: readinessWindow, notWritten: notWritten)
        // Receipt bookkeeping is marked once the composer is ready, so the
        // readiness wait cannot age its pre-dispatch frontier. A cross-actor
        // hop slow enough to age the composer proof earns a fresh check,
        // briefly retried: a busy runtime usually means a redrawing agent.
        let dispatchStarted = ContinuousClock.now
        do { try await beforeWrite?() } catch { throw notWritten(error, "dispatch") }
        if beforeWrite != nil, dispatchStarted.duration(to: .now) >= readinessInterval {
            before = try await inspectForSend(request, window: readinessInterval * 2, notWritten: notWritten)
        }
        let bytes = Data(request.text.utf8)
        do { try await fence.requireCurrent(request.binding) } catch { throw notWritten(error, "fence") }
        guard try await operations.sendText(bytes, .composer, request.binding, before) else {
            if request.binding.transport == .ssh || request.binding.transport == .mosh {
                throw notWritten(AgentActionError.inputNotReady, "transport-not-admitted")
            }
            throw AgentActionError.unavailable
        }
        let provider = request.threadID.providerID.rawValue
        var literalImagePathsOnly = false
        if AgentTextInsertion.images(provider: provider, text: request.text) != nil {
            var attached = false
            // An approved send never reads the composer as ready, so it would
            // spend every check; it gets a bounded moment instead.
            let overrideDeadline = ContinuousClock.now + Self.overrideImageWait
            for _ in 0..<(provider == "claude" ? 40 : 20) {
                if request.composerVerification == .userOverride, ContinuousClock.now >= overrideDeadline { break }
                guard let after = try await inspectIfSettled(request.binding) else {
                    try await Task.sleep(nanoseconds: 50_000_000); continue
                }
                if after.observation.prompt == nil,
                   [.readyReturn, .readyTab].contains(AgentComposerEvidence.safety(provider: provider,
                    visibleText: after.composerVisibleText ?? after.observation.liveTail,
                    cursorRow: after.composerRow, cursorColumn: after.composerColumn, cursorVisible: after.composerCursorVisible,
                    requireEmpty: false, queueWhenWorking: request.queueWhenWorking, text: request.text, screen: after.screenEvidence)) {
                    attached = true; break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            // An approved send still gives the agent its time to read the
            // image: a Return before the marker is swallowed. Only the
            // composer reading that was never recognized is waived.
            if !attached, request.composerVerification == .required, provider == "claude",
               let after = try await inspectIfSettled(request.binding), after.observation.prompt == nil {
                literalImagePathsOnly = Self.submissionKey(after, request: request, literalImagePathsOnly: true) != nil
            }
            guard attached || literalImagePathsOnly || request.composerVerification == .userOverride else { throw AgentActionError.verificationFailed }
        } else if request.composerVerification == .userOverride {
            // The user approved this exact text for this exact binding. Input
            // encoding and carrier admission still use the production path.
        } else if !["codex", "claude"].contains(provider) {
            var inserted = false
            for _ in 0..<20 {
                guard let after = try await inspectIfSettled(request.binding) else {
                    try await Task.sleep(nanoseconds: 50_000_000); continue
                }
                if AgentComposerEvidence.matches(provider: provider,
                    visibleText: after.composerVisibleText ?? after.observation.liveTail,
                    cursorLine: after.composerText, text: request.text, cursorRow: after.composerRow) {
                    inserted = true; break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard inserted else { throw AgentActionError.verificationFailed }
        }
        pendingSubmission = (request, false, literalImagePathsOnly)
    }

    func sendReturn(binding: AgentTerminalBinding) async throws {
        try Task.checkCancellation()
        guard let pendingSubmission, pendingSubmission.request.binding == binding, !pendingSubmission.submitted else {
            throw AgentActionError.verificationFailed
        }
        let request = pendingSubmission.request
        // Consume before the first suspension: two callers cannot both send
        // a key, even if the fresh inspection or key write is ambiguous.
        self.pendingSubmission = nil
        // The text is in the composer now, and the agent redraws around it.
        // Re-inspect for the same short window; the key itself is sent once.
        let deadline = ContinuousClock.now.advanced(by: readinessWindow)
        var fresh: AppleAgentTerminalInspection
        var key: AgentComposerEvidence.SubmissionKey
        if let overrideKey = request.userOverrideSubmissionKey {
            fresh = try await inspectExact(binding)
            key = overrideKey
        } else {
            while true {
                var settled: AppleAgentTerminalInspection?
                do { settled = try await inspectExactOrUnsettled(binding) } catch AppleAgentInspectionUnavailable.capture { settled = nil }
                if let settled, let ready = Self.submissionKey(settled, request: request, literalImagePathsOnly: pendingSubmission.literalImagePathsOnly) {
                    fresh = settled; key = ready; break
                }
                guard ContinuousClock.now.advanced(by: readinessInterval) < deadline else { throw AgentActionError.verificationFailed }
                try await Task.sleep(for: readinessInterval)
            }
        }
        try await fence.requireCurrent(binding)
        guard try await operations.sendKey(key == .tab ? .tab : .return, binding, fresh) else { throw AgentActionError.unavailable }
        self.pendingSubmission = (request, true, pendingSubmission.literalImagePathsOnly)
    }

    func verifySubmission(threadID: AgentThreadID, binding: AgentTerminalBinding) async throws {
        try Task.checkCancellation()
        guard let pendingSubmission,
              pendingSubmission.request.binding == binding,
              pendingSubmission.request.threadID == threadID,
              pendingSubmission.submitted else {
            throw AgentActionError.verificationFailed
        }
        try await fence.requireCurrent(binding)
        // The key's acknowledgement proves delivery, not provider acceptance.
        // Canonical transcript reconciliation settles the outgoing bubble.
        self.pendingSubmission = nil
        let request = pendingSubmission.request
        if request.composerVerification == .required, threadID.providerID == .claude,
           !pendingSubmission.literalImagePathsOnly,
           AgentTextInsertion.images(provider: "claude", text: request.text) != nil {
            // Bound slow captures as well as the number of settled polls.
            let operations = self.operations
            let fence = self.fence
            let window = submissionVerificationWindow
            // Stream termination resumes the caller without waiting for a
            // capture implementation that ignores cancellation. The losing
            // poll is cancelled and cannot start another capture or write.
            let completion = AsyncThrowingStream<Void, Error> { continuation in
                let poll = Task {
                    do {
                        let deadline = ContinuousClock.now + window
                        for _ in 0..<40 {
                            try Task.checkCancellation()
                            guard ContinuousClock.now < deadline else { break }
                            try await fence.requireCurrent(binding)
                            try Task.checkCancellation()
                            guard ContinuousClock.now < deadline else { break }
                            if try await operations.verifySubmission(threadID, request.text, binding) {
                                try Task.checkCancellation()
                                continuation.yield(())
                                continuation.finish()
                                return
                            }
                            try await Task.sleep(nanoseconds: 50_000_000)
                        }
                        continuation.finish(throwing: AgentActionError.verificationFailed)
                    } catch { continuation.finish(throwing: error) }
                }
                let timeout = Task {
                    do {
                        try await Task.sleep(for: window)
                        continuation.finish(throwing: AgentActionError.verificationFailed)
                    } catch { /* The poll completed or its caller cancelled. */ }
                }
                continuation.onTermination = { @Sendable _ in poll.cancel(); timeout.cancel() }
            }
            for try await _ in completion { return }
            try Task.checkCancellation()
            throw AgentActionError.verificationFailed
        }
    }

    func interrupt(binding: AgentTerminalBinding) async throws {
        try Task.checkCancellation()
        guard binding.capabilities.contains(.interrupt) else { throw AgentActionError.staleBinding }
        let fresh = try await inspectExact(binding)
        try await fence.requireCurrent(binding)
        guard try await operations.sendKey(.escape, binding, fresh) else {
            throw binding.transport == .ssh || binding.transport == .mosh ? AgentActionError.inputNotReady : .unavailable
        }
    }

    func openTerminal(binding: AgentTerminalBinding) async throws {
        try Task.checkCancellation()
        _ = try await inspectExact(binding)
        switch try await operations.openExactBinding(binding) {
        case .opened: break
        case .inputNotReady: throw AgentActionError.inputNotReady
        case .staleBinding: throw AgentActionError.staleBinding
        }
    }

    private static func submissionKey(_ fresh: AppleAgentTerminalInspection, request: AgentTextSendRequest, literalImagePathsOnly: Bool = false) -> AgentComposerEvidence.SubmissionKey? {
        let provider = request.threadID.providerID.rawValue
        guard ["codex", "claude"].contains(provider) else {
            return AgentComposerEvidence.submissionKey(provider: provider,
                visibleText: fresh.composerVisibleText ?? fresh.observation.liveTail, cursorLine: fresh.composerText, text: request.text,
                queueWhenWorking: request.queueWhenWorking, cursorRow: fresh.composerRow)
        }
        guard fresh.observation.prompt == nil else { return nil }
        switch AgentComposerEvidence.safety(provider: provider,
            visibleText: fresh.composerVisibleText ?? fresh.observation.liveTail,
            cursorRow: fresh.composerRow, cursorColumn: fresh.composerColumn, cursorVisible: fresh.composerCursorVisible,
            requireEmpty: false, queueWhenWorking: request.queueWhenWorking, text: request.text, screen: fresh.screenEvidence, literalImagePathsOnly: literalImagePathsOnly) {
        case .readyReturn: return .return
        case .readyTab: return .tab
        default: return nil
        }
    }

    /// Every failure here precedes the first byte, so each is reported as
    /// not written. Only an unsettled capture or an unready composer is
    /// retried, within `window` (zero: one check); a changed binding or
    /// process is final.
    private func inspectUntilReady(
        _ request: AgentTextSendRequest,
        window: Duration,
        notWritten: (Error, String, Int, String?) -> AppleAgentSendNotWritten
    ) async throws -> AppleAgentTerminalInspection {
        let provider = request.threadID.providerID.rawValue
        let deadline = ContinuousClock.now.advanced(by: window)
        var attempts = 0
        while true {
            attempts += 1
            var refusal: (error: AgentActionError, reason: String, shape: String?)
            do {
                let inspection = try await inspectExactOrUnsettled(request.binding)
                guard let blocked = Self.inputRefusal(inspection, request: request, provider: provider) else { return inspection }
                refusal = blocked
            } catch AppleAgentInspectionUnavailable.capture {
                // No target can also mean its foreground process was not
                // proved. Unlike an inspected blank screen this is not a
                // display-only refusal that the user can override.
                refusal = (.inputNotReady, "target-unproven", nil)
            } catch {
                throw notWritten(error, "inspect", attempts, nil)
            }
            // Queue support is a property of the agent, not of a redraw.
            if refusal.reason == "queue-unsupported" || ContinuousClock.now.advanced(by: readinessInterval) >= deadline {
                throw notWritten(refusal.error, refusal.reason, attempts, refusal.shape)
            }
            do { try await Task.sleep(for: readinessInterval) } catch { throw notWritten(error, "cancelled", attempts, nil) }
        }
    }

    private func inspectForSend(
        _ request: AgentTextSendRequest,
        window: Duration,
        notWritten: (Error, String, Int, String?) -> AppleAgentSendNotWritten
    ) async throws -> AppleAgentTerminalInspection {
        guard request.composerVerification == .userOverride else {
            return try await inspectUntilReady(request, window: window, notWritten: notWritten)
        }
        // A missing capture may also mean a missing process proof. Keep the
        // endpoint's exact route/process inspection; bypass only what its
        // composer pixels say about readiness and existing terminal text.
        do { return try await inspectExact(request.binding) }
        catch { throw notWritten(error, "inspect", 0, nil) }
    }

    private static func inputRefusal(
        _ inspection: AppleAgentTerminalInspection,
        request: AgentTextSendRequest,
        provider: String
    ) -> (error: AgentActionError, reason: String, shape: String?)? {
        guard !request.queueWhenWorking || inspection.queueSupported else { return (.unavailable, "queue-unsupported", nil) }
        guard hasText(inspection) else { return (.inputNotReady, "capture-unavailable", nil) }
        let visible = inspection.composerVisibleText ?? inspection.observation.liveTail
        guard ["codex", "claude"].contains(provider) else {
            switch AgentComposerEvidence.presence(provider: provider, visibleText: visible, cursorLine: inspection.composerText,
                                                  text: request.text, cursorRow: inspection.composerRow) {
            case .absent: return nil
            case .present: return (.terminalDraft, "composer-occupied", nil)
            case .unavailable: return (.inputNotReady, "composer-unrecognized", nil)
            }
        }
        let shape = { AgentComposerEvidence.diagnosticShape(provider: provider, visibleText: visible,
            cursorRow: inspection.composerRow, cursorColumn: inspection.composerColumn,
            cursorVisible: inspection.composerCursorVisible, screen: inspection.screenEvidence) }
        if inspection.observation.prompt != nil { return (.inputNotReady, "prompt-visible", shape()) }
        switch AgentComposerEvidence.safety(provider: provider, visibleText: visible,
            cursorRow: inspection.composerRow, cursorColumn: inspection.composerColumn, cursorVisible: inspection.composerCursorVisible,
            requireEmpty: true, queueWhenWorking: request.queueWhenWorking, screen: inspection.screenEvidence) {
        case .readyReturn, .readyTab: return nil
        case .occupied: return (.terminalDraft, "composer-occupied", shape())
        case .blocked: return (.inputNotReady, inspection.composerCursorVisible == false ? "cursor-hidden" : "composer-blocked", shape())
        case .unavailable: return (.inputNotReady, "composer-unrecognized", shape())
        }
    }

    /// Identity-only checks (interrupt, open) need a settled capture, not
    /// its text; one that raced a redraw is retried within the window.
    private func inspectExact(_ binding: AgentTerminalBinding) async throws -> AppleAgentTerminalInspection {
        let deadline = ContinuousClock.now.advanced(by: readinessWindow)
        while true {
            do { return try await inspectExactOrUnsettled(binding) }
            catch AppleAgentInspectionUnavailable.capture {
                guard ContinuousClock.now.advanced(by: readinessInterval) < deadline else { throw AgentActionError.inputNotReady }
            }
            try await Task.sleep(for: readinessInterval)
        }
    }

    /// Nil when the capture did not settle: thrown, or a frame with no text
    /// (a tmux capture that raced a redraw), which is evidence of nothing.
    private func inspectIfSettled(_ binding: AgentTerminalBinding) async throws -> AppleAgentTerminalInspection? {
        let inspection: AppleAgentTerminalInspection
        do { inspection = try await inspectExactOrUnsettled(binding) } catch AppleAgentInspectionUnavailable.capture { return nil }
        return Self.hasText(inspection) ? inspection : nil
    }

    /// The endpoint always sets `composerVisibleText`, and a blank pane's
    /// capture is newlines, so only non-whitespace counts. A parsed prompt was
    /// read from text. Android's `agentCaptureHasText` matches.
    private static func hasText(_ inspection: AppleAgentTerminalInspection) -> Bool {
        inspection.observation.prompt != nil
            || (inspection.composerVisibleText ?? "").contains { !$0.isWhitespace }
            || inspection.observation.liveTail.contains { !$0.isWhitespace }
    }

    /// Re-inspects an unsettled capture within the readiness window;
    /// `exhausted` names the failure when none settles.
    private func inspectSettled(_ binding: AgentTerminalBinding, exhausted: AgentActionError) async throws -> AppleAgentTerminalInspection {
        let deadline = ContinuousClock.now.advanced(by: readinessWindow)
        while true {
            if let settled = try await inspectIfSettled(binding) { return settled }
            guard ContinuousClock.now.advanced(by: readinessInterval) < deadline else { throw exhausted }
            try await Task.sleep(for: readinessInterval)
        }
    }

    private func inspectExactOrUnsettled(_ binding: AgentTerminalBinding) async throws -> AppleAgentTerminalInspection {
        try await fence.requireCurrent(binding)
        let inspection = try await operations.inspect(binding)
        try Task.checkCancellation()
        guard inspection.observation.binding == binding else { throw AgentActionError.staleBinding }
        try await fence.requireCurrent(binding)
        return inspection
    }
}
