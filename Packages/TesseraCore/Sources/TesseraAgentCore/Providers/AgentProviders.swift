import Foundation

public enum AgentLifecycleCapability: Equatable, Codable, Sendable {
    case unavailable
    case hooks(version: Int)
    case rpc
}

public enum AgentConversationCapability: Equatable, Codable, Sendable {
    case unavailable(reason: AgentAvailabilityReason)
    case projectedJSONL(adapterID: String)
    case sqliteQuery(adapterID: String)
    case rpc(adapterID: String)
    case projectedJSONLWithHooks(adapterID: String)
    case acp(adapterID: String)

    private enum CodingKeys: String, CodingKey { case kind, value, reason }
    private enum Kind: String, Codable { case unavailable, projectedJSONL, sqliteQuery, rpc, projectedJSONLWithHooks, acp }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .unavailable: self = .unavailable(reason: try values.decode(AgentAvailabilityReason.self, forKey: .reason))
        case .projectedJSONL: self = .projectedJSONL(adapterID: try values.decode(String.self, forKey: .value))
        case .sqliteQuery: self = .sqliteQuery(adapterID: try values.decode(String.self, forKey: .value))
        case .rpc: self = .rpc(adapterID: try values.decode(String.self, forKey: .value))
        case .projectedJSONLWithHooks: self = .projectedJSONLWithHooks(adapterID: try values.decode(String.self, forKey: .value))
        case .acp: self = .acp(adapterID: try values.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let reason): try values.encode(Kind.unavailable, forKey: .kind); try values.encode(reason, forKey: .reason)
        case .projectedJSONL(let id): try values.encode(Kind.projectedJSONL, forKey: .kind); try values.encode(id, forKey: .value)
        case .sqliteQuery(let id): try values.encode(Kind.sqliteQuery, forKey: .kind); try values.encode(id, forKey: .value)
        case .rpc(let id): try values.encode(Kind.rpc, forKey: .kind); try values.encode(id, forKey: .value)
        case .projectedJSONLWithHooks(let id): try values.encode(Kind.projectedJSONLWithHooks, forKey: .kind); try values.encode(id, forKey: .value)
        case .acp(let id): try values.encode(Kind.acp, forKey: .kind); try values.encode(id, forKey: .value)
        }
    }
}

public enum AgentActionCapability: String, Codable, Sendable, Hashable {
    case send
    case queue
    case interrupt
    case answerPrompt
    case spawn
    case fork
}

public struct AgentProcessMatcher: Equatable, Codable, Sendable {
    public let executableNames: [String]
    public init(executableNames: [String]) { self.executableNames = executableNames }
}

/// Bounded platform-observed process facts. The registry decides the match;
/// platform code must not carry its own provider-name table.
public struct AgentProcessDescriptor: Equatable, Codable, Sendable {
    public let executableName: String
    public let arguments: String

    public init?(executableName: String, arguments: String = "") {
        guard !executableName.isEmpty, executableName.utf8.count <= 256,
              !executableName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              arguments.utf8.count <= 4096,
              !arguments.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        self.executableName = executableName
        self.arguments = arguments
    }
}

public struct AgentProviderManifest: Equatable, Codable, Sendable {
    public let id: AgentProviderID
    public let displayName: String
    public let processMatchers: [AgentProcessMatcher]
    public let lifecycle: AgentLifecycleCapability
    public let conversation: AgentConversationCapability
    public let actions: Set<AgentActionCapability>

    public init(id: AgentProviderID, displayName: String, processMatchers: [AgentProcessMatcher], lifecycle: AgentLifecycleCapability, conversation: AgentConversationCapability, actions: Set<AgentActionCapability>) {
        self.id = id
        self.displayName = displayName
        self.processMatchers = processMatchers
        self.lifecycle = lifecycle
        self.conversation = conversation
        self.actions = actions
    }

    public var hasTranscript: Bool {
        if case .unavailable = conversation { return false }
        return true
    }
}

public struct AgentProviderRegistry: Equatable, Sendable {
    private let manifests: [AgentProviderID: AgentProviderManifest]

    public init(manifests: [AgentProviderManifest]) {
        self.manifests = manifests.reduce(into: [:]) { result, manifest in
            if result[manifest.id] == nil { result[manifest.id] = manifest }
        }
    }

    public func manifest(for id: AgentProviderID) -> AgentProviderManifest? { manifests[id] }
    public var allManifests: [AgentProviderManifest] { manifests.values.sorted { $0.id < $1.id } }

    public static let builtIn = AgentProviderRegistry(manifests: [
        .init(id: .claude, displayName: "Claude Code", processMatchers: [.init(executableNames: ["claude"])], lifecycle: .hooks(version: 9), conversation: .projectedJSONL(adapterID: "claude-jsonl-v1"), actions: [.send, .queue, .interrupt, .answerPrompt, .spawn, .fork]),
        .init(id: .codex, displayName: "Codex", processMatchers: [.init(executableNames: ["codex"])], lifecycle: .hooks(version: 9), conversation: .projectedJSONL(adapterID: "codex-rollout-jsonl-v1"), actions: [.send, .queue, .interrupt, .answerPrompt, .spawn]),
        .init(id: .opencode, displayName: "OpenCode", processMatchers: [.init(executableNames: ["opencode"])], lifecycle: .unavailable, conversation: .unavailable(reason: .unsupported), actions: []),
        .init(id: .pi, displayName: "Pi", processMatchers: [.init(executableNames: ["pi"])], lifecycle: .unavailable, conversation: .unavailable(reason: .unsupported), actions: []),
        .init(id: .kimi, displayName: "Kimi", processMatchers: [.init(executableNames: ["kimi"])], lifecycle: .unavailable, conversation: .unavailable(reason: .unsupported), actions: []),
        .init(id: .custom, displayName: "Custom", processMatchers: [], lifecycle: .unavailable, conversation: .unavailable(reason: .unsupported), actions: [])
    ])

    /// Configuration is a selection of these compiled manifests, never an
    /// arbitrary capability-bearing registry received over the platform ABI.
    public static func builtInSelection(_ ids: Set<AgentProviderID>? = nil) -> AgentProviderRegistry {
        let selected = ids ?? Set(builtIn.allManifests.map(\.id))
        return .init(manifests: builtIn.allManifests.filter { selected.contains($0.id) })
    }

    public func providers(matching descriptors: [AgentProcessDescriptor]) -> [AgentProviderID] {
        guard descriptors.count <= 128 else { return [] }
        let names = Set(descriptors.map { descriptor in
            URL(fileURLWithPath: descriptor.executableName).lastPathComponent.lowercased()
        })
        return allManifests.compactMap { manifest in
            manifest.processMatchers.contains { matcher in
                matcher.executableNames.contains { names.contains($0.lowercased()) }
            } ? manifest.id : nil
        }
    }
}

public struct AgentAdapterConformance: Equatable, Codable, Sendable {
    public let providerID: AgentProviderID
    public let adapterID: String
    public let sourceFixtureDigest: String
    public let liveGatePassed: Bool

    public init?(providerID: AgentProviderID, adapterID: String, sourceFixtureDigest: String, liveGatePassed: Bool) {
        guard !adapterID.isEmpty, adapterID.utf8.count <= 128,
              sourceFixtureDigest.utf8.count == 64,
              sourceFixtureDigest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else { return nil }
        self.providerID = providerID
        self.adapterID = adapterID
        self.sourceFixtureDigest = sourceFixtureDigest
        self.liveGatePassed = liveGatePassed
    }
}

/// Tier B/C adapters become visible only when their pinned storage/CLI fixture and live gate agree.
public struct AgentProviderCapabilityGate: Sendable {
    public init() {}

    public func manifest(_ base: AgentProviderManifest, enabling conformance: AgentAdapterConformance?) -> AgentProviderManifest {
        guard let conformance,
              conformance.providerID == base.id,
              conformance.liveGatePassed,
              conformance.sourceFixtureDigest == Self.expectedFixtureDigests[base.id]
        else { return base }
        switch base.id {
        case .opencode:
            guard conformance.adapterID == AgentOpenCodeSQLiteAdapter.adapterID else { return base }
            return .init(
                id: base.id,
                displayName: base.displayName,
                processMatchers: base.processMatchers,
                lifecycle: .unavailable,
                conversation: .sqliteQuery(adapterID: conformance.adapterID),
                actions: [.send, .interrupt]
            )
        case .pi:
            guard conformance.adapterID == AgentPiSessionAdapter.adapterID else { return base }
            return .init(
                id: base.id,
                displayName: base.displayName,
                processMatchers: base.processMatchers,
                // Persisted history plus append observation does not prove
                // the live process's status or authorize provider mutations.
                lifecycle: .unavailable,
                conversation: .projectedJSONL(adapterID: conformance.adapterID),
                actions: []
            )
        case .kimi:
            guard conformance.adapterID == AgentKimiWireAdapter.adapterID else { return base }
            return .init(id: base.id, displayName: base.displayName, processMatchers: base.processMatchers, lifecycle: .hooks(version: 9), conversation: .projectedJSONLWithHooks(adapterID: conformance.adapterID), actions: [.send, .interrupt, .answerPrompt])
        default:
            return base
        }
    }

    /// Pinned, compiled fixture attestations. A caller cannot replace these
    /// values through JSON configuration.
    public static let expectedFixtureDigests: [AgentProviderID: String] = [
        .opencode: "2375ee218f50837310643b139399b41b79b4feefce4c6a2524558d103287f342",
        .pi: "56133a1d19b4b6f99d388f2c9774e55c2c1e93227e6b60b697f0fcff589aed63",
        .kimi: "166878e3a179db49910076d943db4fb395c7a4c3864fa01ddd60f5a9ca464e31",
    ]

    /// Configuration input selects immutable built-ins. Tier-C conversations
    /// are derived only from a matching compiled attestation. Custom remains
    /// enforced Tier A even if an ABI caller supplies a richer manifest.
    public func hardenedRegistry(requested: [AgentProviderManifest], conformances: [AgentAdapterConformance]) -> AgentProviderRegistry {
        let byID = Dictionary(uniqueKeysWithValues: conformances.map { ($0.providerID, $0) })
        let requestedIDs = Set(requested.map(\.id))
        return .init(manifests: AgentProviderRegistry.builtIn.allManifests.compactMap { base in
            guard requestedIDs.contains(base.id) else { return nil }
            switch base.id {
            case .custom:
                return .init(id: .custom, displayName: base.displayName, processMatchers: [], lifecycle: .unavailable, conversation: .unavailable(reason: .unsupported), actions: [])
            case .opencode, .pi, .kimi:
                return self.manifest(base, enabling: byID[base.id])
            default: return base
            }
        })
    }
}

public struct AgentNormalizedRecord: Equatable, Sendable {
    public let message: AgentMessage?
    public let title: String?
    /// How strong `title` is. Only a provider that names its own sessions
    /// reports `.native`; everything else leaves the field alone so a weaker
    /// source cannot displace one.
    public let titleProvenance: AgentTitleProvenance
    public let cost: AgentCostSummary?
    public let queuedMessageCount: Int?
    public let context: AgentContextSummary?
    public let model: String?
    public let projectBasename: String?
    public let branch: String?
    public let permissionMode: AgentPermissionMode?
    public let activity: AgentActivityEvent?
    public let edit: AgentEditRecord?

    public init(message: AgentMessage? = nil, title: String? = nil, titleProvenance: AgentTitleProvenance = .native, cost: AgentCostSummary? = nil, queuedMessageCount: Int? = nil, context: AgentContextSummary? = nil, model: String? = nil, projectBasename: String? = nil, branch: String? = nil, permissionMode: AgentPermissionMode? = nil, activity: AgentActivityEvent? = nil, edit: AgentEditRecord? = nil) {
        self.message = message
        self.title = title
        self.titleProvenance = titleProvenance
        self.cost = cost
        self.queuedMessageCount = queuedMessageCount
        self.context = context
        self.model = model
        self.projectBasename = projectBasename
        self.branch = branch
        self.permissionMode = permissionMode
        self.activity = activity
        self.edit = edit
    }
}

public struct AgentTranscriptNormalizer: Sendable {
    public init() {}

    public func normalize(providerID: AgentProviderID, record: AgentProjectionRecord) -> AgentNormalizedRecord {
        let value = normalizeRecord(providerID: providerID, record: record)
        guard value.message == nil,
              let count = record.record.objectValue?["unparsedContentCount"]?.numberValue, count > 0 else { return value }
        // System/injected records bypass transcript-message construction. They
        // must not bypass diagnostics too, nor become authored title seeds.
        return .init(title: value.title, titleProvenance: value.titleProvenance,
                     cost: value.cost, queuedMessageCount: value.queuedMessageCount,
                     context: value.context, model: value.model, projectBasename: value.projectBasename,
                     branch: value.branch, permissionMode: value.permissionMode,
                     activity: systemActivity(record, title: "Unsupported content", detail: "Some blocks could not be decoded"),
                     edit: value.edit)
    }

    private func normalizeRecord(providerID: AgentProviderID, record: AgentProjectionRecord) -> AgentNormalizedRecord {
        guard let object = record.record.objectValue else {
            return .init(activity: systemActivity(record, title: "Unsupported provider record", detail: "Non-object record"))
        }
        if object["isMeta"]?.boolValue == true {
            return .init(activity: systemActivity(record, title: "Injected system content"))
        }
        // Claude replays the summary of a compacted conversation as a record
        // whose role is `user`. Nobody typed it: rendering it as a user bubble
        // put provider prose in the reader's mouth, and it also became the
        // thread's opening prompt, so a resumed agent was titled "This session
        // is being continued from a previous conversation...". Keep the text —
        // it is the only account of what was compacted away — as its own
        // boundary marker on the system role.
        let normalized: AgentNormalizedRecord
        if object["isCompactSummary"]?.boolValue == true ||
            (providerID == .claude && object["subtype"]?.stringValue == "compact_boundary" &&
                (object["type"]?.stringValue == "system" ||
                    (object["type"]?.stringValue == "message" && object["role"]?.stringValue == "system"))) {
            normalized = compactSummary(record: record, object: object, providerID: providerID)
        } else {
            normalized = normalizeObject(providerID: providerID, record: record, object: object)
        }
        guard object["isSidechain"]?.boolValue == true || object["isSubagent"]?.boolValue == true else { return normalized }
        // Keep child content visible, but no alias or future metadata field
        // may replace the main agent's header, counters, or policy.
        return .init(message: normalized.message, activity: normalized.activity, edit: normalized.edit)
    }

    private func contextSummary(_ object: [String: AgentJSONValue], providerID: AgentProviderID) -> AgentContextSummary? {
        let usedTokens = decimalInt(object["used_tokens"]?.numberValue)
        let maximumTokens = decimalInt(object["max_tokens"]?.numberValue)
        var percentUsed = decimalDouble(object["context_percent"]?.numberValue)
        // Native Codex token-count records carry counts, not a percentage.
        // Request/turn/lifetime totals alone do not describe current context.
        if percentUsed == nil, let usedTokens, usedTokens >= 0, let maximumTokens {
            if providerID == .codex {
                // Match Codex's rounded context-left display after reserving
                // its 12k baseline, rather than rounding raw occupancy.
                if maximumTokens > 12_000 {
                    let effective = maximumTokens - 12_000
                    let used = max(0, usedTokens - 12_000)
                    let percentLeft = (Double(max(0, effective - used)) / Double(effective) * 100).rounded()
                    percentUsed = 100 - percentLeft
                }
            } else if maximumTokens > 0 {
                percentUsed = Double(usedTokens) / Double(maximumTokens) * 100
            }
        }
        guard usedTokens != nil || maximumTokens != nil || percentUsed != nil else { return nil }
        return .init(usedTokens: usedTokens, maximumTokens: maximumTokens, percentUsed: percentUsed)
    }

    private func normalizeObject(providerID: AgentProviderID, record: AgentProjectionRecord, object: [String: AgentJSONValue]) -> AgentNormalizedRecord {
        let type = object["type"]?.stringValue ?? "unknown"
        switch type {
        case "ai-title", "session-title":
            // Claude writes the session title as `aiTitle`; `session-title` is
            // the shape the adapter uses for a provider whose title lives
            // beside the transcript rather than inside it (opencode stores it
            // on the session row, pi answers it from `get_state`).
            //
            // Reading only `title`/`text` meant every real Claude transcript
            // fell through to the literal string "Untitled", which is what
            // Agent Center showed for a live agent. A record with no usable
            // title must leave the existing title alone rather than overwrite
            // it with a placeholder.
            let aiTitle = object["aiTitle"]?.stringValue
                ?? object["title"]?.stringValue
                ?? object["text"]?.stringValue
            return .init(title: aiTitle.map { clipped($0, limit: 512) })
        case "cost-state":
            // Same wire-shape mismatch as `ai-title`: the real record carries
            // `totalCostUSD` / `totalDuration` (milliseconds) / `totalLines*`.
            // The snake_case names are kept as fallbacks for providers that do
            // emit them. Canonical Codex records can carry context-window
            // fields without totals, so publish each summary only when that
            // particular family has a real value.
            let totalDurationMS = decimalDouble(object["totalDuration"]?.numberValue)
            let totalCost = object["totalCostUSD"]?.numberValue ?? object["cost"]?.numberValue
            let durationSeconds = totalDurationMS.map { $0 / 1_000 }
                ?? decimalDouble(object["duration"]?.numberValue)
            let linesAdded = decimalInt(object["totalLinesAdded"]?.numberValue
                ?? object["lines_added"]?.numberValue)
            let linesRemoved = decimalInt(object["totalLinesRemoved"]?.numberValue
                ?? object["lines_removed"]?.numberValue)
            return .init(
                cost: totalCost != nil || durationSeconds != nil || linesAdded != nil || linesRemoved != nil
                    ? .init(totalCost: totalCost, durationSeconds: durationSeconds, linesAdded: linesAdded, linesRemoved: linesRemoved)
                    : nil,
                context: contextSummary(object, providerID: providerID),
                model: object["model"]?.stringValue.map { clipped($0, limit: 256) }
            )
        case "queue-operation":
            return .init(queuedMessageCount: max(0, decimalInt(object["pending"]?.numberValue) ?? decimalInt(object["count"]?.numberValue) ?? 0))
        case "permission-mode", "mode":
            return .init(permissionMode: permissionMode(object["mode"]?.stringValue ?? object["permissionMode"]?.stringValue ?? object["value"]?.stringValue))
        case "metadata", "session_meta", "turn_context":
            return .init(
                title: object["title"]?.stringValue.map { clipped($0, limit: 512) },
                context: contextSummary(object, providerID: providerID),
                model: object["model"]?.stringValue.map { clipped($0, limit: 256) },
                projectBasename: object["project"]?.stringValue.map { clipped($0, limit: 256) },
                branch: object["branch"]?.stringValue.map { clipped($0, limit: 512) },
                permissionMode: permissionMode(object["permissionMode"]?.stringValue)
            )
        case "user":
            let rawRole = object["role"]?.stringValue?.lowercased()
            if rawRole == "system" || rawRole == "developer" {
                return .init(activity: systemActivity(record, title: "Provider system content"))
            }
            return message(recordID: record.recordID, role: .user, object: object, providerID: providerID)
        case "assistant", "message":
            if let role = object["role"], role.stringValue == nil {
                return .init(activity: systemActivity(record, title: "Unsupported provider role"))
            }
            let rawRole = object["role"]?.stringValue?.lowercased()
            if rawRole == "system" || rawRole == "developer" {
                if [.pi, .kimi].contains(providerID), rawRole == "system", object["providerSystemMessage"]?.boolValue == true {
                    let value = message(recordID: record.recordID, role: .system, object: object, providerID: providerID)
                    guard let message = value.message else { return value }
                    return .init(message: .init(recordID: message.recordID, role: .system, displayTime: message.displayTime,
                        blocks: message.blocks.map { block in
                            if case .text(let body) = block { return .systemEvent(body) }
                            return block
                        }))
                }
                return .init(activity: systemActivity(record, title: "Provider system content"))
            }
            guard let role = AgentRole(rawValue: object["role"]?.stringValue ?? "assistant") else {
                return .init(activity: systemActivity(record, title: "Unsupported provider role"))
            }
            return message(recordID: record.recordID, role: role, object: object, providerID: providerID)
        case "thinking":
            return .init(message: .init(recordID: record.recordID, role: .assistant, displayTime: displayTime(object), blocks: [.thinking(clipped(text(object), limit: 16_384))]))
        case "tool_call", "tool-use":
            let name = clipped(object["name"]?.stringValue ?? "Tool", limit: 256)
            return .init(message: .init(recordID: record.recordID, role: .tool, displayTime: nil, blocks: [.toolCall(name: name, preview: clipped(text(object), limit: 16_384))]))
        case "tool_result", "tool-result":
            let original = text(object)
            return .init(message: .init(recordID: record.recordID, role: .tool, displayTime: displayTime(object), blocks: [.toolResult(preview: clipped(original, limit: 16_384), truncated: original.utf8.count > 16_384)]), activity: activity(record, kind: .tool, title: object["name"]?.stringValue ?? "Tool"))
        case "edit", "file_edit":
            let edit = AgentEditRecord(id: record.recordID, path: object["path"]?.stringValue, additions: decimalInt(object["additions"]?.numberValue), deletions: decimalInt(object["deletions"]?.numberValue), diff: object["diff"]?.stringValue)
            return .init(message: .init(recordID: record.recordID, role: .tool, displayTime: displayTime(object), blocks: [.edit(path: edit.path, diff: edit.diff)]), activity: activity(record, kind: .tool, title: "Edit", detail: edit.path), edit: edit)
        case "permission", "permission_request", "question":
            let options = (object["options"]?.arrayValue ?? []).prefix(9).enumerated().compactMap { index, value -> AgentPromptOption? in
                guard let option = value.objectValue else { return nil }
                return .init(id: option["id"]?.stringValue ?? String(index + 1), label: option["label"]?.stringValue ?? "Option \(index + 1)", isDefault: option["default"]?.boolValue ?? false)
            }
            // Projector data is remote input. A malformed optional token must
            // degrade to the stable bounded record ID, never trap while
            // rendering a transcript.
            guard let token = AgentActionToken(object["actionToken"]?.stringValue ?? "")
                ?? AgentActionToken(record.recordID)
            else {
                return .init(message: .init(recordID: record.recordID, role: .system, displayTime: nil, blocks: [.unknown(type: "invalid-action-token")]))
            }
            let prompt = AgentActionPrompt(title: object["title"]?.stringValue ?? (type == "question" ? "Question" : "Permission requested"), detail: object["detail"]?.stringValue ?? object["command"]?.stringValue, options: options, token: token)
            return .init(message: .init(recordID: record.recordID, role: .system, displayTime: displayTime(object), blocks: [.actionPrompt(prompt)]), activity: activity(record, kind: .permission, title: prompt.title))
        case "workflow", "task-list":
            let tasks = (object["tasks"]?.arrayValue ?? []).compactMap { value -> AgentWorkflowTask? in
                guard let task = value.objectValue, let id = task["id"]?.stringValue else { return nil }
                let state = AgentWorkflowTask.State(rawValue: task["state"]?.stringValue ?? "pending") ?? .pending
                return .init(id: id, title: task["title"]?.stringValue ?? "Task", owner: task["owner"]?.stringValue, state: state)
            }
            return .init(message: .init(recordID: record.recordID, role: .system, displayTime: displayTime(object), blocks: [.workflowTasks(tasks)]), activity: activity(record, kind: .workflow, title: "Workflow"))
        case "subagent", "agent":
            let id = object["agent_id"]?.stringValue ?? object["agentId"]?.stringValue ?? record.recordID
            let child = AgentSubagentSummary(id: id, type: object["agent_type"]?.stringValue ?? object["agentType"]?.stringValue, summary: object["summary"]?.stringValue, status: AgentStatus(rawValue: object["status"]?.stringValue ?? "working") ?? .working)
            return .init(message: .init(recordID: record.recordID, role: .system, displayTime: displayTime(object), blocks: [.subagentGroup([child])]), activity: activity(record, kind: .subagent, title: child.type ?? "Subagent"))
        case "completion":
            let summary = object["summary"]?.stringValue.map {
                clipped(providerID == .codex ? AgentCodexTranscriptContent.assistantText($0, truncated: object["truncated"]?.boolValue == true) : $0, limit: 16_384)
            }
            return .init(message: .init(recordID: record.recordID, role: .assistant, displayTime: displayTime(object), blocks: [.completion(summary)]), activity: activity(record, kind: .completion, title: "Completed"))
        case "system":
            return .init(activity: systemActivity(record, title: "Provider system content",
                detail: object["text"]?.stringValue, object: object))
        case "system-event":
            return .init(activity: systemActivity(
                record,
                title: object["title"]?.stringValue ?? object["name"]?.stringValue ?? "System event",
                detail: object["detail"]?.stringValue ?? object["text"]?.stringValue ?? object["message"]?.stringValue,
                object: object
            ))
        default:
            return .init(activity: systemActivity(record, title: "Unsupported provider record", detail: "Record type: \(clipped(type, limit: 128))"))
        }
    }

    private func message(recordID: String, role: AgentRole, object: [String: AgentJSONValue], providerID: AgentProviderID) -> AgentNormalizedRecord {
        func prose(_ text: String, truncated: Bool) -> AgentBlock? {
            let cleaned = providerID == .codex && role == .assistant
                ? AgentCodexTranscriptContent.assistantText(text, truncated: truncated) : text
            let value = clipped(cleaned, limit: 16_384)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .text(value)
        }
        var blocks = (object["blocks"]?.arrayValue ?? []).compactMap { value -> AgentBlock? in
            if let block = value.objectValue, block["type"]?.stringValue == "text" {
                guard let text = block["text"]?.stringValue else { return .unknown(type: "invalid-text") }
                return prose(text, truncated: block["truncated"]?.boolValue == true)
            }
            let block = normalizedBlock(value, role: role)
            if case .thinking(let text) = block, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return block
        }
        if blocks.isEmpty, let fallback = prose(text(object), truncated: object["truncated"]?.boolValue == true) {
            blocks = [fallback]
        }
        let shortened = object["truncated"]?.boolValue == true ||
            (object["blocks"]?.arrayValue ?? []).contains { $0.objectValue?["truncated"]?.boolValue == true }
        if shortened && !blocks.isEmpty {
            // Record-level truncation includes omitted whole blocks, which
            // cannot be represented by a tool-result's local ellipsis alone.
            // Keep the notice typed as system UI, never as authored prose.
            blocks.insert(.shortenedPreviewNotice, at: 0)
        }
        if let unparsed = object["unparsedContentCount"]?.numberValue, unparsed > 0 {
            // The offending block may have been evicted by the helper's
            // preview budget. Preserve the warning independently of its text.
            blocks.insert(.systemEvent("Unsupported content · some blocks could not be decoded"), at: 0)
        }
        return .init(
            message: blocks.isEmpty ? nil : .init(recordID: recordID, role: role, displayTime: displayTime(object), blocks: blocks),
            context: providerID == .claude && role == .assistant && object["used_tokens"]?.numberValue != nil
                ? contextSummary(object, providerID: providerID) : nil,
            model: object["model"]?.stringValue.map { clipped($0, limit: 256) },
            projectBasename: object["project"]?.stringValue.map { clipped($0, limit: 256) },
            branch: object["branch"]?.stringValue.map { clipped($0, limit: 512) },
            permissionMode: permissionMode(object["permissionMode"]?.stringValue)
        )
    }

    /// A projector that predates the `compact-summary` block still sends the
    /// summary as prose, so coerce any text block the flag covers rather than
    /// trusting the block type alone. The record reads as one collapsed
    /// marker, so its notices (a shortened preview, undecodable blocks) fold
    /// into the summary instead of standing beside it as separate rows.
    private func compactSummary(record: AgentProjectionRecord, object: [String: AgentJSONValue], providerID: AgentProviderID) -> AgentNormalizedRecord {
        let activity = systemActivity(record, title: "Context compacted")
        // nil means no context update; an empty summary explicitly resets
        // Claude occupancy until the next measured assistant message.
        let context: AgentContextSummary? = providerID == .claude ? .init() : nil
        guard let message = message(recordID: record.recordID, role: .system, object: object, providerID: providerID).message else {
            return .init(context: context, activity: activity)
        }
        var summaries: [String] = [], notices: [String] = [], others: [AgentBlock] = []
        for block in message.blocks {
            switch block {
            case .text(let value), .compactSummary(let value): summaries.append(value)
            case .systemEvent(let value): notices.append("_\(value)_")
            default: others.append(block)
            }
        }
        let blocks = summaries.isEmpty ? message.blocks
            : [.compactSummary(clipped((notices + summaries).joined(separator: "\n\n"), limit: 16_384))] + others
        return .init(
            message: .init(recordID: message.recordID, role: .system, displayTime: message.displayTime, blocks: blocks),
            context: context,
            activity: activity
        )
    }

    private func normalizedBlock(_ value: AgentJSONValue, role: AgentRole) -> AgentBlock? {
        guard let block = value.objectValue else { return .unknown(type: "invalid-block") }
        let type = block["type"]?.stringValue ?? "unknown"
        if ["text", "thinking", "compact-summary", "system-event"].contains(type), block["text"]?.stringValue == nil {
            return .unknown(type: "invalid-\(type)")
        }
        for field in ["text", "preview", "name", "path", "diff", "mediaType"] {
            if let value = block[field], value.stringValue == nil {
                return .unknown(type: "invalid-\(clipped(type, limit: 128))")
            }
        }
        switch type {
        case "system-event": return .systemEvent(clipped(block["text"]?.stringValue ?? "Provider event", limit: 16_384))
        case "text": return .text(clipped(block["text"]?.stringValue ?? "", limit: 16_384))
        case "thinking": return .thinking(clipped(block["text"]?.stringValue ?? "", limit: 16_384))
        case "tool_call": return .toolCall(name: clipped(block["name"]?.stringValue ?? "Tool", limit: 256), preview: clipped(block["preview"]?.stringValue ?? "", limit: 16_384))
        case "tool_result": return .toolResult(preview: clipped(block["preview"]?.stringValue ?? "", limit: 16_384), truncated: block["truncated"]?.boolValue ?? false)
        case "edit": return .edit(path: block["path"]?.stringValue.map { clipped($0, limit: 2_048) }, diff: block["diff"]?.stringValue.map { clipped($0, limit: 65_536) })
        case "attachment": return .attachment(name: clipped(block["name"]?.stringValue ?? "attachment", limit: 512), mediaType: block["mediaType"]?.stringValue.map { clipped($0, limit: 128) })
        case "system": return .systemEvent(clipped(block["text"]?.stringValue ?? "System event", limit: 16_384))
        case "compact-summary": return .compactSummary(clipped(block["text"]?.stringValue ?? "", limit: 16_384))
        default:
            // Diagnostics are not authored speech and must never seed titles.
            return .unknown(type: clipped(block["sourceType"]?.stringValue ?? type, limit: 128))
        }
    }

    private func permissionMode(_ value: String?) -> AgentPermissionMode? {
        switch value?.lowercased() {
        case "default", "defaultmode", "on-request", "on-failure", "untrusted": return .defaultMode
        case "plan": return .plan
        case "auto", "accept-edits", "bypasspermissions", "never": return .auto
        case "readonly", "read-only": return .readOnly
        case .some: return .unavailable
        case nil: return nil
        }
    }

    private func text(_ object: [String: AgentJSONValue]) -> String {
        object["text"]?.stringValue ?? object["content"]?.stringValue ?? object["message"]?.stringValue ?? ""
    }

    private func clipped(_ value: String, limit: Int) -> String {
        let value = AgentDisplayText.sanitize(value)
        let bytes = value.utf8
        guard bytes.count > limit else { return value }
        return String(decoding: bytes.prefix(limit), as: UTF8.self)
    }

    private func displayTime(_ object: [String: AgentJSONValue]) -> Date? {
        guard let value = object["timestamp"]?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func activity(_ record: AgentProjectionRecord, kind: AgentActivityEvent.Kind, title: String, detail: String? = nil) -> AgentActivityEvent {
        .init(id: "activity-\(record.recordID)", sequence: record.sequence, kind: kind, title: clipped(title, limit: 512), detail: detail)
    }

    private func systemActivity(_ record: AgentProjectionRecord, title: String, detail: String? = nil, object: [String: AgentJSONValue]? = nil) -> AgentActivityEvent {
        let resolvedDetail: String?
        if let detail, !detail.isEmpty {
            resolvedDetail = detail
        } else {
            resolvedDetail = object.flatMap { source in
                source["detail"]?.stringValue ?? source["text"]?.stringValue ?? source["message"]?.stringValue
            }
        }
        return .init(
            id: "activity-\(record.recordID)",
            sequence: record.sequence,
            kind: .system,
            title: clipped(title, limit: 256),
            detail: resolvedDetail.map { clipped($0, limit: 2_048) },
            displayTime: object.flatMap { displayTime($0) }
        )
    }

    private func decimalInt(_ value: Decimal?) -> Int? { value.map { NSDecimalNumber(decimal: $0).intValue } }
    private func decimalDouble(_ value: Decimal?) -> Double? { value.map { NSDecimalNumber(decimal: $0).doubleValue } }
}
