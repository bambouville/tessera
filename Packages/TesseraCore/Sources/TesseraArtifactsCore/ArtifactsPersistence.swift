import Foundation

/// A small manifest and immutable UTF-8 blobs, keyed by lowercase SHA-256.
/// Platforms write missing blobs before stateJSON, then collect unreferenced blobs.
public struct ArtifactsPersistenceFiles: Codable, Equatable, Sendable {
    public var stateJSON: String
    public var blobs: [String: String]

    public init(stateJSON: String, blobs: [String: String]) {
        self.stateJSON = stateJSON
        self.blobs = blobs
    }
}

public enum ArtifactsPersistence {
    public static let maximumDiffBytes = 256 * 1024
    /// Persistence has a hard safety bound even if a corrupt file changes
    /// tabCap. Normal operation uses the configurable reducer's soft cap.
    public static let maximumPersistedTabs = 64

    /// Legacy inline snapshots remain readable. Missing blobs drop only their tab.
    public static func decode(_ data: Data) -> ArtifactsState { join(data, blobs: [:]) }

    /// A malformed container becomes an empty v1 state. Each tab decodes
    /// independently; unknown fields survive compatibility by being ignored.
    public static func join(_ data: Data, blobs: [String: String]) -> ArtifactsState {
        guard let object = container(data) else { return ArtifactsState() }
        let decoder = JSONDecoder()
        var tabs: [ArtifactTab] = []
        var verified: [String: String] = [:]
        var rejected: Set<String> = []
        for raw in object["tabs"] as? [Any] ?? [] {
            guard var raw = raw as? [String: Any] else { continue }
            if var target = raw["target"] as? [String: Any], target["type"] as? String == "change",
               target["diffDigest"] != nil {
                guard let digest = target["diffDigest"] as? String, isBlobDigest(digest), !rejected.contains(digest) else { continue }
                if verified[digest] == nil {
                    guard let diff = blobs[digest], diff.utf8.count <= maximumDiffBytes,
                          ArtifactsDigest.hex(diff) == digest else { rejected.insert(digest); continue }
                    verified[digest] = diff
                }
                target["diff"] = verified[digest]
                raw["target"] = target
            }
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let tab = try? decoder.decode(ArtifactTab.self, from: data) else { continue }
            tabs.append(tab)
        }
        let filter = (object["filter"] as? String).flatMap(ArtifactsFilter.init(rawValue:)) ?? .all
        let requestedCap: Int
        if let raw = object["tabCap"],
           let data = try? JSONSerialization.data(withJSONObject: ["v": raw]),
           let value = try? decoder.decode(Version.self, from: data) { requestedCap = value.v }
        else { requestedCap = ArtifactsState.defaultTabCap }
        return bounded(ArtifactsState(tabs: tabs, selectedID: object["selectedID"] as? String,
                                      filter: filter, tabCap: requestedCap))
    }

    /// Canonical keys and literal slashes. Apply bounds once, without a JSON
    /// round trip; the inline wire format stays compatible with existing callers.
    public static func encode(_ state: ArtifactsState) -> Data {
        (try? encoder.encode(bounded(state))) ?? Data()
    }

    /// Diff bodies never pass through the manifest encoder. Identical bodies
    /// share a blob even when several hosts or paths retain that snapshot.
    public static func split(_ state: ArtifactsState) -> ArtifactsPersistenceFiles {
        let state = bounded(state)
        var blobs: [String: String] = [:]
        var targets: [String: StoredTarget] = [:]
        for tab in state.tabs {
            if case let .change(path, diff, summary) = tab.target {
                let digest = ArtifactsDigest.hex(diff)
                blobs[digest] = diff
                targets[tab.id] = StoredTarget(type: "change", path: path, diffDigest: digest, summary: summary)
            }
        }
        let manifest = StoredState(state: state, targets: targets)
        let data = (try? encoder.encode(manifest)) ?? Data()
        return .init(stateJSON: String(decoding: data, as: UTF8.self), blobs: blobs)
    }

    /// The only names a platform may read from changes/. No path components,
    /// malformed digests or unsupported container versions reach filesystem I/O.
    public static func blobDigests(_ data: Data) -> [String] {
        guard let object = container(data) else { return [] }
        let decoder = JSONDecoder()
        let references = (object["tabs"] as? [Any] ?? []).compactMap { raw -> (digest: String, tab: ArtifactTab)? in
            guard var tab = raw as? [String: Any], var target = tab["target"] as? [String: Any], target["type"] as? String == "change",
                  let digest = target["diffDigest"] as? String, isBlobDigest(digest) else { return nil }
            target["diff"] = ""
            tab["target"] = target
            guard let data = try? JSONSerialization.data(withJSONObject: tab),
                  let metadata = try? decoder.decode(ArtifactTab.self, from: data),
                  !metadata.id.isEmpty, !metadata.hostID.isEmpty, metadata.target.normalized.isValid else { return nil }
            return (digest, metadata)
        }.sorted {
            let selected = object["selectedID"] as? String
            if ($0.tab.id == selected) != ($1.tab.id == selected) { return $0.tab.id == selected }
            if $0.tab.pinned != $1.tab.pinned { return $0.tab.pinned }
            return ArtifactsOverview.recentFirst($0.tab, $1.tab)
        }
        // Valid manifests have at most 64 tabs. A corrupt manifest must not
        // cause an unbounded number of blob reads before join applies bounds.
        var seen: Set<String> = []
        var digests: [String] = []
        for reference in references where seen.insert(reference.digest).inserted {
            digests.append(reference.digest)
            if digests.count == maximumPersistedTabs { break }
        }
        return digests.sorted()
    }

    public static func isBlobDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func container(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versionData = try? JSONSerialization.data(withJSONObject: ["v": object["version"] ?? 1]),
              let version = try? JSONDecoder().decode(Version.self, from: versionData), version.v == 1 else { return nil }
        return object
    }

    private static func bounded(_ input: ArtifactsState) -> ArtifactsState {
        var state = input
        state.version = ArtifactsState.currentVersion
        state.tabCap = min(maximumPersistedTabs, max(1, state.tabCap))
        var ids: Set<String> = []
        var identities = IdentityIndex()
        state.tabs = input.tabs.compactMap { tab in
            var tab = tab
            tab.target = capped(tab.target.normalized)
            tab.kind = tab.target.kind
            guard !tab.id.isEmpty, !tab.hostID.isEmpty, tab.target.isValid,
                  tab.cache.map({ $0.size >= 0 }) ?? true, ids.insert(tab.id).inserted,
                  identities.insert(tab) else { return nil }
            return tab
        }
        if !state.tabs.contains(where: { $0.id == state.selectedID }) { state.selectedID = nil }
        _ = ArtifactsReducer.enforceCap(&state)
        // The reducer's soft cap may retain only-protected tabs beyond 64.
        // The disk bound retains the selection and most recent pinned tabs.
        if state.tabs.count > maximumPersistedTabs {
            let retained = state.tabs.sorted {
                if ($0.id == state.selectedID) != ($1.id == state.selectedID) { return $0.id == state.selectedID }
                if $0.pinned != $1.pinned { return $0.pinned }
                return ArtifactsOverview.recentFirst($0, $1)
            }.prefix(maximumPersistedTabs)
            let ids = Set(retained.map(\.id))
            state.tabs.removeAll { !ids.contains($0.id) }
        }
        return state
    }

    /// Compare exact bytes only within a host/path bucket. Digest work is
    /// reserved for blob names, validation and oversized snapshot markers.
    private struct IdentityIndex {
        private struct Key: Hashable { var host: String; var target: String }
        private var changes: [Key: [String]] = [:]

        /// Files and pages may each be open in several tabs, since a new
        /// tab is always new; an agent edit is one snapshot, kept once.
        mutating func insert(_ tab: ArtifactTab) -> Bool {
            guard case let .change(_, diff, _) = tab.target else { return true }
            let key = Key(host: tab.hostID, target: tab.target.identityGroup)
            guard !(changes[key] ?? []).contains(where: { ArtifactsTarget.Identity.equalDiffBytes($0, diff) }) else { return false }
            changes[key, default: []].append(diff)
            return true
        }
    }

    private struct Version: Decodable { var v: Int }
    private struct StoredTarget: Encodable {
        var type: String
        var path: String
        var diffDigest: String
        var summary: String
    }

    private struct StoredState: Encodable {
        var state: ArtifactsState
        var targets: [String: StoredTarget]
        private enum CodingKeys: String, CodingKey { case version, tabs, selectedID, filter, tabCap }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(state.version, forKey: .version)
            try c.encode(state.tabs.map { StoredTab(tab: $0, target: targets[$0.id]) }, forKey: .tabs)
            try c.encodeIfPresent(state.selectedID, forKey: .selectedID)
            try c.encode(state.filter, forKey: .filter)
            try c.encode(state.tabCap, forKey: .tabCap)
        }
    }

    private struct StoredTab: Encodable {
        var tab: ArtifactTab
        var target: StoredTarget?
        private enum CodingKeys: String, CodingKey {
            case id, hostID, hostLabel, target, kind, title, origin, sessionHint
            case openedAt, viewedAt, pinned, cache, unseenChange, agentEditedAt
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tab.id, forKey: .id)
            try c.encode(tab.hostID, forKey: .hostID)
            try c.encode(tab.hostLabel, forKey: .hostLabel)
            if let target { try c.encode(target, forKey: .target) }
            else { try c.encode(tab.target, forKey: .target) }
            try c.encode(tab.kind, forKey: .kind)
            try c.encode(tab.title, forKey: .title)
            try c.encode(tab.origin, forKey: .origin)
            try c.encodeIfPresent(tab.sessionHint, forKey: .sessionHint)
            try c.encode(tab.openedAt, forKey: .openedAt)
            try c.encode(tab.viewedAt, forKey: .viewedAt)
            try c.encode(tab.pinned, forKey: .pinned)
            try c.encodeIfPresent(tab.cache, forKey: .cache)
            try c.encode(tab.unseenChange, forKey: .unseenChange)
            try c.encodeIfPresent(tab.agentEditedAt, forKey: .agentEditedAt)
        }
    }

    static func capped(_ target: ArtifactsTarget) -> ArtifactsTarget {
        guard case let .change(path, diff, summary) = target, diff.utf8.count > maximumDiffBytes else { return target }
        // Keep the complete snapshot's digest in a metadata line so edits
        // with the same retained prefix still have distinct tab identities.
        let marker = "\\ diff truncated; sha256: \(ArtifactsDigest.hex(diff))\n"
        let bytes = diff.utf8.prefix(maximumDiffBytes - marker.utf8.count)
        // A newline is also a UTF-8 scalar boundary. If the first line is
        // too large, retain only the marker rather than part of a code line.
        let end = bytes.lastIndex(of: 0x0a).map { bytes.index(after: $0) } ?? bytes.startIndex
        return .change(path: path, diff: String(decoding: bytes[..<end], as: UTF8.self) + marker, summary: summary)
    }
}
