import Foundation

public actor AgentCenterRuntime {
    private struct OutgoingState: Sendable {
        var message: AgentOutgoingMessage
        var boundary: AgentProjectionPage?
        var frontier: AgentOutgoingFrontier?
        var dispatched = false
        var terminalAcknowledged = false
        var observationalMatch = false
        var preDispatchSequence: UInt64?
        var preDispatchSourceKey: String?
        var preDispatchEpoch: String?
        var preAcknowledgmentPhysicalOffset: UInt64?
        /// The receipt that settled this send, keyed by physical identity and
        /// offset when available. A replay cannot settle an identical send.
        var matchedReceipt: String?
        /// A loaded reader held no record at dispatch/ACK: every record is newer.
        var heldNothing = false
        let binding: AgentTerminalBinding
    }
    /// Defaults until a platform reports its device tier.
    public static let globalContentLimitBytes = AgentContentBudget.compact.globalBytes
    public static let perThreadContentLimitBytes = AgentContentBudget.compact.perThreadBytes

    private struct ThreadState: Sendable {
        var summary: AgentThreadSummary
        /// Transcript provenance: the remote projector's identity for the
        /// transcript file it read (dev/inode/size/mtime). A change means the
        /// file rotated and the cached records must be dropped.
        var sourceIdentity: String?
        /// The projector discovers the opening prompt while scanning the full
        /// source, even when this client begins with only the newest page.
        /// It is intentionally separate from the visible message cache.
        var openingPrompt: String?
        /// Route provenance: which live pane/session claimed this thread,
        /// proved by the platform binding authority. Never interchangeable
        /// with `sourceIdentity` — comparing the two rejects real traffic.
        var routeIdentity: String?
        /// Whether a live pane on a connected host currently holds this
        /// thread. Set when a lifecycle frame is accepted, and when a detected
        /// terminal candidate is promoted — the two ways an agent is open.
        /// Cleared whenever the binding changes or is retired.
        ///
        /// Deliberately not inferred from `binding`: Tier-C inventory mints an
        /// observe-only binding for every *stored* session so it can authorise
        /// transcript reads, and a stored session is not an open agent.
        var isLiveRoute = false
        /// The thread's latest frame came from a Codex child agent, which
        /// reports under its own thread in its root's process and so does not
        /// replace the root's conversation. Claude reports its subagents'
        /// frames under the root's own session, so a Claude thread is always
        /// a root. Decided by the frame alone, so every platform decides it
        /// the same way whatever it saw before.
        var isChildConversation = false
        var conversationEnded = false
        var conversationEndNanos: UInt64?
        var tenureStartNanos: UInt64?
        /// The newest SessionStart accepted for this root, including a
        /// resume or compaction that kept its ID: an End older than it
        /// belongs to an earlier run of the conversation.
        var rootBoundaryNanos: UInt64?
        /// The newest root activity accepted for this thread: not a neutral
        /// subagent callback, and not an End, which proves no ownership.
        var latestRootActivityNanos: UInt64?
        var firstChildTimestampNanos: UInt64?
        var childRootTenureStartNanos: UInt64?
        var rootAgentID: String?
        var records: [AgentProjectionRecord] = []
        var ingestionEpoch: String?
        var ingestionWindow: AgentIngestionWindow?
        var ingestionWindowTransition: AgentIngestionWindowTransaction.Lane = .bootstrap
        var ingestionLastWindowPage: AgentProjectionPage?
        var ingestionLastWindowPageBytes = 0
        /// The bounded presentation measured when the window was admitted.
        var ingestionPresentationBytes: Int?
        /// What the last admitted older page added, and the retained content
        /// at which one was refused (see `olderPageRoom`).
        var ingestionOlderPageCost = 0
        var ingestionOlderRefusedBytes: Int?
        var ingestionHeadMessages: [AgentMessage] = []
        /// Normalized output and encoded sizes per canonical record revision.
        /// Rebuilding a retained window reuses them instead of renormalizing
        /// and re-encoding every retained page on each admission.
        var normalizedRecords: [String: NormalizedRecord] = [:]
        /// Snapshot messages derived from `messages`. Reusing the same array
        /// keeps unchanged snapshots cheap to compare on the platform side.
        var presentationSource: [AgentMessage] = []
        var presentationMessages: [AgentMessage] = []
        var viewportAnchorRecordID: String?
        var liveCursor: String?
        var ingestionTransactions: [String] = []
        var metadataOrders: [String: UInt64] = [:]
        var hookOverlay = AgentHookOverlayState()
        var messages: [AgentMessage] = []
        var livePrompt: AgentActionPrompt?
        var awaitingPermissionResolution = false
        /// A question tool the hook reported, until it is answered or its
        /// prompt is gone from the terminal.
        var pendingQuestion: AgentLifecycleInputHint?
        var pendingQuestionMisses = 0
        /// A terminal observation, not the hook, set the current attention
        /// and status, so a later miss reverts them.
        var promptRaisedAttention = false
        /// Consecutive misses of a dialog the screen showed under the hook's
        /// own attention; nil until one is seen. A permission answered in the
        /// terminal reports nothing until its tool returns.
        var hookPromptMisses: Int?
        var cursor: String?
        var hasMore = false
        var binding: AgentTerminalBinding?
        var actionLease: AgentActionLease?
        var outgoing: [OutgoingState] = []
        var lastOutgoingReceiptSequence: UInt64?
        var lastOutgoingReceiptSourceKey: String?
        var lastReadRecordID: String?
        var turns: [AgentTurn] = []
        var activity: [AgentActivityEvent] = []
        /// Activity derived from a projection record is removable with that
        /// record. Lifecycle activity deliberately has no entry here.
        var projectionActivityByRecordID: [String: String] = [:]
        var changes = AgentChangeSummary()
        var lineage: AgentThreadLineage?
        var lastAccessOrdinal: UInt64 = 0
        var estimatedContentBytes = 0
        var deliveryGeneration: UInt64 = 0
        /// Advances only on entering `needsYou` or `unreadCompletion`; see
        /// `AgentThreadSnapshot.attentionEpoch`.
        var attentionEpoch: UInt64 = 0
        /// Content-free identity of the Stop behind the current unread
        /// completion; nil once it is read or superseded.
        var completionKey: String?
        /// The newest completion the reader acknowledged, restored from
        /// durable metadata on this state's first lifecycle frame.
        var acknowledgedCompletionKey: String?
        var lastLifecycleFingerprint: String?
        var lastLifecycleSequence: UInt64?
        var recentLifecycleFingerprints: [String] = []
    }

    /// The durable view of each thread's completion read state: seeded by the
    /// platform's stored metadata and kept current by in-process reduction.
    /// Snapshots export it so a platform can persist it; a thread's first
    /// lifecycle frame after a relaunch restores it.
    private struct DurableCompletion: Equatable, Sendable {
        var unread: String?
        var acknowledged: String?
    }

    private struct NormalizedRecord: Sendable {
        let revision: UInt64
        let sequence: UInt64
        let normalized: AgentNormalizedRecord
        let recordBytes: Int
        let messageBytes: Int
        let activityBytes: Int
        let editBytes: Int
    }

    private struct CandidateState: Sendable {
        var candidate: AgentTerminalCandidate
        var fallback: AgentFallbackSnapshot
        var processIDs: Set<Int>
        var registrationOrdinal: UInt64
    }

    /// A fallback represents a terminal surface, not each wrapper/child PID
    /// discovered on it. Durable conversations retain their own identities.
    private struct CandidateSurface: Hashable {
        let hostID: UUID
        let providerID: AgentProviderID
        let liveSessionID: UUID
        let carrierGeneration: UInt64
        let transport: String
        let tmuxSession: String?
        let windowID: String?
        let paneID: String?

        init(hostID: UUID, providerID: AgentProviderID, binding: AgentTerminalBinding) {
            self.hostID = hostID
            self.providerID = providerID
            liveSessionID = binding.liveSessionID
            carrierGeneration = binding.carrierGeneration
            transport = binding.transport.rawValue
            tmuxSession = binding.tmuxSession
            windowID = binding.windowID
            paneID = binding.paneID
        }
    }

    private var registry: AgentProviderRegistry
    private let normalizer: AgentTranscriptNormalizer
    private var budget = AgentContentBudget.compact
    /// Only a platform that copies snapshots through a bounded frame (the
    /// Android ABI) needs admission to reserve room for that copy.
    private let presentationLimitBytes: Int?
    /// Largest acknowledged viewport each connected host accepts.
    private var ingestionHostSegments: [UUID: Int] = [:]
    private var ingestionThreadSegments: [AgentThreadID: Int] = [:]
    private let byteEncoder = JSONEncoder()
    private var threads: [AgentThreadID: ThreadState] = [:]
    private var ingestionEvictions: Set<AgentThreadID> = []
    /// Replaced conversation → the conversation that holds its pane now.
    private var replacedConversations: [AgentThreadID: AgentThreadID] = [:]
    /// The same, kept for the recent replacements whatever a platform took,
    /// so a later read of a replaced thread still finds where its pane went.
    private var replacementSuccessors: [AgentThreadID: AgentThreadID] = [:]
    private var replacementOrder: [AgentThreadID] = []
    private struct ReplacementFence: Sendable {
        let binding: AgentTerminalBinding
        let timestamp: UInt64
    }
    private var replacementFences: [AgentThreadID: ReplacementFence] = [:]
    private var replacementFenceOrder: [AgentThreadID] = []
    /// The newest timestamped clear per agent process (`/new` before its
    /// rollout exists, an unlocatable successor). A frame older than it ran
    /// on that process before the clear, whichever conversation it names
    /// and whether or not a root was registered when the clear came.
    private var clearFences: [ReplacementFence] = []
    private var candidates: [AgentSourceCandidateID: CandidateState] = [:]
    private var candidateRegistrationOrdinal: UInt64 = 0
    private var grouping: AgentListGrouping = .attention
    private var filter = AgentListFilter()
    private var selectedThreadID: AgentThreadID?
    private var accessOrdinal: UInt64 = 0
    private var isEnabled = true
    private var searchSnapshot = AgentSearchSnapshot(results: [])
    private var metadataByThreadID: [AgentThreadID: AgentThreadMetadata] = [:]
    private var durableCompletions: [AgentThreadID: DurableCompletion] = [:]
    private var savedHostDisplayLabels: [UUID: String] = [:]
    /// How many characters of the opening prompt the reader's row can show.
    /// The bottom of the title waterfall is a clipped prompt, and how much of
    /// it fits is a property of the screen, not of the transcript, so the
    /// platform sets it and Core re-clips every thread still resting on that
    /// tier.
    private var titleCharacterBudget = AgentCenterRuntime.defaultTitleCharacterBudget

    public init(registry: AgentProviderRegistry = .builtIn, normalizer: AgentTranscriptNormalizer = .init(),
                presentationLimitBytes: Int? = nil) {
        self.registry = registry
        self.normalizer = normalizer
        self.presentationLimitBytes = presentationLimitBytes
    }

    /// Reported once by the platform from the device's physical memory.
    public func configure(budget: AgentContentBudget) {
        guard budget != self.budget else { return }
        self.budget = budget
        AgentMarkdownDocument.sizeCache(for: budget)
        enforceCacheLimits(excluding: selectedThreadID)
    }

    public func contentBudget() -> AgentContentBudget { budget }

    /// Recorded from the host's hello. It applies from the next bootstrap;
    /// an established window keeps the capacity it was acknowledged with.
    /// Reported for the thread about to bootstrap, it binds to that thread:
    /// another connection to the same host (a different service during a
    /// rollout) cannot resize a window between its request and its page.
    public func setIngestionHostSegments(_ segments: Int, for hostID: UUID, thread: AgentThreadID? = nil) {
        let clamped = min(max(segments, AgentIngestionWindowCapacity.legacy.segments), AgentIngestionWindowCapacity.maximumSegments)
        if let thread, thread.hostID == hostID { ingestionThreadSegments[thread] = clamped }
        else { ingestionHostSegments[hostID] = clamped }
    }

    public func ingestionWindowCapacity(for threadID: AgentThreadID) -> AgentIngestionWindowCapacity {
        .negotiated(budget: budget, hostSegments: ingestionThreadSegments[threadID]
            ?? ingestionHostSegments[threadID.hostID] ?? AgentIngestionWindowCapacity.legacy.segments)
    }

    /// A competing process must first prove the current route absent, then
    /// retry registration. Re-proof on the same process may change capabilities.
    @discardableResult
    public func register(_ summary: AgentThreadSummary, binding: AgentTerminalBinding? = nil) -> AgentRegistration {
        guard isEnabled else { return .registered }
        let existing = threads[summary.id]
        if let existing, existing.isLiveRoute, let current = existing.binding,
           let binding, Self.competesForLiveRoute(held: current, incoming: binding) {
            return .liveElsewhere(current: current)
        }
        var state = existing ?? ThreadState(summary: summary)
        let previousAttention = existing?.summary.attention ?? .none
        let previousSummaryBytes = existing.map { Self.summaryBytes($0.summary) } ?? 0
        // Discovery may repeat the most recent hook-derived summary many
        // times. Once lifecycle reduction owns a canonical thread, preserve
        // its attention state here so an already-acknowledged transition is
        // not resurrected before the duplicate lifecycle frame is rejected.
        let reducedAttention = state.summary.attention
        state.summary = summary
        state.summary.hostDisplayLabel = savedHostDisplayLabels[summary.id.hostID] ?? summary.hostDisplayLabel
        // Discovery owns route/status/availability, not transcript metadata.
        // Rebinding the same durable thread must not publish empty fields
        // between reads. A different source is cleared atomically by apply.
        if let existing, existing.sourceIdentity != nil {
            state.summary.model = existing.summary.model
            state.summary.projectBasename = existing.summary.projectBasename
            state.summary.branch = existing.summary.branch
            state.summary.permissionMode = existing.summary.permissionMode
            state.summary.context = existing.summary.context
            state.summary.cost = existing.summary.cost
            state.summary.preview = existing.summary.preview
            state.summary.queuedMessageCount = existing.summary.queuedMessageCount
            state.summary.lastActivitySequence = existing.summary.lastActivitySequence
        }
        if let existing, existing.lastLifecycleFingerprint != nil {
            state.summary.attention = reducedAttention
            state.summary.status = existing.summary.status
            state.summary.lastActivitySequence = existing.summary.lastActivitySequence
            state.summary.lastActivity = existing.summary.lastActivity
        }
        // A re-announcement carries the discovery placeholder, never the title
        // the transcript already yielded, so replacing the summary wholesale
        // would knock a resolved title back to "Untitled" every refresh. Carry
        // the waterfall across; a stronger source still overwrites it below.
        if let existing, existing.summary.titleProvenance > summary.titleProvenance {
            state.summary.title = existing.summary.title
            state.summary.titleProvenance = existing.summary.titleProvenance
        }
        state.summary.titleSeed = summary.titleSeed ?? existing?.summary.titleSeed
        if let metadata = metadataByThreadID[summary.id] {
            state.lastReadRecordID = metadata.lastReadRecordID
            if let pinnedTitle = metadata.pinnedTitle { applyPinnedTitle(pinnedTitle, to: &state) }
        }
        if let binding, binding != state.binding {
            state.actionLease = nil
            Self.clearLivePrompt(&state)
            state.deliveryGeneration &+= 1
            Self.unsettleOutgoing(&state)
        }
        state.binding = binding ?? state.binding
        Self.noteAttentionTransition(from: previousAttention, in: &state)
        state.estimatedContentBytes += Self.summaryBytes(state.summary) - previousSummaryBytes
        threads[summary.id] = state
        return .registered
    }

    /// A changed or retired route can no longer settle a send in flight, so
    /// its bubble reports the uncertainty. A send the transcript already
    /// showed keeps that: rebinding reverted it to "receipt unavailable" with
    /// its text, and a matched send is never matched again, so it stayed.
    private static func unsettleOutgoing(_ state: inout ThreadState) {
        for index in state.outgoing.indices where !state.outgoing[index].observationalMatch {
            state.outgoing[index].message.status = state.outgoing[index].terminalAcknowledged ? .sentUnconfirmed : .unconfirmed
        }
    }

    /// Entering `needsYou` or `unreadCompletion` starts a new attention epoch.
    /// Every other transition, and any repeat of the same state, keeps it.
    private static func noteAttentionTransition(from previous: AgentAttention, in state: inout ThreadState) {
        guard state.summary.attention != previous, state.summary.attention != .none else { return }
        state.attentionEpoch &+= 1
    }

    /// Content-free identity of a completion: the hook's own source time and
    /// process, both stable when a pane's retained hook state is replayed
    /// after a reconnect or relaunch. Without a source time a completion has
    /// no durable identity (the arrival sequence is process-local).
    static func completionKey(_ envelope: AgentLifecycleEnvelope) -> String? {
        guard let timestamp = envelope.sourceTimestampNanoseconds else { return nil }
        return "c1:" + String(timestamp, radix: 16) + ":" + String(envelope.agentPID ?? 0, radix: 16)
    }

    /// Reading a completion records its identity so a replay of the same
    /// retained Stop after a relaunch stays read.
    private func markCompletionRead(_ state: inout ThreadState, for threadID: AgentThreadID) {
        guard let key = state.completionKey else { return }
        state.acknowledgedCompletionKey = key
        state.completionKey = nil
        durableCompletions[threadID] = .init(unread: nil, acknowledged: key)
    }

    /// Inventory may have been prepared before a live lifecycle event won the
    /// actor. Check authority here, atomically with registration, not only in
    /// a platform's pre-await route lookup. A historical observation must not
    /// replace the proved live binding, availability or prompt state. A
    /// PID-bound pane registration also wins before its first lifecycle frame
    /// commits; preserving it does not itself promote a live route.
    public func registerInventorySummary(_ summary: AgentThreadSummary, binding: AgentTerminalBinding? = nil) {
        let existing = threads[summary.id]
        guard existing?.isLiveRoute != true, existing?.binding?.agentPID == nil else { return }
        register(summary, binding: binding)
    }

    /// One bounded discovery page. No caller-supplied binding or action proof
    /// is introduced, and an oversized page makes no changes.
    public func registerInventoryPage(_ summaries: [AgentThreadSummary]) throws {
        guard summaries.count <= 100 else { throw AgentIngestionError.capacityExceeded }
        for summary in summaries { registerInventorySummary(summary) }
    }

    public func configure(registry: AgentProviderRegistry? = nil, metadata: [AgentThreadMetadata]? = nil) {
        if let registry { self.registry = registry }
        if let metadata {
            metadataByThreadID = metadata.reduce(into: [:]) { result, item in
                if result[item.threadID] == nil { result[item.threadID] = item }
            }
            for id in threads.keys {
                guard var state = threads[id], let item = metadataByThreadID[id] else { continue }
                state.lastReadRecordID = item.lastReadRecordID
                if let pinnedTitle = item.pinnedTitle { applyPinnedTitle(pinnedTitle, to: &state) }
                threads[id] = state
            }
            durableCompletions = metadataByThreadID.compactMapValues { item in
                item.unreadCompletionKey == nil && item.acknowledgedCompletionKey == nil ? nil
                    : .init(unread: item.unreadCompletionKey, acknowledged: item.acknowledgedCompletionKey)
            }
            for id in threads.keys {
                guard var state = threads[id], state.lastLifecycleFingerprint != nil else { continue }
                // Stored read state that lands after this thread's first frame
                // still applies: a replayed Stop it already acknowledged is read.
                let stored = durableCompletions[id]
                if state.acknowledgedCompletionKey == nil { state.acknowledgedCompletionKey = stored?.acknowledged }
                if let key = state.completionKey, key == stored?.acknowledged {
                    state.completionKey = nil
                    if state.summary.attention == .unreadCompletion {
                        state.summary.attention = .none
                        if state.summary.status == .finished { state.summary.status = .idle }
                        state.deliveryGeneration &+= 1
                    }
                }
                // In-process reduction is newer than any stored copy.
                durableCompletions[id] = .init(unread: state.completionKey, acknowledged: state.acknowledgedCompletionKey)
                threads[id] = state
            }
        }
    }

    /// Host names are app-owned display metadata. Refresh them without
    /// replacing a carrier, changing action authority, or parsing provider tags.
    @discardableResult
    public func updateHostDisplayLabels(_ labels: [UUID: String]) -> [AgentThreadID] {
        let bounded = labels.mapValues { String($0.prefix(512)) }
        guard bounded != savedHostDisplayLabels else { return [] }
        savedHostDisplayLabels = bounded
        var changed: [AgentThreadID] = []
        for id in threads.keys {
            guard let label = bounded[id.hostID], threads[id]?.summary.hostDisplayLabel != label else { continue }
            threads[id]?.summary.hostDisplayLabel = label
            changed.append(id)
        }
        for id in candidates.keys {
            guard let label = bounded[id.hostID], let old = candidates[id]?.candidate, old.hostDisplayLabel != label else { continue }
            candidates[id]?.candidate = .init(id: old.id, providerName: old.providerName, title: old.title,
                hostDisplayLabel: label, lastActivity: old.lastActivity, fallback: old.fallback)
        }
        return changed
    }

    public func registerCandidate(
        _ id: AgentSourceCandidateID,
        fallback: AgentFallbackSnapshot,
        providerName: String = "Agent",
        title: String = "Live agent",
        hostDisplayLabel: String = "",
        lastActivity: Date? = nil,
        processIDs: Set<Int>? = nil
    ) {
        guard isEnabled else { return }
        // A platform reports a detected pane, not a provider vocabulary, so it
        // sends the generic "Agent". The compiled manifest already knows this
        // is OpenCode or Pi or Claude Code, and naming it is the whole
        // difference between a row a reader can place and one they cannot.
        // Providers with no lifecycle hooks reach the list only this way, so
        // for them it is the only name they will ever get.
        let resolvedProviderName = registry.manifest(for: id.providerID)?.displayName ?? providerName
        // Codable ingress can bypass the snapshot initializer. Normalize here
        // so every platform gets plain preview text without changing evidence
        // used to authorize terminal actions.
        let fallback = AgentFallbackSnapshot(
            status: fallback.status, location: fallback.location,
            integrationAvailable: fallback.integrationAvailable,
            liveTail: Self.terminalPreview(fallback.liveTail), prompt: fallback.prompt,
            binding: fallback.binding
        )
        candidateRegistrationOrdinal &+= 1
        candidates[id] = CandidateState(
            candidate: AgentTerminalCandidate(
                id: id,
                providerName: resolvedProviderName,
                title: title,
                hostDisplayLabel: savedHostDisplayLabels[id.hostID] ?? hostDisplayLabel,
                // Discovery time is not provider activity. Re-observing the
                // same live terminal must not invalidate every native row.
                lastActivity: candidates[id]?.candidate.lastActivity ?? lastActivity,
                fallback: fallback
            ),
            fallback: fallback,
            processIDs: processIDs ?? Set(fallback.binding.agentPID.map { [$0] } ?? []),
            registrationOrdinal: candidateRegistrationOrdinal
        )
    }

    public func removeCandidate(_ id: AgentSourceCandidateID) {
        candidates.removeValue(forKey: id)
    }

    public func promoteCandidate(_ candidateID: AgentSourceCandidateID, to summary: AgentThreadSummary) {
        guard let candidate = candidates.removeValue(forKey: candidateID) else { return }
        register(summary, binding: candidate.fallback.binding)
        // A candidate is a pane already seen running an agent. Promotion must
        // carry that liveness across, or the row would vanish at the moment it
        // gained a durable identity.
        threads[summary.id]?.isLiveRoute = true
    }

    // MARK: - Title waterfall

    /// Widest sensible clip for a fallback title before a platform reports the
    /// width it actually has. Deliberately conservative: a title cut short
    /// reads as a title, a title that overflows the row reads as a bug.
    public static let defaultTitleCharacterBudget = 64
    static let titleCharacterBudgetRange = 16...200

    /// How much of the opening prompt a fallback title may show. Platforms
    /// derive it from the row width they are about to render into.
    ///
    /// Only threads still resting on the prompt tier are re-clipped: a native
    /// or generated title is a whole phrase, not a truncation, and shortening
    /// it to fit would corrupt it rather than adapt it.
    public func setTitleCharacterBudget(_ characters: Int) {
        let clamped = min(max(characters, Self.titleCharacterBudgetRange.lowerBound), Self.titleCharacterBudgetRange.upperBound)
        guard clamped != titleCharacterBudget else { return }
        titleCharacterBudget = clamped
        for id in threads.keys {
            guard var state = threads[id], state.summary.titleProvenance == .prompt,
                  let seed = state.summary.titleSeed else { continue }
            state.summary.title = Self.clipTitleSeed(seed, budget: clamped)
            threads[id] = state
        }
    }

    /// Records the title an on-device model wrote for `seed`.
    ///
    /// `seed` is passed back rather than trusted implicitly: generation is
    /// asynchronous and the thread may have moved on to a different opening
    /// prompt, or gained the agent-written title, while the model was running.
    /// A stale answer is dropped instead of overwriting a better one.
    @discardableResult
    public func applyGeneratedTitle(_ title: String, for threadID: AgentThreadID, seed: String) -> Bool {
        guard var state = threads[threadID], state.summary.titleSeed == seed else { return false }
        let applied = applyTitle(title, provenance: .generated, to: &state)
        threads[threadID] = state
        return applied
    }

    /// Threads whose title would improve if a platform summarised their
    /// opening prompt: the seed is known and nothing stronger has claimed the
    /// title yet.
    public func threadsAwaitingGeneratedTitle() -> [AgentTitleGenerationRequest] {
        var pending: [AgentTitleGenerationRequest] = []
        for state in threads.values where state.summary.titleProvenance < .generated {
            guard let seed = state.summary.titleSeed else { continue }
            pending.append(AgentTitleGenerationRequest(threadID: state.summary.id, seed: seed))
        }
        pending.sort { $0.threadID.providerSessionID < $1.threadID.providerSessionID }
        return pending
    }

    @discardableResult
    private func applyTitle(_ title: String, provenance: AgentTitleProvenance, to state: inout ThreadState) -> Bool {
        let trimmed = AgentDisplayText.sanitize(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, provenance >= state.summary.titleProvenance else { return false }
        state.summary.title = String(trimmed.prefix(512))
        state.summary.titleProvenance = provenance
        return true
    }

    private func applyPinnedTitle(_ title: String, to state: inout ThreadState) {
        let trimmed = AgentDisplayText.sanitize(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.summary.title = String(trimmed.prefix(512))
        state.summary.titleProvenance = .pinned
    }

    /// `rebuilding` appends into freshly cleared rows whose record IDs are
    /// unique, skipping the per-record scans of every retained message.
    private func applyNormalized(_ normalized: AgentNormalizedRecord, from record: AgentProjectionRecord, to state: inout ThreadState,
                                 rebuilding: Bool = false) {
        func acceptsMetadata(_ key: String) -> Bool {
            // Legacy Tier C pages arrive newest-first too. Context updates
            // and resets must never rewind when older history is loaded.
            guard state.ingestionEpoch != nil || (key == "context" && state.summary.id.providerID == .claude) else { return true }
            guard state.metadataOrders[key].map({ record.sequence >= $0 }) ?? true else { return false }
            state.metadataOrders[key] = record.sequence
            return true
        }
        if let title = normalized.title, acceptsMetadata("title") {
            applyTitle(title, provenance: normalized.titleProvenance, to: &state)
        }
        if let cost = normalized.cost, acceptsMetadata("cost") { state.summary.cost = cost }
        if let count = normalized.queuedMessageCount, acceptsMetadata("queue") { state.summary.queuedMessageCount = count }
        // An empty value is an explicit compaction reset, subject to the same
        // ordering gate as measured usage. nil leaves existing context alone.
        if let context = normalized.context, acceptsMetadata("context") {
            state.summary.context = context
        }
        if let model = normalized.model, acceptsMetadata("model") { state.summary.model = AgentDisplayText.sanitize(model) }
        if let project = normalized.projectBasename, acceptsMetadata("project") { state.summary.projectBasename = AgentDisplayText.sanitize(project) }
        if let branch = normalized.branch, acceptsMetadata("branch") { state.summary.branch = AgentDisplayText.sanitize(branch) }
        if let permissionMode = normalized.permissionMode, acceptsMetadata("permission") { state.summary.permissionMode = permissionMode }
        if let message = normalized.message {
            if !rebuilding { state.messages.removeAll { $0.recordID == message.recordID } }
            state.messages.append(message)
            if let value = message.blocks.compactMap({ if case .text(let text) = $0 { return text }; return nil }).first,
               acceptsMetadata("preview") { state.summary.preview = AgentDisplayText.sanitize(value) }
        }
        if let activity = normalized.activity {
            if !rebuilding { state.activity.removeAll { $0.id == activity.id } }
            state.activity.append(activity)
            state.projectionActivityByRecordID[record.recordID] = activity.id
        }
        if let edit = normalized.edit { state.changes.edits.append(edit) }
        state.summary.lastActivitySequence = max(state.summary.lastActivitySequence, record.sequence)
    }

    /// A canonical record's revision fixes its content (admission rejects a
    /// same-revision body change), so its normalization and sizes are reusable.
    private func normalizedRecord(_ record: AgentProjectionRecord, providerID: AgentProviderID,
                                  state: inout ThreadState) -> NormalizedRecord {
        if let cached = state.normalizedRecords[record.recordID], cached.revision == record.revision,
           cached.sequence == record.sequence { return cached }
        let normalized = normalizer.normalize(providerID: providerID, record: record)
        let entry = NormalizedRecord(revision: record.revision, sequence: record.sequence, normalized: normalized,
            recordBytes: (try? byteEncoder.encode(record).count) ?? 0,
            messageBytes: normalized.message.flatMap { try? byteEncoder.encode($0).count } ?? 0,
            activityBytes: normalized.activity.flatMap { try? byteEncoder.encode($0).count } ?? 0,
            editBytes: normalized.edit.flatMap { try? byteEncoder.encode($0).count } ?? 0)
        state.normalizedRecords[record.recordID] = entry
        return entry
    }

    private func applyPageSummary(_ summary: AgentJSONValue?, providerID: AgentProviderID, to state: inout ThreadState) {
        guard let summary, let source = summary.objectValue else { return }

        if let openingPrompt = source["openingPrompt"]?.stringValue {
            let seed = Self.normalizeTitleSeed(openingPrompt)
            state.openingPrompt = seed.isEmpty ? nil : seed
        }

        var metadata: [String: AgentJSONValue] = ["type": .string("metadata")]
        for key in ["model", "project", "branch", "permissionMode", "used_tokens", "max_tokens", "context_percent"] {
            if let value = source[key] { metadata[key] = value }
        }
        if let title = source["nativeTitle"] ?? source["title"] {
            metadata["title"] = title
        }
        guard let synthetic = AgentProjectionRecord(sequence: 0, recordID: "page-summary", record: .object(metadata)) else { return }
        applyNormalized(normalizer.normalize(providerID: providerID, record: synthetic), from: synthetic, to: &state)
    }

    private func refreshTitleSeed(_ state: inout ThreadState) {
        if let openingPrompt = state.openingPrompt {
            state.summary.titleSeed = openingPrompt
            applyTitle(Self.clipTitleSeed(openingPrompt, budget: titleCharacterBudget), provenance: .prompt, to: &state)
            return
        }
        // The first *loaded* user message is only the opening prompt after
        // pagination has reached the terminal older boundary. A newest-first
        // window or cursor page must not turn a late prompt into a title seed.
        if let window = state.ingestionWindow {
            guard !window.hasOlder else { return }
        } else {
            guard !state.hasMore, state.cursor == nil else { return }
        }
        guard let opening = state.messages.first(where: { $0.role == .user }) else { return }
        guard case .text(let value)? = opening.blocks.first(where: { if case .text = $0 { return true } else { return false } }) else { return }
        let seed = Self.normalizeTitleSeed(value)
        guard !seed.isEmpty else { return }
        state.summary.titleSeed = seed
        // The clipped prompt is the floor of the waterfall, so it is written
        // only while nothing better exists. `applyTitle` enforces that.
        applyTitle(Self.clipTitleSeed(seed, budget: titleCharacterBudget), provenance: .prompt, to: &state)
    }

    /// Collapses the prompt to a single line. A pasted stack trace or a
    /// multi-paragraph brief must still read as one row of text.
    static func normalizeTitleSeed(_ value: String) -> String {
        let collapsed = AgentDisplayText.sanitize(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(1_024))
    }

    /// Clips on a word boundary when one is close enough to the budget, so the
    /// fallback ends on a word rather than mid-token.
    static func clipTitleSeed(_ seed: String, budget: Int) -> String {
        let seed = AgentDisplayText.sanitize(seed)
        guard seed.count > budget else { return seed }
        let head = seed.prefix(budget)
        let cut: Substring
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= budget / 2 {
            cut = head[head.startIndex..<space]
        } else {
            cut = head
        }
        return cut.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    public func replaceBinding(_ binding: AgentTerminalBinding?, for threadID: AgentThreadID) {
        guard var state = threads[threadID] else { return }
        if state.binding != binding {
            state.actionLease = nil
            Self.clearLivePrompt(&state)
            state.deliveryGeneration &+= 1
            Self.unsettleOutgoing(&state)
            state.routeIdentity = nil
            state.isLiveRoute = false
        }
        state.binding = binding
        threads[threadID] = state
    }

    /// Retires only routes whose process or pane a complete observation proves
    /// absent. History remains readable; absence names no successor.
    public func reconcileOccupancy(_ observation: AgentOccupancyObservation) -> [AgentThreadID] {
        reconcileOccupancyRetiringBindings(observation).map { $0.0 }
    }

    public func reconcileOccupancyRetiringBindings(_ observation: AgentOccupancyObservation) -> [(AgentThreadID, AgentTerminalBinding)] {
        let live = threads.compactMap { id, state -> (AgentThreadID, AgentTerminalBinding)? in
            guard state.isLiveRoute, let binding = state.binding else { return nil }
            return (id, binding)
        }
        let retiredIDs = Set(AgentOccupancyPolicy.retirements(live: live, observation: observation))
        let retired = live.filter { retiredIDs.contains($0.0) }
        for (id, _) in retired { replaceBinding(nil, for: id) }
        return retired
    }

    /// A proved empty root can only revoke conversations on that process.
    /// Roots and their live children lose authority while retaining history.
    public func clearConversations(providerID: AgentProviderID, binding: AgentTerminalBinding) -> [AgentThreadID] {
        clearConversations(providerID: providerID, binding: binding, timestampNanoseconds: nil)
    }

    public func clearConversations(providerID: AgentProviderID, binding: AgentTerminalBinding,
                                   timestampNanoseconds: UInt64?) -> [AgentThreadID] {
        clearConversationsRetiringBindings(providerID: providerID, binding: binding,
                                           timestampNanoseconds: timestampNanoseconds).map { $0.0 }
    }

    public func clearConversationsRetiringBindings(providerID: AgentProviderID, binding: AgentTerminalBinding,
                                                   timestampNanoseconds: UInt64? = nil) -> [(AgentThreadID, AgentTerminalBinding)] {
        guard binding.agentPID != nil else { return [] }
        if let timestampNanoseconds { noteClearFence(binding: binding, timestamp: timestampNanoseconds) }
        // A root seen on the process after the clear outlived it (A→B→A with
        // B's clear delayed): the clear is stale and retires nothing.
        let live = threads.filter { id, state in
            id.providerID == providerID && state.isLiveRoute
                && state.binding.map { Self.sameProcess($0, binding) } == true
                && (timestampNanoseconds.map { timestamp in
                    (state.isChildConversation ? state.tenureStartNanos
                        : [state.tenureStartNanos, state.latestRootActivityNanos].compactMap { $0 }.max()).map { $0 < timestamp } ?? false
                } ?? true)
        }
        guard live.contains(where: { !$0.value.isChildConversation }) else { return [] }
        let retired = live.compactMap { id, state in state.binding.map { (id, $0) } }
        for (id, held) in retired {
            if let timestampNanoseconds { noteReplacementFence(id, binding: held, timestamp: timestampNanoseconds) }
            replaceBinding(nil, for: id)
        }
        return retired
    }

    /// Revokes projection-derived content and authority when a provider's
    /// live conformance gate stops passing. Lifecycle state may remain, but no
    /// cached transcript or action lease survives the downgrade.
    public func retireProjection(
        for threadID: AgentThreadID,
        reason: AgentAvailabilityReason = .integrationOutdated
    ) {
        guard var state = threads[threadID] else { return }
        clearProjectionContent(&state, for: threadID)
        Self.clearLivePrompt(&state)
        state.sourceIdentity = nil
        state.actionLease = nil
        Self.unsettleOutgoing(&state)
        state.summary.availability = .init(
            content: false,
            status: false,
            actions: false,
            spawn: false,
            fork: false,
            search: false,
            reason: reason
        )
        state.deliveryGeneration &+= 1
        threads[threadID] = state
        searchSnapshot = .init(results: [])
    }

    public func apply(page: AgentProjectionPage, to threadID: AgentThreadID) -> AgentProjectionApplyResult {
        if let range = page.ingestion { return applyIngestion(page, range: range, to: threadID) }
        guard isEnabled, var state = threads[threadID] else { return .resyncRequired }
        // Legacy receipts are a separate proof path; they must not replace a
        // native ingestion cache or reinterpret its byte-order keys as lines.
        guard state.ingestionEpoch == nil else { return .resyncRequired }
        var didResetSource = false
        let requestedCursor = state.cursor
        if let sourceIdentity = state.sourceIdentity, sourceIdentity != page.sourceIdentity {
            if AgentProjectionContinuation.preservesHistory(previousIdentity: sourceIdentity, page: page),
               let rebased = AgentProjectionContinuation.rebase(state.cursor, using: page.cursor) {
                state.cursor = rebased
            } else {
                state.sourceIdentity = page.sourceIdentity
                clearProjectionContent(&state, for: threadID)
                didResetSource = true
            }
        }
        state.sourceIdentity = page.sourceIdentity
        // A long burst can append more than a whole bounded page. Re-anchor
        // at that newest page instead of rejecting the same gap forever;
        // its backward cursor makes every intervening record loadable again.
        if page.from == nil, let last = state.records.last?.sequence,
           let first = page.records.map(\.sequence).min(), first > last, first - last > 1,
           let oldIdentity = threads[threadID]?.sourceIdentity,
           AgentProjectionContinuation.preservesHistory(previousIdentity: oldIdentity, page: page) {
            clearProjectionContent(&state, for: threadID)
            didResetSource = true
        }
        let byID = Dictionary(uniqueKeysWithValues: state.records.map { ($0.recordID, $0.sequence) })
        if page.records.contains(where: { incoming in
            byID[incoming.recordID].map { existingSequence in existingSequence != incoming.sequence } ?? false
        }) {
            return .resyncRequired
        }
        let existing = Set(state.records.map(\.recordID))
        let incoming = page.records.filter { !existing.contains($0.recordID) }.sorted { $0.sequence < $1.sequence }
        guard Set(incoming.map(\.sequence)).count == incoming.count else { return .resyncRequired }
        let existingSequences = Set(state.records.map(\.sequence))
        guard existingSequences.isDisjoint(with: Set(incoming.map(\.sequence))) else { return .resyncRequired }
        // Cursors page backward from the newest page.  Permit either direction
        // (and overlapping idempotent pages), but require one continuous
        // sequence once an existing range is extended.
        let combinedSequences = (state.records + incoming).map(\.sequence).sorted()
        if combinedSequences.count > 1,
           zip(combinedSequences, combinedSequences.dropFirst()).contains(where: { previous, next in
               next != previous + 1
           }) {
            return .resyncRequired
        }
        // A latest-page refresh must not rewind the reader's oldest loaded
        // continuation. Explicit older requests can also terminate with an
        // empty page, so their `from` cursor remains significant.
        let advancesPagination = state.records.isEmpty || (page.from != nil && page.from == requestedCursor) ||
            page.records.contains { $0.sequence < (state.records.first?.sequence ?? $0.sequence) }
        if !incoming.isEmpty {
            state.records.append(contentsOf: incoming)
            state.records.sort { $0.sequence < $1.sequence }
            for record in incoming {
                applyNormalized(
                    normalizedRecord(record, providerID: threadID.providerID, state: &state).normalized,
                    from: record,
                    to: &state
                )
            }
        }
        applyPageSummary(page.summary, providerID: threadID.providerID, to: &state)
        let sequenceByID = Dictionary(uniqueKeysWithValues: state.records.map { ($0.recordID, $0.sequence) })
        state.messages.sort { (sequenceByID[$0.recordID] ?? 0) < (sequenceByID[$1.recordID] ?? 0) }
        state.activity.sort { $0.sequence < $1.sequence }
        state.changes.authoritativeTotals = state.summary.cost
        state.turns = Self.makeTurns(records: state.records, messages: state.messages)
        if advancesPagination {
            state.cursor = page.cursor
            state.hasMore = page.hasMore
        }
        refreshTitleSeed(&state)
        reconcileOutgoing(&state, sequenceByID: sequenceByID)
        state.estimatedContentBytes = Self.estimatedBytes(state)
        touch(&state)
        threads[threadID] = state
        enforceCacheLimits(excluding: threadID)
        if didResetSource { return .sourceReset }
        return incoming.isEmpty ? .duplicate : .applied
    }

    public func apply(hook: AgentIngestionHook, to threadID: AgentThreadID) -> Bool {
        guard isEnabled, threadID.providerID == .claude, threadID.providerSessionID == hook.sessionID,
              var state = threads[threadID], state.ingestionEpoch == hook.epoch else { return false }
        let previousBytes = state.hookOverlay.estimatedBytes
        state.hookOverlay.accept(hook); state.hookOverlay.reconcile(state.messages, allowCompletedMatch: true)
        state.estimatedContentBytes += state.hookOverlay.estimatedBytes - previousBytes
        threads[threadID] = state
        enforceCacheLimits(excluding: threadID)
        return true
    }

    public func apply(summary: AgentIngestionSummary, to threadID: AgentThreadID) -> Bool {
        guard isEnabled, var state = threads[threadID] else { return false }
        // A demotion response cannot overwrite selected canonical counters or
        // preview. Provider titles can live outside the transcript (Codex's
        // state database), so accept only that metadata while selected too.
        let selected = selectedThreadID == threadID
        let previousSummaryBytes = Self.summaryBytes(state.summary)
        for (index, body) in summary.records.enumerated() {
            guard let record = AgentProjectionRecord(sequence: UInt64(index), recordID: "summary-\(index)", record: body) else { return false }
            let normalized = normalizer.normalize(providerID: threadID.providerID, record: record)
            if let title = normalized.title, !selected || normalized.titleProvenance == .native {
                applyTitle(title, provenance: normalized.titleProvenance, to: &state)
            }
            if selected { continue }
            if let model = normalized.model { state.summary.model = AgentDisplayText.sanitize(model) }
            if let project = normalized.projectBasename { state.summary.projectBasename = AgentDisplayText.sanitize(project) }
            if let branch = normalized.branch { state.summary.branch = AgentDisplayText.sanitize(branch) }
            if let cost = normalized.cost { state.summary.cost = cost }
            if let context = normalized.context { state.summary.context = context }
            if let message = normalized.message,
               let text = message.blocks.compactMap({ if case .text(let text) = $0 { return text }; return nil }).first {
                state.summary.preview = String(AgentDisplayText.sanitize(text).prefix(512))
            }
        }
        if !selected, state.summary.lastActivity.map({ $0 < summary.modified }) ?? true { state.summary.lastActivity = summary.modified }
        // No records/messages, pagination, status, attention, sequence,
        // permission prompt, outgoing receipt or binding can change here.
        state.estimatedContentBytes += Self.summaryBytes(state.summary) - previousSummaryBytes
        threads[threadID] = state
        enforceCacheLimits(excluding: selectedThreadID)
        return true
    }

    private func applyIngestion(_ page: AgentProjectionPage, range: AgentIngestionRange,
                                to threadID: AgentThreadID) -> AgentProjectionApplyResult {
        if let transaction = range.window { return applyWindowIngestion(page, range: range, transaction: transaction, to: threadID) }
        guard isEnabled, var state = threads[threadID],
              Set(page.records.map(\.recordID)).count == page.records.count,
              Set(page.records.map(\.sequence)).count == page.records.count else { return .resyncRequired }
        let resetting = range.operation == .bootstrap
        let previous = Dictionary(uniqueKeysWithValues: state.records.map { ($0.recordID, $0) })
        if state.ingestionEpoch == range.epoch, state.ingestionTransactions.contains(range.requestID) {
            return page.records.allSatisfy { previous[$0.recordID] == $0 } ? .duplicate : .resyncRequired
        }
        if resetting {
            guard page.from == nil, range.liveCursor != nil else { return .resyncRequired }
            clearProjectionContent(&state, for: threadID,
                preservingTitle: (state.sourceIdentity == nil || state.sourceIdentity == page.sourceIdentity) && state.summary.titleProvenance >= .generated,
                preservingOpeningPrompt: state.sourceIdentity == page.sourceIdentity)
            state.ingestionEpoch = range.epoch
        } else {
            guard state.ingestionEpoch == range.epoch, state.sourceIdentity == page.sourceIdentity,
                  page.from != nil,
                  page.from == (range.operation == .history ? state.cursor : state.liveCursor) else { return .resyncRequired }
        }
        state.sourceIdentity = page.sourceIdentity
        var records = Dictionary(uniqueKeysWithValues: state.records.map { ($0.recordID, $0) })
        let oldest = state.records.first?.sequence
        let newest = state.records.last?.sequence
        var incoming: [AgentProjectionRecord] = []
        for record in page.records {
            if let old = records[record.recordID] {
                guard old.sequence == record.sequence else { return .resyncRequired }
                if record.revision < old.revision { continue }
                if record.revision == old.revision {
                    guard record == old else { return .resyncRequired }
                    continue
                }
            } else if !resetting {
                if range.operation == .history, let oldest, record.sequence >= oldest { return .resyncRequired }
                if range.operation == .updates, let newest, record.sequence <= newest { return .resyncRequired }
            }
            records[record.recordID] = record; incoming.append(record)
        }
        guard Set(records.values.map(\.sequence)).count == records.count else { return .resyncRequired }
        state.records = records.values.sorted { $0.sequence < $1.sequence }
        for record in incoming.sorted(by: { $0.sequence < $1.sequence }) {
            state.messages.removeAll { $0.recordID == record.recordID }
            if let activity = state.projectionActivityByRecordID.removeValue(forKey: record.recordID) {
                state.activity.removeAll { $0.id == activity }
            }
            state.changes.edits.removeAll { $0.id == record.recordID }
            applyNormalized(normalizedRecord(record, providerID: threadID.providerID, state: &state).normalized, from: record, to: &state)
        }
        if range.operation != .updates { state.cursor = page.cursor; state.hasMore = page.hasMore }
        if range.operation != .history { state.liveCursor = range.liveCursor }
        state.ingestionTransactions.append(range.requestID)
        if state.ingestionTransactions.count > 32 { state.ingestionTransactions.removeFirst(state.ingestionTransactions.count - 32) }
        let order = Dictionary(uniqueKeysWithValues: state.records.map { ($0.recordID, $0.sequence) })
        state.messages.sort { (order[$0.recordID] ?? 0) < (order[$1.recordID] ?? 0) }
        if range.operation == .updates {
            state.hookOverlay.reconcile(state.messages, newRecordIDs: Set(incoming.map(\.recordID)), allowCompletedMatch: true)
        }
        state.activity.sort { $0.sequence < $1.sequence }
        reconcileOutgoing(&state, sequenceByID: order)
        refreshTitleSeed(&state)
        state.changes.authoritativeTotals = state.summary.cost
        state.turns = Self.makeTurns(records: state.records, messages: state.messages)
        state.estimatedContentBytes = Self.estimatedBytes(state)
        touch(&state); threads[threadID] = state; enforceCacheLimits(excluding: threadID)
        return resetting ? .sourceReset : incoming.isEmpty ? .duplicate : .applied
    }

    private func applyWindowIngestion(_ page: AgentProjectionPage, range: AgentIngestionRange,
                                      transaction: AgentIngestionWindowTransaction, to threadID: AgentThreadID) -> AgentProjectionApplyResult {
        guard isEnabled, var state = threads[threadID] else { return .resyncRequired }
        if state.ingestionEpoch == range.epoch, state.ingestionTransactions.contains(range.requestID) {
            return state.ingestionWindow?.version == transaction.version && state.ingestionLastWindowPage == page ? .duplicate : .resyncRequired
        }
        let reset = transaction.lane == .bootstrap
        if !reset {
            guard state.ingestionEpoch == range.epoch, state.sourceIdentity == page.sourceIdentity,
                  let version = state.ingestionWindow?.version, version < UInt64.max, transaction.version == version + 1 else { return .resyncRequired }
            if transaction.lane == .head || transaction.lane == .revisions {
                guard page.from == state.liveCursor else { return .resyncRequired }
            }
        } else {
            guard page.from == nil, transaction.version == 1 else { return .resyncRequired }
            clearProjectionContent(&state, for: threadID,
                // Discovery can resolve the native title before the first
                // canonical page. A nil prior source is not a replacement;
                // do not flash the newest user prompt during first open.
                preservingTitle: (state.sourceIdentity == nil || state.sourceIdentity == page.sourceIdentity) && state.summary.titleProvenance >= .generated,
                preservingOpeningPrompt: state.sourceIdentity == page.sourceIdentity)
            state.ingestionEpoch = range.epoch; state.viewportAnchorRecordID = nil
        }
        state.sourceIdentity = page.sourceIdentity
        var window = state.ingestionWindow ?? AgentIngestionWindow(capacity: ingestionWindowCapacity(for: threadID))
        state.ingestionLastWindowPage = page
        state.ingestionLastWindowPageBytes = (try? byteEncoder.encode(page).count) ?? 0
        let original = state
        do {
            switch transaction.lane {
            case .bootstrap: try window.bootstrap(transaction.segment(source: page.sourceIdentity, records: page.records))
            case .before, .after:
                guard let from = page.from else { return .resyncRequired }
                try window.navigate(transaction.segment(source: page.sourceIdentity, records: page.records),
                    direction: transaction.lane == .before ? .before : .after, from: from,
                    expectedVersion: window.version, pinnedRecordID: state.viewportAnchorRecordID)
            case .head:
                try window.replaceHead(transaction.segment(source: page.sourceIdentity, records: page.records),
                    expectedVersion: window.version, pinnedRecordID: state.viewportAnchorRecordID)
            case .revisions: try window.revise(page.records, expectedVersion: window.version,
                partitions: transaction.partitions, pinnedRecordID: state.viewportAnchorRecordID)
            }
            guard window.version == transaction.version else { return .resyncRequired }
            while true {
                state = original
                rebuildWindow(window, state: &state, threadID: threadID)
                if let source = page.summary?.objectValue {
                    // page.end metadata has no record sequence. Apply it after
                    // accepted window records, independent of record ordering.
                    if let title = source["nativeTitle"]?.stringValue {
                        applyTitle(title, provenance: .native, to: &state)
                    }
                    if let opening = source["openingPrompt"]?.stringValue {
                        let seed = Self.normalizeTitleSeed(opening)
                        if !seed.isEmpty { state.openingPrompt = seed }
                    }
                    refreshTitleSeed(&state)
                    state.estimatedContentBytes = Self.estimatedBytes(state)
                }
                // Leave bounded room for outgoing/receipt/hook state and for
                // ABI operation metadata. ABI truncation must not secretly
                // discard rows from an acknowledged viewport segment.
                if state.estimatedContentBytes <= budget.perThreadBytes - 524_288 {
                    let presentation = presentationLimitBytes.map { (limit: $0, bytes: Self.windowPresentationBytes(state)) }
                    state.ingestionPresentationBytes = presentation?.bytes
                    if presentation.map({ $0.bytes <= $0.limit }) ?? true { break }
                }
                let evicted = transaction.lane == .revisions ? window.evictRevisionEdge(pinnedRecordID: state.viewportAnchorRecordID) :
                    (window.evictOffscreen(opposite: transaction.lane == .before ? .before : .after,
                        pinnedRecordID: state.viewportAnchorRecordID, protectedSegmentID: transaction.segmentID)
                        // History kept beside a rolled head goes before the update.
                        || (transaction.lane == .head && window.collapseToLiveHead(pinnedRecordID: state.viewportAnchorRecordID)))
                guard evicted else {
                    if transaction.lane == .before { threads[threadID]?.ingestionOlderRefusedBytes = original.estimatedContentBytes }
                    return .capacityExceeded
                }
            }
        } catch AgentIngestionError.capacityExceeded {
            if transaction.lane == .before { threads[threadID]?.ingestionOlderRefusedBytes = original.estimatedContentBytes }
            return .capacityExceeded
        }
        catch { return .resyncRequired }
        if transaction.lane == .before {
            state.ingestionOlderPageCost = max(0, state.estimatedContentBytes - original.estimatedContentBytes,
                (state.ingestionPresentationBytes ?? 0) - (original.ingestionPresentationBytes ?? 0))
        }
        if range.operation != .history { state.liveCursor = range.liveCursor }
        state.ingestionWindowTransition = transaction.lane
        state.ingestionLastWindowPage = page
        state.cursor = window.before; state.hasMore = window.hasOlder
        state.ingestionTransactions.append(range.requestID)
        if state.ingestionTransactions.count > 32 { state.ingestionTransactions.removeFirst(state.ingestionTransactions.count - 32) }
        if transaction.lane == .head || transaction.lane == .revisions {
            state.hookOverlay.reconcile(state.ingestionHeadMessages, newRecordIDs: Set(page.records.map(\.recordID)), allowCompletedMatch: true)
        }
        // A bootstrap is the live head too: a new conversation's first
        // prompt may reach this thread only in its first window.
        if transaction.lane == .bootstrap || transaction.lane == .head || transaction.lane == .revisions {
            let headOrders = Dictionary(uniqueKeysWithValues: (window.head?.records ?? []).map { ($0.recordID, $0.sequence) })
            reconcileOutgoing(&state, sequenceByID: headOrders)
        }
        touch(&state); threads[threadID] = state; enforceCacheLimits(excluding: threadID)
        return reset ? .sourceReset : .applied
    }

    private func rebuildWindow(_ window: AgentIngestionWindow, state: inout ThreadState, threadID: AgentThreadID) {
        let oldProjectionActivity = Set(state.projectionActivityByRecordID.values)
        state.messages = []; state.activity.removeAll { oldProjectionActivity.contains($0.id) }
        state.projectionActivityByRecordID = [:]; state.changes.edits = []
        let retainedRecords: [AgentProjectionRecord] = window.records + window.bridge + (window.head?.records ?? [])
        let combined = Dictionary(retainedRecords.map { ($0.recordID, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.revision >= rhs.revision ? lhs : rhs }).values.sorted { $0.sequence < $1.sequence }
        let lifecycleActivityIDs = Set(state.activity.map(\.id))
        for record in combined {
            applyNormalized(normalizedRecord(record, providerID: threadID.providerID, state: &state).normalized,
                            from: record, to: &state, rebuilding: true)
        }
        // Rebuilt rows are unique per record; only a lifecycle event that
        // shares a projection activity ID needs the replacement semantics.
        if !lifecycleActivityIDs.isEmpty, Set(state.activity.map(\.id)).count != state.activity.count {
            var seen = Set<String>()
            state.activity = Array(state.activity.reversed().filter { seen.insert($0.id).inserted }.reversed())
        }
        // Receipt bodies and their byte/sequence proof must originate from
        // the same live records. A newer history revision may be displayed,
        // but must not borrow the independently retained head's provenance.
        state.ingestionHeadMessages = (window.head?.records ?? []).compactMap {
            normalizedRecord($0, providerID: threadID.providerID, state: &state).normalized.message
        }
        state.records = window.presentedRecords
        state.ingestionWindow = window
        let retained = Set(combined.map(\.recordID))
        state.normalizedRecords = state.normalizedRecords.filter { retained.contains($0.key) }
        pruneDerivedProjectionContent(&state)
        refreshTitleSeed(&state)
        state.changes.authoritativeTotals = state.summary.cost
        state.estimatedContentBytes = Self.estimatedBytes(state)
    }

    public func setIngestionViewportAnchor(_ recordID: String?, for threadID: AgentThreadID) {
        guard var state = threads[threadID], let window = state.ingestionWindow else { return }
        let retained = recordID.map { id in window.viewport.contains { $0.records.contains(where: { $0.recordID == id }) } } ?? true
        // A row the rolled head continues the viewport with is not retained
        // history: pinning none lets the next roll keep it in the head page.
        // Keeping an older anchor instead stranded the reader's rows.
        guard retained || recordID.map({ id in window.presentedRecords.contains { $0.recordID == id } }) == true else { return }
        let anchor = retained ? recordID : nil
        guard state.viewportAnchorRecordID != anchor else { return }
        state.viewportAnchorRecordID = anchor; threads[threadID] = state
    }

    public func releaseIngestionWindow(for threadID: AgentThreadID) {
        guard var state = threads[threadID], state.outgoing.isEmpty else { return }
        clearCachedProjectionContent(&state)
        state.cursor = nil; state.hasMore = false
        threads[threadID] = state
    }

    public func applyLifecycle(_ envelope: AgentLifecycleEnvelope, proof: AgentLifecycleBindingProof, expectedSourceIdentity: String) -> AgentLifecycleAcceptance {
        // After `/clear`, `/new` or `/resume` both platforms register the new
        // conversation on the pane's binding before forwarding its frame, so
        // the old conversation holds that binding too. Validate against the
        // frame's own conversation when it holds the binding, otherwise the
        // conversation this pane ran. An unordered scan picked either, and
        // picking the new one left the old conversation listed for good.
        let holders = threads.filter { $0.value.binding == proof.binding }
        let framedID = envelope.providerSessionID.flatMap {
            AgentThreadID(hostID: proof.hostID, providerID: envelope.providerID, providerSessionID: $0)
        }
        guard let existingID = framedID.flatMap({ holders[$0] == nil ? nil : $0 })
                ?? holders.first(where: { $0.value.isLiveRoute })?.key ?? holders.keys.first,
              let existing = holders[existingID] else { return .rejected(.staleBinding) }
        guard proof.hostID == existingID.hostID else { return .rejected(.sourceMismatch) }
        // A thread already claimed by one route may not be relabeled by
        // another, so prefer the route identity this thread was claimed with.
        // It must never fall back to `existing.sourceIdentity`: that holds
        // transcript provenance written by `apply(page:)`, and substituting it
        // rejected every lifecycle frame arriving after the thread's first
        // transcript page landed.
        let registeredRouteIdentity = existing.routeIdentity ?? expectedSourceIdentity
        let validation = AgentLifecycleValidator(registry: registry).validate(envelope, proof: proof, expectedBinding: existing.binding!, expectedSourceIdentity: registeredRouteIdentity)
        guard case .accepted = validation else { return validation }
        guard let providerSessionID = envelope.providerSessionID,
              let threadID = AgentThreadID(hostID: proof.hostID, providerID: envelope.providerID, providerSessionID: providerSessionID)
        else { return validation }
        if let held = threads[threadID], held.isLiveRoute, let binding = held.binding,
           Self.competesForLiveRoute(held: binding, incoming: proof.binding) {
            return .rejected(.staleBinding)
        }
        let currentRoot = threads.first { id, state in
            id.hostID == proof.hostID && state.isLiveRoute && !state.isChildConversation
                && state.binding.map { Self.sameProcess($0, proof.binding) } == true
        }
        let isChild = Self.isChildFrame(envelope)
        let isEnd = envelope.event == .sessionEnd || envelope.event == .wrapperExit
        if isChild, let rootAgentID = envelope.rootAgentID, let currentRoot,
           namesAnotherRoot(rootAgentID, than: currentRoot.key, state: currentRoot.value) {
            discardRegistration(for: threadID, successor: currentRoot.key)
            return .rejected(.staleBinding)
        }
        if let timestamp = envelope.sourceTimestampNanoseconds {
            // A newer frame of a conversation replaced on this process means
            // it runs there again: retained pane state may carry only the
            // newest frame, never the `/resume` that reopened it.
            if let fence = replacementFences[threadID], Self.sameProcess(fence.binding, proof.binding),
               timestamp <= fence.timestamp {
                discardRegistration(for: threadID, successor: currentRoot?.key)
                return .rejected(.staleBinding)
            }
            if clearFences.contains(where: { Self.sameProcess($0.binding, proof.binding) && timestamp < $0.timestamp }) {
                discardRegistration(for: threadID, successor: currentRoot?.key)
                return .rejected(.staleBinding)
            }
            if !isChild, currentRoot?.key != threadID,
               let start = currentRoot?.value.tenureStartNanos, timestamp < start {
                discardRegistration(for: threadID, successor: currentRoot?.key)
                return .rejected(.staleBinding)
            }
            if isChild, let start = currentRoot?.value.tenureStartNanos, timestamp < start {
                discardRegistration(for: threadID, successor: currentRoot?.key)
                return .rejected(.staleBinding)
            }
            if !isEnd, let held = threads[threadID], held.conversationEnded,
               let end = held.conversationEndNanos, timestamp <= end {
                return .rejected(.staleBinding)
            }
            if isEnd, let held = threads[threadID], held.isLiveRoute,
               let start = [held.tenureStartNanos, held.rootBoundaryNanos].compactMap({ $0 }).max(), timestamp < start {
                return .rejected(.staleBinding)
            }
        }
        // Claude runs a `/clear`'s SessionEnd and the next SessionStart hooks
        // back to back, and their frames can land in either order. An end
        // of a conversation that no longer holds its process's pane cannot
        // take the pane back from the one that does. The platform registered
        // it on the pane only for this frame, so it leaves again.
        if [.sessionEnd, .wrapperExit].contains(envelope.event), proof.binding.agentPID != nil,
           threads[threadID]?.isLiveRoute != true, let current = currentRoot?.key, current != threadID {
            if holders[threadID] != nil {
                threads.removeValue(forKey: threadID)
                noteReplaced(threadID, by: current, binding: proof.binding,
                             timestamp: currentRoot?.value.tenureStartNanos)
            }
            return .rejected(.staleBinding)
        }
        var state: ThreadState
        if let durable = threads[threadID] {
            state = durable
            if durable.binding != proof.binding {
                // Inventory can recreate this conversation after another root
                // wins the pane but before its delayed live frame is reduced.
                // Adopt availability from the exact validated live holder,
                // just as a new conversation does below, not from its history.
                state.summary.availability = existing.summary.availability
            }
        } else {
            // /clear and /resume change conversation identity while retaining
            // the provider process and pane. Route ownership transfers, but
            // transcript content and metadata never do.
            state = ThreadState(summary: AgentThreadSummary(
                id: threadID, providerName: existing.summary.providerName,
                hostDisplayLabel: existing.summary.hostDisplayLabel,
                availability: existing.summary.availability
            ))
        }
        let startsTenure = !state.isLiveRoute || !isChild && state.isChildConversation
            || !isChild && threads.contains { id, other in
                id != threadID && id.hostID == proof.hostID && other.isLiveRoute && !other.isChildConversation
                    && other.binding.map { Self.sameProcess($0, proof.binding) } == true
            }
        let fingerprint = Self.lifecycleFingerprint(envelope)
        let isStaleSequence = envelope.eventSequence.flatMap { sequence in
            state.lastLifecycleSequence.map { sequence <= $0 }
        } ?? false
        if isStaleSequence || state.recentLifecycleFingerprints.contains(fingerprint) {
            // A reconnect or a transient discovery miss retires the route, and
            // rediscovery replays the pane's retained hook state. That frame
            // carries no new status or attention, but it does prove this
            // exact registered route is live again. Adopt the route only;
            // neither attention nor the delivery generation moves.
            if threadID == existingID, !state.isLiveRoute || state.routeIdentity != proof.sourceIdentity {
                state.routeIdentity = proof.sourceIdentity
                state.isLiveRoute = true
                if startsTenure { state.tenureStartNanos = envelope.sourceTimestampNanoseconds }
                threads[threadID] = state
            }
            replacementFences.removeValue(forKey: threadID)
            replacementFenceOrder.removeAll { $0 == threadID }
            if threadID == existingID, !state.isChildConversation {
                removeConversations(replacedOn: proof.binding, by: threadID, rootReplaced: startsTenure,
                                    timestamp: state.tenureStartNanos)
            }
            return validation
        }
        let previousAttention = state.summary.attention
        let previousStatus = state.summary.status
        if state.lastLifecycleFingerprint == nil, let stored = durableCompletions[threadID] {
            // First frame for this thread since launch. Restore its stored read
            // state: a completion still unread when it was persisted survives
            // a later neutral hook state (Claude's idle prompt overwrites the
            // retained Stop); a newer frame below still supersedes it.
            state.acknowledgedCompletionKey = stored.acknowledged
            if let pending = stored.unread, pending != stored.acknowledged {
                state.completionKey = pending
                state.summary.attention = .unreadCompletion
            }
        }
        let childStatusIsNeutral = envelope.event == .subagentStart || envelope.event == .subagentStop
        if startsTenure {
            state.tenureStartNanos = envelope.sourceTimestampNanoseconds
            state.rootAgentID = envelope.rootAgentID
        } else if let rootAgentID = envelope.rootAgentID {
            state.rootAgentID = rootAgentID
        }
        if !isChild, envelope.event == .sessionStart, let timestamp = envelope.sourceTimestampNanoseconds {
            state.rootBoundaryNanos = max(state.rootBoundaryNanos ?? timestamp, timestamp)
        }
        if isChild {
            if state.firstChildTimestampNanos == nil { state.firstChildTimestampNanos = envelope.sourceTimestampNanoseconds }
            // Codex's hooks name no root (`root_agent_id` is absent from its
            // payloads), so an unnamed child belongs to the root tenure that
            // held its process when it was first seen; one naming another
            // known conversation does not.
            if state.childRootTenureStartNanos == nil, let currentRoot,
               state.rootAgentID.map({ !namesAnotherRoot($0, than: currentRoot.key, state: currentRoot.value) }) ?? true {
                state.childRootTenureStartNanos = currentRoot.value.tenureStartNanos
            }
        }
        replacementFences.removeValue(forKey: threadID)
        replacementFenceOrder.removeAll { $0 == threadID }
        if !childStatusIsNeutral, let sequence = envelope.eventSequence {
            state.summary.lastActivitySequence = max(state.summary.lastActivitySequence, sequence)
        }
        if !childStatusIsNeutral, let timestamp = envelope.sourceTimestampNanoseconds {
            state.summary.lastActivity = Date(timeIntervalSince1970: Double(timestamp) / 1_000_000_000)
        }
        if !childStatusIsNeutral { state.awaitingPermissionResolution = false }
        if !childStatusIsNeutral { state.summary.status = envelope.status }
        switch (envelope.event, envelope.inputHint) {
        case (.preToolUse, .some(let hint)):
            state.pendingQuestion = hint
            state.pendingQuestionMisses = 0
        case (.postToolUse, .question?) where state.pendingQuestion == .question:
            state.pendingQuestion = nil
        default: break
        }
        // A blocking question cannot outlive its turn or its process. Codex
        // drops its async questions at turn end too, which the next capture
        // shows; a Kimi background question may stay on screen.
        if [.stop, .stopFailure].contains(envelope.event), state.pendingQuestion == .question { state.pendingQuestion = nil }
        if envelope.event == .sessionEnd || envelope.event == .wrapperExit { state.pendingQuestion = nil }
        // An async question stays answerable while the turn keeps working:
        // its tool events must not take the card away between captures.
        let keepsDeferredPrompt = state.pendingQuestion == .deferredQuestion && state.livePrompt?.isBlocking == false
        // A kept card's attention still came from the screen: a later miss
        // (answered in the terminal) must revert it. So does a card an idle
        // reminder or a failed turn leaves up; only a frame that sets
        // attention itself takes it over.
        if !childStatusIsNeutral, envelope.status == .waitingForInput || envelope.status == .working && !keepsDeferredPrompt {
            state.promptRaisedAttention = false
        }
        // The same dialog's notification repeats its wait; any other status ends it.
        if !childStatusIsNeutral, envelope.status != .waitingForInput { state.hookPromptMisses = nil }
        if !childStatusIsNeutral, envelope.status == .waitingForInput {
            // Codex runs this hook before either guardian or human approval.
            // Only a current terminal prompt proves that a person must act.
            state.summary.attention = envelope.providerID == .codex && envelope.event == .permissionRequest
                ? .none : .needsYou
            if envelope.providerID == .codex && envelope.event == .permissionRequest {
                state.awaitingPermissionResolution = true
                state.summary.status = .working
            }
            // Claude follows PermissionRequest with a permission_prompt
            // Notification for the same dialog; the captured prompt stays.
            if previousStatus != .waitingForInput || state.summary.status != .waitingForInput { state.livePrompt = nil }
            state.completionKey = nil
        } else if !childStatusIsNeutral, envelope.status == .working {
            // A newer task supersedes any unread completion from the prior
            // task and invalidates its pending delivery generation.
            state.summary.attention = keepsDeferredPrompt ? .needsYou : .none
            if !keepsDeferredPrompt { state.livePrompt = nil }
            state.completionKey = nil
        }
        // A completed/interrupted turn cannot still be waiting for an earlier
        // permission request (including one answered by an automatic reviewer).
        if envelope.event == .stop {
            let key = Self.completionKey(envelope)
            if let key, key == state.acknowledgedCompletionKey {
                // The retained Stop replayed after a relaunch: already read.
                state.summary.attention = .none
                if state.summary.status == .finished { state.summary.status = .idle }
                state.completionKey = nil
            } else {
                state.summary.attention = .unreadCompletion
                state.completionKey = key
            }
            state.livePrompt = nil
        }
        if envelope.event == .sessionEnd || envelope.event == .wrapperExit {
            state.summary.attention = .none
            state.livePrompt = nil
            state.completionKey = nil
            state.conversationEnded = true
            if let timestamp = envelope.sourceTimestampNanoseconds {
                state.conversationEndNanos = max(state.conversationEndNanos ?? timestamp, timestamp)
            }
            state.actionLease = nil
            Self.unsettleOutgoing(&state)
        } else if !childStatusIsNeutral {
            state.conversationEnded = false
            state.conversationEndNanos = nil
        }
        // A miss must never revert attention the screen no longer owns.
        if state.summary.attention != .needsYou { state.promptRaisedAttention = false }
        Self.noteAttentionTransition(from: previousAttention, in: &state)
        durableCompletions[threadID] = .init(unread: state.completionKey, acknowledged: state.acknowledgedCompletionKey)
        if !isChild, !isEnd, !childStatusIsNeutral, let timestamp = envelope.sourceTimestampNanoseconds {
            state.latestRootActivityNanos = max(state.latestRootActivityNanos ?? timestamp, timestamp)
        }
        state.binding = proof.binding
        state.routeIdentity = proof.sourceIdentity
        state.isLiveRoute = true
        state.isChildConversation = isChild
        state.activity.append(.init(
            id: "lifecycle-\(state.activity.count)-\(envelope.event.rawValue)",
            sequence: state.summary.lastActivitySequence,
            kind: envelope.event == .permissionRequest ? .permission : .lifecycle,
            title: envelope.event.rawValue,
            detail: envelope.agentType,
            displayTime: nil
        ))
        state.deliveryGeneration &+= 1
        state.lastLifecycleFingerprint = fingerprint
        state.recentLifecycleFingerprints.append(fingerprint)
        if state.recentLifecycleFingerprints.count > 64 { state.recentLifecycleFingerprints.removeFirst(state.recentLifecycleFingerprints.count - 64) }
        if let sequence = envelope.eventSequence { state.lastLifecycleSequence = sequence }
        let rootReplaced = existingID != threadID && !state.isChildConversation
            && existing.isLiveRoute && !existing.isChildConversation
        if existingID != threadID, !state.isChildConversation, !existing.isChildConversation {
            threads.removeValue(forKey: existingID)
            noteReplaced(existingID, by: threadID, binding: proof.binding,
                         timestamp: envelope.sourceTimestampNanoseconds)
        }
        state.estimatedContentBytes = Self.estimatedBytes(state)
        threads[threadID] = state
        if !state.isChildConversation {
            // An ended root stays listed until occupancy or replacement;
            // its children leave because no further frame of theirs is due.
            removeConversations(replacedOn: proof.binding, by: threadID,
                                rootReplaced: rootReplaced || startsTenure,
                                timestamp: envelope.sourceTimestampNanoseconds,
                                endsChildren: Self.endsChildAgents(envelope.event))
        }
        enforceCacheLimits(excluding: threadID)
        return validation
    }

    /// A Codex child agent's frame. Claude subagent frames carry the root's
    /// own session and are the root's.
    public static func isChildFrame(_ envelope: AgentLifecycleEnvelope) -> Bool {
        envelope.agentID != nil && envelope.providerID == .codex
    }

    private static func namesRoot(_ rootAgentID: String, threadID: AgentThreadID, state: ThreadState) -> Bool {
        threadID.providerID == .codex && (rootAgentID == threadID.providerSessionID || rootAgentID == state.rootAgentID)
    }

    /// Whether a child's named root is a conversation other than `root`.
    /// Codex names none today, so its children are placed by tenure; a name
    /// this client cannot match to `root` may be a root it never saw (a
    /// fresh client after `/new`), and acting through `root` on its behalf
    /// would type into another conversation.
    private func namesAnotherRoot(_ rootAgentID: String, than root: AgentThreadID, state: ThreadState) -> Bool {
        !Self.namesRoot(rootAgentID, threadID: root, state: state)
    }

    /// Frames after which a root's child agents have nothing left to report.
    public static func endsChildAgents(_ event: AgentLifecycleEventKind) -> Bool {
        [.stop, .stopFailure, .sessionEnd, .wrapperExit].contains(event)
    }

    /// A proven agent process runs one root conversation at a time. Once it
    /// runs `threadID`, any other open conversation on its binding was
    /// replaced in that process (`/clear`, `/new`, `/resume`) and leaves, as
    /// the route holder above does. An observe-only binding names no
    /// process: several inventory sessions on one pane share it and stay.
    /// Stored sessions never held a live route and are left alone. A child
    /// agent's thread runs beside its root, and leaves with the root it
    /// belonged to: the conversations replaced here, `rootReplaced` naming
    /// the route holder the caller already removed. A binding names its
    /// process without its capabilities: a conversation a platform keeps
    /// observe-only on the same process was replaced there as well.
    private func removeConversations(replacedOn binding: AgentTerminalBinding, by threadID: AgentThreadID,
                                     rootReplaced: Bool, timestamp: UInt64?, endsChildren: Bool = false) {
        guard binding.agentPID != nil else { return }
        let open = threads.filter { id, state in
            id != threadID && id.hostID == threadID.hostID && state.isLiveRoute
                && state.binding.map { Self.sameProcess($0, binding) } == true
        }
        let roots = open.filter { !$0.value.isChildConversation }
        let replaced = rootReplaced || !roots.isEmpty || endsChildren ? open : roots
        for (id, state) in replaced {
            // A new root's child can arrive before its root frame. Its first
            // timestamp, rather than arrival order, places it in that tenure.
            if !endsChildren, state.isChildConversation, let timestamp,
               let first = state.firstChildTimestampNanos, first >= timestamp,
               state.rootAgentID.map({ rootAgentID in
                   threads[threadID].map { !namesAnotherRoot(rootAgentID, than: threadID, state: $0) } == true
               }) ?? true {
                // An unnamed child seen under the previous root belongs here.
                if state.rootAgentID == nil || state.childRootTenureStartNanos == nil {
                    threads[id]?.childRootTenureStartNanos = timestamp
                }
                continue
            }
            threads.removeValue(forKey: id)
            noteReplaced(id, by: threadID, binding: binding, timestamp: timestamp)
        }
    }

    private func discardRegistration(for threadID: AgentThreadID, successor: AgentThreadID?) {
        guard let state = threads[threadID], !state.isLiveRoute else { return }
        if state.lastLifecycleFingerprint != nil {
            replaceBinding(nil, for: threadID)
            return
        }
        threads.removeValue(forKey: threadID)
        if let successor { noteReplaced(threadID, by: successor) }
    }

    /// Whether a live conversation's route keeps it from `incoming` until
    /// occupancy proves that route absent: another pane of the same carrier
    /// (`claude --resume` of a conversation still running next door). The
    /// same pane's newer process (exit, then `--continue`) and a newer
    /// carrier (reconnect) take it over; the old route is dead or no longer
    /// observable there, so waiting would strand the conversation.
    public static func competesForLiveRoute(held: AgentTerminalBinding, incoming: AgentTerminalBinding) -> Bool {
        held != incoming && !sameProcess(held, incoming)
            && held.liveSessionID == incoming.liveSessionID && held.carrierGeneration == incoming.carrierGeneration
            && held.paneID != incoming.paneID
    }

    /// Whether two bindings name the same agent process on the same route,
    /// whatever either allows. A tmux pane id is unique on its server, so
    /// the window is placement, not identity: a pane moved to another window
    /// (`join-pane`, `break-pane`) still runs the same process, and its next
    /// conversation boundary must still replace the one it held.
    public static func sameProcess(_ held: AgentTerminalBinding, _ binding: AgentTerminalBinding) -> Bool {
        held.agentPID != nil && held.agentPID == binding.agentPID
            && held.liveSessionID == binding.liveSessionID && held.carrierGeneration == binding.carrierGeneration
            && held.incarnation == binding.incarnation && held.transport == binding.transport
            && held.tmuxSession == binding.tmuxSession && held.paneID == binding.paneID
    }

    private static func lifecycleFingerprint(_ envelope: AgentLifecycleEnvelope) -> String {
        let sourceSequence = envelope.sourceTimestampNanoseconds ?? envelope.eventSequence
        let sequenceText = sourceSequence.map { String($0) } ?? ""
        return [
            envelope.providerID.rawValue,
            envelope.providerSessionID ?? "",
            envelope.event.rawValue,
            envelope.status.rawValue,
            sequenceText,
            String(envelope.agentPID ?? 0),
            envelope.transcriptRef ?? "",
            envelope.agentID ?? "",
            envelope.agentType ?? "",
            envelope.rootAgentID ?? "",
        ].joined(separator: "\u{1f}")
    }

    /// Live prompts are observations of a terminal, not pages of a transcript.
    /// Keeping them separate prevents a prompt from resetting source identity,
    /// message sequences and the history cursor on either native platform.
    ///
    /// The capture is fenced by what the platform saw before it started: the
    /// thread's `deliveryGeneration`, or the arrival sequence of the newest
    /// lifecycle frame it had forwarded. A frame that arrived since then
    /// (the prompt was answered, the turn ended) makes the capture stale.
    ///
    /// `onDisplay` captures come from a conversation on screen. They are read
    /// even when no hook announced a question (an integration from before
    /// question hints, or a dialog raised before the app last connected):
    /// only the screen proves a dialog, and one it raises reverts on a miss.
    /// Returns whether the thread changed.
    @discardableResult
    public func observeLivePrompt(_ request: AgentPromptObservationRequest,
                                  threadID: AgentThreadID, binding: AgentTerminalBinding,
                                  observedGeneration: UInt64? = nil, observedLifecycleSequence: UInt64? = nil,
                                  onDisplay: Bool = false) -> Bool {
        guard var state = threads[threadID], state.binding == binding,
              request.providerID == threadID.providerID,
              Self.watchesLivePrompt(state) || onDisplay && state.isLiveRoute else { return false }
        if let observedGeneration {
            guard state.deliveryGeneration == observedGeneration else { return false }
        } else if let observedLifecycleSequence {
            guard observedLifecycleSequence >= (state.lastLifecycleSequence ?? 0) else { return false }
        } else {
            return false
        }
        let previousPrompt = state.livePrompt
        let previousAttention = state.summary.attention
        let previousStatus = state.summary.status
        if let observed = AgentPromptGrammar.observe(request) {
            // Kimi's background question looks exactly like its blocking one;
            // only the hook knows the agent kept working.
            let blocking = observed.isBlocking && !(state.pendingQuestion == .deferredQuestion && observed.kind != .permission)
            state.livePrompt = Self.livePrompt(observed, isBlocking: blocking)
            state.pendingQuestionMisses = 0
            if state.summary.attention != .needsYou || (blocking && state.summary.status != .waitingForInput) {
                state.promptRaisedAttention = true
            } else if !state.promptRaisedAttention {
                state.hookPromptMisses = 0
            }
            state.summary.attention = .needsYou
            if blocking { state.summary.status = .waitingForInput }
        } else {
            state.livePrompt = nil
            if state.pendingQuestion == .deferredQuestion {
                // Codex paints a queued question a moment after its tool
                // returns, and drops it at turn end; a run of misses means it
                // was answered in the terminal or discarded.
                state.pendingQuestionMisses += 1
                if state.pendingQuestionMisses >= Self.deferredQuestionMissLimit { state.pendingQuestion = nil }
            }
            if state.promptRaisedAttention || threadID.providerID == .codex && state.awaitingPermissionResolution {
                state.summary.attention = .none
                if state.summary.status == .waitingForInput || state.awaitingPermissionResolution { state.summary.status = .working }
                state.promptRaisedAttention = false
            } else if let misses = state.hookPromptMisses, state.summary.attention == .needsYou {
                // The hook's dialog was on screen and is gone: answered in the
                // terminal. One miss may be a redraw; a run of them is not.
                if misses + 1 >= Self.hookPromptMissLimit {
                    state.summary.attention = .none
                    if state.summary.status == .waitingForInput { state.summary.status = .working }
                    state.hookPromptMisses = nil
                } else {
                    state.hookPromptMisses = misses + 1
                }
            }
        }
        guard previousPrompt != state.livePrompt || previousAttention != state.summary.attention
                || previousStatus != state.summary.status else {
            threads[threadID] = state
            return false
        }
        Self.noteAttentionTransition(from: previousAttention, in: &state)
        state.deliveryGeneration &+= 1
        threads[threadID] = state
        return true
    }

    /// Consecutive empty captures after which an async question is gone.
    static let deferredQuestionMissLimit = 8
    /// Consecutive empty captures after which a dialog the hook raised, and
    /// the screen showed, is gone.
    static let hookPromptMissLimit = 3

    private static func watchesLivePrompt(_ state: ThreadState) -> Bool {
        state.isLiveRoute && (state.summary.status == .waitingForInput || state.awaitingPermissionResolution
            || state.pendingQuestion != nil || state.livePrompt != nil)
    }

    private static func livePrompt(_ observed: AgentPromptObservationResult, isBlocking: Bool) -> AgentActionPrompt {
        let title: String
        switch observed.kind {
        case .permission: title = observed.title ?? "Permission requested"
        case .question, .multiSelect, .textEntry: title = observed.title ?? "Question"
        case .review: title = observed.title ?? "Review your answers"
        case .deferred: title = "Questions waiting"
        }
        return .init(
            title: title,
            detail: observed.detail,
            options: observed.options.map {
                .init(id: $0.id, label: $0.label, isDefault: $0.isDefault, detail: $0.detail, role: $0.role,
                      isChecked: $0.isChecked, acceptsText: $0.acceptsText)
            },
            token: AgentPromptGrammar.actionToken(for: observed.signature),
            kind: observed.kind,
            question: observed.question,
            progress: observed.progress,
            controls: observed.controls,
            entry: observed.entry,
            acceptsText: observed.textFocus != nil,
            isBlocking: isBlocking,
            pendingCount: observed.pendingCount
        )
    }

    private static func clearLivePrompt(_ state: inout ThreadState) {
        if state.livePrompt != nil || state.awaitingPermissionResolution {
            state.summary.attention = .none
            if state.summary.status == .waitingForInput { state.summary.status = .idle }
        }
        state.livePrompt = nil
        state.awaitingPermissionResolution = false
        state.pendingQuestion = nil
        state.pendingQuestionMisses = 0
        state.promptRaisedAttention = false
        state.hookPromptMisses = nil
    }

    public func snapshot(for threadID: AgentThreadID) -> AgentThreadSnapshot? {
        guard let state = threads[threadID] else { return nil }
        var touched = state
        touch(&touched)
        threads[threadID] = touched
        // Transcript/helper data is presentation evidence, never prompt-answer
        // authority. Even a copied live token cannot turn it into a control.
        // Unchanged messages reuse one derived array, so repeated snapshots
        // share storage and compare in constant time on the platform side.
        if touched.presentationSource != state.messages {
            let transcriptMessages = state.messages.map { message in
                guard message.blocks.contains(where: { if case .actionPrompt = $0 { return true }; return false }) else { return message }
                return AgentMessage(recordID: message.recordID, role: message.role, displayTime: message.displayTime,
                    blocks: message.blocks.map { block in
                        guard case .actionPrompt(let prompt) = block else { return block }
                        return .text(([prompt.title] + [prompt.detail].compactMap { $0 } + prompt.options.map(\.label)).joined(separator: "\n"))
                    })
            }
            touched.presentationSource = state.messages
            touched.presentationMessages = threadID.providerID == .codex ? AgentCodexTranscriptContent.presentationMessages(transcriptMessages) : transcriptMessages
            threads[threadID] = touched
        }
        var messages = touched.presentationMessages
        // The card, sends and live preview sit under the newest record: shown
        // while the transcript reaches it, in the head or bridged into it (a
        // busy head rolls past a follower's rows), never under history.
        let reachesLiveHead = state.ingestionWindow.map { $0.atLiveHead || $0.bridgesToHead } ?? true
        if let prompt = state.livePrompt, reachesLiveHead {
            messages.append(.init(recordID: "live-prompt-\(prompt.token.rawValue)", role: .system,
                                  displayTime: nil, blocks: [.actionPrompt(prompt)]))
        }
        var summary = state.summary
        summary.livePromptWatch = Self.watchesLivePrompt(state)
        return .init(summary: summary, messages: messages, turns: Self.makeTurns(records: state.records, messages: messages), activity: state.activity, changes: state.changes, lineage: state.lineage, cursor: state.cursor, hasMore: state.hasMore, binding: state.binding, deliveryGeneration: state.deliveryGeneration,
            outgoingMessages: reachesLiveHead ? state.outgoing.map(\.message) : [],
            livePreview: reachesLiveHead ? state.hookOverlay.preview : nil,
            ingestionWindow: state.ingestionWindow.map { .init($0, epoch: state.ingestionEpoch!, liveCursor: state.liveCursor,
                transition: state.ingestionWindowTransition, retainsOutgoing: !state.outgoing.isEmpty, derivedRoom: olderPageRoom(state)) },
            attentionEpoch: state.attentionEpoch,
            unreadCompletionKey: durableCompletions[threadID]?.unread,
            acknowledgedCompletionKey: durableCompletions[threadID]?.acknowledged,
            conversationEnded: state.conversationEnded)
    }

    public func listSnapshot() -> AgentCenterListSnapshot {
        // The list is "agents open in a connection right now", not "every
        // session a host has ever stored". Tier-C inventory binds every stored
        // session so it can authorise transcript reads, and those never become
        // a live route — which is why the list carried opencode conversations
        // from months earlier, and dormant Claude sessions, on both platforms.
        //
        // Threads filtered out here stay in the reducer and remain readable
        // through `search`, the spec's route to a historical thread.
        let visible = threads.values
            .filter(\.isLiveRoute)
            .map { state in
                var summary = state.summary
                summary.livePromptWatch = Self.watchesLivePrompt(state)
                return summary
            }
            .filter { summary in
                (filter.providerIDs.isEmpty || filter.providerIDs.contains(summary.id.providerID))
                    && (filter.query.isEmpty
                        || summary.title.localizedCaseInsensitiveContains(filter.query)
                        || summary.projectBasename?.localizedCaseInsensitiveContains(filter.query) == true
                        || summary.hostDisplayLabel.localizedCaseInsensitiveContains(filter.query))
            }
        let sorted = visible.sorted { lhs, rhs in
            func rank(_ attention: AgentAttention, _ status: AgentStatus) -> Int {
                if attention == .needsYou { return 0 }
                if status == .working { return 1 }
                if attention == .unreadCompletion { return 2 }
                return 3
            }
            switch grouping {
            case .attention:
                let lhsRank = rank(lhs.attention, lhs.status)
                let rhsRank = rank(rhs.attention, rhs.status)
                return lhsRank == rhsRank ? lhs.lastActivitySequence > rhs.lastActivitySequence : lhsRank < rhsRank
            case .host:
                return lhs.hostDisplayLabel == rhs.hostDisplayLabel
                    ? lhs.lastActivitySequence > rhs.lastActivitySequence
                    : lhs.hostDisplayLabel.localizedStandardCompare(rhs.hostDisplayLabel) == .orderedAscending
            }
        }
        let liveThreads = threads.values.filter(\.isLiveRoute)
        var surfaces: [CandidateSurface: CandidateState] = [:]
        for state in candidates.values {
            let id = state.candidate.id
            let surface = CandidateSurface(hostID: id.hostID, providerID: id.providerID, binding: state.fallback.binding)
            // Only current process evidence can make an identified live
            // conversation replace a fallback. History or a former process
            // on the same pane is not proof of this candidate's identity.
            let hasIdentity = liveThreads.contains { thread in
                guard let binding = thread.binding,
                      CandidateSurface(hostID: thread.summary.id.hostID, providerID: thread.summary.id.providerID,
                                       binding: binding) == surface else { return false }
                if let pid = binding.agentPID { return state.processIDs.contains(pid) }
                return binding.incarnation == state.fallback.binding.incarnation
            }
            if hasIdentity { continue }
            if let previous = surfaces[surface], previous.registrationOrdinal > state.registrationOrdinal { continue }
            surfaces[surface] = state
        }
        let visibleCandidates = surfaces.values.map(\.candidate).filter { candidate in
            (filter.providerIDs.isEmpty || filter.providerIDs.contains(candidate.id.providerID))
                && (filter.query.isEmpty
                    || candidate.title.localizedCaseInsensitiveContains(filter.query)
                    || candidate.hostDisplayLabel.localizedCaseInsensitiveContains(filter.query))
        }.sorted { lhs, rhs in
            let leftRank = lhs.fallback.status == .waitingForInput ? 0 : 1
            let rightRank = rhs.fallback.status == .waitingForInput ? 0 : 1
            if leftRank != rightRank { return leftRank < rightRank }
            // Discovery timestamps describe when a pane was sampled, not when
            // its agent did work. Sorting by them makes every asynchronous
            // probe move a row. Keep terminal surfaces in a deterministic
            // order; only a real attention transition changes their section.
            let left = [lhs.hostDisplayLabel, lhs.fallback.location, lhs.id.providerID.rawValue,
                        lhs.id.hostID.uuidString, lhs.id.sourceIdentity]
            let right = [rhs.hostDisplayLabel, rhs.fallback.location, rhs.id.providerID.rawValue,
                         rhs.id.hostID.uuidString, rhs.id.sourceIdentity]
            return left.lexicographicallyPrecedes(right)
        }
        return .init(threads: sorted, candidates: visibleCandidates)
    }

    private static func terminalPreview(_ value: String) -> String {
        let scalars = Array(String(value.prefix(16_384)).unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar.value == 0x1b else {
                if scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" { result.append(scalar) }
                continue
            }
            guard index < scalars.count else { break }
            let introducer = scalars[index].value
            index += 1
            if [0x5d, 0x50, 0x58, 0x5e, 0x5f].contains(introducer) {
                // OSC/DCS/SOS/PM/APC payloads end at ST (OSC also accepts BEL).
                var complete = false
                while index < scalars.count {
                    if introducer == 0x5d && scalars[index].value == 7 {
                        index += 1; complete = true; break
                    }
                    if scalars[index].value == 0x1b && index + 1 < scalars.count && scalars[index + 1].value == 0x5c {
                        index += 2; complete = true; break
                    }
                    index += 1
                }
                if !complete { break }
            } else {
                if introducer == 0x5b {
                    while index < scalars.count && (0x30...0x3f).contains(scalars[index].value) { index += 1 }
                } else {
                    index -= 1
                }
                while index < scalars.count && (0x20...0x2f).contains(scalars[index].value) { index += 1 }
                let finalRange: ClosedRange<UInt32> = introducer == 0x5b ? 0x40...0x7e : 0x30...0x7e
                guard index < scalars.count, finalRange.contains(scalars[index].value) else { break }
                index += 1
            }
        }
        return String(result)
    }

    /// Returns whether anything changed. A visible tail is reported while
    /// the reader scrolls; a repeat must not publish a new delivery generation.
    @discardableResult
    public func acknowledge(threadID: AgentThreadID, visibleRecordID: String) -> Bool {
        guard needsAcknowledgement(threadID: threadID, visibleRecordID: visibleRecordID),
              var state = threads[threadID] else { return false }
        state.lastReadRecordID = visibleRecordID
        state.summary.attention = .none
        if state.summary.status == .finished { state.summary.status = .idle }
        markCompletionRead(&state, for: threadID)
        state.deliveryGeneration &+= 1
        threads[threadID] = state
        return true
    }

    /// A reader looking at a finished thread in Agent Center has read its
    /// completion even when there is no record to point at: an empty or
    /// unavailable transcript, or a tail that was already visible when the
    /// Stop arrived. Fenced by the attention epoch the reader saw, so a newer
    /// completion (or a request) is never cleared by an older view.
    @discardableResult
    public func acknowledgeCompletion(threadID: AgentThreadID, observedEpoch: UInt64) -> Bool {
        guard var state = threads[threadID], state.summary.attention == .unreadCompletion,
              state.attentionEpoch == observedEpoch else { return false }
        state.summary.attention = .none
        if state.summary.status == .finished { state.summary.status = .idle }
        markCompletionRead(&state, for: threadID)
        state.deliveryGeneration &+= 1
        threads[threadID] = state
        return true
    }

    /// A visible newest row changes nothing once it is read; platforms check
    /// this before durable metadata writes on every scroll frame.
    public func needsAcknowledgement(threadID: AgentThreadID, visibleRecordID: String) -> Bool {
        guard let state = threads[threadID], state.messages.last?.recordID == visibleRecordID else { return false }
        return state.lastReadRecordID != visibleRecordID || state.summary.attention != .none || state.summary.status == .finished
    }

    @discardableResult
    public func acknowledgeTerminal(threadID: AgentThreadID, binding: AgentTerminalBinding,
                                    observedGeneration: UInt64) -> Bool {
        guard var state = threads[threadID], state.binding == binding,
              state.deliveryGeneration == observedGeneration,
              state.summary.attention == .unreadCompletion else { return false }
        state.summary.attention = .none
        if state.summary.status == .finished { state.summary.status = .idle }
        state.lastReadRecordID = state.messages.last?.recordID
        markCompletionRead(&state, for: threadID)
        state.deliveryGeneration &+= 1
        threads[threadID] = state
        return true
    }

    public func select(threadID: AgentThreadID?) {
        selectedThreadID = threadID
    }

    public func setGrouping(_ grouping: AgentListGrouping) { self.grouping = grouping }
    public func setFilter(_ filter: AgentListFilter) { self.filter = filter }
    public func currentGrouping() -> AgentListGrouping { grouping }
    public func currentFilter() -> AgentListFilter { filter }

    public func applySearch(_ snapshot: AgentSearchSnapshot) { searchSnapshot = snapshot }
    public func currentSearchSnapshot() -> AgentSearchSnapshot { searchSnapshot }

    public func search(query: String) -> AgentSearchSnapshot {
        let needle = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchSnapshot = .init(results: [])
            return searchSnapshot
        }
        var results: [AgentSearchResult] = []
        var hostCounts: [UUID: Int] = [:]
        var admittedHosts: Set<UUID> = []
        for (threadID, state) in threads {
            let hostID = threadID.hostID
            guard hostCounts[hostID, default: 0] < AgentSearchSnapshot.maximumResultsPerHost else { continue }
            for message in state.messages {
                let searchable = message.blocks.compactMap(Self.searchText).joined(separator: "\n")
                guard let range = searchable.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                if !admittedHosts.contains(hostID) {
                    // Only a host with a hit consumes one of the global
                    // connected-host slots; quiet hosts must not starve later
                    // result-bearing hosts.
                    guard admittedHosts.count < AgentSearchSnapshot.maximumHosts else { break }
                    admittedHosts.insert(hostID)
                }
                let start = searchable.index(range.lowerBound, offsetBy: -80, limitedBy: searchable.startIndex) ?? searchable.startIndex
                let end = searchable.index(range.upperBound, offsetBy: 160, limitedBy: searchable.endIndex) ?? searchable.endIndex
                results.append(.init(threadID: threadID, recordID: message.recordID, excerpt: String(searchable[start..<end])))
                hostCounts[hostID, default: 0] += 1
                if hostCounts[hostID, default: 0] == AgentSearchSnapshot.maximumResultsPerHost { break }
            }
        }
        searchSnapshot = .init(results: results)
        return searchSnapshot
    }

    public func setLineage(_ lineage: AgentThreadLineage, for threadID: AgentThreadID) {
        guard var state = threads[threadID] else { return }
        state.lineage = lineage
        state.summary.isFork = lineage.parentThreadID != nil
        threads[threadID] = state
    }

    public func fallback(for candidateID: AgentSourceCandidateID) -> AgentFallbackSnapshot? {
        candidates[candidateID]?.fallback
    }

    public func attentionEvent(for threadID: AgentThreadID, routeToken: AgentRouteToken) -> AgentAttentionEvent? {
        guard let state = threads[threadID], state.summary.attention != .none else { return nil }
        return .init(threadID: threadID, routeToken: routeToken, attention: state.summary.attention, deliveryGeneration: state.deliveryGeneration,
                     attentionEpoch: state.attentionEpoch)
    }

    public func memoryWarning() {
        for id in threads.keys {
            guard var state = threads[id] else { continue }
            if state.ingestionWindow != nil { ingestionEvictions.insert(id) }
            evictThreadContent(&state)
            threads[id] = state
        }
        searchSnapshot = .init(results: [])
        AgentMarkdownDocument.purgeCache()
    }

    public func takeIngestionEvictions() -> Set<AgentThreadID> {
        let result = ingestionEvictions; ingestionEvictions.removeAll(); return result
    }

    /// Conversations a lifecycle frame removed because the agent process on
    /// their pane moved on to another (`/clear`, `/new`, `/resume`), each
    /// with the conversation that holds the pane now. A platform retires
    /// what it still holds for them and moves their reader along. One
    /// registered again since is current and not reported.
    public func takeReplacedConversations() -> [AgentThreadID: AgentThreadID] {
        defer { replacedConversations.removeAll() }
        return replacedConversations.filter { threads[$0.key] == nil }
    }

    /// The conversation that holds the pane `threadID` held when a newer one
    /// replaced it, following `/clear` after `/clear`; nil while `threadID`
    /// is held again, or when nothing Core holds replaced it.
    public func conversationReplacing(_ threadID: AgentThreadID) -> AgentThreadID? {
        guard threads[threadID] == nil else { return nil }
        var current = threadID
        for _ in 0..<replacementOrder.count {
            guard let next = replacementSuccessors[current] else { break }
            if threads[next] != nil { return next }
            current = next
        }
        return nil
    }

    private func noteReplaced(_ threadID: AgentThreadID, by successor: AgentThreadID,
                              binding: AgentTerminalBinding? = nil, timestamp: UInt64? = nil) {
        replacedConversations[threadID] = successor
        if replacementSuccessors.updateValue(successor, forKey: threadID) == nil { replacementOrder.append(threadID) }
        if replacementOrder.count > 256 { replacementSuccessors.removeValue(forKey: replacementOrder.removeFirst()) }
        if let binding, let timestamp { noteReplacementFence(threadID, binding: binding, timestamp: timestamp) }
    }

    private func noteReplacementFence(_ threadID: AgentThreadID, binding: AgentTerminalBinding, timestamp: UInt64) {
        if let held = replacementFences[threadID], Self.sameProcess(held.binding, binding), held.timestamp >= timestamp { return }
        if replacementFences.updateValue(.init(binding: binding, timestamp: timestamp), forKey: threadID) == nil {
            replacementFenceOrder.append(threadID)
        }
        if replacementFenceOrder.count > 256 {
            replacementFences.removeValue(forKey: replacementFenceOrder.removeFirst())
        }
    }

    private func noteClearFence(binding: AgentTerminalBinding, timestamp: UInt64) {
        if let index = clearFences.firstIndex(where: { Self.sameProcess($0.binding, binding) }) {
            guard clearFences[index].timestamp < timestamp else { return }
            clearFences.remove(at: index)
        }
        clearFences.append(.init(binding: binding, timestamp: timestamp))
        if clearFences.count > 64 { clearFences.removeFirst(clearFences.count - 64) }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        memoryWarning()
        // Explicit feature disable is a privacy purge, unlike memory pressure.
        for id in threads.keys {
            threads[id]?.outgoing = []
            if let state = threads[id] { threads[id]?.estimatedContentBytes = Self.estimatedBytes(state) }
        }
        candidates.removeAll()
        selectedThreadID = nil
        for id in threads.keys {
            if var state = threads[id] {
                Self.clearLivePrompt(&state)
                threads[id] = state
            }
            threads[id]?.actionLease = nil
            threads[id]?.deliveryGeneration &+= 1
            threads[id]?.summary.availability = .init(content: false, status: false, actions: false, spawn: false, fork: false, search: false, reason: .disabled)
        }
    }

    public func acquireLease(threadID: AgentThreadID, action: AgentActionKind, binding: AgentTerminalBinding, textRequest: AgentTextSendRequest? = nil) throws -> AgentActionLease {
        guard var state = threads[threadID] else { throw AgentActionError.unavailable }
        // Opening the exact existing terminal binding is navigation, not a
        // provider mutation. It remains possible when provider actions are
        // unavailable, but is still fenced by the bound carrier identity.
        guard action == .openTerminal || !state.conversationEnded && state.summary.availability.actions else { throw AgentActionError.unavailable }
        guard state.binding == binding else { throw AgentActionError.staleBinding }
        if action != .openTerminal, state.isChildConversation {
            // A child acts through its root's TUI: only while the root tenure
            // it belongs to still holds the process.
            guard let root = threads.first(where: { id, other in
                      id.hostID == threadID.hostID && other.isLiveRoute && !other.isChildConversation && !other.conversationEnded
                          && other.binding.map { Self.sameProcess($0, binding) } == true
                          && (state.rootAgentID.map { !namesAnotherRoot($0, than: id, state: other) } ?? true)
                  }), state.childRootTenureStartNanos == root.value.tenureStartNanos else { throw AgentActionError.unavailable }
        }
        let capabilityAllowed: Bool = switch action {
        case .send, .queue: binding.capabilities.contains(.send)
        case .interrupt: binding.capabilities.contains(.interrupt)
        case .answerPrompt: binding.capabilities.contains(.promptAnswer)
        case .openTerminal: binding.capabilities.contains(.observe)
        case .spawn: state.summary.availability.spawn && binding.hasCurrentTmuxTarget
        case .fork: state.summary.availability.fork && binding.hasCurrentTmuxTarget
        }
        guard capabilityAllowed else { throw AgentActionError.unavailable }
        guard state.actionLease == nil else { throw AgentActionError.actionInFlight }
        if let textRequest {
            guard AgentABIActionPayload(text: textRequest).isValid(for: action, threadID: threadID, binding: binding) else { throw AgentActionError.unavailable }
            // Retain unknown terminal-delivery intent. Acknowledged delivery is
            // already sent, even when history is unavailable; its bounded local
            // presentation may expire without claiming transcript causality.
            if state.outgoing.count >= 32, let settled = state.outgoing.firstIndex(where: { $0.terminalAcknowledged }) {
                state.outgoing.remove(at: settled)
            }
            guard state.outgoing.count < 32 else { throw AgentActionError.actionInFlight }
        }
        let lease = AgentActionLease(threadID: threadID, binding: binding, action: action)
        state.actionLease = lease
        if let textRequest {
            state.outgoing.append(.init(message: .init(id: lease.token, text: textRequest.text, status: action == .queue ? .queueing : .sending), binding: binding))
            guard (try? JSONEncoder().encode(state.outgoing.map(\.message)).count).map({ $0 <= 262_144 }) == true else { throw AgentActionError.actionInFlight }
            state.estimatedContentBytes = Self.estimatedBytes(state)
        }
        threads[threadID] = state
        enforceCacheLimits(excluding: threadID)
        return lease
    }

    /// Arms this action with a fresh source EOF without requiring a canonical
    /// page, live cursor, or completed index. Binding authority is supplied by
    /// the platform's current process/route proof, never by the source itself.
    public func armOutgoing(_ lease: AgentActionLease, frontier: AgentOutgoingFrontier) throws {
        guard var state = threads[lease.threadID], state.actionLease == lease,
              state.binding == lease.binding, frontier.actionID == lease.token,
              frontier.provider == lease.threadID.providerID,
              frontier.providerSessionID == lease.threadID.providerSessionID,
              let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token }),
              state.outgoing[index].boundary == nil, state.outgoing[index].frontier == nil,
              !state.outgoing[index].dispatched else { throw AgentActionError.staleBinding }
        state.outgoing[index].frontier = frontier
        state.estimatedContentBytes = Self.estimatedBytes(state)
        threads[lease.threadID] = state
    }

    /// Called when entering terminal dispatch, before the final process/composer
    /// checks so this actor hop cannot stale the mutation proof. Fresh-frontier
    /// correlation also excludes every record observed before the terminal ACK.
    public func markOutgoingDispatched(_ lease: AgentActionLease) throws {
        guard var state = threads[lease.threadID], state.actionLease == lease,
              state.binding == lease.binding,
              let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token }),
              !state.outgoing[index].dispatched,
              state.outgoing[index].frontier != nil || state.outgoing[index].boundary != nil else {
            throw AgentActionError.staleBinding
        }
        state.outgoing[index].dispatched = true
        let records = state.ingestionWindow?.head?.records ?? state.records
        state.outgoing[index].preDispatchSequence = records.map(\.sequence).max()
        state.outgoing[index].preDispatchSourceKey = state.sourceIdentity.map(Self.sourceFileKey)
        state.outgoing[index].preDispatchEpoch = state.ingestionEpoch
        state.outgoing[index].heldNothing = records.isEmpty && state.ingestionEpoch != nil
        if let frontier = state.outgoing[index].frontier {
            state.outgoing[index].preAcknowledgmentPhysicalOffset = records
                .filter { $0.receiptSourceIdentity == frontier.sourceIdentity }.compactMap(\.receiptSourceOffset).max()
        }
        state.estimatedContentBytes = Self.estimatedBytes(state)
        threads[lease.threadID] = state
    }

    /// A new bounded tail boundary (or fresh page for non-JSONL providers)
    /// establishes what existed before submission, without scanning a transcript.
    public func armOutgoing(_ lease: AgentActionLease, freshPage: AgentProjectionPage) throws {
        guard var state = threads[lease.threadID], state.actionLease == lease,
              state.binding == lease.binding,
              ([AgentProviderID.pi, .opencode].contains(lease.threadID.providerID) ? !freshPage.hasMore : freshPage.from == nil),
              let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token }),
              state.outgoing[index].boundary == nil, state.outgoing[index].frontier == nil,
              !state.outgoing[index].dispatched else { throw AgentActionError.staleBinding }
        if let epoch = freshPage.summary?.objectValue?["nativeReceiptEpoch"]?.stringValue {
            guard epoch == state.ingestionEpoch, freshPage.sourceIdentity == state.sourceIdentity,
                  freshPage.records.last == (state.ingestionWindow?.head?.records ?? state.records).last,
                  !freshPage.hasMore else { throw AgentActionError.verificationFailed }
            if AgentIngestionSourceIdentity.file(freshPage.sourceIdentity) {
                let last = (state.ingestionWindow?.head?.records ?? state.records).last
                let offset = AgentIngestionSourceIdentity.indexedFile(freshPage.sourceIdentity) ? last?.sourceOffset : last?.sequence
                guard let raw = freshPage.summary?.objectValue?["nativeReceiptSourceEnd"]?.stringValue,
                      let end = UInt64(raw), last == nil || offset.map({ $0 < end }) == true else {
                    throw AgentActionError.verificationFailed
                }
            }
        } else if state.ingestionEpoch != nil {
            throw AgentActionError.verificationFailed
        }
        if let value = freshPage.summary?.objectValue?["receiptByteOffset"] {
            let identityParts = freshPage.sourceIdentity.split(separator: ":")
            let parts = identityParts.first == "codex-images1" ? Array(identityParts.dropFirst()) : identityParts
            guard let size = value.stringValue.flatMap(UInt64.init), parts.count == 4,
                  parts.allSatisfy({ UInt64($0, radix: 16) != nil }), UInt64(parts[2], radix: 16) == size,
                  !freshPage.hasMore,
                  size == 0 ? freshPage.records.isEmpty : (freshPage.records.count == 1 && freshPage.records[0].sourceHash != nil && freshPage.records[0].sourceOffset.map { $0 < size } == true)
            else { throw AgentActionError.verificationFailed }
        }
        // Retain only the last record as a continuity anchor, not another page.
        state.outgoing[index].boundary = AgentProjectionPage(sourceIdentity: freshPage.sourceIdentity,
            records: Array(freshPage.records.suffix(1)), cursor: nil, hasMore: false, summary: freshPage.summary)
        let pendingBytes = state.outgoing.reduce(0) { $0 + ((try? JSONEncoder().encode($1.message))?.count ?? 0) + ((try? JSONEncoder().encode($1.boundary))?.count ?? 0) }
        guard pendingBytes <= 524_288 else { throw AgentActionError.actionInFlight }
        state.estimatedContentBytes = Self.estimatedBytes(state)
        threads[lease.threadID] = state
        enforceCacheLimits(excluding: lease.threadID)
    }

    /// Read-only live checkpoint for a multiplexed observational connection.
    /// This is not a terminal/action binding or submission receipt.
    public func ingestionCheckpoint(for threadID: AgentThreadID) -> (epoch: String, cursor: String)? {
        guard let state = threads[threadID], let epoch = state.ingestionEpoch, let cursor = state.liveCursor else { return nil }
        return (epoch, cursor)
    }

    public func ingestionWindowSnapshot(for threadID: AgentThreadID) -> AgentIngestionWindowSnapshot? {
        guard let state = threads[threadID], let window = state.ingestionWindow, let epoch = state.ingestionEpoch else { return nil }
        return .init(window, epoch: epoch, liveCursor: state.liveCursor, transition: state.ingestionWindowTransition,
            retainsOutgoing: !state.outgoing.isEmpty, derivedRoom: olderPageRoom(state))
    }

    /// The derived-model half of `olderPageFits`: an older page that leaves
    /// no room here is refused rather than evict a follower's live head. A
    /// page carries up to the page limit in records and about as much again
    /// in the rows derived from them; one that cost more (edits count in
    /// records, messages and changes) sets the room the next one needs, so
    /// head growth that evicts it does not invite it straight back. After a
    /// refusal nothing is offered until the content shrinks by a page.
    private func olderPageRoom(_ state: ThreadState) -> Bool {
        let page = max(262_144, state.ingestionOlderPageCost)
        return state.estimatedContentBytes + 2 * page <= budget.perThreadBytes - 524_288
            && state.ingestionOlderRefusedBytes.map { state.estimatedContentBytes + 262_144 <= $0 } ?? true
            && presentationLimitBytes.map { limit in state.ingestionPresentationBytes.map { $0 + page + 65_536 <= limit } ?? false } ?? true
    }

    /// Called only after a fresh, fully caught-up canonical read has committed.
    /// Hook overlays never enter state.records and cannot acknowledge sends.
    public func nativeReceiptBoundary(for threadID: AgentThreadID, after page: AgentProjectionPage) throws -> AgentProjectionPage {
        var summary: [String: AgentJSONValue] = [:]
        if AgentIngestionSourceIdentity.file(page.sourceIdentity) {
            guard let end = page.ingestion?.sourceEnd else { throw AgentActionError.verificationFailed }
            summary["nativeReceiptSourceEnd"] = .string(String(end))
        }
        summary["nativeReceiptEpoch"] = page.ingestion.map { .string($0.epoch) }
        guard let state = threads[threadID], let range = page.ingestion, range.operation == .updates, !range.hasNewer,
              state.ingestionEpoch == range.epoch, state.liveCursor == range.liveCursor,
              state.ingestionTransactions.last == range.requestID, state.sourceIdentity == page.sourceIdentity,
              let boundary = AgentProjectionPage(sourceIdentity: page.sourceIdentity,
                records: Array((state.ingestionWindow?.head?.records ?? state.records).suffix(1)), cursor: nil, hasMore: false,
                summary: .object(summary)) else { throw AgentActionError.verificationFailed }
        return boundary
    }

    public func releaseLease(_ lease: AgentActionLease, result: AgentActionResultStatus = .failed) {
        guard var state = threads[lease.threadID] else { return }
        guard state.actionLease == lease else {
            // A rebind revokes the lease (its bubble turns unconfirmed) while
            // the platform may still be proving the composer. A refusal before
            // any byte still withdraws that bubble: the lease token names it,
            // and nothing was written for a receipt to settle.
            if result == .notSent,
               let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token && !$0.terminalAcknowledged }) {
                state.outgoing.remove(at: index)
                state.estimatedContentBytes = Self.estimatedBytes(state)
                threads[lease.threadID] = state
            }
            return
        }
        state.actionLease = nil
        if result == .notSent, let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token }) {
            // Nothing was written, so there is no receipt to wait for. The
            // platform returns the text to its composer instead of a bubble.
            state.outgoing.remove(at: index)
            state.estimatedContentBytes = Self.estimatedBytes(state)
        } else if let index = state.outgoing.firstIndex(where: { $0.message.id == lease.token }) {
            state.outgoing[index].terminalAcknowledged = result == .verified
            if state.outgoing[index].frontier != nil && result == .verified {
                // The final process/composer proof follows dispatch arming.
                // Fence everything observed before the terminal ACK. Claude
                // image receipts below may settle advisorily during its longer
                // departure check; never invent causality or retry the write.
                let identity = state.outgoing[index].frontier?.sourceIdentity
                let records = (state.ingestionWindow?.head?.records ?? state.records).filter { $0.receiptSourceIdentity == identity }
                if lease.threadID.providerID == .claude,
                   AgentTextInsertion.images(provider: "claude", text: state.outgoing[index].message.text) != nil,
                   let frontier = state.outgoing[index].frontier, frontier.consistency == .observedPrefix, let end = frontier.sourceEnd {
                    let held = state.ingestionWindow == nil ? state.messages : state.ingestionHeadMessages
                    // Claim a receipt ingested during Claude's departure check
                    // as an observational match, never as causal proof. The
                    // physical claim prevents reuse by another identical send.
                    let claimed = state.outgoing.compactMap(\.matchedReceipt)
                    if let receipt = records.first(where: { record in
                        guard let offset = record.receiptSourceOffset, offset >= end,
                              state.outgoing[index].preAcknowledgmentPhysicalOffset.map({ offset > $0 }) ?? true,
                              !claimed.contains(Self.receiptClaimKey(record, in: state)),
                              let message = held.first(where: { $0.recordID == record.recordID && $0.role == .user }) else { return false }
                        return AgentTextInsertion.matchesReceipt(provider: "claude", text: state.outgoing[index].message.text, blocks: message.blocks)
                    }) {
                        state.outgoing[index].observationalMatch = true
                        state.outgoing[index].matchedReceipt = Self.receiptClaimKey(receipt, in: state)
                        // Do not advance the reconcile sequence watermark here:
                        // an older held record may still settle another send.
                    }
                }
                let observed = records.compactMap(\.receiptSourceOffset).max()
                state.outgoing[index].preAcknowledgmentPhysicalOffset =
                    [state.outgoing[index].preAcknowledgmentPhysicalOffset, observed].compactMap { $0 }.max()
            }
            // A send with no source at dispatch keeps the opening-prompt rule:
            // the new transcript's first window can land before the ACK, and
            // fencing at it excluded the send's own prompt.
            if state.outgoing[index].frontier?.consistency == .unavailable && result == .verified,
               state.outgoing[index].preDispatchSourceKey != nil,
               let key = state.sourceIdentity.map(Self.sourceFileKey) {
                let records = state.ingestionWindow?.head?.records ?? state.records
                let held = records.map(\.sequence).max()
                let sameSource = state.outgoing[index].preDispatchSourceKey == key
                    && state.outgoing[index].preDispatchEpoch == state.ingestionEpoch
                if sameSource, lease.threadID.providerID == .claude,
                   AgentTextInsertion.images(provider: "claude", text: state.outgoing[index].message.text) != nil {
                    let messages = state.ingestionWindow == nil ? state.messages : state.ingestionHeadMessages
                    let claimed = state.outgoing.compactMap(\.matchedReceipt)
                    // As with a physical frontier, claim Claude's early image
                    // receipt before fencing the rest of the held records.
                    if let receipt = records.first(where: { record in
                        guard state.outgoing[index].preDispatchSequence.map({ record.sequence > $0 }) ?? state.outgoing[index].heldNothing,
                              !claimed.contains(Self.receiptClaimKey(record, in: state)),
                              let message = messages.first(where: { $0.recordID == record.recordID && $0.role == .user }) else { return false }
                        return AgentTextInsertion.matchesReceipt(provider: "claude", text: state.outgoing[index].message.text, blocks: message.blocks)
                    }) {
                        state.outgoing[index].observationalMatch = true
                        state.outgoing[index].matchedReceipt = Self.receiptClaimKey(receipt, in: state)
                        // Leave the reconcile watermark for older held receipts.
                    }
                }
                // Every other record held before the ACK predates this write.
                state.outgoing[index].preDispatchSequence = sameSource
                    ? [state.outgoing[index].preDispatchSequence, held].compactMap { $0 }.max() : held
                state.outgoing[index].preDispatchSourceKey = key
                state.outgoing[index].preDispatchEpoch = state.ingestionEpoch
                state.outgoing[index].heldNothing = held == nil && state.ingestionEpoch != nil
            }
            state.outgoing[index].message.status = result == .verified
                ? (state.outgoing[index].observationalMatch ? .observed
                    : state.outgoing[index].frontier?.consistency == .unavailable ? .sentUnconfirmed : .awaitingReceipt) : .unconfirmed
        }
        threads[lease.threadID] = state
    }

    private func reconcileOutgoing(_ state: inout ThreadState, sequenceByID: [String: UInt64]) {
        let held = state.ingestionWindow == nil ? state.messages : state.ingestionHeadMessages
        // The prompt that opened a transcript this thread holds from its
        // first record, when it is the only one so far.
        let heldFromStart = state.ingestionWindow.map { $0.head?.hasOlder == false } ?? !state.hasMore
        let prompts = held.filter { $0.role == .user }
        let openingPromptID = heldFromStart && prompts.count == 1 ? prompts[0].recordID : nil
        for message in held where message.role == .user {
            guard let sequence = sequenceByID[message.recordID] else { continue }
            let sourceKey = state.sourceIdentity.map(Self.sourceFileKey)
            if state.lastOutgoingReceiptSourceKey == sourceKey,
               let last = state.lastOutgoingReceiptSequence, sequence <= last { continue }
            let claimed = state.outgoing.compactMap(\.matchedReceipt)
            guard let index = state.outgoing.firstIndex(where: {
                // The transcript belongs to this conversation, not to a route.
                // A write the terminal acknowledged is settled by its record
                // even after the thread was rebound (a reconnect, or a new
                // conversation handing the pane back); a send whose write was
                // never acknowledged still needs its own route.
                guard $0.dispatched, !$0.observationalMatch,
                      $0.binding == state.binding || $0.terminalAcknowledged,
                      AgentTextInsertion.matchesReceipt(provider: state.summary.id.providerID.rawValue,
                        text: $0.message.text, blocks: message.blocks) else { return false }
                if let frontier = $0.frontier, frontier.consistency == .unavailable {
                    // No source frontier: the transcript did not exist yet
                    // (a conversation's first prompt), OpenCode, or the host
                    // did not answer in time. An acknowledged write is
                    // matched, advisorily, by a newer record than any the
                    // thread held at its ACK in the same source and reader.
                    // Without a source then, only the prompt that opens the
                    // transcript is: older history may repeat the text, and
                    // another source cannot be ordered against the write.
                    guard $0.terminalAcknowledged,
                          let received = (state.ingestionWindow?.head?.records ?? state.records).first(where: { $0.recordID == message.recordID }),
                          !claimed.contains(Self.receiptClaimKey(received, in: state)) else { return false }
                    guard let before = $0.preDispatchSourceKey else { return message.recordID == openingPromptID }
                    guard before == sourceKey, $0.preDispatchEpoch == state.ingestionEpoch else { return false }
                    // A reader emptied by eviction knows nothing; one that
                    // loaded an empty transcript knows every record is new.
                    guard let baseline = $0.preDispatchSequence else { return $0.heldNothing }
                    return sequence > baseline
                }
                if let frontier = $0.frontier {
                    // The physical offset is the file's, whichever reader or
                    // chain generation holds it now.
                    guard $0.terminalAcknowledged, frontier.consistency == .observedPrefix,
                          let received = (state.ingestionWindow?.head?.records ?? state.records).first(where: { $0.recordID == message.recordID }),
                          received.receiptSourceIdentity == frontier.sourceIdentity,
                          let offset = received.receiptSourceOffset, let end = frontier.sourceEnd else { return false }
                    return offset >= end && ($0.preAcknowledgmentPhysicalOffset.map { offset > $0 } ?? true)
                        && !claimed.contains(Self.receiptClaimKey(received, in: state))
                }
                if $0.preDispatchSourceKey == sourceKey, let before = $0.preDispatchSequence, sequence <= before { return false }
                guard let boundary = $0.boundary,
                      Self.sourceFileKey(boundary.sourceIdentity) == state.sourceIdentity.map(Self.sourceFileKey),
                      AgentTextInsertion.matchesReceipt(provider: state.summary.id.providerID.rawValue,
                        text: $0.message.text, blocks: message.blocks) else { return false }
                if let epoch = boundary.summary?.objectValue?["nativeReceiptEpoch"]?.stringValue {
                    guard epoch == state.ingestionEpoch else { return false }
                    if AgentIngestionSourceIdentity.file(boundary.sourceIdentity) {
                        let received = (state.ingestionWindow?.head?.records ?? state.records).first { $0.recordID == message.recordID }
                        let offset = AgentIngestionSourceIdentity.indexedFile(boundary.sourceIdentity) ? received?.sourceOffset : sequence
                        guard let raw = boundary.summary?.objectValue?["nativeReceiptSourceEnd"]?.stringValue,
                              let end = UInt64(raw), offset.map({ $0 >= end }) == true else { return false }
                    }
                    guard let anchor = boundary.records.last else { return true }
                    return sequence > anchor.sequence && (state.ingestionWindow?.head?.records ?? state.records).contains {
                        $0.recordID == anchor.recordID && $0.sequence == anchor.sequence && $0.revision >= anchor.revision
                    }
                }
                if let value = boundary.summary?.objectValue?["receiptByteOffset"]?.stringValue {
                    guard let offset = UInt64(value),
                          let received = state.records.first(where: { $0.recordID == message.recordID }),
                          let receivedOffset = received.sourceOffset, receivedOffset >= offset else { return false }
                    guard let anchor = boundary.records.last else { return offset == 0 }
                    return state.records.contains { $0.sourceOffset == anchor.sourceOffset && $0.sourceHash != nil && $0.sourceHash == anchor.sourceHash && $0.record == anchor.record }
                }
                guard let anchor = boundary.records.last else { return true }
                return sequence > anchor.sequence && state.records.contains { $0.sequence == anchor.sequence && $0.record == anchor.record }
            }) else { continue }
            if state.outgoing[index].frontier != nil {
                // Even a later full scan cannot upgrade portable EOF/text
                // evidence into causal proof after truncation or other writes.
                state.outgoing[index].observationalMatch = true
                if let received = (state.ingestionWindow?.head?.records ?? state.records).first(where: { $0.recordID == message.recordID }) {
                    state.outgoing[index].matchedReceipt = Self.receiptClaimKey(received, in: state)
                }
                if state.outgoing[index].terminalAcknowledged { state.outgoing[index].message.status = .observed }
            } else { state.outgoing.remove(at: index) }
            state.lastOutgoingReceiptSequence = sequence
            state.lastOutgoingReceiptSourceKey = sourceKey
        }
    }

    private static func receiptClaimKey(_ record: AgentProjectionRecord, in state: ThreadState) -> String {
        if let identity = record.receiptSourceIdentity, let offset = record.receiptSourceOffset { return "\(identity)@\(offset)" }
        // Length prefixes separate opaque IDs; the terminator distinguishes
        // this key from physical keys, which always end in a decimal offset.
        return "record:" + [state.sourceIdentity.map(sourceFileKey) ?? "", state.ingestionEpoch ?? "", record.recordID]
            .map { "\($0.utf8.count):\($0)" }.joined() + ";"
    }

    private static func sourceFileKey(_ identity: String) -> String {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        let database = identity.split(separator: ";").first?.split(separator: ":") ?? []
        if database.count == 6, database[1] == "db",
           database.dropFirst(2).allSatisfy({ UInt64($0, radix: 16) != nil }) { return database.prefix(4).joined(separator: ":") }
        // Projector identities for JSONL sources are dev:inode:size:mtime.
        // SQLite aggregate identities remain opaque and fail closed on change.
        if parts.count == 4, parts.allSatisfy({ UInt64($0, radix: 16) != nil }) { return parts.prefix(2).joined(separator: ":") }
        if parts.count == 5, parts.first == "pi" || parts.first == "codex-images1", parts.dropFirst().allSatisfy({ UInt64($0, radix: 16) != nil }) { return parts.prefix(3).joined(separator: ":") }
        return identity
    }

    private func touch(_ state: inout ThreadState) {
        accessOrdinal &+= 1
        state.lastAccessOrdinal = accessOrdinal
    }

    private func enforceCacheLimits(excluding selected: AgentThreadID?) {
        for id in threads.keys {
            guard var state = threads[id], state.estimatedContentBytes > budget.perThreadBytes else { continue }
            // Window admission owns whole segments and their recovery cursors.
            // Never partially prune an acknowledged segment in a cache sweep.
            if state.ingestionWindow != nil { continue }
            while state.estimatedContentBytes > budget.perThreadBytes {
                if state.records.isEmpty {
                    guard !state.activity.isEmpty || !state.changes.edits.isEmpty else { break }
                    if !state.activity.isEmpty {
                        let removed = state.activity.removeFirst()
                        state.projectionActivityByRecordID = state.projectionActivityByRecordID
                            .filter { $0.value != removed.id }
                    }
                    else { state.changes.edits.removeFirst() }
                    state.estimatedContentBytes = Self.estimatedBytes(state)
                    continue
                }
                // Prune a proportional batch, then recompute once. Encoding
                // the entire multi-megabyte cache for each removed record
                // turns one bounded page into quadratic allocation/work.
                let excess = state.estimatedContentBytes - budget.perThreadBytes
                let average = max(1, state.estimatedContentBytes / state.records.count)
                let count = min(state.records.count, max(1, (excess + average - 1) / average))
                state.records.removeFirst(count)
                pruneDerivedProjectionContent(&state)
            }
            threads[id] = state
        }
        while threads.values.reduce(0, { $0 + $1.estimatedContentBytes }) > budget.globalBytes {
            guard let victim = threads.filter({ entry in
                entry.key != selected && (!entry.value.records.isEmpty || !entry.value.activity.isEmpty ||
                    !entry.value.changes.edits.isEmpty || !entry.value.outgoing.isEmpty || entry.value.hookOverlay.preview != nil)
            }).min(by: { $0.value.lastAccessOrdinal < $1.value.lastAccessOrdinal })?.key,
                  var state = threads[victim] else { break }
            let before = state.estimatedContentBytes
            if state.ingestionWindow != nil { ingestionEvictions.insert(victim) }
            evictThreadContent(&state)
            threads[victim] = state
            guard state.estimatedContentBytes < before else { break }
        }
    }

    // A same-source bootstrap replaces the viewport, not a resolved title.
    // Its external summary arrives separately; clearing the title in between
    // publishes a visible native -> prompt -> native flash on both platforms.
    // Source replacement and conformance retirement retain the strict default.
    private func clearProjectionContent(_ state: inout ThreadState, for threadID: AgentThreadID,
                                        preservingTitle: Bool = false, preservingOpeningPrompt: Bool = false) {
        // A same-source bootstrap replaces only the viewport. Source changes,
        // retirement and cache eviction must discard the old opening prompt.
        // A seed is only ever the opening prompt (supplied, or read once the
        // loaded pages reached the thread's start), and a newest-first
        // bootstrap cannot rediscover it, so the same source keeps it too.
        let openingPrompt = preservingOpeningPrompt ? state.openingPrompt : nil
        let titleSeed = preservingOpeningPrompt ? state.summary.titleSeed : nil
        clearCachedProjectionContent(&state)
        state.openingPrompt = openingPrompt
        state.cursor = nil
        state.hasMore = false
        if let pinnedTitle = metadataByThreadID[threadID]?.pinnedTitle {
            applyPinnedTitle(pinnedTitle, to: &state)
        } else if !preservingTitle {
            state.summary.title = state.summary.providerName
            state.summary.titleProvenance = .placeholder
            state.summary.titleSeed = nil
            if let titleSeed {
                state.summary.titleSeed = titleSeed
                applyTitle(Self.clipTitleSeed(titleSeed, budget: titleCharacterBudget), provenance: .prompt, to: &state)
            }
        }
        state.summary.model = nil
        state.summary.projectBasename = nil
        state.summary.branch = nil
        state.summary.preview = nil
        state.summary.cost = .init()
        state.summary.context = .init()
        state.summary.queuedMessageCount = 0
        state.summary.permissionMode = .unavailable
        state.summary.lastActivitySequence = state.lastLifecycleSequence ?? 0
        state.summary.lastActivity = nil
        state.estimatedContentBytes = Self.estimatedBytes(state)
    }

    /// Cache eviction intentionally preserves the summary, read marker, and
    /// cursor. Source replacement above is stricter because its old summary is
    /// itself transcript-derived provider projection.
    private func clearCachedProjectionContent(_ state: inout ThreadState) {
        state.hookOverlay.reset()
        let projectionActivityIDs = Set(state.projectionActivityByRecordID.values)
        state.records = []
        state.ingestionEpoch = nil
        state.ingestionWindow = nil
        state.ingestionHeadMessages = []
        state.viewportAnchorRecordID = nil
        state.liveCursor = nil
        state.ingestionTransactions = []
        state.ingestionLastWindowPage = nil
        state.ingestionLastWindowPageBytes = 0
        state.ingestionOlderPageCost = 0; state.ingestionOlderRefusedBytes = nil
        state.normalizedRecords = [:]
        state.metadataOrders = [:]
        state.openingPrompt = nil
        state.messages = []
        // Eviction, memory warnings and disable purge the derived copy too.
        state.presentationSource = []
        state.presentationMessages = []
        state.turns = []
        state.activity.removeAll { projectionActivityIDs.contains($0.id) }
        state.projectionActivityByRecordID = [:]
        state.changes = .init()
        state.estimatedContentBytes = Self.estimatedBytes(state)
    }

    private func evictThreadContent(_ state: inout ThreadState) {
        // Memory pressure cannot turn an uncertain send into an absent send.
        // Preserve the bounded receipt fence and surface uncertainty instead.
        Self.unsettleOutgoing(&state)
        clearCachedProjectionContent(&state)
        // Activity is display cache, not durable metadata. Dropping it on a
        // global eviction guarantees progress even if lifecycle churn alone
        // filled the process-wide budget.
        state.activity = []
        state.estimatedContentBytes = Self.estimatedBytes(state)
    }

    private func pruneDerivedProjectionContent(_ state: inout ThreadState) {
        let retainedRecordIDs = Set(state.records.map(\.recordID))
        state.messages.removeAll { !retainedRecordIDs.contains($0.recordID) }
        // A window's head records live outside `records`; rebuild prunes its cache.
        if state.ingestionWindow == nil {
            state.normalizedRecords = state.normalizedRecords.filter { retainedRecordIDs.contains($0.key) }
        }
        let removedActivityIDs = Set(state.projectionActivityByRecordID
            .filter { !retainedRecordIDs.contains($0.key) }
            .map(\.value))
        state.activity.removeAll { removedActivityIDs.contains($0.id) }
        state.projectionActivityByRecordID = state.projectionActivityByRecordID
            .filter { retainedRecordIDs.contains($0.key) }
        state.changes.edits.removeAll { !retainedRecordIDs.contains($0.id) }
        state.turns = Self.makeTurns(records: state.records, messages: state.messages)
        state.estimatedContentBytes = Self.estimatedBytes(state)
    }

    private static func summaryBytes(_ summary: AgentThreadSummary) -> Int {
        (try? JSONEncoder().encode(summary))?.count ?? 0
    }

    private static func windowPresentationBytes(_ state: ThreadState) -> Int {
        let messages = state.summary.id.providerID == .codex ? AgentCodexTranscriptContent.presentationMessages(state.messages) : state.messages
        // Bounded platforms receive messages without the duplicate `turns`.
        let snapshot = AgentThreadSnapshot(summary: state.summary, messages: messages,
            turns: [], activity: state.activity, changes: state.changes,
            lineage: state.lineage, cursor: state.cursor, hasMore: state.hasMore, binding: state.binding,
            outgoingMessages: state.outgoing.map(\.message), livePreview: state.hookOverlay.preview)
        let encoder = JSONEncoder()
        return ((try? encoder.encode(snapshot).count) ?? Int.max / 4) +
            ((try? encoder.encode(AgentTranscriptGrouping.toolRunDescriptors(messages)).count) ?? Int.max / 4) + 65_536
    }

    /// Each retained record and derived row is counted once, from sizes
    /// measured when its revision was normalized. Turns only reference the
    /// same messages, and a window's viewport records are `state.records`.
    private static func estimatedBytes(_ state: ThreadState) -> Int {
        let encoder = JSONEncoder()
        func encoded<T: Encodable>(_ value: T) -> Int { (try? encoder.encode(value))?.count ?? 0 }
        let cache = state.normalizedRecords
        let records = state.ingestionWindow?.encodedBytes ??
            state.records.reduce(0) { $0 + (cache[$1.recordID]?.recordBytes ?? encoded($1)) }
        let messages = state.messages.reduce(0) { $0 + (cache[$1.recordID]?.messageBytes ?? encoded($1)) }
        let headMessages = state.ingestionHeadMessages.reduce(0) { $0 + (cache[$1.recordID]?.messageBytes ?? encoded($1)) }
        let projectionActivity = Set(state.projectionActivityByRecordID.values)
        let activity = state.projectionActivityByRecordID.keys.reduce(0) { $0 + (cache[$1]?.activityBytes ?? 256) } +
            encoded(state.activity.filter { !projectionActivity.contains($0.id) })
        let edits = state.changes.edits.reduce(0) { $0 + (cache[$1.id]?.editBytes ?? encoded($1)) }
        let summary = encoded(state.summary) + encoded(state.changes.authoritativeTotals)
        let outgoing = encoded(state.outgoing.map(\.message))
        let boundaries = state.outgoing.reduce(0) { $0 + encoded($1.boundary) +
            encoded($1.frontier) + ($1.preDispatchSourceKey?.utf8.count ?? 0) + 64 }
        return records + messages + headMessages + activity + edits + summary + outgoing + boundaries +
            state.hookOverlay.estimatedBytes + (state.ingestionLastWindowPage == nil ? 0 : state.ingestionLastWindowPageBytes)
    }

    static func searchText(_ block: AgentBlock) -> String? {
        switch block {
        case .text(let value), .thinking(let value), .queuedMessage(let value), .workflow(let value), .systemEvent(let value), .compactSummary(let value): return value
        case .toolCall(let name, let preview): return "\(name)\n\(preview)"
        case .toolResult(let preview, _): return preview
        case .edit(let path, let diff): return [path, diff].compactMap { $0 }.joined(separator: "\n")
        case .permission(let title), .question(let title): return title
        case .completion(let summary): return summary
        case .attachment(let name, _): return name
        case .actionPrompt(let prompt): return ([prompt.title, prompt.detail] + prompt.options.map(\.label)).compactMap { $0 }.joined(separator: "\n")
        case .workflowTasks(let tasks): return tasks.map { "\($0.title) \($0.owner ?? "")" }.joined(separator: "\n")
        case .subagent(let agentID, let agentType): return "\(agentID) \(agentType ?? "")"
        case .subagentGroup(let agents): return agents.map { "\($0.id) \($0.type ?? "") \($0.summary ?? "")" }.joined(separator: "\n")
        case .unknown(let type): return type
        }
    }

    private static func makeTurns(records: [AgentProjectionRecord], messages: [AgentMessage]) -> [AgentTurn] {
        guard let first = records.first?.sequence, let last = records.last?.sequence else { return [] }
        return [.init(id: "turn-\(first)-\(last)", firstSequence: first, lastSequence: last, state: .completed, messages: messages)]
    }

    private static func reidentified(_ summary: AgentThreadSummary, as id: AgentThreadID) -> AgentThreadSummary {
        .init(
            id: id,
            title: summary.title,
            providerName: summary.providerName,
            model: summary.model,
            projectBasename: summary.projectBasename,
            branch: summary.branch,
            hostDisplayLabel: summary.hostDisplayLabel,
            permissionMode: summary.permissionMode,
            status: summary.status,
            attention: summary.attention,
            lastActivitySequence: summary.lastActivitySequence,
            lastActivity: summary.lastActivity,
            preview: summary.preview,
            cost: summary.cost,
            context: summary.context,
            queuedMessageCount: summary.queuedMessageCount,
            isFork: summary.isFork,
            availability: summary.availability
        )
    }
}
