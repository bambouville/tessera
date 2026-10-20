import Foundation

/// Searches one bounded canonical page without mutating the displayed window.
/// Callers page explicitly, retain only hits, and stop at their result quota.
public enum AgentNativePageSearch {
    public static func matches(page: AgentProjectionPage, threadID: AgentThreadID, query: String) -> [AgentSearchResult] {
        let needle = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let normalizer = AgentTranscriptNormalizer()
        return page.records.compactMap { record in
            guard let message = normalizer.normalize(providerID: threadID.providerID, record: record).message else { return nil }
            let text = message.blocks.compactMap(AgentCenterRuntime.searchText).joined(separator: "\n")
            guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            return .init(threadID: threadID, recordID: record.recordID, excerpt: String(text[start..<end]))
        }
    }
}

public struct AgentSearchResult: Equatable, Codable, Sendable {
    public static let maximumExcerptBytes = 1_024
    public let threadID: AgentThreadID
    public let recordID: String
    public let excerpt: String

    public init(threadID: AgentThreadID, recordID: String, excerpt: String) {
        self.threadID = threadID
        self.recordID = recordID
        self.excerpt = Self.boundedExcerpt(excerpt)
    }

    private enum CodingKeys: String, CodingKey { case threadID, recordID, excerpt }
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
        self.init(threadID: threadID, recordID: recordID, excerpt: excerpt)
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
        self.unavailableHostIDs = Array(
            unavailableHostIDs.reduce(into: [UUID]()) { values, id in
                guard !perHostCount.keys.contains(id),
                      !values.contains(id),
                      perHostCount.keys.count + values.count < Self.maximumHosts else { return }
                values.append(id)
            }
        )
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
              unavailableSet.isDisjoint(with: resultHosts),
              unavailableSet.union(resultHosts).count <= Self.maximumHosts,
              perHostWithinLimit else {
            throw DecodingError.dataCorruptedError(forKey: .results, in: values, debugDescription: "Too many search results")
        }
        self.results = results; self.unavailableHostIDs = unavailableHostIDs
    }
}
