import Foundation

public enum AgentLifecycleEventKind: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"
    case wrapperExit = "WrapperExit"
}

/// The provider hook wire event accepted from OSC before any session/binding
/// authority is attached. Both Apple and Android decode this exact schema in
/// Core; platform code only adds exact-session capability and process proof.
public struct AgentLifecycleHookEvent: Equatable, Codable, Sendable {
    public let version: Int
    public let providerID: AgentProviderID
    public let event: AgentLifecycleEventKind
    public let status: AgentStatus
    public let reason: String?
    public let timestampNanoseconds: UInt64
    public let providerSessionID: String?
    public let turnID: String?
    public let notificationType: String?
    public let permissionMode: String?
    public let agentPID: Int?
    public let transcriptRef: String?
    public let agentID: String?
    public let agentType: String?
    public let rootAgentID: String?

    public static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= 65_536,
              let wire = try? JSONDecoder().decode(WireEvent.self, from: data),
              AgentLifecycleEnvelope.compatibleVersions.contains(wire.version),
              let providerID = AgentProviderID(rawValue: wire.provider),
              let manifest = hookSchemaRegistry.manifest(for: providerID),
              case .hooks(let currentVersion) = manifest.lifecycle,
              wire.version <= currentVersion,
              let event = AgentLifecycleEventKind(rawValue: wire.event),
              allowedStatuses[event]?.contains(wire.state) == true,
              let status = status(wire.state),
              let timestampNanoseconds = UInt64(wire.timestampNs),
              wire.agentPid.map({ $0 > 1 }) ?? true,
              validToken(wire.reason, maximumBytes: 64),
              validToken(wire.sessionId, maximumBytes: 256),
              validToken(wire.turnId, maximumBytes: 256),
              validToken(wire.notificationType, maximumBytes: 64),
              validToken(wire.permissionMode, maximumBytes: 64),
              validToken(wire.agentId, maximumBytes: 256),
              validToken(wire.agentType, maximumBytes: 64),
              validToken(wire.rootAgentId, maximumBytes: 256),
              validLocator(wire.transcriptRef)
        else { return nil }
        // The hook scripts emit every unset optional as "", never by omitting
        // the key, so "present but empty" always means "not set". Collapsing it
        // here is what keeps the two ends of this contract agreeing:
        // `validToken` above accepts an empty string, while
        // `AgentLifecycleEnvelope`'s accepts only a non-empty one, so an
        // unnormalised "" parsed cleanly and was then refused by the envelope
        // built from it -- Core rejecting its own output. Every real Claude
        // frame carries agentId/agentType/rootAgentId as "", so that refusal hit
        // every agent on every platform, and surfaced only as an opaque
        // `command_failed`.
        return .init(
            version: wire.version,
            providerID: providerID,
            event: event,
            status: status,
            reason: token(wire.reason),
            timestampNanoseconds: timestampNanoseconds,
            providerSessionID: token(wire.sessionId),
            turnID: token(wire.turnId),
            notificationType: token(wire.notificationType),
            permissionMode: token(wire.permissionMode),
            agentPID: wire.agentPid,
            // A locator longer than the envelope and projection carry cannot
            // be read: the frame is unlocatable, which still revokes the
            // conversation it replaced, rather than one Core later refuses.
            transcriptRef: token(wire.transcriptRef).flatMap {
                $0.utf8.count <= AgentLifecycleEnvelope.maximumLocatorBytes ? $0 : nil
            },
            agentID: token(wire.agentId),
            agentType: token(wire.agentType),
            rootAgentID: token(wire.rootAgentId)
        )
    }

    public static func supportsHookPayload(providerID: AgentProviderID, version: Int) -> Bool {
        guard AgentLifecycleEnvelope.compatibleVersions.contains(version),
              let manifest = hookSchemaRegistry.manifest(for: providerID),
              case .hooks(let currentVersion) = manifest.lifecycle
        else { return false }
        return version <= currentVersion
    }

    private struct WireEvent: Decodable {
        let version: Int
        let provider: String
        let event: String
        let state: String
        let reason: String?
        let timestampNs: String
        let sessionId: String?
        let turnId: String?
        let notificationType: String?
        let permissionMode: String?
        let agentPid: Int?
        let transcriptRef: String?
        let agentId: String?
        let agentType: String?
        let rootAgentId: String?
    }

    private static let hookSchemaRegistry: AgentProviderRegistry = {
        let kimi = AgentKimiWireAdapter.liveConformance(
            sessionIndexPassed: true,
            hookConfigurationPassed: true
        )
        return AgentProviderCapabilityGate().hardenedRegistry(
            requested: AgentProviderRegistry.builtIn.allManifests,
            conformances: kimi.map { [$0] } ?? []
        )
    }()

    private static let allowedStatuses: [AgentLifecycleEventKind: Set<String>] = [
        .sessionStart: ["idle"], .subagentStart: ["working"], .subagentStop: ["working"],
        .userPromptSubmit: ["working"], .preToolUse: ["working"], .postToolUse: ["working"],
        .permissionRequest: ["waitingForInput"], .notification: ["waitingForInput", "idle"],
        .stop: ["idle"], .stopFailure: ["unavailable"], .sessionEnd: ["unavailable"],
        .wrapperExit: ["unavailable"],
    ]

    private static func status(_ value: String) -> AgentStatus? {
        switch value {
        case "waitingForInput": .waitingForInput
        case "working": .working
        case "idle": .idle
        case "unavailable": .unavailable
        default: nil
        }
    }

    /// An optional wire token, with "" folded to absent. See the note in `parse`.
    private static func token(_ value: String?) -> String? {
        value?.isEmpty == true ? nil : value
    }

    private static func validToken(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= maximumBytes else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 46 || byte == 95 || byte == 58 || byte == 45
        }
    }

    private static func validLocator(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= 4_096 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }
    }
}

/// A content-free hint from integration v21 hooks that a question tool
/// started or finished. The hook reports it in `reason`; the prompt itself is
/// only ever read from the terminal.
public enum AgentLifecycleInputHint: String, Codable, Sendable {
    /// A question that stops the agent until it is answered: Codex
    /// `request_user_input`, Claude and Kimi `AskUserQuestion`.
    case question
    /// A question that returns at once and waits beside the working turn:
    /// Codex `request_user_input_async`, Kimi `AskUserQuestion` in the background.
    case deferredQuestion = "deferred-question"

    /// Only tool boundaries carry the hint.
    public init?(reason: String?, event: AgentLifecycleEventKind) {
        guard event == .preToolUse || event == .postToolUse, let reason, let hint = Self(rawValue: reason) else { return nil }
        self = hint
    }
}

public struct AgentLifecycleEnvelope: Equatable, Codable, Sendable {
    public static let currentVersion = 9
    public static let compatibleVersions = Set([2, 3, 4, 6, 7, 8, 9])

    public let version: Int
    public let providerID: AgentProviderID
    public let event: AgentLifecycleEventKind
    public let status: AgentStatus
    public let providerSessionID: String?
    public let agentPID: Int?
    public let transcriptRef: String?
    public let agentID: String?
    public let agentType: String?
    public let rootAgentID: String?
    /// Monotonic local-arrival evidence for one accepted hook transition.
    /// Remote wall-clock timestamps are display metadata and must never be
    /// allowed to overrule a newer frame received by the client.
    public let eventSequence: UInt64?
    /// Stable source identity for retained-hook deduplication, never ordering.
    public let sourceTimestampNanoseconds: UInt64?
    /// Set only on PreToolUse/PostToolUse; see `withInputHint`.
    public private(set) var inputHint: AgentLifecycleInputHint?

    /// The same frame carrying a question hint. A hint on any other event is
    /// dropped: only tool boundaries report question tools.
    public func withInputHint(_ hint: AgentLifecycleInputHint?) -> Self {
        var copy = self
        copy.inputHint = event == .preToolUse || event == .postToolUse ? hint : nil
        return copy
    }

    public init?(version: Int, providerID: AgentProviderID, event: AgentLifecycleEventKind, status: AgentStatus, providerSessionID: String? = nil, agentPID: Int? = nil, transcriptRef: String? = nil, agentID: String? = nil, agentType: String? = nil, rootAgentID: String? = nil) {
        self.init(
            version: version,
            providerID: providerID,
            event: event,
            status: status,
            providerSessionID: providerSessionID,
            agentPID: agentPID,
            transcriptRef: transcriptRef,
            agentID: agentID,
            agentType: agentType,
            rootAgentID: rootAgentID,
            eventSequence: nil
        )
    }

    public init?(version: Int, providerID: AgentProviderID, event: AgentLifecycleEventKind, status: AgentStatus, providerSessionID: String? = nil, agentPID: Int? = nil, transcriptRef: String? = nil, agentID: String? = nil, agentType: String? = nil, rootAgentID: String? = nil, eventSequence: UInt64?, sourceTimestampNanoseconds: UInt64? = nil) {
        guard Self.firstInvalidField(
            version: version, agentPID: agentPID, providerSessionID: providerSessionID,
            agentID: agentID, agentType: agentType, rootAgentID: rootAgentID, transcriptRef: transcriptRef
        ) == nil else { return nil }
        self.version = version
        self.providerID = providerID
        self.event = event
        self.status = status
        self.providerSessionID = providerSessionID
        self.agentPID = agentPID
        self.transcriptRef = transcriptRef
        self.agentID = agentID
        self.agentType = agentType
        self.rootAgentID = rootAgentID
        self.eventSequence = eventSequence
        self.sourceTimestampNanoseconds = sourceTimestampNanoseconds
    }

    /// The single admission rule for an envelope, reported as the field that
    /// actually failed. It used to be one `guard` with seven conditions whose
    /// only output was `nil`, and the decoder anchored the resulting error on
    /// `version` no matter which condition tripped -- so a device log said
    /// `dataCorrupted:lifecycle.version` for a bad `agentID`. Returning the key
    /// keeps the accepted set identical and makes the refusal readable.
    static func firstInvalidField(
        version: Int,
        agentPID: Int?,
        providerSessionID: String?,
        agentID: String?,
        agentType: String?,
        rootAgentID: String?,
        transcriptRef: String?
    ) -> CodingKeys? {
        if !compatibleVersions.contains(version) { return .version }
        if let agentPID, agentPID <= 1 { return .agentPID }
        if !validToken(providerSessionID, limit: 512) { return .providerSessionID }
        if !validToken(agentID, limit: 256) { return .agentID }
        if !validToken(agentType, limit: 128) { return .agentType }
        if !validToken(rootAgentID, limit: 256) { return .rootAgentID }
        if version >= 9 && !validOpaqueLocator(transcriptRef) { return .transcriptRef }
        return nil
    }

    private static func validToken(_ value: String?, limit: Int) -> Bool {
        value.map { !$0.isEmpty && $0.utf8.count <= limit && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) } ?? true
    }

    /// The longest transcript locator an envelope or projection carries.
    public static let maximumLocatorBytes = 2_048

    private static func validOpaqueLocator(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLocatorBytes else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, providerID, event, status, providerSessionID, agentPID
        case transcriptRef, agentID, agentType, rootAgentID, eventSequence, sourceTimestampNanoseconds, inputHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let providerID = try container.decode(AgentProviderID.self, forKey: .providerID)
        let event = try container.decode(AgentLifecycleEventKind.self, forKey: .event)
        let status = try container.decode(AgentStatus.self, forKey: .status)
        let providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
        let agentPID = try container.decodeIfPresent(Int.self, forKey: .agentPID)
        let transcriptRef = try container.decodeIfPresent(String.self, forKey: .transcriptRef)
        let agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        let agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        let rootAgentID = try container.decodeIfPresent(String.self, forKey: .rootAgentID)
        let eventSequence = try container.decodeIfPresent(UInt64.self, forKey: .eventSequence)
        guard let validated = Self(
            version: version,
            providerID: providerID,
            event: event,
            status: status,
            providerSessionID: providerSessionID,
            agentPID: agentPID,
            transcriptRef: transcriptRef,
            agentID: agentID,
            agentType: agentType,
            rootAgentID: rootAgentID,
            eventSequence: eventSequence,
            sourceTimestampNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .sourceTimestampNanoseconds)
        ) else {
            let offending = Self.firstInvalidField(
                version: version, agentPID: agentPID, providerSessionID: providerSessionID,
                agentID: agentID, agentType: agentType, rootAgentID: rootAgentID, transcriptRef: transcriptRef
            ) ?? .version
            throw DecodingError.dataCorruptedError(
                forKey: offending, in: container,
                debugDescription: "Invalid lifecycle envelope field \(offending.stringValue)"
            )
        }
        self = validated.withInputHint(try container.decodeIfPresent(AgentLifecycleInputHint.self, forKey: .inputHint))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(event, forKey: .event)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(providerSessionID, forKey: .providerSessionID)
        try container.encodeIfPresent(agentPID, forKey: .agentPID)
        try container.encodeIfPresent(transcriptRef, forKey: .transcriptRef)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(agentType, forKey: .agentType)
        try container.encodeIfPresent(rootAgentID, forKey: .rootAgentID)
        try container.encodeIfPresent(eventSequence, forKey: .eventSequence)
        // The decoder reads it; dropping it here made a Swift round trip lose
        // the retained-hook identity that dedupe and completion reads use.
        try container.encodeIfPresent(sourceTimestampNanoseconds, forKey: .sourceTimestampNanoseconds)
        try container.encodeIfPresent(inputHint, forKey: .inputHint)
    }
}

public struct AgentLifecycleBindingProof: Equatable, Codable, Sendable {
    public let hostID: UUID
    public let binding: AgentTerminalBinding
    public let sourceIdentity: String
    public let processIDs: Set<Int>

    public init(hostID: UUID, binding: AgentTerminalBinding, sourceIdentity: String, processIDs: Set<Int>) {
        self.hostID = hostID
        self.binding = binding
        self.sourceIdentity = sourceIdentity
        self.processIDs = processIDs
    }
}

public enum AgentLifecycleAcceptance: Equatable, Sendable {
    case accepted(threadID: AgentThreadID?)
    case rejected(AgentLifecycleRejection)
}

public enum AgentLifecycleRejection: String, Equatable, Sendable {
    case unknownProvider
    case unsupportedVersion
    case staleBinding
    case pidMismatch
    case sourceMismatch
    case invalidV9Locator
}

public struct AgentLifecycleValidator: Sendable {
    public let registry: AgentProviderRegistry

    public init(registry: AgentProviderRegistry) { self.registry = registry }

    public func validate(_ envelope: AgentLifecycleEnvelope, proof: AgentLifecycleBindingProof, expectedBinding: AgentTerminalBinding, expectedSourceIdentity: String) -> AgentLifecycleAcceptance {
        guard registry.manifest(for: envelope.providerID) != nil else { return .rejected(.unknownProvider) }
        guard AgentLifecycleEnvelope.compatibleVersions.contains(envelope.version) else { return .rejected(.unsupportedVersion) }
        guard proof.binding == expectedBinding else { return .rejected(.staleBinding) }
        guard proof.sourceIdentity == expectedSourceIdentity else { return .rejected(.sourceMismatch) }
        let actionablePIDProof = envelope.agentPID.map { proof.processIDs.contains($0) } ?? false
        // Providers sometimes emit a truthful lifecycle state before a stable
        // agent PID exists.  An observe-only registration is allowed to carry
        // that state, but its exact capability shape prevents it from ever
        // authorizing send/interrupt/prompt/launch.
        let observeOnlyFallback = envelope.agentPID == nil &&
            proof.processIDs.isEmpty &&
            proof.binding.agentPID == nil &&
            proof.binding.capabilities == [.observe]
        guard actionablePIDProof || observeOnlyFallback else { return .rejected(.pidMismatch) }
        guard envelope.version < 9 || envelope.transcriptRef != nil else { return .rejected(.invalidV9Locator) }
        let threadID = envelope.providerSessionID.flatMap {
            AgentThreadID(hostID: proof.hostID, providerID: envelope.providerID, providerSessionID: $0)
        }
        return .accepted(threadID: threadID)
    }
}
