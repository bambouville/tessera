import Foundation
import Observation
import TesseraCore

/// Main-actor presentation bridge for the portable actor runtime.  SwiftUI
/// presentation can observe snapshots here without gaining a second reducer
/// or bypassing portable action leases.
@MainActor
@Observable
final class AppleAgentCenterRuntimeBridge {
    @ObservationIgnored private let runtime: AgentCenterRuntime
    /// The middle tier of the title waterfall. When the device has no model,
    /// every thread keeps shared Core's clipped opening prompt.
    @ObservationIgnored private let titleGenerator: AgentTitleGenerating?
    /// Seeds already sent to the model, so a list refresh is not a re-run.
    @ObservationIgnored private var requestedTitleSeeds: Set<String> = []
    @ObservationIgnored private var titleGenerationTask: Task<Void, Never>?
    @ObservationIgnored private var titleCharacterBudget = 0

    private(set) var listSnapshot = AgentCenterListSnapshot(threads: [])
    private(set) var threadSnapshots: [AgentThreadID: AgentThreadSnapshot] = [:]
    /// Threads whose snapshot changed since the presentation last took them.
    /// Inventory keeps a snapshot per stored session, and a publish runs
    /// several times a second on the main actor: it applies these, not all.
    @ObservationIgnored private var presentationChanges: Set<AgentThreadID> = []
    /// Threads Core dropped since the presentation last took them.
    @ObservationIgnored private var presentationRemovals: Set<AgentThreadID> = []
    /// Replaced conversation → the one that holds its pane now.
    @ObservationIgnored private var presentationSuccessors: [AgentThreadID: AgentThreadID] = [:]
    @ObservationIgnored private var presentationNeedsAll = true
    private(set) var searchSnapshot = AgentSearchSnapshot(results: [])
    private(set) var lastActionError: AgentActionError?

    init(runtime: AgentCenterRuntime = .init(), titleGenerator: AgentTitleGenerating? = AppleAgentTitleGenerator()) {
        self.runtime = runtime
        self.titleGenerator = titleGenerator
    }

    /// Reports how many characters of an opening prompt a list row can show.
    ///
    /// The bottom tier of the title waterfall is a clipped prompt, and how much
    /// of it fits is a property of this screen, so the width comes from the UI
    /// and the clipping stays in shared Core where both platforms get it.
    func setTitleCharacterBudget(_ characters: Int) async {
        guard characters != titleCharacterBudget else { return }
        titleCharacterBudget = characters
        await runtime.setTitleCharacterBudget(characters)
        await refreshList()
    }

    /// Asks the on-device model for a title for every thread still resting on a
    /// clipped prompt.
    ///
    /// Core publishes both which threads want one and the seed to summarise,
    /// and refuses a late answer whose seed no longer matches, so a thread that
    /// meanwhile gains the agent's own title simply keeps it.
    private func generateMissingTitles() async {
        guard let titleGenerator else { return }
        let pending = await runtime.threadsAwaitingGeneratedTitle()
            .filter { requestedTitleSeeds.insert($0.seed).inserted }
        guard !pending.isEmpty else { return }
        let previous = titleGenerationTask
        titleGenerationTask = Task { [weak self] in
            // Serialised: the system model is one session, and a list refresh
            // can want a dozen titles at once.
            await previous?.value
            for request in pending {
                guard let title = await titleGenerator.title(for: request.seed) else { continue }
                guard let self else { return }
                guard await self.applyGeneratedTitle(title, for: request) else { continue }
            }
        }
    }

    private func applyGeneratedTitle(_ title: String, for request: AgentTitleGenerationRequest) async -> Bool {
        guard await runtime.applyGeneratedTitle(title, for: request.threadID, seed: request.seed) else { return false }
        await refresh(request.threadID)
        return true
    }

    func configure(registry: AgentProviderRegistry) async {
        await runtime.configure(registry: registry)
    }

    func updateHostDisplayLabels(_ labels: [UUID: String]) async {
        for id in await runtime.updateHostDisplayLabels(labels) {
            threadSnapshots[id] = await runtime.snapshot(for: id)
            presentationChanges.insert(id)
        }
        await refreshList()
    }

    func register(_ summary: AgentThreadSummary, binding: AgentTerminalBinding? = nil) async {
        await runtime.register(summary, binding: binding)
        await refresh(summary.id)
    }

    func registerInventoryPage(_ summaries: [AgentThreadSummary]) async throws {
        guard !summaries.isEmpty else { return }
        try await runtime.registerInventoryPage(summaries)
        // Keep existing per-thread presentation semantics, including any
        // lifecycle update arriving while the actor is suspended. Only list
        // projection/title scheduling is coalesced to the page boundary.
        for summary in summaries { await refresh(summary.id, refreshList: false) }
        await refreshList()
    }

    func registerCandidate(
        _ id: AgentSourceCandidateID,
        fallback: AgentFallbackSnapshot,
        providerName: String,
        title: String,
        hostDisplayLabel: String,
        lastActivity: Date? = nil,
        processIDs: Set<Int>? = nil
    ) async {
        await runtime.registerCandidate(
            id,
            fallback: fallback,
            providerName: providerName,
            title: title,
            hostDisplayLabel: hostDisplayLabel,
            lastActivity: lastActivity,
            processIDs: processIDs
        )
        await refreshList()
    }

    func removeCandidate(_ id: AgentSourceCandidateID) async {
        await runtime.removeCandidate(id)
        await refreshList()
    }

    func replaceBinding(_ binding: AgentTerminalBinding?, for threadID: AgentThreadID) async {
        await runtime.replaceBinding(binding, for: threadID)
        await refresh(threadID)
    }

    func retireProjection(
        for threadID: AgentThreadID,
        reason: AgentAvailabilityReason = .integrationOutdated
    ) async {
        await runtime.retireProjection(for: threadID, reason: reason)
        await refresh(threadID)
    }

    @discardableResult
    func apply(page: AgentProjectionPage, to threadID: AgentThreadID) async -> AgentProjectionApplyResult {
        let result = await runtime.apply(page: page, to: threadID)
        await refresh(threadID)
        return result
    }

    @discardableResult
    func applyLifecycle(
        _ envelope: AgentLifecycleEnvelope,
        proof: AgentLifecycleBindingProof,
        expectedSourceIdentity: String
    ) async -> AgentLifecycleAcceptance {
        let result = await runtime.applyLifecycle(envelope, proof: proof, expectedSourceIdentity: expectedSourceIdentity)
        if let id = AgentThreadID(
            hostID: proof.hostID,
            providerID: envelope.providerID,
            providerSessionID: envelope.providerSessionID ?? ""
        ) {
            await refresh(id)
        } else {
            await refreshList()
        }
        return result
    }

    func acknowledge(threadID: AgentThreadID, visibleRecordID: String) async {
        guard await runtime.acknowledge(threadID: threadID, visibleRecordID: visibleRecordID) else { return }
        await refresh(threadID)
    }

    /// Reads a finish the reader has seen, even when it carries no record.
    @discardableResult
    func acknowledgeCompletion(threadID: AgentThreadID, observedEpoch: UInt64) async -> Bool {
        guard await runtime.acknowledgeCompletion(threadID: threadID, observedEpoch: observedEpoch) else { return false }
        await refresh(threadID)
        return true
    }

    func select(threadID: AgentThreadID?) async {
        await runtime.select(threadID: threadID)
    }

    func setFilter(_ filter: AgentListFilter) async {
        await runtime.setFilter(filter)
        await refreshList()
    }

    func setGrouping(_ grouping: AgentListGrouping) async {
        await runtime.setGrouping(grouping)
        await refreshList()
    }

    func search(query: String) async {
        searchSnapshot = await runtime.search(query: query)
    }

    func applySearch(_ snapshot: AgentSearchSnapshot) async {
        await runtime.applySearch(snapshot)
        searchSnapshot = await runtime.currentSearchSnapshot()
    }

    /// `successor` names the conversation that replaced `threadID` on its
    /// pane, which a reader on `threadID` follows once it is gone.
    func refresh(_ threadID: AgentThreadID, refreshList: Bool = true, successor: AgentThreadID? = nil) async {
        let started = Date()
        defer { AgentCenterV2PerformanceDiagnostics.shared.record("snapshotRead", since: started) }
        if let snapshot = await runtime.snapshot(for: threadID) {
            if threadSnapshots[threadID] != snapshot {
                threadSnapshots[threadID] = snapshot
                presentationChanges.insert(threadID)
            }
            presentationSuccessors.removeValue(forKey: threadID)
        } else {
            var successor = successor
            if threadSnapshots.removeValue(forKey: threadID) != nil {
                presentationChanges.remove(threadID)
                presentationRemovals.insert(threadID)
                // Any read can meet the replaced thread first, such as the
                // open transcript's refresh; Core still knows where it went.
                if successor == nil { successor = await runtime.conversationReplacing(threadID) }
            }
            if let successor { presentationSuccessors[threadID] = successor }
        }
        if refreshList { await self.refreshList() }
    }

    /// The snapshots changed since the last call (every snapshot after
    /// `invalidatePresentation`). Removed threads are reported by
    /// `takePresentationRemovals`.
    func takePresentationChanges() -> [AgentThreadSnapshot] {
        defer { presentationChanges.removeAll(keepingCapacity: true); presentationNeedsAll = false }
        if presentationNeedsAll { return Array(threadSnapshots.values) }
        return presentationChanges.compactMap { threadSnapshots[$0] }
    }

    /// The threads Core dropped since the last call, such as the conversation
    /// a `/clear` replaced on its pane, with the conversation that replaced
    /// each one that has a successor.
    func takePresentationRemovals() -> (removed: Set<AgentThreadID>, successors: [AgentThreadID: AgentThreadID]) {
        defer {
            presentationRemovals.removeAll(keepingCapacity: true)
            presentationSuccessors.removeAll(keepingCapacity: true)
        }
        return (presentationRemovals.filter { threadSnapshots[$0] == nil },
                presentationSuccessors.filter { threadSnapshots[$0.key] == nil })
    }

    /// The presentation dropped its copies; the next take returns them all.
    func invalidatePresentation() {
        presentationNeedsAll = true
    }

    /// Disabling purges content in Core. Re-read every cached snapshot, so the
    /// presentation's next full take cannot restore what was purged.
    func reloadSnapshotsAfterDisable() async {
        for threadID in Array(threadSnapshots.keys) { await refresh(threadID, refreshList: false) }
        presentationNeedsAll = true
    }

    func refreshList() async {
        let started = Date()
        defer { AgentCenterV2PerformanceDiagnostics.shared.record("listRead", since: started) }
        let list = await runtime.listSnapshot()
        if listSnapshot != list { listSnapshot = list }
        let search = await runtime.currentSearchSnapshot()
        if searchSnapshot != search { searchSnapshot = search }
        await generateMissingTitles()
    }

    func submit(
        _ request: AgentTextSendRequest,
        terminal: AppleAgentTerminalAdapter,
        requestedAt: ContinuousClock.Instant = .now,
        prepareReceipt: @escaping (AgentActionLease) async throws -> Void,
        onAccepted: (() async -> Void)? = nil,
        onNotSent: ((AppleAgentSendNotWritten) async -> Void)? = nil
    ) async -> Result<Void, AgentActionError> {
        let label = "provider=\(request.threadID.providerID.rawValue) transport=\(request.binding.transport.rawValue)"
        let timing: @Sendable (String) -> Void = { stage in
            let elapsed = requestedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            DiagnosticLogStore.appendAgentCenter("send-latency \(label) stage=\(stage) elapsedMs=\(milliseconds)")
        }
        return await performLeaseAction(threadID: request.threadID, action: request.queueWhenWorking ? .queue : .send, binding: request.binding, textRequest: request, onAccepted: onAccepted, onNotSent: onNotSent, prepareReceipt: { lease in
            // Nothing has been written while the receipt is prepared.
            do { try await prepareReceipt(lease) } catch {
                let code: AgentActionError = error is CancellationError ? .cancelled : (error as? AgentActionError) ?? .unavailable
                throw AppleAgentSendNotWritten(error: code, reason: "receipt", attempts: 0, shape: nil)
            }
        }) { [runtime] lease in
            timing("receipt-ready")
            try await terminal.sendText(request, beforeWrite: { try await runtime.markOutgoingDispatched(lease) })
            timing("text-write-ack")
            do { try await terminal.sendReturn(binding: request.binding) } catch {
                // The text reached the composer but no key followed it.
                DiagnosticLogStore.appendAgentCenter("send-submit-refused \(label) error=\(String(describing: error))")
                throw error
            }
            timing("submit-key-ack")
            try await terminal.verifySubmission(threadID: request.threadID, binding: request.binding)
        }
    }

    func answer(
        _ request: AgentPromptAnswerRequest,
        observation: AgentTerminalObservation,
        terminal: AppleAgentTerminalAdapter
    ) async -> Result<Void, AgentActionError> {
        await performLeaseAction(threadID: request.threadID, action: .answerPrompt, binding: request.binding) { _ in
            try await terminal.answer(request, freshObservation: observation)
        }
    }

    func interrupt(
        threadID: AgentThreadID,
        binding: AgentTerminalBinding,
        terminal: AppleAgentTerminalAdapter
    ) async -> Result<Void, AgentActionError> {
        await performLeaseAction(threadID: threadID, action: .interrupt, binding: binding) { _ in
            try await terminal.interrupt(binding: binding)
        }
    }

    private func performLeaseAction(
        threadID: AgentThreadID,
        action: AgentActionKind,
        binding: AgentTerminalBinding,
        textRequest: AgentTextSendRequest? = nil,
        onAccepted: (() async -> Void)? = nil,
        onNotSent: ((AppleAgentSendNotWritten) async -> Void)? = nil,
        prepareReceipt: ((AgentActionLease) async throws -> Void)? = nil,
        operation: @escaping @Sendable (AgentActionLease) async throws -> Void
    ) async -> Result<Void, AgentActionError> {
        let lease: AgentActionLease
        do {
            lease = try await runtime.acquireLease(threadID: threadID, action: action, binding: binding, textRequest: textRequest)
        } catch let error as AgentActionError {
            lastActionError = error
            return .failure(error)
        } catch {
            lastActionError = .unavailable
            return .failure(.unavailable)
        }

        await refresh(threadID)
        await onAccepted?()
        do {
            // Receipt observation samples an independent bounded source frontier;
            // transcript reconstruction never blocks terminal submission.
            do {
                try Task.checkCancellation()
                if let prepareReceipt { try await prepareReceipt(lease) }
                try Task.checkCancellation()
            } catch is CancellationError {
                throw AppleAgentSendNotWritten(error: .cancelled, reason: "cancelled", attempts: 0, shape: nil)
            }
            try await operation(lease)
            await runtime.releaseLease(lease, result: .verified)
            lastActionError = nil
            await refresh(threadID)
            return .success(())
        } catch let refusal as AppleAgentSendNotWritten {
            // Refused before the first byte: no receipt can follow, so the
            // bubble is withdrawn and the caller returns the draft.
            await runtime.releaseLease(lease, result: textRequest == nil ? .failed : .notSent)
            lastActionError = refusal.error
            DiagnosticLogStore.appendAgentCenter("\(textRequest == nil ? "action-refused action=\(action.rawValue)" : "send-refused") provider=\(threadID.providerID.rawValue) transport=\(binding.transport.rawValue) error=\(refusal.error.rawValue) reason=\(refusal.reason) attempts=\(refusal.attempts)\(refusal.shape.map { " " + $0 } ?? "")")
            await refresh(threadID)
            if textRequest != nil { await onNotSent?(refusal) }
            return .failure(refusal.error)
        } catch let error as AgentActionError {
            await runtime.releaseLease(lease)
            lastActionError = error
            await refresh(threadID)
            return .failure(error)
        } catch is CancellationError {
            await runtime.releaseLease(lease)
            lastActionError = .cancelled
            await refresh(threadID)
            return .failure(.cancelled)
        } catch {
            await runtime.releaseLease(lease)
            lastActionError = .unavailable
            await refresh(threadID)
            return .failure(.unavailable)
        }
    }
}
