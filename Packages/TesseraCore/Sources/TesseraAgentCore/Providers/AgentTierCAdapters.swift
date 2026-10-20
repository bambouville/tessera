import Foundation

/// Pure, fixture-pinned adapters for providers whose live routes are gated.
/// These types deliberately parse only the documented storage/protocol shapes;
/// callers must not turn a parse failure into a shell/PTY fallback.
public enum AgentTierCAdapterError: Error, Equatable, Sendable {
    case unsupportedSchema
    case malformedCursor
    case malformedOpenCodeRecord
    case malformedRPCFrame
    case malformedPiRPCState
    case unexpectedPiRPCResponse
    case rpcNotAttached
    case cancelled
    case malformedKimiWire
}

public struct AgentOpenCodeSQLiteSchema: Equatable, Sendable {
    public let tables: [String: Set<String>]
    public init(tables: [String: Set<String>]) { self.tables = tables }
}

public struct AgentOpenCodeCursor: Equatable, Codable, Sendable {
    public let sessionID: String
    public let partID: String
    public init?(sessionID: String, partID: String) {
        guard !sessionID.isEmpty, !partID.isEmpty, sessionID.utf8.count <= 512, partID.utf8.count <= 512 else { return nil }
        self.sessionID = sessionID; self.partID = partID
    }
}

public enum AgentOpenCodeSQLiteAdapter {
    public static let adapterID = "opencode-sqlite-v1"
    public static let wireCapability = "opencode.sqlite.v1-v2"

    /// Current pinned read-only shape from OpenCode 1.18.x.  This includes
    /// ordering columns rather than merely the JSON payload columns: a
    /// projector must never guess a stable transcript order after a schema
    /// change.
    public static let requiredTables: [String: Set<String>] = [
        "session": ["id", "title", "directory", "version", "time_created", "time_updated"],
        "message": ["id", "session_id", "time_created", "time_updated", "data"],
        "part": ["id", "message_id", "session_id", "time_created", "time_updated", "data"]
    ]

    public static func validate(schema: AgentOpenCodeSQLiteSchema) throws {
        for (table, columns) in requiredTables {
            guard schema.tables[table]?.isSuperset(of: columns) == true else { throw AgentTierCAdapterError.unsupportedSchema }
        }
    }

    /// The platform calls this only after a read-only live probe has both
    /// inspected the schema and successfully projected a redacted fixture.
    /// A schema match alone is deliberately insufficient to expose the UI.
    public static func liveConformance(
        schema: AgentOpenCodeSQLiteSchema,
        liveGatePassed: Bool
    ) -> AgentAdapterConformance? {
        guard liveGatePassed, (try? validate(schema: schema)) != nil else { return nil }
        return AgentAdapterConformance(
            providerID: .opencode,
            adapterID: adapterID,
            sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.opencode]!,
            liveGatePassed: true
        )
    }

    public static func encode(cursor: AgentOpenCodeCursor) -> String {
        let data = (try? JSONEncoder().encode(cursor)) ?? Data()
        return data.base64URLEncodedString()
    }

    public static func decode(cursor: String?) throws -> AgentOpenCodeCursor? {
        guard let cursor else { return nil }
        guard let data = Data(base64URLEncoded: cursor), let decoded = try? JSONDecoder().decode(AgentOpenCodeCursor.self, from: data) else {
            throw AgentTierCAdapterError.malformedCursor
        }
        return decoded
    }

    /// Converts the strictly selected OpenCode `message.data` and `part.data`
    /// JSON values into one shared transcript record. The caller is expected to
    /// have already schema-validated a read-only SQLite snapshot; malformed
    /// provider JSON is not made into a plausible message.
    public static func normalize(
        sequence: UInt64,
        sessionID: String,
        partID: String,
        message: AgentJSONValue,
        part: AgentJSONValue
    ) throws -> AgentProjectionRecord {
        guard validIdentifier(sessionID), validIdentifier(partID),
              let messageFields = message.objectValue,
              let partFields = part.objectValue,
              let partType = partFields["type"]?.stringValue,
              !partType.isEmpty,
              partType.utf8.count <= 128
        else { throw AgentTierCAdapterError.malformedOpenCodeRecord }

        let role = clipped(messageFields["role"]?.stringValue ?? "assistant", limit: 32)
        var record: [String: AgentJSONValue] = [
            "provider": .string("opencode"),
            "sessionID": .string(sessionID),
        ]
        switch partType {
        case "text":
            record["type"] = .string("message")
            record["role"] = .string(role)
            record["blocks"] = .array([.object([
                "type": .string("text"),
                "text": .string(clipped(partFields["text"]?.stringValue ?? "", limit: 16_384)),
            ])])
        case "reasoning":
            record["type"] = .string("message")
            record["role"] = .string("assistant")
            record["blocks"] = .array([.object([
                "type": .string("thinking"),
                "text": .string(clipped(partFields["text"]?.stringValue ?? "", limit: 16_384)),
            ])])
        case "tool", "tool_result":
            record["type"] = .string("message")
            record["role"] = .string("tool")
            let name = clipped(partFields["tool"]?.stringValue ?? partFields["name"]?.stringValue ?? "Tool", limit: 256)
            let output = partFields["output"]?.stringValue ?? partFields["text"]?.stringValue ?? ""
            record["blocks"] = .array([.object([
                "type": .string(partType == "tool" ? "tool_call" : "tool_result"),
                "name": .string(name),
                "preview": .string(clipped(output, limit: 16_384)),
            ])])
        case "step-finish":
            record["type"] = .string("completion")
            record["summary"] = .string(clipped(partFields["reason"]?.stringValue ?? "", limit: 16_384))
        case "step-start":
            record["type"] = .string("metadata")
        default:
            record["type"] = .string("unknown")
            record["sourceType"] = .string(partType)
        }
        if let timestamp = partFields["time"] { record["timestamp"] = timestamp }
        guard let projection = AgentProjectionRecord(
            sequence: sequence,
            recordID: "opencode-\(partID)",
            record: .object(record)
        ) else { throw AgentTierCAdapterError.malformedOpenCodeRecord }
        return projection
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0.value == 95 || $0.value == 45 || $0.value == 46
        }
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        String(decoding: value.utf8.prefix(limit), as: UTF8.self)
    }
}

/// Bounded Pi RPC codec.  Pi is JSONL, but it is not JSON-RPC: commands carry
/// a `type` (and optional caller-chosen `id`) directly.  The adapter consumes
/// an already-attached `pi --mode rpc` stream; it neither launches Pi nor
/// writes to an interactive agent PTY.
/// Read-only persisted branch history supplied by the authenticated native
/// host. A CLI/RPC probe alone cannot attest this independent reader.
public enum AgentPiSessionAdapter {
    public static let adapterID = "pi-session-jsonl-v1-v3"
    public static let wireCapability = "pi.sessions.v1-v3"
}

public enum AgentPiRPCAdapter {
    public static let adapterID = "pi-rpc-jsonl-v1"

    /// State is intentionally metadata-only.  `sessionFile` is never an
    /// authority to open a file: a platform endpoint may use it only as an
    /// opaque Pi attachment argument after its own remote-path validation.
    public struct State: Equatable, Sendable {
        public let isStreaming: Bool
        public let sessionID: String?
        public let sessionFile: String?
        public let messageCount: Int
        public let pendingMessageCount: Int

        public var durableIdentity: String? { sessionID ?? sessionFile }

        public init?(
            isStreaming: Bool,
            sessionID: String?,
            sessionFile: String?,
            messageCount: Int,
            pendingMessageCount: Int
        ) {
            guard sessionID.map(AgentPiRPCAdapter.validMetadataString) ?? true,
                  sessionFile.map(AgentPiRPCAdapter.validMetadataString) ?? true,
                  messageCount >= 0,
                  pendingMessageCount >= 0
            else { return nil }
            self.isStreaming = isStreaming
            self.sessionID = sessionID
            self.sessionFile = sessionFile
            self.messageCount = messageCount
            self.pendingMessageCount = pendingMessageCount
        }
    }

    public static func getState(id: String? = nil) throws -> Data {
        try command(type: "get_state", id: id)
    }

    public static func prompt(id: String? = nil, message: String) throws -> Data {
        guard !message.isEmpty, message.utf8.count <= 49_152, containsOnlySafeText(message) else {
            throw AgentTierCAdapterError.malformedRPCFrame
        }
        return try command(type: "prompt", id: id, fields: ["message": .string(message)])
    }

    public static func abort(id: String? = nil) throws -> Data {
        try command(type: "abort", id: id)
    }

    public static func command(
        type: String,
        id: String? = nil,
        fields: [String: AgentJSONValue] = [:]
    ) throws -> Data {
        guard validCommandType(type), id.map(validRequestID) ?? true,
              fields["type"] == nil, fields["id"] == nil
        else { throw AgentTierCAdapterError.malformedRPCFrame }
        var root = fields
        root["type"] = .string(type)
        if let id { root["id"] = .string(id) }
        let data = try JSONEncoder().encode(AgentJSONValue.object(root))
        guard data.count < AgentExecFrame.maximumFrameBytes else { throw AgentTierCAdapterError.malformedRPCFrame }
        return data + Data([0x0A])
    }

    /// One record is delimited by LF.  Pi's documented decoder permits one
    /// CR immediately before that LF for Windows pipes; all other CR or LF
    /// bytes are rejected rather than becoming ambiguous nested records.
    public static func decodeLine(_ data: Data) throws -> AgentJSONValue {
        guard !Task.isCancelled else { throw AgentTierCAdapterError.cancelled }
        guard data.last == 0x0A, data.count <= AgentExecFrame.maximumFrameBytes else {
            throw AgentTierCAdapterError.malformedRPCFrame
        }
        var body = Data(data.dropLast())
        if body.last == 0x0D { body.removeLast() }
        guard !body.isEmpty, !body.contains(0x0A), !body.contains(0x0D),
              let value = try? JSONDecoder().decode(AgentJSONValue.self, from: body),
              value.isBounded()
        else { throw AgentTierCAdapterError.malformedRPCFrame }
        return value
    }

    /// Verifies a nonce-correlated `get_state` response.  A malformed,
    /// failed, missing-id, or out-of-order response fails closed and cannot
    /// enable Pi's capability manifest.
    public static func decodeStateResponse(
        _ data: Data,
        expectedRequestID: String
    ) throws -> State {
        guard validRequestID(expectedRequestID), let object = try decodeLine(data).objectValue,
              object["type"]?.stringValue == "response",
              object["command"]?.stringValue == "get_state",
              object["success"]?.boolValue == true,
              object["id"]?.stringValue == expectedRequestID,
              let fields = object["data"]?.objectValue,
              let isStreaming = fields["isStreaming"]?.boolValue,
              let messageCount = decimalInt(fields["messageCount"]?.numberValue),
              let pendingMessageCount = decimalInt(fields["pendingMessageCount"]?.numberValue),
              let state = State(
                  isStreaming: isStreaming,
                  sessionID: nullableString(fields["sessionId"]),
                  sessionFile: nullableString(fields["sessionFile"]),
                  messageCount: messageCount,
                  pendingMessageCount: pendingMessageCount
              ), state.durableIdentity != nil
        else { throw AgentTierCAdapterError.malformedPiRPCState }
        return state
    }

    /// Produces the immutable, fixture-pinned capability attestation only
    /// after a live, nonce-correlated state probe has supplied durable Pi
    /// identity.  The state itself is deliberately not encoded into ABI data.
    public static func liveConformance(for state: State) -> AgentAdapterConformance? {
        guard state.durableIdentity != nil else { return nil }
        return AgentAdapterConformance(
            providerID: .pi,
            adapterID: adapterID,
            sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.pi]!,
            liveGatePassed: true
        )
    }

    /// Maps only documented RPC event fields to the existing transcript
    /// vocabulary.  Unknown events stay explicitly unknown rather than being
    /// guessed into messages.
    public static func normalize(sequence: UInt64, event: AgentJSONValue) throws -> AgentProjectionRecord {
        guard let fields = event.objectValue,
              let eventType = fields["type"]?.stringValue,
              validCommandType(eventType)
        else { throw AgentTierCAdapterError.malformedRPCFrame }
        var record: [String: AgentJSONValue] = ["provider": .string("pi")]
        switch eventType {
        case "message_update":
            guard let update = fields["assistantMessageEvent"]?.objectValue,
                  update["type"]?.stringValue == "text_delta",
                  let delta = update["delta"]?.stringValue
            else { throw AgentTierCAdapterError.malformedRPCFrame }
            record["type"] = .string("message")
            record["role"] = .string("assistant")
            record["text"] = .string(clipped(delta, limit: 16_384))
        case "message_end", "turn_end":
            guard let message = fields["message"]?.objectValue else { throw AgentTierCAdapterError.malformedRPCFrame }
            record["type"] = .string("message")
            record["role"] = .string(clipped(message["role"]?.stringValue ?? "assistant", limit: 32))
            if let content = message["content"]?.stringValue {
                record["text"] = .string(clipped(content, limit: 16_384))
            } else {
                record["sourceType"] = .string("pi-message-without-text")
            }
        case "agent_end":
            record["type"] = .string("completion")
            record["summary"] = .string("")
        case "queue_update":
            let steering = fields["steering"]?.arrayValue?.count ?? 0
            let followUp = fields["followUp"]?.arrayValue?.count ?? 0
            record["type"] = .string("queue-operation")
            record["pending"] = .number(Decimal(steering + followUp))
        default:
            record["type"] = .string("unknown")
            record["sourceType"] = .string(eventType)
        }
        guard let projection = AgentProjectionRecord(
            sequence: sequence,
            recordID: "pi-\(sequence)-\(eventType)",
            record: .object(record)
        ) else { throw AgentTierCAdapterError.malformedRPCFrame }
        return projection
    }

    private static func validCommandType(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    private static func validRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && containsOnlySafeText(value)
    }

    private static func validMetadataString(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2_048 && containsOnlySafeText(value)
    }

    private static func containsOnlySafeText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func nullableString(_ value: AgentJSONValue?) -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return value.stringValue
    }

    private static func decimalInt(_ value: Decimal?) -> Int? {
        guard var value, value >= 0, value <= Decimal(Int.max) else { return nil }
        var integral = Decimal()
        NSDecimalRound(&integral, &value, 0, .down)
        guard integral == value else { return nil }
        return NSDecimalNumber(decimal: value).intValue
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        String(decoding: value.utf8.prefix(limit), as: UTF8.self)
    }
}

public enum AgentKimiWireAdapter {
    public static let adapterID = "kimi-wire-jsonl-v1.4-v1.5"
    public static let wireCapability = "kimi.wire.v1.4-v1.5"

    public static func liveConformance(
        sessionIndexPassed: Bool,
        hookConfigurationPassed: Bool
    ) -> AgentAdapterConformance? {
        guard sessionIndexPassed, hookConfigurationPassed else { return nil }
        return AgentAdapterConformance(
            providerID: .kimi,
            adapterID: adapterID,
            sourceFixtureDigest: AgentProviderCapabilityGate.expectedFixtureDigests[.kimi]!,
            liveGatePassed: true
        )
    }

    /// Converts current Kimi wire JSONL records into the shared canonical
    /// envelope. The caller supplies only records found through the pinned
    /// `session_index.jsonl` -> `sessions/<wd>/<id>/agents/*/wire.jsonl` walk.
    public static func normalize(sequence: UInt64, wire: AgentJSONValue) throws -> AgentProjectionRecord {
        guard let object = wire.objectValue else { throw AgentTierCAdapterError.malformedKimiWire }
        guard let event = object["type"]?.stringValue,
              !event.isEmpty,
              event.utf8.count <= 128
        else { throw AgentTierCAdapterError.malformedKimiWire }
        var record: [String: AgentJSONValue] = ["provider": .string("kimi")]
        switch event {
        case "turn.prompt":
            record["type"] = .string("message")
            record["role"] = .string("user")
            record["blocks"] = blocks(object["input"])
        case "context.append_message":
            guard let message = object["message"]?.objectValue else {
                throw AgentTierCAdapterError.malformedKimiWire
            }
            record["type"] = .string("message")
            record["role"] = .string(clipped(message["role"]?.stringValue ?? "user", limit: 32))
            record["blocks"] = blocks(message["content"])
        case "context.append_loop_event":
            guard let loop = object["event"]?.objectValue,
                  let loopType = loop["type"]?.stringValue
            else { throw AgentTierCAdapterError.malformedKimiWire }
            switch loopType {
            case "content.part":
                guard let part = loop["part"]?.objectValue,
                      let kind = part["type"]?.stringValue,
                      kind == "text" || kind == "think"
                else { throw AgentTierCAdapterError.malformedKimiWire }
                let text = kind == "think" ? part["think"]?.stringValue : part["text"]?.stringValue
                record["type"] = .string("message")
                record["role"] = .string("assistant")
                record["blocks"] = .array([.object([
                    "type": .string(kind == "think" ? "thinking" : "text"),
                    "text": .string(clipped(text ?? "", limit: 16_384)),
                ])])
            case "tool.call":
                record["type"] = .string("message")
                record["role"] = .string("tool")
                record["blocks"] = .array([.object([
                    "type": .string("tool_call"),
                    "name": .string(clipped(loop["name"]?.stringValue ?? "Tool", limit: 256)),
                    "preview": .string(clipped(render(loop["args"]), limit: 16_384)),
                ])])
            case "tool.result":
                let result = loop["result"]?.objectValue
                record["type"] = .string("message")
                record["role"] = .string("tool")
                record["blocks"] = .array([.object([
                    "type": .string("tool_result"),
                    "preview": .string(clipped(render(result?["output"]), limit: 16_384)),
                    "truncated": .bool(false),
                ])])
            case "step.end":
                let usage = loop["usage"]?.objectValue ?? [:]
                let used = ["inputOther", "inputCacheRead", "inputCacheCreation", "output"]
                    .compactMap { usage[$0]?.numberValue }
                    .reduce(Decimal.zero, +)
                record["type"] = .string("cost-state")
                record["used_tokens"] = .number(used)
            default:
                record["type"] = .string("unknown")
                record["sourceType"] = .string(clipped(loopType, limit: 128))
            }
        case "usage.record":
            let usage = object["usage"]?.objectValue ?? [:]
            let used = ["inputOther", "inputCacheRead", "inputCacheCreation", "output"]
                .compactMap { usage[$0]?.numberValue }
                .reduce(Decimal.zero, +)
            record["type"] = .string("cost-state")
            record["used_tokens"] = .number(used)
            if let model = object["model"]?.stringValue { record["model"] = .string(clipped(model, limit: 256)) }
        case "config.update":
            record["type"] = .string("metadata")
            if let model = object["modelAlias"]?.stringValue { record["model"] = .string(clipped(model, limit: 256)) }
        case "permission.set_mode":
            record["type"] = .string("permission-mode")
            record["mode"] = .string(clipped(object["mode"]?.stringValue ?? "", limit: 64))
        case "turn.cancel":
            record["type"] = .string("completion")
            record["summary"] = .string("Cancelled")
        default:
            record["type"] = .string("unknown")
            record["sourceType"] = .string(String(event.prefix(128)))
        }
        if let timestamp = object["time"] ?? object["created_at"] { record["timestamp"] = timestamp }
        guard let projection = AgentProjectionRecord(
            sequence: sequence,
            recordID: "kimi-\(sequence)-\(event.replacingOccurrences(of: ".", with: "-"))",
            record: .object(record)
        ) else { throw AgentTierCAdapterError.malformedKimiWire }
        return projection
    }

    public static func lifecycle(_ fields: [String: AgentJSONValue]) -> AgentLifecycleEnvelope? {
        let event = AgentLifecycleEventKind(rawValue: fields["event"]?.stringValue ?? "") ?? .notification
        let status = AgentStatus(rawValue: fields["state"]?.stringValue ?? "") ?? .working
        let pid = fields["agent_pid"]?.numberValue.map { NSDecimalNumber(decimal: $0).intValue }
        return AgentLifecycleEnvelope(version: 9, providerID: .kimi, event: event, status: status, providerSessionID: fields["session_id"]?.stringValue ?? fields["sessionId"]?.stringValue, agentPID: pid, transcriptRef: fields["transcript_ref"]?.stringValue ?? fields["transcriptRef"]?.stringValue, agentID: fields["agent_id"]?.stringValue, agentType: fields["agent_type"]?.stringValue, rootAgentID: fields["root_agent_id"]?.stringValue)
    }

    private static func blocks(_ value: AgentJSONValue?) -> AgentJSONValue {
        if let string = value?.stringValue {
            return .array([.object(["type": .string("text"), "text": .string(clipped(string, limit: 16_384))])])
        }
        guard let values = value?.arrayValue else { return .array([]) }
        return .array(values.prefix(128).map { item in
            guard let fields = item.objectValue,
                  let kind = fields["type"]?.stringValue
            else { return .object(["type": .string("unknown")]) }
            switch kind {
            case "text":
                return .object(["type": .string("text"), "text": .string(clipped(fields["text"]?.stringValue ?? "", limit: 16_384))])
            case "think", "thinking":
                return .object(["type": .string("thinking"), "text": .string(clipped(fields["think"]?.stringValue ?? fields["thinking"]?.stringValue ?? "", limit: 16_384))])
            default:
                return .object(["type": .string("unknown")])
            }
        })
    }

    private static func render(_ value: AgentJSONValue?) -> String {
        guard let value else { return "" }
        if let string = value.stringValue { return string }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        String(decoding: value.utf8.prefix(limit), as: UTF8.self)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
