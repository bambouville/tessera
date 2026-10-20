import Foundation
import TesseraCore

/// The complete durable V2 record. Deliberately absent: transcript text,
/// source paths, transcript locators/cursors, tool input/results, previews,
/// diagnostics, and provider launch arguments.
struct AppleAgentThreadMetadataRecord: Codable, Equatable, Sendable, Identifiable {
    let threadID: AgentThreadID
    var lastReadRecordID: String?
    var routeToken: UUID?
    /// A monotonic, content-free fence for OS notification taps. It is stored
    /// beside the opaque token so a cold process can reject an invalidated
    /// delivered notification without reconstructing transcript state.
    var notificationGeneration: UInt64?
    var pinnedTitle: String?
    var lineage: AgentThreadLineage?
    /// Content-free completion identities (hook source time and PID) from
    /// Core: a finish still unread, and the newest one the reader acknowledged.
    /// Optional, so documents written before them decode unchanged.
    var unreadCompletionKey: String?
    var acknowledgedCompletionKey: String?

    var id: AgentThreadID { threadID }

    init(
        threadID: AgentThreadID,
        lastReadRecordID: String? = nil,
        routeToken: UUID? = nil,
        notificationGeneration: UInt64? = nil,
        pinnedTitle: String? = nil,
        lineage: AgentThreadLineage? = nil,
        unreadCompletionKey: String? = nil,
        acknowledgedCompletionKey: String? = nil
    ) {
        self.threadID = threadID
        self.lastReadRecordID = Self.bounded(lastReadRecordID, maximum: 512)
        self.routeToken = routeToken
        self.notificationGeneration = notificationGeneration
        self.pinnedTitle = Self.bounded(pinnedTitle, maximum: 512)
        self.lineage = lineage
        self.unreadCompletionKey = Self.bounded(unreadCompletionKey, maximum: 128)
        self.acknowledgedCompletionKey = Self.bounded(acknowledgedCompletionKey, maximum: 128)
    }

    var coreMetadata: AgentThreadMetadata {
        AgentThreadMetadata(
            threadID: threadID,
            lastReadRecordID: lastReadRecordID,
            routeToken: routeToken,
            pinnedTitle: pinnedTitle,
            unreadCompletionKey: unreadCompletionKey,
            acknowledgedCompletionKey: acknowledgedCompletionKey
        )
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let result = String(String.UnicodeScalarView(cleaned)).prefix(maximum)
        return result.isEmpty ? nil : String(result)
    }
}

/// Device-local view state. Search text is intentionally excluded: it may
/// contain transcript terms. Provider filters, grouping, and selection are
/// identifiers/preferences only.
struct AppleAgentViewMetadata: Codable, Equatable, Sendable {
    var grouping: AgentListGrouping
    var providerIDs: Set<AgentProviderID>
    var lastSelectedThreadID: AgentThreadID?
    /// Activity is intentionally quiet by default. This is only a local
    /// presentation preference; activity content itself remains in memory.
    var showSystemEvents: Bool

    init(
        grouping: AgentListGrouping = .attention,
        providerIDs: Set<AgentProviderID> = [],
        lastSelectedThreadID: AgentThreadID? = nil,
        showSystemEvents: Bool = false
    ) {
        self.grouping = grouping
        self.providerIDs = providerIDs
        self.lastSelectedThreadID = lastSelectedThreadID
        self.showSystemEvents = showSystemEvents
    }

    private enum CodingKeys: String, CodingKey {
        case grouping, providerIDs, lastSelectedThreadID, showSystemEvents
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A retired grouping (project) falls back to attention rather than
        // discarding the provider filters and selection saved beside it.
        grouping = (try? values.decodeIfPresent(AgentListGrouping.self, forKey: .grouping)) ?? .attention
        providerIDs = try values.decodeIfPresent(Set<AgentProviderID>.self, forKey: .providerIDs) ?? []
        lastSelectedThreadID = try values.decodeIfPresent(AgentThreadID.self, forKey: .lastSelectedThreadID)
        // V2 metadata created before this control deliberately keeps the
        // quieter default on upgrade.
        showSystemEvents = try values.decodeIfPresent(Bool.self, forKey: .showSystemEvents) ?? false
    }
}

/// Pure schema gate used before every persistence write and by focused tests.
/// This catches future accidental additions that would enlarge the privacy
/// boundary rather than merely relying on a comment beside the store.
enum AppleAgentMetadataPersistencePolicy {
    static let forbiddenSchemaFragments = [
        "transcript", "locator", "path", "cursor", "preview", "message",
        "content", "tool", "command", "diagnostic", "search"
    ]

    static func allows(_ record: AppleAgentThreadMetadataRecord) -> Bool {
        record.pinnedTitle.map(isSafeScalarText) ?? true
            && (record.lastReadRecordID.map(isSafeScalarText) ?? true)
    }

    static func encodedSchemaIsMetadataOnly(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let keys = keys(in: object)
        else { return false }
        return !keys.contains { key in
            forbiddenSchemaFragments.contains { key.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func isSafeScalarText(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func keys(in object: Any) -> [String]? {
        if let dictionary = object as? [String: Any] {
            return Array(dictionary.keys)
                + dictionary.values.compactMap { keys(in: $0) }.flatMap { $0 }
        }
        if let array = object as? [Any] {
            return array.compactMap { keys(in: $0) }.flatMap { $0 }
        }
        return []
    }
}

/// A small, protected file-backed metadata repository. Content remains only
/// in runtime RAM; this document carries only the narrow V2 metadata schema.
actor AppleAgentMetadataRepository: AgentMetadataRepository {
    struct Document: Codable, Equatable, Sendable {
        static let schemaVersion = 3
        var schemaVersion: Int
        var records: [AppleAgentThreadMetadataRecord]
        var view: AppleAgentViewMetadata

        init(
            schemaVersion: Int = Self.schemaVersion,
            records: [AppleAgentThreadMetadataRecord],
            view: AppleAgentViewMetadata = .init()
        ) {
            self.schemaVersion = schemaVersion
            self.records = records
            self.view = view
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, records, view }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            records = try values.decodeIfPresent([AppleAgentThreadMetadataRecord].self, forKey: .records) ?? []
            view = try values.decodeIfPresent(AppleAgentViewMetadata.self, forKey: .view) ?? .init()
        }
    }

    enum RepositoryError: Error, Equatable {
        case rejectedByPrivacyPolicy
        case encodeFailed
    }

    static let fileName = "agent-center-v2-metadata.json"

    private let fileURL: URL
    private let fileManager: FileManager

    /// Production keeps the document in Application Support, rather than in
    /// UserDefaults where its lifetime and protection class are less explicit.
    init(
        fileURL: URL = AppleAgentMetadataRepository.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func metadata(for threadID: AgentThreadID) async -> AgentThreadMetadata? {
        load().records.first(where: { $0.threadID == threadID })?.coreMetadata
    }

    func allMetadata() -> [AgentThreadMetadata] {
        load().records.map(\.coreMetadata)
    }

    func allRecords() -> [AppleAgentThreadMetadataRecord] {
        load().records
    }

    func save(_ metadata: AgentThreadMetadata) async throws {
        var document = load()
        let existing = document.records.first(where: { $0.threadID == metadata.threadID })
        let record = AppleAgentThreadMetadataRecord(
            threadID: metadata.threadID,
            lastReadRecordID: metadata.lastReadRecordID,
            routeToken: metadata.routeToken,
            notificationGeneration: existing?.notificationGeneration,
            pinnedTitle: metadata.pinnedTitle,
            lineage: existing?.lineage,
            unreadCompletionKey: existing?.unreadCompletionKey,
            acknowledgedCompletionKey: existing?.acknowledgedCompletionKey
        )
        try upsert(record, in: &document)
    }

    func saveLineage(_ lineage: AgentThreadLineage?, for threadID: AgentThreadID) throws {
        var document = load()
        let existing = document.records.first(where: { $0.threadID == threadID })
        let record = AppleAgentThreadMetadataRecord(
            threadID: threadID,
            lastReadRecordID: existing?.lastReadRecordID,
            routeToken: existing?.routeToken,
            notificationGeneration: existing?.notificationGeneration,
            pinnedTitle: existing?.pinnedTitle,
            lineage: lineage,
            unreadCompletionKey: existing?.unreadCompletionKey,
            acknowledgedCompletionKey: existing?.acknowledgedCompletionKey
        )
        try upsert(record, in: &document)
    }

    /// The only writer of the completion identities; every other save keeps
    /// them, so a read-modify-write of older metadata cannot roll them back.
    func saveCompletion(unread: String?, acknowledged: String?, for threadID: AgentThreadID) throws {
        var document = load()
        let existing = document.records.first(where: { $0.threadID == threadID })
        guard existing?.unreadCompletionKey != unread || existing?.acknowledgedCompletionKey != acknowledged
        else { return }
        let record = AppleAgentThreadMetadataRecord(
            threadID: threadID,
            lastReadRecordID: existing?.lastReadRecordID,
            routeToken: existing?.routeToken,
            notificationGeneration: existing?.notificationGeneration,
            pinnedTitle: existing?.pinnedTitle,
            lineage: existing?.lineage,
            unreadCompletionKey: unread,
            acknowledgedCompletionKey: acknowledged
        )
        try upsert(record, in: &document)
    }

    func lineage(for threadID: AgentThreadID) -> AgentThreadLineage? {
        load().records.first(where: { $0.threadID == threadID })?.lineage
    }

    func routeToken(for threadID: AgentThreadID) throws -> AgentRouteToken {
        var document = load()
        let existing = document.records.first(where: { $0.threadID == threadID })
        let rawToken = existing?.routeToken ?? UUID()
        let record = AppleAgentThreadMetadataRecord(
            threadID: threadID,
            lastReadRecordID: existing?.lastReadRecordID,
            routeToken: rawToken,
            notificationGeneration: existing?.notificationGeneration,
            pinnedTitle: existing?.pinnedTitle,
            lineage: existing?.lineage,
            unreadCompletionKey: existing?.unreadCompletionKey,
            acknowledgedCompletionKey: existing?.acknowledgedCompletionKey
        )
        try upsert(record, in: &document)
        return AgentRouteToken(rawValue: rawToken)
    }

    func resolve(_ routeToken: AgentRouteToken) -> AgentThreadID? {
        load().records.first { $0.routeToken == routeToken.rawValue }?.threadID
    }

    func allRouteTokens() -> [AgentRouteToken] {
        load().records.compactMap { $0.routeToken.map(AgentRouteToken.init(rawValue:)) }
    }

    func notificationGeneration(for threadID: AgentThreadID) -> UInt64? {
        load().records.first(where: { $0.threadID == threadID })?.notificationGeneration
    }

    func saveNotificationGeneration(_ generation: UInt64, for threadID: AgentThreadID) throws {
        var document = load()
        let existing = document.records.first(where: { $0.threadID == threadID })
        let record = AppleAgentThreadMetadataRecord(
            threadID: threadID,
            lastReadRecordID: existing?.lastReadRecordID,
            routeToken: existing?.routeToken,
            notificationGeneration: generation,
            pinnedTitle: existing?.pinnedTitle,
            lineage: existing?.lineage,
            unreadCompletionKey: existing?.unreadCompletionKey,
            acknowledgedCompletionKey: existing?.acknowledgedCompletionKey
        )
        try upsert(record, in: &document)
    }

    func viewMetadata() -> AppleAgentViewMetadata { load().view }

    func saveViewMetadata(_ view: AppleAgentViewMetadata) throws {
        var document = load()
        document.view = view
        try write(document)
    }

    func removeAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func upsert(_ record: AppleAgentThreadMetadataRecord, in document: inout Document) throws {
        guard AppleAgentMetadataPersistencePolicy.allows(record) else {
            throw RepositoryError.rejectedByPrivacyPolicy
        }
        document.records.removeAll { $0.threadID == record.threadID }
        document.records.append(record)
        document.records.sort { lhs, rhs in
            lhs.threadID.providerSessionID < rhs.threadID.providerSessionID
        }
        try write(document)
    }

    private func write(_ document: Document) throws {
        var document = document
        document.schemaVersion = Document.schemaVersion
        guard let data = try? JSONEncoder().encode(document) else {
            throw RepositoryError.encodeFailed
        }
        guard AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(data) else {
            throw RepositoryError.rejectedByPrivacyPolicy
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // `Data.write(.atomic)` creates its replacement alongside the
            // destination. Protect the parent first so that replacement also
            // inherits the intended class before its final explicit check.
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw RepositoryError.encodeFailed
        }
    }

    private func load() -> Document {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              (1...Document.schemaVersion).contains(document.schemaVersion),
              AppleAgentMetadataPersistencePolicy.encodedSchemaIsMetadataOnly(data)
        else {
            return Document(records: [])
        }
        return document
    }

    private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Tessera", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
