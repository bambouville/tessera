import Foundation

/// Searches one bounded canonical page without mutating the displayed window.
/// Callers page explicitly, retain only hits, and stop at their result quota.
public enum AgentNativePageSearch {
    public static func matches(page: AgentProjectionPage, threadID: AgentThreadID, query: String) -> [AgentSearchResult] {
        matches(records: page.records, threadID: threadID, query: query)
    }

    public static func matches(records: [AgentProjectionRecord], threadID: AgentThreadID, query: String) -> [AgentSearchResult] {
        let needle = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let normalizer = AgentTranscriptNormalizer()
        return records.compactMap { record in
            guard let message = normalizer.normalize(providerID: threadID.providerID, record: record).message else { return nil }
            let text = message.blocks.compactMap(AgentCenterRuntime.searchText).joined(separator: "\n")
            guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            return .init(threadID: threadID, recordID: record.recordID, excerpt: String(text[start..<end]),
                         sequence: record.sequence, sourceOffset: record.sourceOffset, seekToken: record.seekToken)
        }
    }
}

public struct AgentSearchResult: Equatable, Codable, Sendable {
    public static let maximumExcerptBytes = 1_024
    public let threadID: AgentThreadID
    public let recordID: String
    public let excerpt: String
    /// Where the matched record stands in its transcript, for opening the
    /// conversation there (`window.read` seek): its provider order and, when
    /// the host reported them, the source offset and seek token that prove
    /// it unmoved.
    public let sequence: UInt64?
    public let sourceOffset: UInt64?
    public let seekToken: String?

    public init(threadID: AgentThreadID, recordID: String, excerpt: String,
                sequence: UInt64? = nil, sourceOffset: UInt64? = nil, seekToken: String? = nil) {
        self.threadID = threadID
        self.recordID = recordID
        self.excerpt = Self.boundedExcerpt(excerpt)
        self.sequence = sequence
        self.sourceOffset = sequence == nil ? nil : sourceOffset
        self.seekToken = sequence == nil ? nil : seekToken.flatMap {
            !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy { (33...126).contains($0) } ? $0 : nil
        }
    }

    private enum CodingKeys: String, CodingKey { case threadID, recordID, excerpt, sequence, sourceOffset, seekToken }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let threadID = try values.decode(AgentThreadID.self, forKey: .threadID)
        let recordID = try values.decode(String.self, forKey: .recordID)
        let excerpt = try values.decode(String.self, forKey: .excerpt)
        guard !recordID.isEmpty, recordID.utf8.count <= 512 else {
            throw DecodingError.dataCorruptedError(forKey: .excerpt, in: values, debugDescription: "Invalid bounded search result")
        }
        // Projectors are permitted to be conservative, but an overlong
        // redacted excerpt must not reject the whole cross-host response.
        self.init(threadID: threadID, recordID: recordID, excerpt: excerpt,
                  sequence: try values.decodeIfPresent(UInt64.self, forKey: .sequence),
                  sourceOffset: try values.decodeIfPresent(UInt64.self, forKey: .sourceOffset),
                  seekToken: try values.decodeIfPresent(String.self, forKey: .seekToken))
    }

    private static func boundedExcerpt(_ input: String) -> String {
        var value = AgentDisplayText.sanitize(input)
        while value.utf8.count > maximumExcerptBytes { value.removeLast() }
        return value
    }
}

public struct AgentSearchSnapshot: Equatable, Codable, Sendable {
    /// The projector contract is 100 redacted excerpts for each connected
    /// host. Four hosts keeps worst-case canonical JSON below the 1 MiB ABI
    /// ceiling even when strings need escaping.
    public static let maximumHosts = 4
    public static let maximumResultsPerHost = 100
    public static let maximumResults = maximumHosts * maximumResultsPerHost

    public let results: [AgentSearchResult]
    /// Hosts that were not fully searched: unreachable, out of time, or
    /// stopped before every thread was read to its end. A host listed here
    /// may also have results, which are then partial. Result hosts and these
    /// together stay within `maximumHosts`.
    public let unavailableHostIDs: [UUID]
    public init(results: [AgentSearchResult], unavailableHostIDs: [UUID] = []) {
        var admittedHosts: [UUID] = []
        var perHostCount: [UUID: Int] = [:]
        var admitted: [AgentSearchResult] = []
        for result in results {
            let hostID = result.threadID.hostID
            if perHostCount[hostID] == nil {
                guard admittedHosts.count < Self.maximumHosts else { continue }
                admittedHosts.append(hostID)
                perHostCount[hostID] = 0
            }
            guard perHostCount[hostID, default: 0] < Self.maximumResultsPerHost else { continue }
            admitted.append(result)
            perHostCount[hostID, default: 0] += 1
        }
        self.results = admitted
        // A partial result host already holds its slot; any other host needs
        // a free one, so the union stays within the host bound.
        var unavailable: [UUID] = []
        var resultlessCount = 0
        for id in unavailableHostIDs where !unavailable.contains(id) {
            if perHostCount[id] == nil {
                guard perHostCount.count + resultlessCount < Self.maximumHosts else { continue }
                resultlessCount += 1
            }
            unavailable.append(id)
        }
        self.unavailableHostIDs = unavailable
    }

    private enum CodingKeys: String, CodingKey { case results, unavailableHostIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let results = try values.decode([AgentSearchResult].self, forKey: .results)
        let unavailableHostIDs = try values.decodeIfPresent([UUID].self, forKey: .unavailableHostIDs) ?? []
        let resultHosts = Set(results.map(\.threadID.hostID))
        let perHostWithinLimit = Dictionary(grouping: results, by: { $0.threadID.hostID })
            .values.allSatisfy { $0.count <= Self.maximumResultsPerHost }
        let unavailableSet = Set(unavailableHostIDs)
        guard results.count <= Self.maximumResults,
              resultHosts.count <= Self.maximumHosts,
              unavailableHostIDs.count == unavailableSet.count,
              unavailableHostIDs.count <= Self.maximumHosts,
              unavailableSet.union(resultHosts).count <= Self.maximumHosts,
              perHostWithinLimit else {
            throw DecodingError.dataCorruptedError(forKey: .results, in: values, debugDescription: "Too many search results")
        }
        self.results = results; self.unavailableHostIDs = unavailableHostIDs
    }

    /// What the app already holds first, then what its sources found, each
    /// record once: a search keeps the rows it showed while it ran, in the
    /// same order, when it ends. A row keeps the first position any copy of
    /// it reported, so it can still open at its record, or a later copy's
    /// that carries the token proving it; a position is never split between
    /// copies.
    public static func merging(_ loaded: [AgentSearchResult], _ found: [AgentSearchResult],
                               unavailableHostIDs: [UUID] = []) -> AgentSearchSnapshot {
        struct Key: Hashable { let threadID: AgentThreadID; let recordID: String }
        var index: [Key: Int] = [:]
        var results: [AgentSearchResult] = []
        for result in loaded + found {
            let key = Key(threadID: result.threadID, recordID: result.recordID)
            guard let at = index[key] else { index[key] = results.count; results.append(result); continue }
            let kept = results[at]
            if result.sequence != nil, kept.sequence == nil || (kept.seekToken == nil && result.seekToken != nil) {
                results[at] = .init(threadID: kept.threadID, recordID: kept.recordID, excerpt: kept.excerpt,
                                    sequence: result.sequence, sourceOffset: result.sourceOffset, seekToken: result.seekToken)
            }
        }
        return .init(results: results, unavailableHostIDs: unavailableHostIDs)
    }
}
