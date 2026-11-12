import Foundation
import TesseraDomainCore

public struct ArtifactsQuickOpenHost: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var home: String?

    public init(id: String, label: String, home: String? = nil) {
        self.id = id
        self.label = label
        self.home = home
    }
}

/// A saved rule whose local listener is running now in a live session of
/// hostID. Running is live platform state; which rules a page can borrow is
/// the forward planner's reuse policy.
public struct ArtifactsActiveForward: Codable, Equatable, Sendable {
    public var hostID: String
    public var rule: PortForwardRule

    public init(hostID: String, rule: PortForwardRule) {
        self.hostID = hostID
        self.rule = rule
    }
}

public struct ArtifactsQuickOpenContext: Codable, Equatable, Sendable {
    public var hosts: [ArtifactsQuickOpenHost]
    public var currentHostID: String?
    public var cwd: String?
    /// These observations belong only to currentHostID.
    public var listeningPorts: [ArtifactsListeningPort]
    /// Every host's, unlike listeningPorts. Optional on the wire.
    public var activeForwards: [ArtifactsActiveForward]

    public init(
        hosts: [ArtifactsQuickOpenHost], currentHostID: String? = nil, cwd: String? = nil,
        listeningPorts: [ArtifactsListeningPort] = [], activeForwards: [ArtifactsActiveForward] = []
    ) {
        self.hosts = hosts
        self.currentHostID = currentHostID
        self.cwd = cwd
        self.listeningPorts = listeningPorts
        self.activeForwards = activeForwards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([ArtifactsQuickOpenHost].self, forKey: .hosts)
        currentHostID = try c.decodeIfPresent(String.self, forKey: .currentHostID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        listeningPorts = try c.decode([ArtifactsListeningPort].self, forKey: .listeningPorts)
        activeForwards = try c.decodeIfPresent([ArtifactsActiveForward].self, forKey: .activeForwards) ?? []
    }
}

public enum ArtifactsQuickOpenInvalidReason: String, Codable, Equatable, Sendable {
    case emptyInput, invalidInput, unknownHost, ambiguousHost, missingHost, missingCwd, unsupportedURL, invalidPort
}

/// Flat JSON, e.g. {"type":"file","hostID":"h1","path":"/tmp/a.md"}
/// or {"type":"invalid","reason":"unknownHost"}.
public enum ArtifactsQuickOpenIntent: Codable, Equatable, Sendable {
    case file(hostID: String, path: String)
    case directory(hostID: String, path: String)
    case page(hostID: String, scheme: String, port: UInt16, path: String)
    case search(text: String)
    case invalid(reason: ArtifactsQuickOpenInvalidReason)

    private struct Wire: Codable {
        var type: String
        var hostID: String?
        var path: String?
        var scheme: String?
        var port: UInt16?
        var text: String?
        var reason: ArtifactsQuickOpenInvalidReason?
    }

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        switch w.type {
        case "file", "directory", "page":
            guard let host = w.hostID, let path = w.path else { throw ArtifactsCoding.invalid(decoder, "missing destination") }
            if w.type == "file" { self = .file(hostID: host, path: path) }
            else if w.type == "directory" { self = .directory(hostID: host, path: path) }
            else {
                guard let scheme = w.scheme, let port = w.port, ["http", "https"].contains(scheme), port > 0 else {
                    throw ArtifactsCoding.invalid(decoder, "invalid page intent")
                }
                self = .page(hostID: host, scheme: scheme, port: port, path: path)
            }
        case "search":
            guard let text = w.text else { throw ArtifactsCoding.invalid(decoder, "missing search text") }
            self = .search(text: text)
        case "invalid":
            guard let reason = w.reason else { throw ArtifactsCoding.invalid(decoder, "missing invalid reason") }
            self = .invalid(reason: reason)
        default: throw ArtifactsCoding.invalid(decoder, "unknown intent type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let w: Wire
        switch self {
        case let .file(host, path): w = Wire(type: "file", hostID: host, path: path)
        case let .directory(host, path): w = Wire(type: "directory", hostID: host, path: path)
        case let .page(host, scheme, port, path): w = Wire(type: "page", hostID: host, path: path, scheme: scheme, port: port)
        case let .search(text): w = Wire(type: "search", text: text)
        case let .invalid(reason): w = Wire(type: "invalid", reason: reason)
        }
        try w.encode(to: encoder)
    }

    public static func == (lhs: ArtifactsQuickOpenIntent, rhs: ArtifactsQuickOpenIntent) -> Bool {
        switch (lhs, rhs) {
        case let (.file(aHost, aPath), .file(bHost, bPath)),
             let (.directory(aHost, aPath), .directory(bHost, bPath)):
            return aHost == bHost && aPath.utf8.elementsEqual(bPath.utf8)
        case let (.page(aHost, aScheme, aPort, aPath), .page(bHost, bScheme, bPort, bPath)):
            return aHost == bHost && aScheme == bScheme && aPort == bPort && aPath.utf8.elementsEqual(bPath.utf8)
        case let (.search(a), .search(b)): return a == b
        case let (.invalid(a), .invalid(b)): return a == b
        default: return false
        }
    }
}

public enum ArtifactsSuggestionKind: String, Codable, Equatable, Sendable {
    case hostPrefix, activeForward, openTab, listeningPort, recent
}

public struct ArtifactsSuggestion: Codable, Equatable, Sendable {
    public var kind: ArtifactsSuggestionKind
    public var title: String
    public var subtitle: String
    public var intent: ArtifactsQuickOpenIntent
    /// Lets an open change suggestion select its immutable snapshot instead
    /// of opening a file at that path.
    public var tabID: String?

    public init(
        kind: ArtifactsSuggestionKind, title: String, subtitle: String,
        intent: ArtifactsQuickOpenIntent, tabID: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.intent = intent
        self.tabID = tabID
    }
}

public struct ArtifactsRecent: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var intent: ArtifactsQuickOpenIntent
    public var viewedAt: Int64

    public init(title: String, subtitle: String, intent: ArtifactsQuickOpenIntent, viewedAt: Int64) {
        self.title = title
        self.subtitle = subtitle
        self.intent = intent
        self.viewedAt = viewedAt
    }
}

public enum ArtifactsQuickOpen {
    public static func parse(_ input: String, context: ArtifactsQuickOpenContext) -> ArtifactsQuickOpenIntent {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid(reason: .emptyInput) }
        guard !RemotePathGrammar.containsControlCharacter(text) else { return .invalid(reason: .invalidInput) }
        if text.hasPrefix("?") {
            let query = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? .invalid(reason: .emptyInput) : .search(text: query)
        }
        var hostID = context.currentHostID
        var path = text
        var explicitHost = false
        let lowered = text.lowercased()
        let portForm = lowered.hasPrefix(":") || lowered.hasPrefix("localhost:")
            || lowered.hasPrefix("127.") || lowered.hasPrefix("0.0.0.0:") || isBracketedPortForm(text)
        if text.contains("://") || portForm {
            guard let host = hostID, context.hosts.contains(where: { $0.id == host }) else { return .invalid(reason: .missingHost) }
            let url: String
            if text.contains("://") { url = text }
            else if text.hasPrefix(":") { url = "http://localhost" + text }
            else { url = "http://" + text }
            switch ArtifactsLinkClassifier.classify(url) {
            case let .remoteLoopback(scheme, port, path): return .page(hostID: host, scheme: scheme, port: port, path: path)
            default: return .invalid(reason: portForm ? .invalidPort : .unsupportedURL)
            }
        }
        if !text.hasPrefix("["), let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            let label = String(text[..<colon])
            let matches = context.hosts.filter { $0.label.lowercased() == label.lowercased() }
            guard matches.count == 1 else { return .invalid(reason: matches.isEmpty ? .unknownHost : .ambiguousHost) }
            hostID = matches[0].id
            path = String(text[text.index(after: colon)...])
            explicitHost = true
            if path.isEmpty { path = "~/" }
        }
        // Bare prose is search; bare filenames/relative directory names
        // resolve against cwd just like the existing Files path bar.
        if !explicitHost, !path.contains("/"), !path.contains("."), !path.hasPrefix("~"), path.contains(" ") {
            return .search(text: text)
        }
        guard let id = hostID, let host = context.hosts.first(where: { $0.id == id }) else {
            return .invalid(reason: .missingHost)
        }
        let isDirectory = path.hasSuffix("/") || path == "~" || path == "/" || path == "." || path == ".."
        let expanded: String
        if path == "~" || path.hasPrefix("~/") {
            expanded = ArtifactsPaths.normalize(host.home.map { $0 + path.dropFirst() } ?? path)
        } else if path.hasPrefix("~") {
            return .invalid(reason: .invalidInput)
        } else if path.hasPrefix("/") {
            expanded = ArtifactsPaths.normalize(path)
        } else {
            // cwd belongs to the current host only. Another host's relative
            // path is relative to its known home, never to the current cwd.
            let cwd = id == context.currentHostID ? context.cwd : host.home
            guard let cwd, cwd.hasPrefix("/") else { return .invalid(reason: .missingCwd) }
            expanded = ArtifactsPaths.normalize(cwd + "/" + path)
        }
        return isDirectory ? .directory(hostID: id, path: expanded) : .file(hostID: id, path: expanded)
    }

    public static func suggestions(
        _ input: String, state: ArtifactsState, context: ArtifactsQuickOpenContext,
        recents: [ArtifactsRecent], limit: Int = 8
    ) -> [ArtifactsSuggestion] {
        guard limit > 0 else { return [] }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [ArtifactsSuggestion] = []
        let parsed = parse(text, context: context)
        let needle: String
        if case let .search(query) = parsed { needle = folded(query) }
        else { needle = folded(text) }
        let prefix = text.firstIndex(of: ":").map { String(text[..<$0]) }
        if let prefix, context.hosts.contains(where: { $0.label.lowercased() == prefix.lowercased() }),
           isDestination(parsed) {
            result.append(.init(kind: .hostPrefix, title: text, subtitle: prefix, intent: parsed))
        }
        if result.count == limit { return result }
        // Running forwards lead even an empty entry, ahead of open tabs that
        // could otherwise fill the limit. A forward already open as a tab is
        // left to its tab.
        result += selectSuggestions(activeForwardPages(context, tabs: state.tabs), limit: limit - result.count,
                                    excluding: result, precedes: ActiveForwardPage.precedes) { page in
            var intent = ArtifactsQuickOpenIntent.page(hostID: page.hostID, scheme: page.scheme, port: page.port, path: "/")
            var matchesPagePort = false
            if case let .page(host, scheme, port, _) = parsed, host == page.hostID, scheme == page.scheme, port == page.port {
                matchesPagePort = true
                intent = parsed
            }
            guard needle.isEmpty || matchesPagePort || folded(page.searchable).contains(needle) else { return nil }
            return .init(kind: .activeForward, title: "localhost:\(page.port)", subtitle: page.subtitle, intent: intent)
        }
        if result.count == limit { return result }
        // A typed port asks for the host's ports: they come before tabs that
        // could fill the limit, except one already open as a tab, which is
        // left to its tab.
        // Bare "localhost" lists them all; a file named "localhost.conf"
        // or a host labelled "localhost-dev" is not a port.
        let lowered = text.lowercased()
        let spellsPort = text.hasPrefix(":") || lowered == "localhost" || lowered.hasPrefix("localhost:")
        if spellsPort, let host = context.currentHostID, context.hosts.contains(where: { $0.id == host }) {
            let portInput = text.hasPrefix(":") ? String(text.dropFirst())
                : String(lowered.dropFirst("localhost:".count))
            let portPrefix = String(portInput.prefix { !"/?#".contains($0) })
            let tabbedPorts = Set(state.tabs.compactMap { tab -> UInt16? in
                guard tab.hostID == host, case let .page(_, port, _) = tab.target else { return nil }
                return port
            })
            result += selectSuggestions(context.listeningPorts, limit: limit - result.count, excluding: result,
                                        precedes: { $0.port < $1.port }) { port in
                guard !tabbedPorts.contains(port.port),
                      portPrefix.isEmpty || String(port.port).hasPrefix(portPrefix) else { return nil }
                let intent: ArtifactsQuickOpenIntent
                if case let .page(_, _, parsedPort, _) = parsed, parsedPort == port.port { intent = parsed }
                else { intent = .page(hostID: host, scheme: "http", port: port.port, path: "/") }
                return .init(kind: .listeningPort, title: "localhost:\(port.port)",
                             subtitle: port.process ?? port.bindAddress, intent: intent)
            }
        }
        if result.count == limit { return result }
        result += selectSuggestions(state.tabs, limit: limit - result.count, excluding: result,
                                    precedes: ArtifactsOverview.recentFirst) { tab in
            // Every tab's "host:path" holds a colon: a typed port matches pages only.
            if spellsPort { guard case .page = tab.target else { return nil } }
            var searchable = "\(tab.title) \(tab.target.path) \(tab.hostLabel) \(tab.hostLabel):\(tab.target.path)"
            var matchesPagePort = false
            if case let .page(scheme, port, path) = tab.target {
                searchable += " \(scheme)://localhost:\(port)\(path)"
                if case let .page(host, parsedScheme, parsedPort, _) = parsed {
                    matchesPagePort = host == tab.hostID && scheme == parsedScheme && port == parsedPort
                }
            }
            guard needle.isEmpty || matchesPagePort || folded(searchable).contains(needle) else { return nil }
            let intent: ArtifactsQuickOpenIntent
            switch tab.target {
            case let .page(scheme, port, path):
                if case let .page(host, newScheme, newPort, _) = parsed,
                   host == tab.hostID, scheme == newScheme, port == newPort { intent = parsed }
                else { intent = .page(hostID: tab.hostID, scheme: scheme, port: port, path: path) }
            case let .file(path), let .change(path, _, _): intent = .file(hostID: tab.hostID, path: path)
            }
            return .init(kind: .openTab, title: tab.title, subtitle: "\(tab.hostLabel) · \(tab.target.path)",
                         intent: intent, tabID: tab.id)
        }
        if result.count == limit { return result }
        result += selectSuggestions(recents, limit: limit - result.count, excluding: result, precedes: {
            if $0.viewedAt != $1.viewedAt { return $0.viewedAt > $1.viewedAt }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.subtitle < $1.subtitle
        }) { recent in
            guard isDestination(recent.intent),
                  needle.isEmpty || folded(recent.title + " " + recent.subtitle).contains(needle) else { return nil }
            return .init(kind: .recent, title: recent.title, subtitle: recent.subtitle, intent: recent.intent)
        }
        return result
    }

    private static func selectSuggestions<Value>(
        _ values: [Value], limit: Int, excluding: [ArtifactsSuggestion],
        precedes: @escaping (Value, Value) -> Bool, makeSuggestion: (Value) -> ArtifactsSuggestion?
    ) -> [ArtifactsSuggestion] {
        var best = ArtifactsQuickOpenTopK<(value: Value, suggestion: ArtifactsSuggestion)>(limit: limit)
        for value in values {
            // Worse-ranked candidates cannot enter a full selection. Avoid
            // folding their paths or constructing their suggestions as well.
            if let last = best.values.last, best.values.count == limit, !precedes(value, last.value) { continue }
            guard let suggestion = makeSuggestion(value),
                  !excluding.contains(where: { duplicates($0, suggestion) }) else { continue }
            best.insert((value, suggestion), precedes: { precedes($0.value, $1.value) },
                        duplicates: { duplicates($0.suggestion, $1.suggestion) })
        }
        return best.values.map(\.suggestion)
    }

    private static func duplicates(_ lhs: ArtifactsSuggestion, _ rhs: ArtifactsSuggestion) -> Bool {
        (lhs.tabID == rhs.tabID || lhs.tabID == nil || rhs.tabID == nil) && lhs.intent == rhs.intent
    }

    /// The page a running forward serves, as a tab would open it. Rules for
    /// the same page collapse to the lowest rule ID, the one the planner reuses.
    private struct ActiveForwardPage {
        /// The current host first, then the context's host order.
        let hostRank: Int
        let hostID: String
        let scheme: String
        let port: UInt16
        let ruleID: String
        let subtitle: String
        let searchable: String

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.hostRank != rhs.hostRank { return lhs.hostRank < rhs.hostRank }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            if lhs.scheme != rhs.scheme { return lhs.scheme < rhs.scheme }
            return lhs.ruleID < rhs.ruleID
        }
    }

    private static func activeForwardPages(_ context: ArtifactsQuickOpenContext, tabs: [ArtifactTab]) -> [ActiveForwardPage] {
        guard !context.activeForwards.isEmpty else { return [] }
        var hosts: [String: (rank: Int, label: String)] = [:]
        for (index, host) in context.hosts.enumerated() where hosts[host.id] == nil {
            hosts[host.id] = (host.id == context.currentHostID ? -1 : index, host.label)
        }
        let hostRules = Dictionary(grouping: context.activeForwards, by: \.hostID).mapValues { $0.map(\.rule) }
        return context.activeForwards.compactMap { forward in
            let rule = forward.rule
            guard let host = hosts[forward.hostID], let port = rule.target?.port,
                  ArtifactsForwardPlanner.isReusable(rule, hostRules: hostRules[forward.hostID] ?? []),
                  let scheme = ForwardedWebPolicy.webTarget(for: rule)?.scheme,
                  !tabs.contains(where: { tab in
                      guard tab.hostID == forward.hostID, case let .page(tabScheme, tabPort, _) = tab.target else { return false }
                      return tabScheme == scheme && tabPort == port
                  }) else { return nil }
            let subtitle = rule.label.isEmpty ? host.label : "\(host.label) · \(rule.label)"
            return ActiveForwardPage(hostRank: host.rank, hostID: forward.hostID, scheme: scheme, port: port,
                                     ruleID: rule.id.uuidString, subtitle: subtitle,
                                     searchable: "localhost:\(port) \(subtitle) \(scheme)://localhost:\(port)/")
        }
    }

    #if DEBUG
    private final class Work: NSObject {
        var folds = 0
        var bytes = 0
    }
    private static let workKey = "TesseraArtifactsCore.quickOpenWork"

    static func measure<T>(_ operation: () throws -> T) rethrows -> (value: T, folds: Int, bytes: Int) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[workKey]
        let work = Work()
        dictionary[workKey] = work
        defer { dictionary[workKey] = previous }
        let value = try operation()
        return (value, work.folds, work.bytes)
    }
    #endif

    private static func folded(_ value: String) -> String {
        #if DEBUG
        if let work = Thread.current.threadDictionary[workKey] as? Work {
            work.folds += 1
            work.bytes += value.utf8.count
        }
        #endif
        return ArtifactsPaths.folded(value)
    }

    private static func isBracketedPortForm(_ input: String) -> Bool {
        // Delimiters are scalars even when a following mark joins their grapheme.
        let authority = String(String.UnicodeScalarView(input.unicodeScalars.prefix { !"/?#".unicodeScalars.contains($0) }))
        guard authority.hasPrefix("["), let bracket = authority.firstIndex(of: "]"),
              ArtifactsHTTPURL.validIPv6(String(authority.dropFirst().prefix(upTo: bracket)).lowercased()) else { return false }
        let suffix = authority[authority.index(after: bracket)...]
        return suffix.hasPrefix(":") && suffix.count > 1 && suffix.dropFirst().allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private static func isDestination(_ intent: ArtifactsQuickOpenIntent) -> Bool {
        switch intent {
        case .file, .directory, .page: return true
        case .invalid, .search: return false
        }
    }
}

/// Insertion order breaks ranking ties, matching a stable full sort. Each
/// source has the same tab-ID shape, so duplicate replacement is transitive.
struct ArtifactsQuickOpenTopK<Value> {
    let limit: Int
    private(set) var values: [Value] = []

    mutating func insert(
        _ value: Value, precedes: (Value, Value) -> Bool, duplicates: (Value, Value) -> Bool
    ) {
        guard limit > 0 else { return }
        let index = values.firstIndex(where: { precedes(value, $0) }) ?? values.count
        guard index < limit else { return }
        if let duplicate = values.firstIndex(where: { duplicates(value, $0) }) {
            guard index <= duplicate else { return }
            values.remove(at: duplicate)
        }
        if values.count == limit { values.removeLast() }
        values.insert(value, at: index)
    }
}
