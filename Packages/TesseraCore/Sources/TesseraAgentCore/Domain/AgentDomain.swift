import Foundation

public struct AgentProviderID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64,
              trimmed.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
              })
        else { return nil }
        self.rawValue = trimmed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public static let claude = AgentProviderID(rawValue: "claude")!
    public static let codex = AgentProviderID(rawValue: "codex")!
    public static let opencode = AgentProviderID(rawValue: "opencode")!
    public static let pi = AgentProviderID(rawValue: "pi")!
    public static let kimi = AgentProviderID(rawValue: "kimi")!
    public static let custom = AgentProviderID(rawValue: "custom")!

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        guard let validated = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(forKey: .rawValue, in: container, debugDescription: "Invalid provider identifier")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public struct AgentThreadID: Hashable, Codable, Sendable {
    public let hostID: UUID
    public let providerID: AgentProviderID
    public let providerSessionID: String

    public init?(hostID: UUID, providerID: AgentProviderID, providerSessionID: String) {
        let value = providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        self.hostID = hostID
        self.providerID = providerID
        self.providerSessionID = value
    }

    private enum CodingKeys: String, CodingKey { case hostID, providerID, providerSessionID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hostID = try container.decode(UUID.self, forKey: .hostID)
        let providerID = try container.decode(AgentProviderID.self, forKey: .providerID)
        let providerSessionID = try container.decode(String.self, forKey: .providerSessionID)
        guard let validated = Self(hostID: hostID, providerID: providerID, providerSessionID: providerSessionID) else {
            throw DecodingError.dataCorruptedError(forKey: .providerSessionID, in: container, debugDescription: "Invalid provider session identifier")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(providerSessionID, forKey: .providerSessionID)
    }
}

public struct AgentSourceCandidateID: Hashable, Codable, Sendable {
    public let hostID: UUID
    public let providerID: AgentProviderID
    public let sourceIdentity: String

    public init?(hostID: UUID, providerID: AgentProviderID, sourceIdentity: String) {
        guard !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 512 else { return nil }
        self.hostID = hostID
        self.providerID = providerID
        self.sourceIdentity = sourceIdentity
    }
}

public struct AgentIncarnationToken: Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 256 else { return nil }
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        guard let validated = Self(rawValue) else {
            throw DecodingError.dataCorruptedError(forKey: .rawValue, in: container, debugDescription: "Invalid incarnation token")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public enum AgentTransportKind: String, Codable, Sendable {
    case ssh
    case sshTmux
    case mosh
    case moshTmux
}

public struct AgentTerminalCapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let observe = Self(rawValue: 1 << 0)
    public static let send = Self(rawValue: 1 << 1)
    public static let interrupt = Self(rawValue: 1 << 2)
    public static let promptAnswer = Self(rawValue: 1 << 3)
    public static let tmux = Self(rawValue: 1 << 4)
}

public struct AgentTerminalBinding: Equatable, Codable, Sendable {
    public let liveSessionID: UUID
    public let carrierGeneration: UInt64
    public let incarnation: AgentIncarnationToken
    public let transport: AgentTransportKind
    public let tmuxSession: String?
    public let windowID: String?
    public let paneID: String?
    public let agentPID: Int?
    public let capabilities: AgentTerminalCapabilities

    public init(
        liveSessionID: UUID,
        carrierGeneration: UInt64,
        incarnation: AgentIncarnationToken,
        transport: AgentTransportKind,
        tmuxSession: String? = nil,
        windowID: String? = nil,
        paneID: String? = nil,
        agentPID: Int? = nil,
        capabilities: AgentTerminalCapabilities
    ) {
        self.liveSessionID = liveSessionID
        self.carrierGeneration = carrierGeneration
        self.incarnation = incarnation
        self.transport = transport
        self.tmuxSession = tmuxSession
        self.windowID = windowID
        self.paneID = paneID
        self.agentPID = agentPID
        self.capabilities = capabilities
    }

    public var hasCurrentTmuxTarget: Bool {
        capabilities.contains(.tmux) && tmuxSession != nil && (windowID != nil || paneID != nil)
    }
}

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case unavailable
    case idle
    case working
    case waitingForInput
    case finished
}

public enum AgentAttention: String, Codable, Sendable {
    case none
    case needsYou
    case unreadCompletion
}

public enum AgentPermissionMode: String, Codable, Sendable {
    case defaultMode
    case plan
    case auto
    case readOnly
    case unavailable
}

public struct AgentContextSummary: Equatable, Codable, Sendable {
    public var usedTokens: Int?
    public var maximumTokens: Int?
    public var percentUsed: Double?

    public init(usedTokens: Int? = nil, maximumTokens: Int? = nil, percentUsed: Double? = nil) {
        self.usedTokens = usedTokens
        self.maximumTokens = maximumTokens
        self.percentUsed = percentUsed.map { min(max($0, 0), 100) }
    }
}

public enum AgentAvailabilityReason: String, Codable, Sendable {
    case unsupported
    case integrationOutdated
    case channelUnavailable
    case hostAccessRequired
    case staleBinding
    case disabled
}

public struct AgentAvailability: Equatable, Codable, Sendable {
    public var content: Bool
    public var status: Bool
    public var actions: Bool
    public var spawn: Bool
    public var fork: Bool
    public var search: Bool
    public var reason: AgentAvailabilityReason?

    public init(content: Bool, status: Bool, actions: Bool, spawn: Bool, fork: Bool, search: Bool, reason: AgentAvailabilityReason? = nil) {
        self.content = content
        self.status = status
        self.actions = actions
        self.spawn = spawn
        self.fork = fork
        self.search = search
        self.reason = reason
    }
}

public enum AgentRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
    case unknown
}

public enum AgentBlock: Equatable, Codable, Sendable {
    case text(String)
    case thinking(String)
    case toolCall(name: String, preview: String)
    case toolResult(preview: String, truncated: Bool)
    case edit(path: String?, diff: String?)
    case permission(title: String)
    case question(title: String)
    case queuedMessage(String)
    case workflow(String)
    case subagent(agentID: String, agentType: String?)
    case systemEvent(String)
    /// The summary Claude replays after compacting a conversation. It is
    /// provider-authored continuation context, not something the human typed,
    /// so it renders as its own boundary marker rather than a user message.
    case compactSummary(String)
    case completion(String?)
    case attachment(name: String, mediaType: String?)
    case actionPrompt(AgentActionPrompt)
    case workflowTasks([AgentWorkflowTask])
    case subagentGroup([AgentSubagentSummary])
    case unknown(type: String)

    public static let shortenedPreviewNotice = AgentBlock.systemEvent("Shortened preview · some content is omitted")
}

public struct AgentPromptOption: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// The row carries the TUI's selection marker.
    public let isDefault: Bool
    /// Live prompts only: the row's description line.
    public let detail: String?
    /// Live prompts only; nil reads as `.choice`.
    public let role: AgentPromptOptionRole?
    /// A multi-select row's check box; nil for other rows.
    public let isChecked: Bool?
    /// Typed text answers through this row (live prompts only).
    public let acceptsText: Bool?

    public init(id: String, label: String, isDefault: Bool = false, detail: String? = nil,
                role: AgentPromptOptionRole? = nil, isChecked: Bool? = nil, acceptsText: Bool? = nil) {
        self.id = String(id.prefix(64))
        self.label = String(AgentDisplayText.sanitize(label).prefix(512))
        self.isDefault = isDefault
        self.detail = detail.map { String(AgentDisplayText.sanitize($0).prefix(1_024)) }.flatMap { $0.isEmpty ? nil : $0 }
        self.role = role
        self.isChecked = isChecked
        self.acceptsText = acceptsText
    }
}

public struct AgentActionToken: Hashable, Codable, Sendable {
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 512 else { return nil }
        self.rawValue = rawValue
    }
}

public struct AgentActionPrompt: Equatable, Codable, Sendable {
    public let title: String
    public let detail: String?
    public let options: [AgentPromptOption]
    public let token: AgentActionToken
    /// The fields below describe a live terminal prompt; transcript prompts
    /// leave them nil. `kind` nil reads as `.permission`.
    public let kind: AgentPromptKind?
    /// The question itself ("Which database should we use?").
    public let question: String?
    /// "1 of 2", "Question 1/1", or the question tabs.
    public let progress: String?
    public let controls: [AgentPromptControl]?
    /// The text field that has focus in the terminal, and what it shows.
    public let entry: AgentPromptEntry?
    /// Typed text can answer this prompt.
    public let acceptsText: Bool?
    /// The agent waits on this prompt; false for Codex's async questions.
    public let isBlocking: Bool?
    /// Codex's collapsed async summary: how many questions wait.
    public let pendingCount: Int?

    public init(title: String, detail: String? = nil, options: [AgentPromptOption], token: AgentActionToken,
                kind: AgentPromptKind? = nil, question: String? = nil, progress: String? = nil,
                controls: [AgentPromptControl]? = nil, entry: AgentPromptEntry? = nil, acceptsText: Bool? = nil,
                isBlocking: Bool? = nil, pendingCount: Int? = nil) {
        self.title = String(AgentDisplayText.sanitize(title).prefix(512))
        self.detail = detail.map { String(AgentDisplayText.sanitize($0).prefix(16_384)) }
        self.options = Array(options.prefix(9))
        self.token = token
        self.kind = kind
        self.question = question.map { String(AgentDisplayText.sanitize($0).prefix(2_048)) }
        self.progress = progress.map { String(AgentDisplayText.sanitize($0).prefix(256)) }
        self.controls = controls.map { Array($0.prefix(4)) }
        self.entry = entry.map { .init(optionID: $0.optionID, text: AgentDisplayText.sanitize($0.text)) }
        self.acceptsText = acceptsText
        self.isBlocking = isBlocking
        self.pendingCount = pendingCount
    }
}

public struct AgentWorkflowTask: Equatable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, working, completed, failed }
    public let id: String
    public let title: String
    public let owner: String?
    public let state: State

    public init(id: String, title: String, owner: String? = nil, state: State) {
        self.id = String(id.prefix(512))
        self.title = String(AgentDisplayText.sanitize(title).prefix(512))
        self.owner = owner.map { String(AgentDisplayText.sanitize($0).prefix(128)) }
        self.state = state
    }
}

public struct AgentSubagentSummary: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let type: String?
    public let summary: String?
    public let status: AgentStatus
    public let threadID: AgentThreadID?

    public init(id: String, type: String? = nil, summary: String? = nil, status: AgentStatus, threadID: AgentThreadID? = nil) {
        self.id = String(id.prefix(256))
        self.type = type.map { String(AgentDisplayText.sanitize($0).prefix(128)) }
        self.summary = summary.map { String(AgentDisplayText.sanitize($0).prefix(1_024)) }
        self.status = status
        self.threadID = threadID
    }
}

public struct AgentMessage: Equatable, Codable, Sendable {
    public let recordID: String
    public let role: AgentRole
    public let displayTime: Date?
    public let blocks: [AgentBlock]

    public init(recordID: String, role: AgentRole, displayTime: Date?, blocks: [AgentBlock]) {
        self.recordID = recordID
        self.role = role
        self.displayTime = displayTime
        self.blocks = blocks
    }
}

public struct AgentTurn: Equatable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, working, completed, interrupted, failed }
    public let id: String
    public let firstSequence: UInt64
    public let lastSequence: UInt64
    public let state: State
    public let startedAt: Date?
    public let completedAt: Date?
    public let messages: [AgentMessage]

    public init(id: String, firstSequence: UInt64, lastSequence: UInt64, state: State, startedAt: Date? = nil, completedAt: Date? = nil, messages: [AgentMessage]) {
        self.id = String(id.prefix(512))
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.messages = messages
    }
}

public struct AgentActivityEvent: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case lifecycle, message, tool, permission, workflow, subagent, completion, system }
    public let id: String
    public let sequence: UInt64
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let displayTime: Date?

    public init(id: String, sequence: UInt64, kind: Kind, title: String, detail: String? = nil, displayTime: Date? = nil) {
        self.id = String(id.prefix(512))
        self.sequence = sequence
        self.kind = kind
        self.title = String(AgentDisplayText.sanitize(title).prefix(512))
        self.detail = detail.map { String(AgentDisplayText.sanitize($0).prefix(16_384)) }
        self.displayTime = displayTime
    }
}

public struct AgentEditRecord: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let path: String?
    public let additions: Int?
    public let deletions: Int?
    public let diff: String?

    public init(id: String, path: String? = nil, additions: Int? = nil, deletions: Int? = nil, diff: String? = nil) {
        self.id = String(id.prefix(512))
        self.path = path.map { String(AgentDisplayText.sanitize($0).prefix(2_048)) }
        self.additions = additions
        self.deletions = deletions
        self.diff = diff.map { String(AgentDisplayText.sanitize($0).prefix(65_536)) }
    }
}

public struct AgentChangeSummary: Equatable, Codable, Sendable {
    public var authoritativeTotals: AgentCostSummary
    public var edits: [AgentEditRecord]
    public init(authoritativeTotals: AgentCostSummary = .init(), edits: [AgentEditRecord] = []) {
        self.authoritativeTotals = authoritativeTotals
        self.edits = edits
    }
}

public struct AgentLaunchReceiptMetadata: Equatable, Codable, Sendable {
    public let receiptID: String
    public let createdAt: Date
    public let placement: String

    public init(receiptID: String, createdAt: Date, placement: String) {
        self.receiptID = String(receiptID.prefix(512))
        self.createdAt = createdAt
        self.placement = String(placement.prefix(512))
    }
}

public struct AgentThreadLineage: Equatable, Codable, Sendable {
    public let parentThreadID: AgentThreadID?
    public let sourceTurnID: String?
    public let sourceRecordID: String?
    public let creationReceipt: AgentLaunchReceiptMetadata?
    public var childThreadIDs: [AgentThreadID]

    public init(parentThreadID: AgentThreadID? = nil, sourceTurnID: String? = nil, sourceRecordID: String? = nil, creationReceipt: AgentLaunchReceiptMetadata? = nil, childThreadIDs: [AgentThreadID] = []) {
        self.parentThreadID = parentThreadID
        self.sourceTurnID = sourceTurnID
        self.sourceRecordID = sourceRecordID
        self.creationReceipt = creationReceipt
        self.childThreadIDs = childThreadIDs
    }
}

public struct AgentCostSummary: Equatable, Codable, Sendable {
    public var totalCost: Decimal?
    public var durationSeconds: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?

    public init(totalCost: Decimal? = nil, durationSeconds: Double? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil) {
        self.totalCost = totalCost
        self.durationSeconds = durationSeconds
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }
}

/// Where a thread title came from, ordered weakest to strongest.
///
/// Titles arrive from several places and out of order, so the winner cannot be
/// "whatever wrote last". A thread can gain a native title pages after the
/// first user prompt has already produced a fallback, and an on-device summary
/// can land after either. Every write compares provenance first, so a weaker
/// source can never replace a stronger one.
public enum AgentTitleProvenance: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Nothing but the provider display name.
    case placeholder = 0
    /// The opening user prompt, clipped to the reader's character budget.
    case prompt = 1
    /// An on-device model summarised the opening prompt.
    case generated = 2
    /// The agent wrote this title itself.
    case native = 3
    /// The reader renamed the thread. Nothing outranks a human.
    case pinned = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thread whose title would improve if the platform summarised `seed`
/// with its on-device model.
public struct AgentTitleGenerationRequest: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    /// The opening user prompt, already collapsed to one line.
    public let seed: String

    public init(threadID: AgentThreadID, seed: String) {
        self.threadID = threadID
        self.seed = seed
    }
}

public struct AgentThreadSummary: Equatable, Codable, Sendable {
    public let id: AgentThreadID
    public var title: String
    /// The strongest source that has written `title` so far.
    public var titleProvenance: AgentTitleProvenance
    /// The opening user prompt, bounded. Material for the two fallback
    /// tiers: a platform summarises it on device, and Core clips it when
    /// no summary is available.
    public var titleSeed: String?
    public var providerName: String
    public var model: String?
    public var projectBasename: String?
    public var branch: String?
    public var hostDisplayLabel: String
    public var permissionMode: AgentPermissionMode
    public var status: AgentStatus
    public var attention: AgentAttention
    public var lastActivitySequence: UInt64
    public var lastActivity: Date?
    public var preview: String?
    public var cost: AgentCostSummary
    public var context: AgentContextSummary
    public var queuedMessageCount: Int
    public var isFork: Bool
    public var availability: AgentAvailability
    /// Core wants the platform to keep capturing this thread's terminal for a
    /// live prompt: it waits for input, a question tool is open, or a prompt
    /// is on screen. Nil reads as false.
    public var livePromptWatch: Bool? = nil

    public init(id: AgentThreadID, title: String = "Untitled", titleProvenance: AgentTitleProvenance = .placeholder, titleSeed: String? = nil, providerName: String, model: String? = nil, projectBasename: String? = nil, branch: String? = nil, hostDisplayLabel: String = "", permissionMode: AgentPermissionMode = .unavailable, status: AgentStatus = .unavailable, attention: AgentAttention = .none, lastActivitySequence: UInt64 = 0, lastActivity: Date? = nil, preview: String? = nil, cost: AgentCostSummary = .init(), context: AgentContextSummary = .init(), queuedMessageCount: Int = 0, isFork: Bool = false, availability: AgentAvailability) {
        self.id = id
        self.title = AgentDisplayText.sanitize(title)
        self.titleProvenance = titleProvenance
        self.titleSeed = titleSeed.map(AgentDisplayText.sanitize)
        self.providerName = AgentDisplayText.sanitize(providerName)
        self.model = model.map(AgentDisplayText.sanitize)
        self.projectBasename = projectBasename.map(AgentDisplayText.sanitize)
        self.branch = branch.map(AgentDisplayText.sanitize)
        self.hostDisplayLabel = AgentDisplayText.sanitize(hostDisplayLabel)
        self.permissionMode = permissionMode
        self.status = status
        self.attention = attention
        self.lastActivitySequence = lastActivitySequence
        self.lastActivity = lastActivity
        self.preview = preview.map(AgentDisplayText.sanitize)
        self.cost = cost
        self.context = context
        self.queuedMessageCount = queuedMessageCount
        self.isFork = isFork
        self.availability = availability
    }
}

/// Local, ephemeral send intent. Terminal delivery and transcript evidence are
/// distinct: an observed portable-file match never proves causal receipt.
public struct AgentOutgoingMessage: Equatable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case sending, queueing, awaitingReceipt, observed, sentUnconfirmed, unconfirmed }
    public let id: UUID
    public let text: String
    public var status: Status
    public init(id: UUID, text: String, status: Status) {
        self.id = id; self.text = text; self.status = status
    }
}

public struct AgentThreadSnapshot: Equatable, Codable, Sendable {
    public let version: Int
    public let summary: AgentThreadSummary
    public let messages: [AgentMessage]
    public let turns: [AgentTurn]
    public let activity: [AgentActivityEvent]
    public let changes: AgentChangeSummary
    public let lineage: AgentThreadLineage?
    public let cursor: String?
    public let hasMore: Bool
    public let binding: AgentTerminalBinding?
    public let deliveryGeneration: UInt64
    /// Optional for backward-compatible decoding of older ABI snapshots.
    public let outgoingMessages: [AgentOutgoingMessage]?
    public let livePreview: AgentLivePreview?
    public let ingestionWindow: AgentIngestionWindowSnapshot?
    /// Advances only when the thread *enters* `needsYou` or
    /// `unreadCompletion`, unlike `deliveryGeneration`, which moves on every
    /// accepted frame. One OS alert per epoch; the reader's record-free
    /// completion acknowledgement is fenced by it too. Optional only for
    /// decoding older ABI snapshots.
    public let attentionEpoch: UInt64?
    /// Durable, content-free completion identities for the platform's
    /// metadata store: the completion still unread (nil once read or
    /// superseded) and the newest one the reader acknowledged.
    public let unreadCompletionKey: String?
    public let acknowledgedCompletionKey: String?
    /// The conversation ended in its process (SessionEnd, wrapper exit): it
    /// stays listed until its route retires, but takes no replies. Optional
    /// only for decoding older ABI snapshots.
    public let conversationEnded: Bool?

    public init(version: Int = 1, summary: AgentThreadSummary, messages: [AgentMessage], turns: [AgentTurn] = [], activity: [AgentActivityEvent] = [], changes: AgentChangeSummary = .init(), lineage: AgentThreadLineage? = nil, cursor: String?, hasMore: Bool, binding: AgentTerminalBinding?, deliveryGeneration: UInt64 = 0, outgoingMessages: [AgentOutgoingMessage]? = nil, livePreview: AgentLivePreview? = nil, ingestionWindow: AgentIngestionWindowSnapshot? = nil,
                attentionEpoch: UInt64? = nil, unreadCompletionKey: String? = nil, acknowledgedCompletionKey: String? = nil,
                conversationEnded: Bool? = nil) {
        self.version = version
        self.summary = summary
        self.messages = messages
        self.turns = turns
        self.activity = activity
        self.changes = changes
        self.lineage = lineage
        self.cursor = cursor
        self.hasMore = hasMore
        self.binding = binding
        self.deliveryGeneration = deliveryGeneration
        self.outgoingMessages = outgoingMessages
        self.livePreview = livePreview
        self.ingestionWindow = ingestionWindow
        self.attentionEpoch = attentionEpoch
        self.unreadCompletionKey = unreadCompletionKey
        self.acknowledgedCompletionKey = acknowledgedCompletionKey
        self.conversationEnded = conversationEnded
    }
}

public struct AgentCenterListSnapshot: Equatable, Codable, Sendable {
    public let version: Int
    public let threads: [AgentThreadSummary]
    public let candidates: [AgentTerminalCandidate]
    public let unavailableHostIDs: [UUID]
    public init(
        version: Int = 1,
        threads: [AgentThreadSummary],
        candidates: [AgentTerminalCandidate] = [],
        unavailableHostIDs: [UUID] = []
    ) {
        self.version = version
        self.threads = threads
        self.candidates = candidates
        self.unavailableHostIDs = unavailableHostIDs
    }

    private enum CodingKeys: String, CodingKey {
        case version, threads, candidates, unavailableHostIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        threads = try values.decode([AgentThreadSummary].self, forKey: .threads)
        candidates = try values.decodeIfPresent([AgentTerminalCandidate].self, forKey: .candidates) ?? []
        unavailableHostIDs = try values.decodeIfPresent([UUID].self, forKey: .unavailableHostIDs) ?? []
    }
}

public struct AgentFallbackSnapshot: Equatable, Codable, Sendable {
    public let status: AgentStatus
    public let location: String
    public let integrationAvailable: Bool
    public let liveTail: String
    public let prompt: AgentActionPrompt?
    public let binding: AgentTerminalBinding

    public init(status: AgentStatus, location: String, integrationAvailable: Bool, liveTail: String, prompt: AgentActionPrompt?, binding: AgentTerminalBinding) {
        self.status = status
        self.location = String(location.prefix(512))
        self.integrationAvailable = integrationAvailable
        self.liveTail = String(liveTail.prefix(16_384))
        self.prompt = prompt
        self.binding = binding
    }
}

/// A live terminal agent whose durable provider conversation identity is not
/// proven. It participates in the V2 list without fabricating an
/// `AgentThreadID` or claiming transcript history.
public struct AgentTerminalCandidate: Equatable, Codable, Sendable, Identifiable {
    public let id: AgentSourceCandidateID
    public let providerName: String
    public let title: String
    public let hostDisplayLabel: String
    public let lastActivity: Date?
    public let fallback: AgentFallbackSnapshot

    public init(
        id: AgentSourceCandidateID,
        providerName: String,
        title: String,
        hostDisplayLabel: String,
        lastActivity: Date? = nil,
        fallback: AgentFallbackSnapshot
    ) {
        self.id = id
        self.providerName = String(AgentDisplayText.sanitize(providerName).prefix(128))
        self.title = String(AgentDisplayText.sanitize(title).prefix(512))
        self.hostDisplayLabel = String(AgentDisplayText.sanitize(hostDisplayLabel).prefix(512))
        self.lastActivity = lastActivity
        self.fallback = fallback
    }
}

public struct AgentComposerState: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case send, queue, answer, unavailable }
    public let threadID: AgentThreadID
    public var draft: String
    public var mode: Mode
    public var isSending: Bool
    public var canInterrupt: Bool

    public init(threadID: AgentThreadID, draft: String = "", mode: Mode, isSending: Bool = false, canInterrupt: Bool = false) {
        self.threadID = threadID
        self.draft = String(draft.prefix(32_768))
        self.mode = mode
        self.isSending = isSending
        self.canInterrupt = canInterrupt
    }
}

public enum AgentListGrouping: String, Codable, Sendable { case attention, host }
public struct AgentListFilter: Equatable, Codable, Sendable {
    public var providerIDs: Set<AgentProviderID>
    public var query: String
    public init(providerIDs: Set<AgentProviderID> = [], query: String = "") {
        self.providerIDs = providerIDs
        self.query = String(query.prefix(512))
    }
}

public struct AgentAttentionEvent: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public let routeToken: AgentRouteToken
    public let attention: AgentAttention
    public let deliveryGeneration: UInt64
    /// Identifies this entry into `attention`. A later generation of the same
    /// finish or request (an idle notification, a rebinding) keeps it, so a
    /// platform alerts once per epoch rather than once per generation.
    public let attentionEpoch: UInt64

    public init(threadID: AgentThreadID, routeToken: AgentRouteToken, attention: AgentAttention, deliveryGeneration: UInt64,
                attentionEpoch: UInt64 = 0) {
        self.threadID = threadID
        self.routeToken = routeToken
        self.attention = attention
        self.deliveryGeneration = deliveryGeneration
        self.attentionEpoch = attentionEpoch
    }
}

public struct AgentRouteToken: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum AgentJSONValue: Equatable, Sendable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
}

extension AgentJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        // `isBounded` below intentionally walks an already-decoded value.  Do
        // not let a hostile JSON tree consume an unbounded recursive decoder
        // stack before that postcondition gets a chance to run.  A projection
        // record contributes four coding-path components before its JSON root,
        // so this admits the public 32-level value limit and rejects the next
        // descent before decoding its children.
        guard decoder.codingPath.count <= 40 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Agent JSON nesting exceeds the bounded projection depth")
            )
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AgentJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AgentJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension AgentJSONValue {
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var numberValue: Decimal? { if case .number(let value) = self { value } else { nil } }
    public var objectValue: [String: AgentJSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [AgentJSONValue]? { if case .array(let value) = self { value } else { nil } }

    /// Validates decoded provider JSON before it enters reducer state. This is
    /// intentionally iterative so hostile nesting cannot recurse indefinitely.
    public func isBounded(maximumDepth: Int = 32, maximumNodes: Int = 4_096, maximumStringBytes: Int = 16_384) -> Bool {
        var pending: [(AgentJSONValue, Int)] = [(self, 0)]
        var nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= maximumNodes, depth <= maximumDepth else { return false }
            switch value {
            case .string(let string):
                guard string.utf8.count <= maximumStringBytes else { return false }
            case .array(let values):
                guard values.count <= maximumNodes else { return false }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let object):
                guard object.count <= maximumNodes,
                      object.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 })
                else { return false }
                pending.append(contentsOf: object.values.map { ($0, depth + 1) })
            case .number, .bool, .null: break
            }
        }
        return true
    }
}
