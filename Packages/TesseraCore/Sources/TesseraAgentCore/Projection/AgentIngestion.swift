import Foundation

/// Native-host range continuity. `order` is a provider order key (a byte
/// offset for JSONL), NOT a dense line counter. History and live cursors must
/// never be substituted for each other or used as terminal-action evidence.
public struct AgentIngestionRange: Equatable, Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case bootstrap, history, updates }
    public let epoch: String
    public let requestID: String
    public let operation: Operation
    public let liveCursor: String?
    public let hasNewer: Bool
    /// Raw JSONL EOF at read start, including an incomplete trailing line.
    /// This is receipt evidence only after a fresh caught-up update commits.
    public let sourceEnd: UInt64?
    public let window: AgentIngestionWindowTransaction?

    public init?(epoch: String, requestID: String, operation: Operation, liveCursor: String?, hasNewer: Bool = false, sourceEnd: UInt64? = nil,
                 window: AgentIngestionWindowTransaction? = nil) {
        guard Self.identifier(epoch), Self.identifier(requestID),
              liveCursor.map(Self.identifier) ?? true,
              (operation == .history) == (liveCursor == nil), operation != .history || (!hasNewer && sourceEnd == nil) else { return nil }
        self.epoch = epoch; self.requestID = requestID; self.operation = operation; self.liveCursor = liveCursor
        self.hasNewer = hasNewer
        self.sourceEnd = sourceEnd
        if let window {
            guard (operation == .bootstrap) == (window.lane == .bootstrap),
                  (operation == .history) == (window.lane == .before || window.lane == .after) else { return nil }
        }
        self.window = window
    }

    public static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = try Self(epoch: values.decode(String.self, forKey: .epoch),
            requestID: values.decode(String.self, forKey: .requestID),
            operation: values.decode(Operation.self, forKey: .operation),
            liveCursor: values.decodeIfPresent(String.self, forKey: .liveCursor),
            hasNewer: values.decodeIfPresent(Bool.self, forKey: .hasNewer) ?? false,
            sourceEnd: values.decodeIfPresent(UInt64.self, forKey: .sourceEnd),
            window: values.decodeIfPresent(AgentIngestionWindowTransaction.self, forKey: .window)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ingestion range"))
        }
        self = value
    }
}

public enum AgentIngestionError: Error, Equatable, Sendable {
    case malformedFrame, capacityExceeded, staleEpoch, incompletePage, remote(String)
}

/// Observational card data. Deliberately not a page and carries no canonical
/// cursor, lifecycle status, action authority, or receipt witness.
public struct AgentIngestionSummary: Sendable {
    public let epoch: String
    public let requestID: String
    public let thread: String
    public let revision: String
    public let modified: Date
    public let records: [AgentJSONValue]
    /// The host's classifier code for card metadata it could not read (for
    /// example `codexTitleUnavailable`), never transcript content. The
    /// transcript itself is unaffected; only the card's native title is. A
    /// value outside the code rule (a newer host's spelling) reads as
    /// `unclassified` rather than failing the frame: this field only feeds
    /// the diagnostics log and must never cost the connection.
    public let metadataIssue: String?
    /// The underlying store code behind `metadataIssue` (for example
    /// `opencodeDatabaseUnavailable`), under the same code rule. Two hosts
    /// reporting the same issue for different reasons must log differently.
    public let metadataReason: String?

    public init(epoch: String, requestID: String, thread: String, revision: String, modified: Date,
                records: [AgentJSONValue], metadataIssue: String? = nil, metadataReason: String? = nil) {
        self.epoch = epoch; self.requestID = requestID; self.thread = thread; self.revision = revision
        self.modified = modified; self.records = records; self.metadataIssue = metadataIssue
        self.metadataReason = metadataReason
    }

    /// A host code is ASCII alphanumeric and short; anything else (a newer
    /// host's spelling, or a message that leaked) reads as `unclassified`.
    static func metadataCode(_ value: AgentJSONValue?) -> String? {
        guard let value else { return nil }
        if let code = value.stringValue, !code.isEmpty, code.utf8.count <= 80,
           code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) {
            return code
        }
        return "unclassified"
    }

    public static func decode(_ data: Data, epoch: String, thread: String) throws -> Self {
        guard data.count <= 65_536,
              let value = try JSONDecoder().decode(AgentJSONValue.self, from: data).objectValue,
              value["kind"]?.stringValue == "summary", value["serviceEpoch"]?.stringValue == epoch,
              value["thread"]?.stringValue == thread,
              AgentIngestionRange.identifier(epoch), AgentIngestionRange.identifier(thread),
              let id = value["id"]?.stringValue, AgentIngestionRange.identifier(id),
              let revision = value["revision"]?.stringValue, AgentIngestionRange.identifier(revision),
              let seconds = value["modified"]?.numberValue, seconds >= 0, seconds <= 32_503_680_000,
              let records = value["records"]?.arrayValue, records.count <= 16,
              records.allSatisfy({ $0.isBounded() }) else { throw AgentIngestionError.malformedFrame }
        return Self(epoch: epoch, requestID: id, thread: thread, revision: revision,
            modified: Date(timeIntervalSince1970: NSDecimalNumber(decimal: seconds).doubleValue), records: records,
            metadataIssue: metadataCode(value["metadataIssue"]), metadataReason: metadataCode(value["metadataReason"]))
    }
}

public struct AgentLivePreview: Equatable, Codable, Sendable {
    public let id: String
    public let text: String
    public let hasGap: Bool
}

public struct AgentIngestionHook: Sendable {
    public let epoch: String
    public let requestID: String
    public let sessionID: String
    let messageID: String
    let turnID: String
    let index: Int
    let delta: String
    let final: Bool
    let invalidates: Bool

    public static func decode(_ data: Data, epoch: String, thread: String) throws -> Self {
        guard data.count <= 65_536,
              let value = try JSONDecoder().decode(AgentJSONValue.self, from: data).objectValue,
              value["kind"]?.stringValue == "hookPreview", value["serviceEpoch"]?.stringValue == epoch,
              value["thread"]?.stringValue == thread, AgentIngestionRange.identifier(epoch), AgentIngestionRange.identifier(thread),
              let id = value["id"]?.stringValue, AgentIngestionRange.identifier(id),
              let event = value["event"]?.objectValue, let session = event["session_id"]?.stringValue,
              !session.isEmpty, session.utf8.count <= 256 else { throw AgentIngestionError.malformedFrame }
        let message = event["message_id"]?.stringValue ?? ""
        let turn = event["turn_id"]?.stringValue ?? ""
        let delta = event["delta"]?.stringValue ?? ""
        let number = event["index"]?.numberValue ?? -1
        let index = NSDecimalNumber(decimal: number).intValue
        let valid = event["hook_event_name"]?.stringValue == "MessageDisplay" && !message.isEmpty &&
            message.utf8.count <= 256 && turn.utf8.count <= 256 && delta.utf8.count <= 32768 &&
            index >= 0 && index <= 4096 && Decimal(index) == number && event["final"]?.boolValue != nil
        return Self(epoch: epoch, requestID: id, sessionID: session, messageID: message, turnID: turn,
            index: index, delta: delta, final: event["final"]?.boolValue ?? false, invalidates: !valid)
    }
}

struct AgentHookOverlayState: Sendable {
    private struct Batch: Equatable, Sendable { let text: String; let final: Bool }
    private var key = ""
    private var retired: [String] = []
    private var batches: [Int: Batch] = [:]
    private var bytes = 0
    private var completed = false
    private(set) var preview: AgentLivePreview?
    var estimatedBytes: Int { bytes + (preview?.text.utf8.count ?? 0) + batches.count * 64 + retired.reduce(0) { $0 + $1.utf8.count } }

    mutating func accept(_ hook: AgentIngestionHook) {
        if hook.invalidates { reset(); return }
        let incoming = hook.turnID + ":" + hook.messageID
        if retired.contains(incoming) { return }
        if incoming != key {
            // A delayed continuation from an earlier display cannot replace
            // the active display. Index zero establishes a new display.
            if !key.isEmpty && hook.index != 0 { return }
            retire(); key = incoming
        }
        let batch = Batch(text: hook.delta, final: hook.final)
        if let previous = batches[hook.index] {
            if previous != batch { retire() }
            return
        }
        guard batches.count < 256, bytes + hook.delta.utf8.count <= 32768 else { retire(); return }
        batches[hook.index] = batch; bytes += hook.delta.utf8.count
        var text = "", next = 0, final = false
        while let batch = batches[next] {
            text += batch.text; next += 1
            if batch.final { final = true; break }
        }
        // At most eight out-of-order batches; gaps are explicit, never
        // silently concatenated into fabricated assistant prose.
        guard batches.keys.filter({ $0 >= next }).count <= 8,
              !final || batches.keys.allSatisfy({ $0 < next }) else { retire(); return }
        let display = AgentDisplayText.sanitize(text)
        preview = display.isEmpty ? nil : .init(id: key, text: display, hasGap: batches.keys.contains(where: { $0 >= next }))
        completed = final
    }

    mutating func reconcile(_ messages: [AgentMessage], newRecordIDs: Set<String> = [], allowCompletedMatch: Bool = false) {
        guard let preview else { return }
        let candidates = messages.suffix(16).filter { $0.role == .assistant }
        func text(_ message: AgentMessage) -> String {
            AgentDisplayText.sanitize(message.blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined())
        }
        // Display IDs are not transcript IDs. Canonical text wins and the
        // provisional overlay disappears; it is never inserted into history.
        if candidates.contains(where: { newRecordIDs.contains($0.recordID) && text($0).hasPrefix(preview.text) }) { retire(); return }
        // A late final hook can arrive after its canonical record. Only exact
        // complete-text equality against the latest assistant is usable here;
        // an old generic prefix such as "Sure" must not kill a new stream.
        if allowCompletedMatch, completed, let latest = candidates.last, text(latest) == preview.text { retire() }
    }
    mutating func reset() { key = ""; retired = []; batches = [:]; bytes = 0; preview = nil; completed = false }
    private mutating func retire() {
        if !key.isEmpty { retired.append(key); if retired.count > 8 { retired.removeFirst() } }
        key = ""; batches = [:]; bytes = 0; preview = nil; completed = false
    }
}

public enum AgentIngestionProjection {
    /// JNI passes original framed bytes, not numbers re-encoded by a platform
    /// JSON library. Both native apps therefore share exact UInt64, revision,
    /// transaction and cursor validation.
    public static func decode(_ bytes: Data, epoch: String, thread: String) throws -> AgentProjectionPage {
        guard bytes.count <= 300_000, AgentIngestionRange.identifier(thread) else { throw AgentIngestionError.capacityExceeded }
        var framer = AgentIngestionFramer()
        var decoder = try AgentIngestionPageDecoder(epoch: epoch)
        var page: AgentProjectionPage?
        try framer.append(bytes) { frame in
            if let complete = try decoder.accept(frame) {
                guard complete.thread == thread, page == nil else { throw AgentIngestionError.malformedFrame }
                page = complete.page
            }
        }
        try framer.finish(); try decoder.finish()
        guard let page else { throw AgentIngestionError.incompletePage }
        return page
    }
}

/// Incremental 4-byte BE framing; bounded independently of SSH callback size.
/// A complete frame is consumed before accepting more than one frame of input.
public struct AgentIngestionFramer: Sendable {
    public static let maximumFrameBytes = 65_536
    private var pending = Data()

    public init() {}

    public mutating func append(_ bytes: Data, consume: (Data) throws -> Void) throws {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let target: Int
            if pending.count < 4 { target = 4 }
            else {
                let size = pending.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size <= Self.maximumFrameBytes else { throw AgentIngestionError.malformedFrame }
                target = 4 + Int(size)
            }
            let count = min(target - pending.count, bytes.endIndex - offset)
            pending.append(contentsOf: bytes[offset..<(offset + count)]); offset += count
            if pending.count == target, target > 4 {
                let frame = Data(pending.dropFirst(4)); pending.removeAll(keepingCapacity: true)
                try consume(frame)
            }
        }
    }

    public func finish() throws {
        guard pending.isEmpty else { throw AgentIngestionError.incompletePage }
    }

    public static func encode(_ value: AgentJSONValue) throws -> Data {
        guard value.isBounded() else { throw AgentIngestionError.capacityExceeded }
        let json = try JSONEncoder().encode(value)
        guard !json.isEmpty, json.count <= maximumFrameBytes else { throw AgentIngestionError.capacityExceeded }
        let size = UInt32(json.count)
        var data = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        data.append(json); return data
    }
}

/// Multiplexed page transactions commit only at page.end. Disconnect, malformed
/// frames, wrong epoch, duplicate IDs and capacity errors discard all pending
/// work; callers reconnect/bootstrap, never publish a partial transaction.
enum AgentIngestionSourceIdentity {
    static func indexedFile(_ source: String) -> Bool {
        source.hasPrefix("claude-chain:") || source.hasPrefix("codex-history:") || source.hasPrefix("pi-chain:") || source.hasPrefix("kimi-history:")
    }
    static func file(_ source: String) -> Bool { source.hasPrefix("jsonl:") || indexedFile(source) }
}

public struct AgentIngestionPageDecoder: Sendable {
    private struct Pending: Sendable {
        let thread: String
        let identity: String
        let operation: AgentIngestionRange.Operation
        let from: String?
        var records: [AgentProjectionRecord] = []
        var bytes: Int
    }
    public let epoch: String
    private var pending: [String: Pending] = [:]

    public init(epoch: String) throws {
        guard AgentIngestionRange.identifier(epoch) else { throw AgentIngestionError.malformedFrame }
        self.epoch = epoch
    }

    public mutating func accept(_ data: Data) throws -> (thread: String, page: AgentProjectionPage)? {
        do { return try acceptValidated(data) }
        catch { pending.removeAll(); throw error }
    }

    private mutating func acceptValidated(_ data: Data) throws -> (thread: String, page: AgentProjectionPage)? {
        guard data.count <= AgentIngestionFramer.maximumFrameBytes,
              let object = try JSONDecoder().decode(AgentJSONValue.self, from: data).objectValue,
              let kind = object["kind"]?.stringValue,
              object["serviceEpoch"]?.stringValue == epoch else { throw AgentIngestionError.staleEpoch }
        guard kind.hasPrefix("page.") else { return nil }
        guard let id = object["id"]?.stringValue, AgentIngestionRange.identifier(id),
              let thread = object["thread"]?.stringValue, AgentIngestionRange.identifier(thread) else {
            throw AgentIngestionError.malformedFrame
        }
        if kind == "page.begin" {
            guard pending[id] == nil, pending.count < 16,
                  let identity = object["sourceIdentity"]?.stringValue, !identity.isEmpty, identity.utf8.count <= 512,
                  let name = object["operation"]?.stringValue, let operation = AgentIngestionRange.Operation(rawValue: name) else {
                throw AgentIngestionError.malformedFrame
            }
            let from = object["from"]?.stringValue
            guard (operation == .bootstrap) == (from == nil), from.map(AgentIngestionRange.identifier) ?? true else {
                throw AgentIngestionError.malformedFrame
            }
            pending[id] = Pending(thread: thread, identity: identity, operation: operation, from: from, bytes: data.count)
            return nil
        }
        guard var transaction = pending[id], transaction.thread == thread else { throw AgentIngestionError.incompletePage }
        transaction.bytes += data.count
        guard transaction.bytes <= 262_144,
              pending.values.reduce(0, { $0 + $1.bytes }) + data.count <= 1_048_576 else { throw AgentIngestionError.capacityExceeded }
        if kind == "page.record" {
            guard transaction.records.count < 100,
                  let recordID = object["recordID"]?.stringValue,
                  let order = Self.unsigned(object["order"]),
                  let revision = Self.unsigned(object["revision"]), revision > 0,
                  let body = object["record"],
                  (object["sourceOffset"] == nil || Self.unsigned(object["sourceOffset"]) != nil),
                  (!AgentIngestionSourceIdentity.indexedFile(transaction.identity) || Self.unsigned(object["sourceOffset"]) != nil),
                  (object["receiptSourceIdentity"] == nil || object["receiptSourceIdentity"]?.stringValue != nil),
                  (object["receiptSourceOffset"] == nil || Self.receiptOffset(object["receiptSourceOffset"]) != nil),
                  let record = AgentProjectionRecord(sequence: order, recordID: recordID, record: body,
                    sourceOffset: Self.unsigned(object["sourceOffset"]), revision: revision,
                    receiptSourceIdentity: object["receiptSourceIdentity"]?.stringValue,
                    receiptSourceOffset: Self.receiptOffset(object["receiptSourceOffset"])),
                  !transaction.records.contains(where: { $0.recordID == recordID || $0.sequence == order }),
                  transaction.records.last.map({ $0.sequence < order }) ?? true else { throw AgentIngestionError.malformedFrame }
            transaction.records.append(record); pending[id] = transaction; return nil
        }
        let hasNewer = object["hasNewer"]?.boolValue
        let sourceEnd = Self.unsigned(object["sourceEnd"])
        let chain = AgentIngestionSourceIdentity.indexedFile(transaction.identity)
        guard object["sourceEnd"] == nil || (sourceEnd != nil && AgentIngestionSourceIdentity.file(transaction.identity)) else {
            throw AgentIngestionError.malformedFrame
        }
        if let sourceEnd, transaction.records.contains(where: { (chain ? $0.sourceOffset : $0.sequence).map { $0 >= sourceEnd } ?? true }) {
            throw AgentIngestionError.malformedFrame
        }
        guard transaction.operation == .history ? hasNewer == nil : hasNewer != nil else { throw AgentIngestionError.malformedFrame }
        guard kind == "page.end", Self.unsigned(object["records"]) == UInt64(transaction.records.count),
              let range = AgentIngestionRange(epoch: epoch, requestID: id, operation: transaction.operation,
                  liveCursor: object["liveCursor"]?.stringValue, hasNewer: hasNewer ?? false, sourceEnd: sourceEnd,
                  window: try object["window"].map { try JSONDecoder().decode(AgentIngestionWindowTransaction.self, from: JSONEncoder().encode($0)) }) else { throw AgentIngestionError.incompletePage }
        let history = object["historyCursor"]?.stringValue
        let hasOlder = object["hasOlder"]?.boolValue
        if transaction.operation == .updates {
            guard history == nil, hasOlder == nil else { throw AgentIngestionError.malformedFrame }
        } else {
            guard let hasOlder, hasOlder == (history != nil), history.map(AgentIngestionRange.identifier) ?? true else {
                throw AgentIngestionError.malformedFrame
            }
        }
        // Metadata is advisory and page-scoped. Invalid fields, unknown keys,
        // and even a summary that exceeds its encoded budget cannot reject
        // otherwise valid transcript records.
        var acceptedMetadata: [String: AgentJSONValue] = [:]
        if let metadata = object["metadata"]?.objectValue {
            for (key, limit) in [("nativeTitle", 512), ("openingPrompt", 4_096)] {
                if let value = metadata[key]?.stringValue, value.utf8.count <= limit {
                    acceptedMetadata[key] = .string(value)
                }
            }
        }
        let summary: AgentJSONValue? = acceptedMetadata.isEmpty ? nil : .object(acceptedMetadata)
        let page = AgentProjectionPage(sourceIdentity: transaction.identity, from: transaction.from,
            records: transaction.records, cursor: history, hasMore: hasOlder ?? false,
            summary: summary, ingestion: range)
            ?? AgentProjectionPage(sourceIdentity: transaction.identity, from: transaction.from,
                records: transaction.records, cursor: history, hasMore: hasOlder ?? false, ingestion: range)
        guard let page else {
            throw AgentIngestionError.capacityExceeded
        }
        pending.removeValue(forKey: id); return (thread, page)
    }

    public func finish() throws {
        guard pending.isEmpty else { throw AgentIngestionError.incompletePage }
    }

    /// The host sends a receipt offset as a canonical decimal string, as it
    /// sends `receipt.frontier`'s `sourceEnd`, to which it is compared. A JSON
    /// integer is accepted too; "007", "+7" or "7.0" are not.
    private static func receiptOffset(_ value: AgentJSONValue?) -> UInt64? {
        guard let text = value?.stringValue else { return unsigned(value) }
        guard let offset = UInt64(text), String(offset) == text else { return nil }
        return offset
    }

    private static func unsigned(_ value: AgentJSONValue?) -> UInt64? {
        guard let number = value?.numberValue, number >= 0, number <= Decimal(UInt64.max) else { return nil }
        let result = NSDecimalNumber(decimal: number).uint64Value
        return Decimal(result) == number ? result : nil
    }
}
