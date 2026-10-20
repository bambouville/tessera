import Foundation
import Observation
import TesseraCore

/// Apple presentation state only. The portable runtime remains the source of
/// truth for thread reduction, action availability, ordering, and privacy.
@MainActor
@Observable
final class AgentCenterV2PresentationModel {
    enum KeyboardFocus: Equatable { case none, list, search, composer, promptAnswer, action }

    enum LaunchMode: Identifiable {
        case spawn
        case fork(AgentThreadID)

        var id: String {
            switch self {
            case .spawn: return "spawn"
            case .fork(let id): return "fork-\(id.providerSessionID)"
            }
        }
    }

    struct LaunchTarget: Identifiable, Equatable {
        struct Window: Identifiable, Equatable {
            let id: String
            let title: String
            let paneIDs: [String]
        }

        let id: UUID
        let title: String
        let detail: String
        let providerIDs: [AgentProviderID]
        let recentDirectories: [String]
        let windows: [Window]

        init(
            id: UUID,
            title: String,
            detail: String,
            providerIDs: [AgentProviderID],
            recentDirectories: [String],
            windows: [Window]
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.providerIDs = providerIDs
            self.recentDirectories = recentDirectories
            self.windows = windows
        }
    }

    struct LaunchDraft {
        var task = ""
        var name = ""
        var targetID: UUID?
        var providerID: AgentProviderID?
        var directory = ""
        var placement: Placement = .newWindow
        var windowID: String?
        var paneID: String?
        var axis: AgentSplitAxis = .right
        var isolation: Isolation = .currentWorktree
        var branch = ""

        enum Placement: String, CaseIterable, Identifiable { case newWindow, split; var id: String { rawValue } }
        enum Isolation: String, CaseIterable, Identifiable { case currentWorktree, newWorktree; var id: String { rawValue } }
    }

    struct PromptOverflow: Identifiable {
        let threadID: AgentThreadID
        let prompt: AgentActionPrompt
        var id: String { "\(threadID.providerSessionID)-\(prompt.token.rawValue)" }
    }

    struct ComposerSend: Identifiable {
        let id: UUID
        let threadID: AgentThreadID
        let binding: AgentTerminalBinding
        let text: String
        let queueWhenWorking: Bool
        let composerVerification: AgentComposerVerification
        /// Acceptance removes only the returned message, retaining any draft
        /// that was merged underneath it while the first send was refused.
        let draftToReplace: String
        let replacementDraft: String
        let sendAnywayGeneration: UInt64
        let requestedAt = ContinuousClock.now
    }

    struct SendAnywayCandidate {
        let request: ComposerSend
        let returnedDraft: String
        let remainingDraft: String
    }

    struct AttachmentPickerRequest: Identifiable {
        let id: UUID
        let threadID: AgentThreadID
        var source: Source = .file
        var composerWasFocused = false

        enum Source { case file, photo }

        var photoDirectory: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("agent-photos-\(id)", isDirectory: true)
        }

        func shouldRestoreComposerFocus(hardwareKeyboardConnected: Bool) -> Bool {
            composerWasFocused || hardwareKeyboardConnected
        }
    }

    struct ComposerFocusRequest {
        let id = UUID()
        let threadID: AgentThreadID
    }

    enum Action {
        case select(AgentThreadID)
        case selectCandidate(AgentSourceCandidateID)
        case answer(threadID: AgentThreadID, token: AgentActionToken, goal: AgentPromptAnswerGoal)
        case send(ComposerSend)
        case interrupt(AgentThreadID)
        case openTerminal(AgentThreadID)
        case openCandidateTerminal(AgentSourceCandidateID)
        case answerCandidate(candidateID: AgentSourceCandidateID, token: AgentActionToken, optionID: String)
        case beginDictation(AgentThreadID)
        case search(String)
        case setGrouping(AgentListGrouping)
        case setShowSystemEvents(Bool)
        /// How many characters of a title one list row can show, measured by
        /// the list itself so the prompt fallback is clipped to the screen it
        /// is actually rendered on rather than to a guess.
        case setTitleCharacterBudget(Int)
        case requestOlderPage(AgentThreadID)
        /// History for a transcript shorter than its viewport, which no
        /// gesture can ask for. Never trims the live head.
        case fillOlderPage(AgentThreadID)
        case requestNewerPage(AgentThreadID)
        /// The newer page that retains rows a bridged window only shows
        /// (`bridgesToHead`). Optional: never clears a failed read.
        case retainBridgedRows(AgentThreadID)
        case returnToLatest(AgentThreadID)
        case viewportAnchor(threadID: AgentThreadID, recordID: String?)
        case refreshTranscript(AgentThreadID)
        case cardVisibility(AgentThreadID, Bool)
        case detailVisibility(AgentThreadID, Bool)
        case newestRecordVisible(threadID: AgentThreadID, recordID: String)
        /// The reader sees the live end of a finished thread. The epoch fences
        /// the read to the finish that was on screen, and it also covers a
        /// finish with no transcript records.
        case completionVisible(threadID: AgentThreadID, attentionEpoch: UInt64)
        case launch(AgentLaunchIntent)
        case fixIntegration(sessionID: UUID, action: AgentIntegrationFixAction)
    }

    struct IntegrationNotice: Equatable {
        let sessionID: UUID
        let state: AgentIntegrationWarningState
    }

    var listSnapshot = AgentCenterListSnapshot(threads: [])
    var threadSnapshots: [AgentThreadID: AgentThreadSnapshot] = [:] {
        didSet {
            // A refusal still in flight cannot offer an override after its
            // original target changed, even if that target later returns.
            let relevant = Set(pendingSends.keys).union(selectedThreadID.map { [$0] } ?? [])
            if relevant.contains(where: { oldValue[$0]?.binding != threadSnapshots[$0]?.binding }) {
                invalidateSendAnyway()
            }
            refreshSelectedThread()
            invalidateChangedSendAnyway()
        }
    }
    var selectedThreadID: AgentThreadID? {
        didSet {
            if selectedThreadID != oldValue {
                invalidateSendAnyway()
                composerFocusRequest = nil
            }
            refreshSelectedThread()
            invalidateChangedSendAnyway()
        }
    }
    /// Observing this, not `threadSnapshots`, keeps other agents' publishes
    /// (several a second) from re-evaluating the selected transcript.
    private(set) var selectedThread: AgentThreadSnapshot?
    /// The selected snapshot as the detail renders it: it moves only when a
    /// field the detail shows changes (`detailRendersSame`). A working agent
    /// republishes lifecycle activity with every hook, and each republish
    /// re-diffed and re-laid out every rendered transcript row mid-scroll.
    /// Anything that needs the hidden fields reads `selectedThread`.
    private(set) var selectedThreadForDetail: AgentThreadSnapshot?

    /// Snapshot fields the detail never shows. `detailRendersSame` compares
    /// every other field; a test keeps the two lists covering the snapshot.
    nonisolated static let detailHiddenFields: Set<String> = [
        "turns", "activity", "changes", "lineage", "deliveryGeneration", "unreadCompletionKey", "acknowledgedCompletionKey",
    ]

    nonisolated static func detailRendersSame(_ lhs: AgentThreadSnapshot?, _ rhs: AgentThreadSnapshot?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        // The list shows these summary fields; the detail does not.
        func shown(_ summary: AgentThreadSummary) -> AgentThreadSummary {
            var summary = summary
            summary.lastActivity = nil
            summary.lastActivitySequence = 0
            summary.preview = nil
            return summary
        }
        return lhs.version == rhs.version && shown(lhs.summary) == shown(rhs.summary) && lhs.messages == rhs.messages
            && lhs.cursor == rhs.cursor && lhs.hasMore == rhs.hasMore && lhs.binding == rhs.binding
            && lhs.outgoingMessages == rhs.outgoingMessages && lhs.livePreview == rhs.livePreview
            && lhs.ingestionWindow == rhs.ingestionWindow && lhs.attentionEpoch == rhs.attentionEpoch
            && lhs.conversationEnded == rhs.conversationEnded
    }
    var selectedCandidateID: AgentSourceCandidateID? { didSet { if selectedCandidateID == nil { candidateChosenByUser = false } } }
    /// Distinguishes a candidate the user picked from the list's fallback
    /// selection, which a thread's first snapshot may still replace.
    @ObservationIgnored private var candidateChosenByUser = false
    /// A verified cold notification may arrive before a narrow root is
    /// mounted. This remains in-memory and contains only a canonical thread
    /// identity; the root consumes it by pushing the selected detail.
    var pendingNarrowThreadNavigation: AgentThreadID?
    var grouping: AgentListGrouping = .attention
    var searchQuery = ""
    var isSearching = false
    var searchSnapshot = AgentSearchSnapshot(results: [])
    var searchFocusRequest = 0
    var keyboardFocus: KeyboardFocus = .none
    private(set) var threadDetailVisible = false

    /// Selection survives a compact navigation pop; only the root knows
    /// whether the selected detail is actually on screen.
    func setThreadDetailVisible(_ visible: Bool) {
        threadDetailVisible = visible
        updatePromptKeyboardFocus()
    }
    private(set) var composerFocusRequest: ComposerFocusRequest?
    @ObservationIgnored private var mountedComposerThreadID: AgentThreadID?
    @ObservationIgnored private var titleCharacterBudget = 0
    // One selected conversation only: scrolling and unrelated status updates
    // must not regroup every loaded message. This cache owns no domain state.
    @ObservationIgnored private var groupedMessages: [AgentMessage] = []
    @ObservationIgnored private var groupedItems: [AgentTranscriptItem] = []

    func transcriptItems(for messages: [AgentMessage]) -> [AgentTranscriptItem] {
        guard messages != groupedMessages else { return groupedItems }
        let started = Date()
        groupedItems = AgentTranscriptGrouping.items(messages)
        groupedMessages = messages
        AgentCenterV2PerformanceDiagnostics.shared.record("groupSync", since: started)
        return groupedItems
    }

    func discardTranscriptLayoutCache() {
        groupedMessages = []
        groupedItems = []
    }
    /// Device-local preference restored by the Apple coordinator. System
    /// events are hidden initially to keep the activity timeline actionable.
    var showSystemEvents = false
    var launchMode: LaunchMode?
    var promptOverflow: PromptOverflow?
    var launchDraft = LaunchDraft()
    var launchTargets: [LaunchTarget] = []
    var drafts: [AgentThreadID: String] = [:] { didSet { invalidateChangedSendAnyway() } }
    var pendingSends: [AgentThreadID: UUID] = [:]
    var answeringPromptThreads: Set<AgentThreadID> = []
    var uploadingThreads: Set<AgentThreadID> = []
    var loadingTranscriptThreads: Set<AgentThreadID> = []
    var ingestionCapacityThreads: Set<AgentThreadID> = []
    var ingestionReadStatuses: [AgentThreadID: AgentIngestionReadStatus] = [:]
    /// The host's last card-metadata issue per thread, kept so a repeated
    /// summary does not log the same failed title lookup again. Diagnostics
    /// bookkeeping only: no view reads it.
    @ObservationIgnored var summaryMetadataIssues: [AgentThreadID: String] = [:]

    /// The read status the detail shows above `thread`'s transcript. A
    /// working agent appends constantly and the host re-validates a grown
    /// file before serving it, so most refreshes briefly report progress:
    /// over a transcript already on screen, that row pushed the conversation
    /// down and back on nearly every refresh. Progress shows only while there
    /// is nothing else to show; a failure always shows, with Retry.
    func visibleReadStatus(for thread: AgentThreadSnapshot) -> AgentIngestionReadStatus? {
        guard let status = ingestionReadStatuses[thread.summary.id] else { return nil }
        // A live CLI creates its transcript on the first prompt, after it
        // publishes the conversation identity. Keep its empty composer usable.
        if status.code == "sourceMissing", thread.messages.isEmpty,
           (thread.binding?.agentPID ?? 0) > 1, thread.conversationEnded != true { return nil }
        // A send the transcript showed has no bubble of its own.
        let transcriptShown = !thread.messages.isEmpty || thread.outgoingMessages?.contains { $0.status != .observed } == true
        return status.isProgress && transcriptShown ? nil : status
    }
    var attachmentPickerRequest: AttachmentPickerRequest?
    private var loadingAttachmentPhotoRequestID: UUID?
    @ObservationIgnored private var cancelAttachmentPhotoLoad: (() -> Void)?
    var loadingAttachmentPhotos: Bool {
        attachmentPickerRequest != nil && loadingAttachmentPhotoRequestID == attachmentPickerRequest?.id
    }
    @ObservationIgnored private var attachmentPickerDismissalRequest: AttachmentPickerRequest?
    @ObservationIgnored var onPrepareAttachments: ((AgentThreadSnapshot) -> AttachmentPickerRequest?)?
    @ObservationIgnored var onCompleteAttachments: ((AttachmentPickerRequest, [URL]) -> Void)?
    /// A deliberately plain capability outcome. It is set by the coordinator
    /// when a live binding or session-owned adapter has not been injected;
    /// views must never substitute a title/address-derived terminal route.
    var capabilityNotice: String? {
        didSet {
            if capabilityNotice != oldValue, sendAnywayCandidate != nil { invalidateSendAnyway() }
        }
    }
    private(set) var sendAnywayCandidate: SendAnywayCandidate?
    @ObservationIgnored private var sendAnywayGeneration: UInt64 = 0
    /// Status for the exact connected session represented by the current
    /// Agent Center surface. The coordinator owns all remote work; the view
    /// can only request one of the bounded semantic repair actions.
    var integrationNotice: IntegrationNotice?

    /// Supplied by the Apple runtime adapter. Views emit semantic requests and
    /// never handle a terminal route, transcript locator, or provider command.
    @ObservationIgnored var onAction: ((Action) -> Void)?

    private func refreshSelectedThread() {
        let current = selectedThreadID.flatMap { threadSnapshots[$0] }
        // Observation notifies on every write, equal or not.
        if current != selectedThread { selectedThread = current }
        if !Self.detailRendersSame(current, selectedThreadForDetail) { selectedThreadForDetail = current }
        updatePromptKeyboardFocus()
    }

    var selectedCandidate: AgentTerminalCandidate? {
        selectedCandidateID.flatMap { id in listSnapshot.candidates.first { $0.id == id } }
    }

    func apply(list: AgentCenterListSnapshot) {
        if listSnapshot != list { listSnapshot = list }
        if let selectedCandidateID,
           !list.candidates.contains(where: { $0.id == selectedCandidateID }) {
            self.selectedCandidateID = nil
        }
        if self.selectedCandidateID == nil {
            if let selectedThreadID, !list.threads.contains(where: { $0.id == selectedThreadID }),
               threadSnapshots[selectedThreadID]?.summary.availability.content != true {
                self.selectedThreadID = list.threads.first?.id
            } else if selectedThreadID == nil {
                selectedThreadID = list.threads.first?.id
            }
            if self.selectedThreadID == nil {
                self.selectedCandidateID = list.candidates.first?.id
            }
        }
    }

    func apply(thread: AgentThreadSnapshot) {
        if threadSnapshots[thread.summary.id] != thread { threadSnapshots[thread.summary.id] = thread }
        // A thread publishing (working agents do, several times a second)
        // never takes over a candidate the user chose.
        if selectedThreadID == nil, selectedCandidateID == nil || !candidateChosenByUser {
            selectedThreadID = thread.summary.id
        }
    }

    /// Applies one publish: the list, the snapshots that changed and the
    /// threads Core dropped. Core drops a conversation when `/clear`, `/new`
    /// or `/resume` hands its pane to the next one, and names that one as its
    /// successor; a stale copy would still claim the pane's binding. A reader
    /// on the replaced conversation follows its pane to the successor, even
    /// before the successor's first snapshot or a list row that a search
    /// hides. A dropped thread without one leaves the reader on the first row.
    func apply(list: AgentCenterListSnapshot, changed: [AgentThreadSnapshot], removed: Set<AgentThreadID>,
               successors: [AgentThreadID: AgentThreadID] = [:]) {
        let previous = selectedThreadID
        apply(list: list)
        for snapshot in changed { apply(thread: snapshot) }
        for threadID in removed { threadSnapshots.removeValue(forKey: threadID) }
        guard let previous, removed.contains(previous) || successors[previous] != nil else { return }
        // `/clear` twice between publishes chains the replacements.
        var successor = successors[previous]
        var hops = 0
        while let current = successor, let next = successors[current], hops < successors.count {
            successor = next
            hops += 1
        }
        if let successor {
            select(successor)
        } else if selectedThreadID == previous {
            selectedThreadID = list.threads.first { !removed.contains($0.id) }?.id
        }
    }

    func select(_ threadID: AgentThreadID) {
        invalidateSendAnyway()
        selectedThreadID = threadID
        selectedCandidateID = nil
        onAction?(.select(threadID))
    }

    func requestNarrowThreadNavigation(_ threadID: AgentThreadID) {
        selectedThreadID = threadID
        selectedCandidateID = nil
        pendingNarrowThreadNavigation = threadID
    }

    func consumeNarrowThreadNavigation(_ threadID: AgentThreadID) {
        guard pendingNarrowThreadNavigation == threadID else { return }
        pendingNarrowThreadNavigation = nil
    }

    /// Reported by the list as it lays out. Repeats are dropped here rather
    /// than in the runtime: a resize emits a value on every frame of the
    /// animation, and each distinct one costs a snapshot round trip.
    func reportTitleCharacterBudget(_ characters: Int) {
        guard characters > 0, characters != titleCharacterBudget else { return }
        titleCharacterBudget = characters
        onAction?(.setTitleCharacterBudget(characters))
    }

    func selectCandidate(_ candidateID: AgentSourceCandidateID) {
        invalidateSendAnyway()
        selectedCandidateID = candidateID
        candidateChosenByUser = true
        selectedThreadID = nil
        onAction?(.selectCandidate(candidateID))
    }

    func draftBinding(for threadID: AgentThreadID) -> String {
        drafts[threadID] ?? ""
    }

    func setDraft(_ value: String, for threadID: AgentThreadID) {
        drafts[threadID] = value
    }

    func reportUnavailable(_ message: String) {
        capabilityNotice = message
    }

    func reportConversationEnded() {
        reportUnavailable("This conversation has ended. Open its terminal to start or resume a conversation. Your draft is kept.")
    }

    func reportActionError(_ error: AgentActionError, promptAnswer: Bool = false) {
        switch error {
        case .unavailable:
            reportUnavailable("This action is unavailable for the current terminal.")
        case .actionInFlight:
            reportUnavailable("An action is already in progress for this thread.")
        case .staleBinding:
            reportUnavailable("The terminal changed before the action could be completed.")
        case .invalidLaunch:
            reportUnavailable("The requested launch configuration is invalid.")
        case .stalePrompt:
            reportUnavailable("That prompt has changed; review the current terminal state.")
        case .verificationFailed:
            reportUnavailable("Tessera could not verify the terminal action.")
        case .cancelled:
            reportUnavailable("The terminal action was cancelled.")
        case .inputNotReady:
            reportUnavailable("The agent's input wasn't ready, so nothing was typed into the terminal.")
        case .terminalDraft:
            reportUnavailable(promptAnswer
                ? "The question's text field in the terminal already has text. Clear it there before answering."
                : "The terminal's prompt already has unsent text, so nothing was typed. Clear it in the terminal first.")
        }
    }

    /// A send refused before its first byte has no receipt to wait for; say
    /// so plainly instead of leaving an unconfirmed bubble behind. Wording
    /// matches Android's not-sent notice.
    enum NotSentDraft: Equatable {
        /// The box was empty (or already held exactly the message).
        case restored
        /// The box had newer text; the message now sits above it.
        case merged
    }

    /// Hands an unsent message back without discarding anything typed while
    /// it was being refused. A box the send never cleared, because typing
    /// continued before acceptance, still starts with the message and is
    /// left alone. Android's `agentDraftWithUnsentMessage` matches.
    func returnUnsentText(_ text: String, for threadID: AgentThreadID, boxWasCleared: Bool = true) -> NotSentDraft {
        let current = draftBinding(for: threadID)
        if !boxWasCleared, current.hasPrefix(text) { return .restored }
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setDraft(text, for: threadID)
            return .restored
        }
        if current == text { return .restored }
        setDraft(text + "\n\n" + current, for: threadID)
        return .merged
    }

    /// `reason` is the adapter's content-free refusal code; the wording
    /// matches Android's `agentNotSentNotice`.
    func reportNotSent(_ error: AgentActionError, reason: String, providerName: String?, draft: NotSentDraft) {
        let possessive = providerName.map { "\($0)'s" } ?? "the agent's"
        let cause: String
        switch (reason, error) {
        case ("input-policy", _): cause = "this message can't be typed into \(possessive) prompt from here"
        case (_, .cancelled): cause = "the send was cancelled"
        case ("receipt", _): cause = "delivery tracking couldn't start"
        case (_, .inputNotReady): cause = "\(possessive) input wasn't ready"
        case (_, .terminalDraft): cause = "the terminal already has unsent text in \(possessive) prompt"
        case (_, .staleBinding): cause = "the terminal changed"
        case (_, .unavailable): cause = "this terminal can't take verified input right now"
        default: cause = "the terminal wasn't ready"
        }
        let returned = switch draft {
        case .restored: " Nothing was typed; your message is back in the box."
        case .merged: " Nothing was typed; your message is back in the box above what you typed since."
        }
        reportUnavailable("Not sent — \(cause).\(returned)")
    }

    /// The offer is tied to one confirmed refusal, including its returned
    /// draft. It is never reconstructed from a generic verification error.
    func offerSendAnyway(for request: ComposerSend, refusal: AppleAgentSendNotWritten, draft: NotSentDraft) {
        guard request.composerVerification == .required, refusal.allowsSendAnyway,
              request.sendAnywayGeneration == sendAnywayGeneration,
              request.threadID.providerID == .codex || request.threadID.providerID == .claude,
              selectedThreadID == request.threadID,
              threadSnapshots[request.threadID]?.binding == request.binding,
              threadSnapshots[request.threadID]?.conversationEnded != true,
              capabilityNotice != nil else { return }
        let returned = draftBinding(for: request.threadID)
        let remaining: String
        if returned == request.text { remaining = "" }
        else if draft == .merged, returned.hasPrefix(request.text + "\n\n") {
            remaining = String(returned.dropFirst(request.text.count + 2))
        } else {
            // The user edited the original before it could be cleared; that
            // edited text has no exact removable returned-message segment.
            return
        }
        sendAnywayCandidate = .init(request: request, returnedDraft: returned, remainingDraft: remaining)
    }

    func invalidateSendAnyway() {
        sendAnywayGeneration &+= 1
        sendAnywayCandidate = nil
    }

    private func invalidateChangedSendAnyway() {
        guard let candidate = sendAnywayCandidate else { return }
        let request = candidate.request
        if selectedThreadID != request.threadID
            || threadSnapshots[request.threadID]?.binding != request.binding
            || threadSnapshots[request.threadID]?.conversationEnded == true
            || draftBinding(for: request.threadID) != candidate.returnedDraft {
            invalidateSendAnyway()
        }
    }

    func sendAnyway() {
        invalidateChangedSendAnyway()
        guard let candidate = sendAnywayCandidate, let onAction,
              pendingSends[candidate.request.threadID] == nil,
              !uploadingThreads.contains(candidate.request.threadID) else { return }
        let original = candidate.request
        // Consume synchronously, before the alert dismisses or Core awaits a
        // lease. A double tap cannot replay this approval.
        invalidateSendAnyway()
        capabilityNotice = nil
        let request = ComposerSend(id: UUID(), threadID: original.threadID, binding: original.binding,
            text: original.text, queueWhenWorking: original.queueWhenWorking, composerVerification: .userOverride,
            draftToReplace: candidate.returnedDraft, replacementDraft: candidate.remainingDraft,
            sendAnywayGeneration: sendAnywayGeneration)
        pendingSends[request.threadID] = request.id
        onAction(.send(request))
    }

    func clearForExperimentDisable() {
        cancelAttachmentPhotoLoad?()
        cancelAttachmentPhotoLoad = nil
        threadDetailVisible = false
        discardTranscriptLayoutCache()
        listSnapshot = AgentCenterListSnapshot(threads: [])
        threadSnapshots.removeAll()
        summaryMetadataIssues.removeAll()
        selectedThreadID = nil
        selectedCandidateID = nil
        pendingNarrowThreadNavigation = nil
        searchQuery = ""
        isSearching = false
        searchSnapshot = .init(results: [])
        keyboardFocus = .none
        composerFocusRequest = nil
        mountedComposerThreadID = nil
        showSystemEvents = false
        launchMode = nil
        promptOverflow = nil
        launchTargets.removeAll()
        drafts.removeAll()
        pendingSends.removeAll()
        uploadingThreads.removeAll()
        loadingTranscriptThreads.removeAll()
        ingestionCapacityThreads.removeAll()
        ingestionReadStatuses.removeAll()
        attachmentPickerRequest = nil
        attachmentPickerDismissalRequest = nil
        loadingAttachmentPhotoRequestID = nil
        capabilityNotice = nil
        integrationNotice = nil
    }

    func sendDraft(for thread: AgentThreadSnapshot, queueWhenWorking: Bool = false) {
        invalidateSendAnyway()
        let id = thread.summary.id
        let text = draftBinding(for: id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingSends[id] == nil, !uploadingThreads.contains(id) else { return }
        guard thread.conversationEnded != true else {
            reportConversationEnded()
            return
        }
        guard let binding = thread.binding, binding.capabilities.contains(.send), let onAction else {
            reportUnavailable("Sending is unavailable because this terminal is no longer live.")
            return
        }
        let request = ComposerSend(id: UUID(), threadID: id, binding: binding, text: text, queueWhenWorking: queueWhenWorking,
            composerVerification: .required, draftToReplace: text, replacementDraft: "", sendAnywayGeneration: sendAnywayGeneration)
        // Update before dispatching the asynchronous action, including its
        // projection/proof work. A second tap cannot submit the same draft.
        pendingSends[id] = request.id
        onAction(.send(request))
    }

    func finishSend(_ request: ComposerSend) {
        if pendingSends[request.threadID] == request.id { pendingSends.removeValue(forKey: request.threadID) }
    }

    func prepareAttachments(for thread: AgentThreadSnapshot, source: AttachmentPickerRequest.Source = .file, composerWasFocused: Bool? = nil) {
        invalidateSendAnyway()
        guard attachmentPickerRequest == nil, !uploadingThreads.contains(thread.summary.id), pendingSends[thread.summary.id] == nil else { return }
        guard var request = onPrepareAttachments?(thread) else {
            reportUnavailable("The original upload terminal is unavailable.")
            return
        }
        request.source = source
        request.composerWasFocused = composerWasFocused ?? (keyboardFocus == .composer)
        attachmentPickerDismissalRequest = request
        attachmentPickerRequest = request
    }

    func completeAttachments(_ request: AttachmentPickerRequest, urls: [URL]) {
        if loadingAttachmentPhotoRequestID == request.id {
            loadingAttachmentPhotoRequestID = nil
            if urls.isEmpty { cancelAttachmentPhotoLoad?() }
            cancelAttachmentPhotoLoad = nil
        }
        if attachmentPickerRequest?.id == request.id { attachmentPickerRequest = nil }
        onCompleteAttachments?(request, urls)
    }

    func failPhotoAttachments(_ request: AttachmentPickerRequest, error: Error) {
        if attachmentPickerRequest?.id == request.id {
            reportUnavailable("Photo attachment failed: \(error.localizedDescription)")
        }
        completeAttachments(request, urls: [])
    }

    func beginLoadingAttachmentPhotos(_ request: AttachmentPickerRequest, onCancel: (() -> Void)? = nil) -> Bool {
        guard attachmentPickerRequest?.id == request.id else { return false }
        loadingAttachmentPhotoRequestID = request.id
        cancelAttachmentPhotoLoad = onCancel
        return true
    }

    func cancelLoadingAttachmentPhotos() {
        guard loadingAttachmentPhotos, let request = attachmentPickerRequest else { return }
        completeAttachments(request, urls: [])
    }

    func attachmentPickerDidDismiss(hardwareKeyboardConnected: Bool? = nil) {
        guard let request = attachmentPickerDismissalRequest else { return }
        attachmentPickerDismissalRequest = nil
        completeAttachments(request, urls: [])
        restoreComposerFocus(after: request, hardwareKeyboardConnected: hardwareKeyboardConnected)
    }

    func restoreComposerFocus(after request: AttachmentPickerRequest, hardwareKeyboardConnected: Bool? = nil) {
        guard keyboardFocus == .none || keyboardFocus == .composer || keyboardFocus == .action else { return }
        if request.shouldRestoreComposerFocus(hardwareKeyboardConnected: hardwareKeyboardConnected ?? AgentHardwareKeyboard.shared.isConnected) {
            requestComposerFocus(for: request.threadID)
        }
    }

    func setComposerMounted(_ mounted: Bool, for threadID: AgentThreadID) {
        if mounted {
            if mountedComposerThreadID != threadID { composerFocusRequest = nil }
            mountedComposerThreadID = threadID
        } else if mountedComposerThreadID == threadID {
            mountedComposerThreadID = nil
            composerFocusRequest = nil
        }
    }

    func requestComposerFocus(for threadID: AgentThreadID) {
        guard selectedThreadID == threadID, mountedComposerThreadID == threadID else { return }
        composerFocusRequest = ComposerFocusRequest(threadID: threadID)
    }

    func consumeComposerFocusRequest(_ request: ComposerFocusRequest) -> Bool {
        guard composerFocusRequest?.id == request.id, selectedThreadID == request.threadID,
              keyboardFocus == .none || keyboardFocus == .composer || keyboardFocus == .action,
              mountedComposerThreadID == request.threadID else { return false }
        composerFocusRequest = nil
        return true
    }

    func requestSearchFocus() {
        // The search field reports `.search` once it actually takes focus; a
        // field that is not on screen (compact detail) never does, so setting
        // it here could strand digits and composer focus behind a dead state.
        composerFocusRequest = nil
        searchFocusRequest &+= 1
    }

    var allowsListNavigationShortcuts: Bool { keyboardFocus == .list }

    private var answerablePrompt: AgentActionPrompt? {
        guard threadDetailVisible, let thread = selectedThread,
              Self.rendersInlinePromptOptions(for: thread.summary),
              thread.summary.availability.actions,
              thread.binding?.capabilities.contains(.promptAnswer) == true,
              !answeringPromptThreads.contains(thread.summary.id) else { return nil }
        for message in thread.messages.reversed() {
            for case .actionPrompt(let prompt) in message.blocks { return prompt.options.isEmpty ? nil : prompt }
        }
        return nil
    }

    static func rendersInlinePromptOptions(for summary: AgentThreadSummary) -> Bool {
        summary.attention == .needsYou
    }

    var allowsPromptDigitShortcuts: Bool {
        (keyboardFocus == .none || keyboardFocus == .list || keyboardFocus == .action) && answerablePrompt != nil
    }

    func updatePromptKeyboardFocus() {
        // List arrows remain available beside prompt digits. Neither a new
        // selection nor a new prompt may take focus from a text input.
        guard keyboardFocus == .none || keyboardFocus == .action else { return }
        let focus: KeyboardFocus = answerablePrompt == nil ? .none : .action
        if keyboardFocus != focus { keyboardFocus = focus }
    }

    func setShowSystemEvents(_ showSystemEvents: Bool) {
        self.showSystemEvents = showSystemEvents
        onAction?(.setShowSystemEvents(showSystemEvents))
    }

    func displayedActivityEvents(from events: [AgentActivityEvent]) -> [AgentActivityEvent] {
        Self.displayedActivityEvents(events, showSystemEvents: showSystemEvents)
    }

    static func displayedActivityEvents(
        _ events: [AgentActivityEvent],
        showSystemEvents: Bool
    ) -> [AgentActivityEvent] {
        guard !showSystemEvents else { return events }
        return events.filter { $0.kind != .system }
    }

    func selectAdjacentThread(offset: Int) {
        guard !listSnapshot.threads.isEmpty else { return }
        let current = selectedThreadID.flatMap { id in
            listSnapshot.threads.firstIndex(where: { $0.id == id })
        } ?? 0
        let next = min(max(0, current + offset), listSnapshot.threads.count - 1)
        select(listSnapshot.threads[next].id)
    }

    func answerDefaultPrompt() {
        answerPromptOption(0)
    }

    func answerPromptOption(_ index: Int) {
        guard let thread = selectedThread,
              let prompt = answerablePrompt,
              prompt.options.indices.contains(index),
              prompt.options[index].role != .freeform,
              prompt.options[index].acceptsText != true
        else { return }
        onAction?(.answer(threadID: thread.summary.id, token: prompt.token, goal: .option(prompt.options[index].id)))
    }

    func interruptSelectedThread() {
        guard threadDetailVisible, let thread = selectedThread, thread.summary.status == .working else { return }
        onAction?(.interrupt(thread.summary.id))
    }

    func showPromptOverflow(threadID: AgentThreadID, prompt: AgentActionPrompt) {
        promptOverflow = .init(threadID: threadID, prompt: prompt)
    }

    func openLaunch(_ mode: LaunchMode) {
        guard !launchTargets.isEmpty else {
            reportUnavailable("Launching requires an injected live session route.")
            return
        }
        launchMode = mode
        launchDraft = LaunchDraft()
        let target: LaunchTarget?
        switch mode {
        case .spawn:
            target = launchTargets.first
        case .fork(let source):
            guard let binding = threadSnapshots[source]?.binding,
                  let matching = launchTargets.first(where: { $0.id == binding.liveSessionID }),
                  matching.providerIDs.contains(source.providerID),
                  AgentProviderRegistry.builtIn.manifest(for: source.providerID)?.actions.contains(.fork) == true
            else {
                launchMode = nil
                reportUnavailable("Forking requires the source agent's connected tmux target.")
                return
            }
            target = matching
            launchDraft.providerID = source.providerID
            launchDraft.placement = .split
        }
        launchDraft.targetID = target?.id
        if launchDraft.providerID == nil {
            launchDraft.providerID = target?.providerIDs.first {
                AgentProviderRegistry.builtIn.manifest(for: $0)?.actions.contains(.spawn) == true
            }
        }
        launchDraft.directory = target?.recentDirectories.first ?? ""
        launchDraft.windowID = target?.windows.first?.id
        launchDraft.paneID = target?.windows.first?.paneIDs.first
    }

    func submitLaunch() {
        guard let mode = launchMode,
              let targetID = launchDraft.targetID,
              let providerID = launchDraft.providerID,
              let directory = AgentRemotePath(launchDraft.directory)
        else { return }

        let kind: AgentLaunchKind
        switch mode {
        case .spawn:
            kind = .spawn(name: launchDraft.name.nilIfBlank)
        case .fork(let threadID):
            kind = .fork(source: AgentForkSource(threadID: threadID), name: launchDraft.name.nilIfBlank)
        }
        let placement: AgentPlacement
        switch launchDraft.placement {
        case .newWindow:
            placement = .newWindow(name: launchDraft.name.nilIfBlank)
        case .split:
            guard let windowID = launchDraft.windowID else { return }
            placement = .split(
                windowID: windowID,
                paneID: launchDraft.paneID,
                axis: launchDraft.axis
            )
        }
        let isolation: AgentIsolation = launchDraft.isolation == .currentWorktree
            ? .currentWorktree : .newWorktree(branch: launchDraft.branch)
        guard let intent = AgentLaunchIntent(
            kind: kind,
            liveSessionID: targetID,
            providerID: providerID,
            workingDirectory: directory,
            task: launchDraft.task,
            placement: placement,
            isolation: isolation
        ) else { return }
        onAction?(.launch(intent))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
