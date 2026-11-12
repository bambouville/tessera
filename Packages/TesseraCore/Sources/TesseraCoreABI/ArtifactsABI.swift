import Foundation
import TesseraArtifactsCore
import TesseraDomainCore

// All entries use SharedABI's exact-size/copy-out string contract, sorted
// JSON keys and omitted nil optionals. -1 means invalid JSON/UTF-8, an invalid
// argument, or an undersized output buffer. Millisecond timestamps are Int64.
// Tagged enums are flat objects with a lowerCamel `type` string. See the
// golden fixture in TesseraCoreABITests/Fixtures/artifacts-abi-golden.json.
// Artifacts use a separate 128 MiB input ceiling: 64 embedded 256 KiB diffs
// can exceed the generic 1 MiB ceiling (and JSON escaping can expand 6x).

/// {"state":{"version":1,"tabs":[],"filter":"all","tabCap":64},
///  "action":{"type":"select","tabID":"t1","nowMillis":10}}
public struct ArtifactsReduceABIRequest: Codable, Equatable, Sendable {
    public var state: ArtifactsState
    public var action: ArtifactsAction

    public init(state: ArtifactsState, action: ArtifactsAction) { self.state = state; self.action = action }
}

/// Response is ArtifactsReduction, e.g.
/// {"evictedTabIDs":[],"state":{"filter":"all","tabCap":64,"tabs":[],"version":1}}.
/// focusedTabID is omitted when no selection exists. navigatedPath is present
/// on page opens (including reused ports) and page navigations, and includes
/// query and fragment.
@_cdecl("tessera_artifacts_reduce")
public func tesseraArtifactsReduce(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsReduceABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsReducer.reduce($0.state, $0.action)
    }
}

/// {"state":{"tabs":[]},"filter":"all","query":"plan"}
public struct ArtifactsOverviewABIRequest: Codable, Equatable, Sendable {
    public var state: ArtifactsState
    public var filter: ArtifactsFilter
    public var query: String

    public init(state: ArtifactsState, filter: ArtifactsFilter, query: String) {
        self.state = state; self.filter = filter; self.query = query
    }
}

/// Response is ArtifactsOverview, e.g. {"groups":[],"countsByKind":
/// {"docs":0,"pages":0,"changes":0,"files":0},"totalCount":0,"filter":"all","query":""}.
/// Counts and totalCount include the text query before the kind filter.
@_cdecl("tessera_artifacts_overview")
public func tesseraArtifactsOverview(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsOverviewABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsOverview.make($0.state, filter: $0.filter, query: $0.query)
    }
}

/// {"input":":5173","context":{"hosts":[{"id":"h1","label":"dev"}],
/// "currentHostID":"h1","cwd":"/work","listeningPorts":[]}}
public struct ArtifactsQuickOpenParseABIRequest: Codable, Equatable, Sendable {
    public var input: String
    public var context: ArtifactsQuickOpenContext

    public init(input: String, context: ArtifactsQuickOpenContext) { self.input = input; self.context = context }
}

/// Response is ArtifactsQuickOpenIntent, e.g.
/// {"type":"page","hostID":"h1","scheme":"http","port":5173,"path":"/"}.
/// A rejected user entry succeeds with {"type":"invalid","reason":"unknownHost"}.
/// Reasons: emptyInput, invalidInput, unknownHost, ambiguousHost, missingHost,
/// missingCwd, unsupportedURL, invalidPort. Search uses {"type":"search","text":"…"}.
@_cdecl("tessera_artifacts_quick_open_parse")
public func tesseraArtifactsQuickOpenParse(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsQuickOpenParseABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsQuickOpen.parse($0.input, context: $0.context)
    }
}

/// {"input":"plan","state":{"tabs":[]},"context":{"hosts":[],
/// "listeningPorts":[],"activeForwards":[]},"recents":[],"limit":8}.
/// Recent entries: {"title":"PLAN.md","subtitle":"dev · /work/PLAN.md",
/// "intent":{"type":"file","hostID":"h1","path":"/work/PLAN.md"},"viewedAt":10}.
/// activeForwards is optional: {"hostID":"h1","rule":{…PortForwardRule…}} for
/// each saved rule whose listener is running now, on any host.
public struct ArtifactsQuickOpenSuggestionsABIRequest: Codable, Equatable, Sendable {
    public var input: String
    public var state: ArtifactsState
    public var context: ArtifactsQuickOpenContext
    public var recents: [ArtifactsRecent]
    public var limit: Int

    public init(input: String, state: ArtifactsState, context: ArtifactsQuickOpenContext,
                recents: [ArtifactsRecent], limit: Int) {
        self.input = input; self.state = state; self.context = context; self.recents = recents; self.limit = limit
    }
}

/// Response is an array, e.g. [{"kind":"openTab","title":"PLAN.md",
/// "subtitle":"dev · /work/PLAN.md","tabID":"t1",
/// "intent":{"type":"file","hostID":"h1","path":"/work/PLAN.md"}}].
/// kind: hostPrefix | activeForward | openTab | listeningPort | recent. tabID
/// is optional; select it for a change snapshot rather than opening its
/// current file. An activeForward opens its page intent like any other.
@_cdecl("tessera_artifacts_quick_open_suggestions")
public func tesseraArtifactsQuickOpenSuggestions(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsQuickOpenSuggestionsABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsQuickOpen.suggestions($0.input, state: $0.state, context: $0.context, recents: $0.recents, limit: $0.limit)
    }
}

/// {"urlString":"http://127.0.0.2:3000/x?y#z"}
public struct ArtifactsClassifyLinkABIRequest: Codable, Equatable, Sendable {
    public var urlString: String
    public init(urlString: String) { self.urlString = urlString }
}

/// Response is ArtifactsLinkClass, e.g. {"type":"remoteLoopback","scheme":"http",
/// "port":3000,"pathAndQuery":"/x?y#z"}, {"type":"refused"}, {"type":"external"}, or
/// {"type":"unsupported"}. A refused URL is device-local and never opens on the device.
/// Defaults are 80/443. Wildcard binds count as remote loopback.
@_cdecl("tessera_artifacts_classify_link")
public func tesseraArtifactsClassifyLink(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsClassifyLinkABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsLinkClassifier.classify($0.urlString)
    }
}

/// {"link":"../README.md","documentPath":"/work/docs/guide.md","home":"/home/me"}.
/// home is optional; without it a "~" link is refused.
public struct ArtifactsDocumentLinkABIRequest: Codable, Equatable, Sendable {
    public var link: String
    public var documentPath: String
    public var home: String?
    public init(link: String, documentPath: String, home: String? = nil) {
        self.link = link; self.documentPath = documentPath; self.home = home
    }
}

/// Response is ArtifactsDocumentLink: {"type":"file","path":"/work/README.md"},
/// {"type":"page","scheme":"http","port":3000,"pathAndQuery":"/x?y#z"},
/// {"type":"external"}, {"type":"refused"} or {"type":"ignored"}. A file or page
/// is on the document's own host and opens as an Artifacts tab.
@_cdecl("tessera_artifacts_document_link")
public func tesseraArtifactsDocumentLink(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsDocumentLinkABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsDocumentLinks.resolve($0.link, documentPath: $0.documentPath, home: $0.home)
    }
}

/// {"command":"sh -c '…'"}. Run on an already authenticated connection;
/// the generated POSIX command's entire fallback chain has a one-second watchdog.
public struct ArtifactsListeningPortsCommandABIResponse: Codable, Equatable, Sendable {
    public var command: String
    public init(command: String) { self.command = command }
}

/// No input. Response example: {"command":"sh -c '…'"}.
@_cdecl("tessera_artifacts_listening_ports_command")
public func tesseraArtifactsListeningPortsCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    SharedABI.copyOutJSON(ArtifactsListeningPortsCommandABIResponse(command: ArtifactsListeningPorts.probeCommand),
                          outputBytes, outputCapacity)
}

/// {"output":"TESSERA_ARTIFACTS_PORTS:ss\nLISTEN 0 128 127.0.0.1:8000 0.0.0.0:*\n","sshPort":2222}.
/// sshPort is optional; 22 is always excluded. Only the final marked format is parsed.
public struct ArtifactsListeningPortsParseABIRequest: Codable, Equatable, Sendable {
    public var output: String
    public var sshPort: UInt16?
    public init(output: String, sshPort: UInt16? = nil) { self.output = output; self.sshPort = sshPort }
}

/// Response is a deduplicated, ascending-port array, e.g.
/// [{"port":8000,"bindAddress":"127.0.0.1","process":"python3"}]. process is optional.
@_cdecl("tessera_artifacts_listening_ports_parse")
public func tesseraArtifactsListeningPortsParse(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsListeningPortsParseABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsListeningPorts.parse($0.output, sshPort: $0.sshPort)
    }
}

/// {"remotePort":5173,"hostRules":[]}.
/// Rules use the existing DomainCore PortForwardRule wire format.
public struct ArtifactsForwardPlanABIRequest: Codable, Equatable, Sendable {
    public var remotePort: UInt16
    public var hostRules: [PortForwardRule]
    public init(remotePort: UInt16, hostRules: [PortForwardRule]) { self.remotePort = remotePort; self.hostRules = hostRules }
}

/// Response is ArtifactsForwardPlan, e.g. {"type":"ephemeral","rule":
/// {"id":"00000000-0000-0000-0000-000000000000","enabled":true,"autoStart":false,
/// "direction":"local","bind":{"host":"127.0.0.1","port":5173},
/// "target":{"host":"127.0.0.1","port":5173},"label":""}}.
/// Reuse: {"type":"reuse","ruleID":"…","target":{"scheme":"http",
/// "host":"127.0.0.1","port":5173,"url":"http://127.0.0.1:5173/"}}.
/// The nil UUID is an ephemeral sentinel. Bind port 0 requests OS allocation.
@_cdecl("tessera_artifacts_forward_plan")
public func tesseraArtifactsForwardPlan(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsForwardPlanABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) { request -> ArtifactsForwardPlan? in
        guard request.remotePort > 0 else { return nil }
        let plan = ArtifactsForwardPlanner.plan(remotePort: request.remotePort, hostRules: request.hostRules)
        if case let .ephemeral(rule) = plan, !ArtifactsForwardPlanner.isValidEphemeral(rule) { return nil }
        return plan
    }
}

/// {"ephemeral":{…PortForwardRule…},"label":"dev app","ruleID":"…","hostRules":[]}.
/// hostRules is optional. Replace an allocated ephemeral's bind.port with
/// its actual nonzero port before saving. Validation failure returns -1.
public struct ArtifactsKeepAsRuleABIRequest: Codable, Equatable, Sendable {
    public var ephemeral: PortForwardRule
    public var label: String
    public var ruleID: UUID
    public var hostRules: [PortForwardRule]?
    public init(ephemeral: PortForwardRule, label: String, ruleID: UUID, hostRules: [PortForwardRule]? = nil) {
        self.ephemeral = ephemeral; self.label = label; self.ruleID = ruleID; self.hostRules = hostRules
    }
}

/// Response is the persistent PortForwardRule, e.g. {"id":"…","enabled":true,
/// "autoStart":true,"direction":"local","bind":{"host":"127.0.0.1","port":5173},
/// "target":{"host":"localhost","port":5173},"label":"dev app"}.
@_cdecl("tessera_artifacts_keep_as_rule")
public func tesseraArtifactsKeepAsRule(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsKeepAsRuleABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) { request -> PortForwardRule? in
        guard ArtifactsForwardPlanner.isValidEphemeral(request.ephemeral) else { return nil }
        let rule = ArtifactsForwardPlanner.keepAsRule(request.ephemeral, label: request.label, ruleID: request.ruleID)
        guard PortForwardRuleValidator.validate(rule, against: request.hostRules ?? []) == nil else { return nil }
        return rule
    }
}

/// {"tab":{"id":"t1","hostID":"h1","hostLabel":"dev","target":{"type":"file",
/// "path":"/work/a.md"},"kind":"docs","title":"a.md","origin":"files",
/// "openedAt":1,"viewedAt":1,"pinned":false,"unseenChange":false}}.
public struct ArtifactsCacheKeyABIRequest: Codable, Equatable, Sendable {
    public var tab: ArtifactTab
    public init(tab: ArtifactTab) { self.tab = tab }
}

/// {"key":"fc41…"}. key is exactly 64 lowercase hex digits (SHA-256).
public struct ArtifactsCacheKeyABIResponse: Codable, Equatable, Sendable {
    public var key: String
    public init(key: String) { self.key = key }
}

/// Response example: {"key":"fc41…"}. Hashes UTF-8 hostID|kind|normalized path.
@_cdecl("tessera_artifacts_cache_key")
public func tesseraArtifactsCacheKey(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsCacheKeyABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsCacheKeyABIResponse(key: ArtifactsCachePolicy.cacheKey($0.tab))
    }
}

/// {"entries":[{"key":"a","size":100,"viewedAt":10,"pinned":false}],
/// "budgetBytes":0,"protectedKeys":[]}.
/// Include selected tab keys in protectedKeys; pinned entries protect themselves.
public struct ArtifactsCacheEvictionsABIRequest: Codable, Equatable, Sendable {
    public var entries: [ArtifactsCacheEntry]
    public var budgetBytes: Int64
    public var protectedKeys: [String]
    public init(entries: [ArtifactsCacheEntry], budgetBytes: Int64, protectedKeys: [String]) {
        self.entries = entries; self.budgetBytes = budgetBytes; self.protectedKeys = protectedKeys
    }
}

/// {"keys":["a","b"]}. In oldest-viewed order, lexical key breaking ties.
public struct ArtifactsCacheEvictionsABIResponse: Codable, Equatable, Sendable {
    public var keys: [String]
    public init(keys: [String]) { self.keys = keys }
}

/// Response example: {"keys":["a"]}.
@_cdecl("tessera_artifacts_cache_evictions")
public func tesseraArtifactsCacheEvictions(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsCacheEvictionsABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsCacheEvictionsABIResponse(keys: ArtifactsCachePolicy.evictions(
            $0.entries, budgetBytes: $0.budgetBytes, protectedKeys: Set($0.protectedKeys)))
    }
}

/// {"tab":{…ArtifactTab…},"liveConnection":false,"nowMillis":1000}.
public struct ArtifactsCachePresentationABIRequest: Codable, Equatable, Sendable {
    public var tab: ArtifactTab
    public var liveConnection: Bool
    public var nowMillis: Int64
    public init(tab: ArtifactTab, liveConnection: Bool, nowMillis: Int64) {
        self.tab = tab; self.liveConnection = liveConnection; self.nowMillis = nowMillis
    }
}

/// Response is ArtifactsCachePresentation, e.g.
/// {"state":"cached","fetchedAt":10,"canRefresh":false}.
/// state: live | cached | stale | offline | none. No live connection always
/// means canRefresh=false; a tab never reconnects its host.
@_cdecl("tessera_artifacts_cache_presentation")
public func tesseraArtifactsCachePresentation(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsCachePresentationABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsCachePolicy.presentation($0.tab, liveConnection: $0.liveConnection, nowMillis: $0.nowMillis)
    }
}

/// Takes the raw v1 persistence object, not a wrapper, e.g.
/// {"version":1,"tabs":[{"broken":true}],"futureField":true}.
/// Response is canonical ArtifactsState, e.g.
/// {"filter":"all","tabCap":64,"tabs":[],"version":1}.
/// Drops malformed tabs independently, caps diffs at 256 KiB and persisted
/// tabs at 64. Invalid JSON/UTF-8/non-object input returns -1. A valid object
/// with an unsupported version returns the empty v1 state.
@_cdecl("tessera_artifacts_decode_state")
public func tesseraArtifactsDecodeState(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let text = ArtifactsABI.requiredJSON(requestBytes, requestCount),
          let data = text.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return -1 }
    return SharedABI.copyOutJSON(ArtifactsPersistence.decode(data), outputBytes, outputCapacity)
}

/// Raw ArtifactsState -> canonical inline state, applying bounds once.
@_cdecl("tessera_artifacts_encode_state")
public func tesseraArtifactsEncodeState(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard ArtifactsABI.requiredJSON(requestBytes, requestCount) != nil,
          let state = SharedABI.decode(ArtifactsState.self, requestBytes, requestCount,
                                       maximum: ArtifactsABI.maximumInputBytes) else { return -1 }
    return SharedABI.copyOut([UInt8](ArtifactsPersistence.encode(state)), outputBytes, outputCapacity)
}

/// Raw ArtifactsState -> {"stateJSON":"{...manifest...}","blobs":{"<sha256>":"diff"}}.
/// Change targets in stateJSON carry diffDigest instead of diff. Write missing
/// blobs first, atomically replace state.json, then collect unreferenced blobs.
@_cdecl("tessera_artifacts_split_state")
public func tesseraArtifactsSplitState(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsState.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsPersistence.split($0)
    }
}

public struct ArtifactsBlobDigestsABIResponse: Codable, Equatable, Sendable {
    public var digests: [String]
    public init(digests: [String]) { self.digests = digests }
}

/// Raw manifest -> {"digests":["<sha256>"]}, sorted and unique. Only lowercase
/// 64-digit hex filenames may reach filesystem reads; inline files return [].
@_cdecl("tessera_artifacts_state_blob_digests")
public func tesseraArtifactsStateBlobDigests(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let text = ArtifactsABI.requiredJSON(requestBytes, requestCount),
          let data = text.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return -1 }
    return SharedABI.copyOutJSON(ArtifactsBlobDigestsABIResponse(digests: ArtifactsPersistence.blobDigests(data)),
                                 outputBytes, outputCapacity)
}

/// {"stateJSON":"{...manifest or legacy inline state...}","blobs":{"<sha256>":"diff"}}.
/// Response is canonical inline ArtifactsState. Missing, over-cap or tampered
/// blobs drop only their tabs. Malformed inner JSON/non-object returns -1.
@_cdecl("tessera_artifacts_join_state")
public func tesseraArtifactsJoinState(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsPersistenceFiles.self, requestBytes, requestCount, outputBytes, outputCapacity) { request -> ArtifactsState? in
        let data = Data(request.stateJSON.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return ArtifactsPersistence.join(data, blobs: request.blobs)
    }
}

/// {"path":"/work/PLAN.mdx","mimeHint":"text/markdown"}. mimeHint is optional.
public struct ArtifactsKindABIRequest: Codable, Equatable, Sendable {
    public var path: String
    public var mimeHint: String?
    public init(path: String, mimeHint: String? = nil) { self.path = path; self.mimeHint = mimeHint }
}

/// {"kind":"docs","viewer":"markdown"}.
/// kind: docs | pages | changes | files. viewer: markdown | html | web |
/// image | pdf | text | diff | other. This entry classifies files; page and
/// change targets carry pages/web and changes/diff respectively.
public struct ArtifactsKindABIResponse: Codable, Equatable, Sendable {
    public var kind: ArtifactsKind
    public var viewer: ArtifactsViewer
    public init(kind: ArtifactsKind, viewer: ArtifactsViewer) { self.kind = kind; self.viewer = viewer }
}

/// Response example: {"kind":"docs","viewer":"markdown"}.
@_cdecl("tessera_artifacts_kind")
public func tesseraArtifactsKind(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    ArtifactsABI.perform(ArtifactsKindABIRequest.self, requestBytes, requestCount, outputBytes, outputCapacity) {
        ArtifactsKindABIResponse(kind: ArtifactsKind.for(path: $0.path),
                                viewer: ArtifactsViewer.for(path: $0.path, mimeHint: $0.mimeHint))
    }
}

private enum ArtifactsABI {
    static let maximumInputBytes = 128 * 1024 * 1024

    static func requiredJSON(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> String? {
        guard let text = SharedABI.requiredString(bytes, count, maximum: maximumInputBytes),
              !text.utf8.contains(0) else { return nil }
        return text
    }

    static func perform<Request: Decodable, Response: Encodable>(
        _ type: Request.Type, _ bytes: UnsafePointer<UInt8>?, _ count: Int,
        _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
        _ response: (Request) -> Response?
    ) -> Int32 {
        guard requiredJSON(bytes, count) != nil,
              let request = SharedABI.decode(type, bytes, count, maximum: maximumInputBytes),
              let value = response(request) else { return -1 }
        return SharedABI.copyOutJSON(value, output, capacity)
    }
}
