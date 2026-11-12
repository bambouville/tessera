import Foundation

public struct ArtifactsHostGroup: Codable, Equatable, Sendable {
    public var hostID: String
    public var hostLabel: String
    public var tabIDs: [String]

    public init(hostID: String, hostLabel: String, tabIDs: [String]) {
        self.hostID = hostID
        self.hostLabel = hostLabel
        self.tabIDs = tabIDs
    }
}

public struct ArtifactsOverview: Codable, Equatable, Sendable {
    public var groups: [ArtifactsHostGroup]
    /// String keys (`docs`, `pages`, `changes`, `files`) encode as an object.
    /// Counts include the query, before applying the kind filter.
    public var countsByKind: [String: Int]
    public var totalCount: Int
    public var filter: ArtifactsFilter
    public var query: String

    public static func make(
        _ state: ArtifactsState, filter: ArtifactsFilter, query: String
    ) -> ArtifactsOverview {
        let needle = ArtifactsPaths.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let matching = state.tabs.filter {
            needle.isEmpty || [$0.title, $0.target.path, $0.hostLabel].contains {
                ArtifactsPaths.folded($0).contains(needle)
            }
        }.sorted(by: recentFirst)
        var counts = Dictionary(uniqueKeysWithValues: ArtifactsKind.allCases.map { ($0.rawValue, 0) })
        var groups: [ArtifactsHostGroup] = []
        for tab in matching {
            counts[tab.kind.rawValue, default: 0] += 1
            guard filter.includes(tab.kind) else { continue }
            if let index = groups.firstIndex(where: { $0.hostID == tab.hostID }) {
                groups[index].tabIDs.append(tab.id)
            } else {
                groups.append(.init(hostID: tab.hostID, hostLabel: tab.hostLabel, tabIDs: [tab.id]))
            }
        }
        return .init(groups: groups, countsByKind: counts, totalCount: matching.count, filter: filter, query: query)
    }

    static func recentFirst(_ lhs: ArtifactTab, _ rhs: ArtifactTab) -> Bool {
        if lhs.viewedAt != rhs.viewedAt { return lhs.viewedAt > rhs.viewedAt }
        if lhs.openedAt != rhs.openedAt { return lhs.openedAt > rhs.openedAt }
        return lhs.id < rhs.id
    }
}
