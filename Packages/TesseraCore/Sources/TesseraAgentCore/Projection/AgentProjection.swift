import Foundation

public enum AgentProjectionKind: String, Codable, Sendable {
    case project
    case inventory
    case search
}

public struct AgentProjectionRequest: Equatable, Codable, Sendable {
    public static let maximumBytes = 262_144
    public static let maximumRecords = 100

    public let version: Int
    public let kind: AgentProjectionKind
    public let providerID: AgentProviderID
    public let transcriptRef: String?
    public let cursor: String?
    public let limitBytes: Int
    public let limitRecords: Int
    public let query: String?
    public let receiptBoundaryOnly: Bool
    /// The previous snapshot's bounded cursor lets the projector prove that
    /// its bytes survived an append before Core retains the loaded history.
    public let continuationCursor: String?

    public init?(version: Int = 1, kind: AgentProjectionKind, providerID: AgentProviderID, transcriptRef: String? = nil, cursor: String? = nil, limitBytes: Int = Self.maximumBytes, limitRecords: Int = Self.maximumRecords, query: String? = nil, receiptBoundaryOnly: Bool = false, continuationCursor: String? = nil) {
        guard version == 1, limitBytes > 0, limitBytes <= Self.maximumBytes,
              limitRecords > 0, limitRecords <= Self.maximumRecords,
              transcriptRef.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true,
              cursor.map({ $0.utf8.count <= 2048 }) ?? true,
              continuationCursor.map({ $0.utf8.count <= 2048 }) ?? true,
              query.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true
        else { return nil }
        self.version = version
        self.kind = kind
        self.providerID = providerID
        self.transcriptRef = transcriptRef
        self.cursor = cursor
        self.limitBytes = limitBytes
        self.limitRecords = limitRecords
        self.query = query
        self.receiptBoundaryOnly = receiptBoundaryOnly
        self.continuationCursor = continuationCursor
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case providerID = "provider"
        case transcriptRef, cursor, limitBytes, limitRecords, query, receiptBoundaryOnly, continuationCursor
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let kind = try values.decode(AgentProjectionKind.self, forKey: .kind)
        let providerValue = try values.decode(String.self, forKey: .providerID)
        guard let providerID = AgentProviderID(rawValue: providerValue) else {
            throw DecodingError.dataCorruptedError(forKey: .providerID, in: values, debugDescription: "Invalid provider identifier")
        }
        let transcriptRef = try values.decodeIfPresent(String.self, forKey: .transcriptRef)
        let cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        let limitBytes = try values.decode(Int.self, forKey: .limitBytes)
        let limitRecords = try values.decode(Int.self, forKey: .limitRecords)
        let query = try values.decodeIfPresent(String.self, forKey: .query)
        let receiptBoundaryOnly = try values.decodeIfPresent(Bool.self, forKey: .receiptBoundaryOnly) ?? false
        let continuationCursor = try values.decodeIfPresent(String.self, forKey: .continuationCursor)
        guard let validated = Self(version: version, kind: kind, providerID: providerID, transcriptRef: transcriptRef, cursor: cursor, limitBytes: limitBytes, limitRecords: limitRecords, query: query, receiptBoundaryOnly: receiptBoundaryOnly, continuationCursor: continuationCursor) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Invalid projection request")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(kind, forKey: .kind)
        try values.encode(providerID.rawValue, forKey: .providerID)
        try values.encodeIfPresent(transcriptRef, forKey: .transcriptRef)
        try values.encodeIfPresent(cursor, forKey: .cursor)
        try values.encode(limitBytes, forKey: .limitBytes)
        try values.encode(limitRecords, forKey: .limitRecords)
        try values.encodeIfPresent(query, forKey: .query)
        if receiptBoundaryOnly { try values.encode(true, forKey: .receiptBoundaryOnly) }
        try values.encodeIfPresent(continuationCursor, forKey: .continuationCursor)
    }
}

public enum AgentProjectionError: String, Codable, Sendable, Error {
    case sourceMissing
    case sourceChanged
    case adapterOutdated
    case permissionDenied
    case unsupported
    case malformed
    case channelUnavailable
}

public struct AgentProjectionRecord: Equatable, Codable, Sendable {
    public let sequence: UInt64
    public let recordID: String
    public let record: AgentJSONValue
    public let sourceOffset: UInt64?
    public let sourceHash: String?
    /// Physical file coordinates for advisory Send correlation; distinct from virtual lineage offsets.
    public let receiptSourceIdentity: String?
    public let receiptSourceOffset: UInt64?
    public let revision: UInt64

    public init?(sequence: UInt64, recordID: String, record: AgentJSONValue, sourceOffset: UInt64? = nil, sourceHash: String? = nil, revision: UInt64 = 1, receiptSourceIdentity: String? = nil, receiptSourceOffset: UInt64? = nil) {
        let record = Self.presentationRecord(record)
        guard (receiptSourceIdentity == nil) == (receiptSourceOffset == nil),
              receiptSourceIdentity.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true,
              revision > 0, !recordID.isEmpty, recordID.utf8.count <= 512, record.isBounded(),
              sourceHash.map({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true else { return nil }
        self.sequence = sequence
        self.recordID = recordID
        self.record = record
        self.sourceOffset = sourceOffset
        self.sourceHash = sourceHash
        self.receiptSourceIdentity = receiptSourceIdentity; self.receiptSourceOffset = receiptSourceOffset
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case sequence, recordID, record, sourceOffset, sourceHash, revision, receiptSourceIdentity, receiptSourceOffset }

    private static func presentationRecord(_ record: AgentJSONValue) -> AgentJSONValue {
        guard var object = record.objectValue,
              object["provider"]?.stringValue == "claude",
              object["type"]?.stringValue == "queue-operation"
        else { return record }
        // Older host helpers copied the queued prompt into status metadata.
        // Queue status consumes pending/count, never this duplicate prompt.
        // Drop it before validation so existing hosts cannot reject an entire
        // history page because a queued prompt exceeds the text preview limit.
        object.removeValue(forKey: "content")
        return .object(object)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sequence = try values.decode(UInt64.self, forKey: .sequence)
        let recordID = try values.decode(String.self, forKey: .recordID)
        let record = try values.decode(AgentJSONValue.self, forKey: .record)
        let sourceOffset = try values.decodeIfPresent(UInt64.self, forKey: .sourceOffset)
        let sourceHash = try values.decodeIfPresent(String.self, forKey: .sourceHash)
        let revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 1
        guard let validated = Self(sequence: sequence, recordID: recordID, record: record, sourceOffset: sourceOffset, sourceHash: sourceHash, revision: revision,
            receiptSourceIdentity: try values.decodeIfPresent(String.self, forKey: .receiptSourceIdentity),
            receiptSourceOffset: try values.decodeIfPresent(UInt64.self, forKey: .receiptSourceOffset)) else {
            let key: CodingKeys = recordID.isEmpty || recordID.utf8.count > 512 ? .recordID
                : !Self.presentationRecord(record).isBounded() ? .record : .sourceHash
            throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Invalid projection record")
        }
        self = validated
    }

}

public struct AgentProjectionPage: Equatable, Codable, Sendable {
    public let sourceIdentity: String
    public let from: String?
    public let to: String?
    public let records: [AgentProjectionRecord]
    public let cursor: String?
    public let hasMore: Bool
    /// Provider-neutral, page-scoped metadata. It is never a transcript
    /// record and is therefore not assigned a durable sequence or record ID.
    public let summary: AgentJSONValue?
    public let ingestion: AgentIngestionRange?

    public init?(sourceIdentity: String, from: String? = nil, to: String? = nil, records: [AgentProjectionRecord], cursor: String?, hasMore: Bool, summary: AgentJSONValue? = nil, ingestion: AgentIngestionRange? = nil) {
        guard let recordsData = try? JSONEncoder().encode(records) else { return nil }
        let summaryData: Data?
        if let summary {
            if let openingPrompt = summary.objectValue?["openingPrompt"] {
                guard let openingText = openingPrompt.stringValue,
                      openingText.utf8.count <= 4_096
                else { return nil }
            }
            guard summary.objectValue != nil,
                  summary.isBounded(),
                  let encoded = try? JSONEncoder().encode(summary),
                  encoded.count <= 16_384
            else { return nil }
            summaryData = encoded
        } else {
            summaryData = nil
        }
        guard !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 512,
              from.map({ $0.utf8.count <= 2_048 }) ?? true,
              to.map({ $0.utf8.count <= 2_048 }) ?? true,
              cursor.map({ $0.utf8.count <= 2_048 }) ?? true,
              records.count <= AgentProjectionRequest.maximumRecords,
              recordsData.count + (summaryData?.count ?? 0) <= AgentProjectionRequest.maximumBytes
        else { return nil }
        self.sourceIdentity = sourceIdentity
        self.from = from
        self.to = to
        self.records = records
        self.cursor = cursor
        self.hasMore = hasMore
        self.summary = summary
        self.ingestion = ingestion
    }

    private enum CodingKeys: String, CodingKey { case sourceIdentity, from, to, records, cursor, hasMore, summary, ingestion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceIdentity = try values.decode(String.self, forKey: .sourceIdentity)
        let from = try values.decodeIfPresent(String.self, forKey: .from)
        let to = try values.decodeIfPresent(String.self, forKey: .to)
        let records = try values.decode([AgentProjectionRecord].self, forKey: .records)
        let cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
        let hasMore = try values.decode(Bool.self, forKey: .hasMore)
        let summary = try values.decodeIfPresent(AgentJSONValue.self, forKey: .summary)
        let ingestion = try values.decodeIfPresent(AgentIngestionRange.self, forKey: .ingestion)
        guard let validated = Self(sourceIdentity: sourceIdentity, from: from, to: to, records: records, cursor: cursor, hasMore: hasMore, summary: summary, ingestion: ingestion) else {
            throw DecodingError.dataCorruptedError(forKey: .sourceIdentity, in: values, debugDescription: "Invalid projection page")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceIdentity, forKey: .sourceIdentity)
        try values.encodeIfPresent(from, forKey: .from)
        try values.encodeIfPresent(to, forKey: .to)
        try values.encode(records, forKey: .records)
        try values.encodeIfPresent(cursor, forKey: .cursor)
        try values.encode(hasMore, forKey: .hasMore)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(ingestion, forKey: .ingestion)
    }
}

public enum AgentProjectionApplyResult: Equatable, Sendable {
    case capacityExceeded
    case applied
    case duplicate
    case resyncRequired
    case sourceReset
    public var accepted: Bool { self == .applied || self == .duplicate || self == .sourceReset }
}

public protocol AgentRemoteExecPort: Sendable {
    func execute(_ request: AgentExecRequest) async throws -> AgentExecStream
}

public struct AgentExecRequest: Equatable, Sendable {
    public enum Program: Sendable { case projector, ingestionHost }
    public let binding: AgentTerminalBinding
    public let stdin: Data
    public let program: Program

    public init?(binding: AgentTerminalBinding, stdin: Data, program: Program = .projector) {
        guard !stdin.isEmpty, stdin.count <= AgentProjectionRequest.maximumBytes else { return nil }
        self.binding = binding
        self.stdin = stdin
        self.program = program
    }
}

public struct AgentExecFrame: Equatable, Sendable {
    public static let maximumFrameBytes = 65_536
    public static let maximumDiagnosticBytes = 8_192

    public enum Kind: Equatable, Sendable {
        case stdout(Data)
        case stderr(Data)
        case exit(status: Int32)
    }

    public let carrierGeneration: UInt64
    public let kind: Kind

    public init?(carrierGeneration: UInt64, kind: Kind) {
        switch kind {
        case .stdout(let data) where data.count > Self.maximumFrameBytes: return nil
        case .stderr(let data) where data.count > Self.maximumDiagnosticBytes: return nil
        default: break
        }
        self.carrierGeneration = carrierGeneration
        self.kind = kind
    }
}

public protocol AgentExecStream: Sendable {
    func nextFrame() async throws -> AgentExecFrame?
    func cancel() async
}

public protocol AgentRemoteDataChannel: Sendable {
    func inventory(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentProjectionPage, Error>
    func project(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentProjectionPage, Error>
    func search(_ request: AgentProjectionRequest) async throws -> AsyncThrowingStream<AgentSearchResult, Error>
}
