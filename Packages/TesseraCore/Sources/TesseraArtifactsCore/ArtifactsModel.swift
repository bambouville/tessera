import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Wire enums use a flat `type` discriminator, never Swift's synthesized
/// associated-value spelling. Example: {"type":"file","path":"/tmp/a.md"}.
public enum ArtifactsTarget: Codable, Equatable, Sendable {
    case file(path: String)
    case page(scheme: String, port: UInt16, path: String)
    case change(path: String, diff: String, summary: String)

    private struct Wire: Codable {
        var type: String
        var path: String
        var scheme: String?
        var port: UInt16?
        var diff: String?
        var summary: String?
    }

    public init(from decoder: Decoder) throws {
        let value = try Wire(from: decoder)
        switch value.type {
        case "file": self = .file(path: value.path)
        case "page":
            guard let scheme = value.scheme, let port = value.port,
                  ["http", "https"].contains(scheme), port > 0 else {
                throw ArtifactsCoding.invalid(decoder, "invalid page target")
            }
            self = .page(scheme: scheme, port: port, path: value.path)
        case "change":
            guard let diff = value.diff, let summary = value.summary else {
                throw ArtifactsCoding.invalid(decoder, "missing change snapshot")
            }
            self = .change(path: value.path, diff: diff, summary: summary)
        default: throw ArtifactsCoding.invalid(decoder, "unknown target type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value: Wire
        switch self {
        case let .file(path): value = Wire(type: "file", path: path)
        case let .page(scheme, port, path):
            value = Wire(type: "page", path: path, scheme: scheme, port: port)
        case let .change(path, diff, summary):
            value = Wire(type: "change", path: path, diff: diff, summary: summary)
        }
        try value.encode(to: encoder)
    }

    public static func == (lhs: ArtifactsTarget, rhs: ArtifactsTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.file(a), .file(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.page(aScheme, aPort, aPath), .page(bScheme, bPort, bPath)):
            return aScheme == bScheme && aPort == bPort && aPath.utf8.elementsEqual(bPath.utf8)
        case let (.change(aPath, aDiff, aSummary), .change(bPath, bDiff, bSummary)):
            return aPath.utf8.elementsEqual(bPath.utf8) && aDiff.utf8.elementsEqual(bDiff.utf8)
                && aSummary.utf8.elementsEqual(bSummary.utf8)
        default: return false
        }
    }

    public var path: String {
        switch self {
        case let .file(path), let .page(_, _, path), let .change(path, _, _): return path
        }
    }

    public var kind: ArtifactsKind {
        switch self {
        case let .file(path): return ArtifactsKind.for(path: path)
        case .page: return .pages
        case .change: return .changes
        }
    }

    public var viewer: ArtifactsViewer {
        switch self {
        case let .file(path): return ArtifactsViewer.for(path: path, mimeHint: nil)
        case .page: return .web
        case .change: return .diff
        }
    }

    /// A page's identity is its scheme + remote port; path changes navigate
    /// that tab. Files preserve `..` (a symlink may give it meaning).
    public var normalized: ArtifactsTarget {
        switch self {
        case let .file(path): return .file(path: ArtifactsPaths.normalize(path))
        case let .page(scheme, port, path):
            return .page(scheme: scheme.lowercased(), port: port, path: ArtifactsPaths.page(path))
        case let .change(path, diff, summary):
            return .change(path: ArtifactsPaths.normalize(path), diff: diff, summary: summary)
        }
    }

    var identity: Identity {
        if case let .change(_, diff, _) = self { return Identity(group: identityGroup, diff: diff) }
        return Identity(group: identityGroup)
    }

    /// Cheap prefilter: distinct paths and target cases never compare bodies.
    var identityGroup: String {
        switch normalized {
        case let .file(path): return "file|\(ArtifactsPaths.byteIdentity(path))"
        case let .page(scheme, port, _): return "page|\(scheme)|\(port)"
        case let .change(path, _, _): return "change|\(ArtifactsPaths.byteIdentity(path))"
        }
    }

    struct Identity: Equatable {
        var group: String
        var diff: String?

        static func == (lhs: Identity, rhs: Identity) -> Bool {
            guard lhs.group == rhs.group else { return false }
            switch (lhs.diff, rhs.diff) {
            case (nil, nil): return true
            case let (a?, b?): return equalDiffBytes(a, b)
            default: return false
            }
        }

        /// Native strings cache their UTF-8 count. Compare contiguous bytes,
        /// preserving Unicode spellings and the complete truncation marker.
        static func equalDiffBytes(_ lhs: String, _ rhs: String) -> Bool {
            let count = lhs.utf8.count
            guard count == rhs.utf8.count else { return false }
            guard count > 0 else { return true }
            var lhs = lhs
            var rhs = rhs
            return lhs.withUTF8 { a in
                rhs.withUTF8 { b in memcmp(a.baseAddress!, b.baseAddress!, count) == 0 }
            }
        }
    }

    var isValid: Bool {
        guard !path.isEmpty else { return false }
        if case let .page(scheme, port, _) = self { return ["http", "https"].contains(scheme) && port > 0 }
        return true
    }
}

/// Times and mtimes are integer milliseconds. `remoteMTime` describes the
/// fetched bytes, not the latest stat; only `fetched` replaces that baseline.
public struct ArtifactsCacheMetadata: Codable, Equatable, Sendable {
    public var fetchedAt: Int64
    public var remoteMTime: Int64?
    public var size: Int64
    public var isStale: Bool

    public init(fetchedAt: Int64, remoteMTime: Int64? = nil, size: Int64, isStale: Bool = false) {
        self.fetchedAt = fetchedAt
        self.remoteMTime = remoteMTime
        self.size = size
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey { case fetchedAt, remoteMTime, size, isStale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try c.decode(Int64.self, forKey: .fetchedAt)
        remoteMTime = try c.decodeIfPresent(Int64.self, forKey: .remoteMTime)
        size = try c.decode(Int64.self, forKey: .size)
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        guard size >= 0 else { throw ArtifactsCoding.invalid(decoder, "negative cache size") }
    }
}

public struct ArtifactTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var hostID: String
    public var hostLabel: String
    public var target: ArtifactsTarget
    public var kind: ArtifactsKind
    public var title: String
    /// Open vocabulary: files, terminalSelection, forwarding, terminalLink,
    /// agentEdit, quickOpen. Unknown future origins survive persistence.
    public var origin: String
    /// The opening session's identifier, which a page forward prefers. An
    /// identifier, not display text.
    public var sessionHint: String?
    public var openedAt: Int64
    public var viewedAt: Int64
    public var pinned: Bool
    public var cache: ArtifactsCacheMetadata?
    public var unseenChange: Bool
    public var agentEditedAt: Int64?

    public init(
        id: String, hostID: String, hostLabel: String, target: ArtifactsTarget,
        title: String, origin: String = "quickOpen", sessionHint: String? = nil,
        openedAt: Int64, viewedAt: Int64, pinned: Bool = false,
        cache: ArtifactsCacheMetadata? = nil, unseenChange: Bool = false,
        agentEditedAt: Int64? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.hostLabel = hostLabel
        self.target = target.normalized
        self.kind = target.kind
        self.title = title
        self.origin = origin
        self.sessionHint = sessionHint
        self.openedAt = openedAt
        self.viewedAt = viewedAt
        self.pinned = pinned
        self.cache = cache
        self.unseenChange = unseenChange
        self.agentEditedAt = agentEditedAt
    }
}

public enum ArtifactsFilter: String, Codable, Equatable, Sendable, CaseIterable {
    case all, docs, pages, changes, files

    func includes(_ kind: ArtifactsKind) -> Bool { self == .all || rawValue == kind.rawValue }
}

public struct ArtifactsState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultTabCap = 64
    /// Like the tab cap, pins and the selected tab are protected from eviction.
    public static let maximumRetainedDiffBytes = 4 * 1024 * 1024
    public var version: Int
    public var tabs: [ArtifactTab]
    public var selectedID: String?
    public var filter: ArtifactsFilter
    /// A soft cap when every remaining tab is pinned or selected.
    public var tabCap: Int

    public init(
        version: Int = currentVersion, tabs: [ArtifactTab] = [], selectedID: String? = nil,
        filter: ArtifactsFilter = .all, tabCap: Int = defaultTabCap
    ) {
        self.version = version
        self.tabs = tabs
        self.selectedID = selectedID
        self.filter = filter
        self.tabCap = max(1, tabCap)
    }

    private enum CodingKeys: String, CodingKey { case version, tabs, selectedID, filter, tabCap }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        tabs = try c.decode([ArtifactTab].self, forKey: .tabs)
        selectedID = try c.decodeIfPresent(String.self, forKey: .selectedID)
        filter = try c.decodeIfPresent(ArtifactsFilter.self, forKey: .filter) ?? .all
        tabCap = max(1, try c.decodeIfPresent(Int.self, forKey: .tabCap) ?? Self.defaultTabCap)
    }
}

enum ArtifactsCoding {
    static func invalid(_ decoder: Decoder, _ description: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: description))
    }
}

enum ArtifactsPaths {
    /// ASCII identities avoid String's canonical Unicode equivalence. Escape
    /// percent and the field delimiter as well, so literal escapes stay unique.
    static func byteIdentity(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        for byte in value.utf8 {
            if byte >= 0x20 && byte < 0x7f && byte != 0x25 && byte != 0x7c { bytes.append(byte) }
            else { bytes.append(contentsOf: [0x25, digits[Int(byte >> 4)], digits[Int(byte & 15)]]) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + parts : parts
    }

    /// A combining mark after the slash joins its grapheme, so compare scalars.
    static func page(_ path: String) -> String {
        path.unicodeScalars.first == "/" ? path : "/" + path
    }

    static func withoutFragment(_ path: String) -> String {
        String(path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    /// Canonical decomposition and removal of Unicode marks are available
    /// in swift-corelibs-foundation; ICU transliteration is Apple-only.
    static func folded(_ value: String) -> String {
        let scalars = value.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
