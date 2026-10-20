import Foundation
import TmuxControlCore

/// One `TmuxShowEdgeTracker` per presentation slot behind a JSON handle, so
/// Android's tab slots detect show and hide edges with the same timing as
/// iOS. Like the lifecycle reducer, a reduction advances state and cannot be
/// retried with a larger buffer, so request and response share one small
/// bound and an oversized result is rejected before it is committed.
public enum TmuxShowEdgesABI {
    public static let maximumPayloadBytes = 4 * 1024
}

/// Requests carry `version` 1, an `event` and a non-negative `nowMillis` on the adapter's
/// one monotonic clock, which keeps running while the device sleeps. The
/// tracker owns no timer: the adapter sends `tick` at `nextDeadlineMillis`.
///
/// - `displayed` (requires `displayed`): the slot is the presented one, the
///   app is in the foreground and the app lock is not up.
/// - `explicitOpen`: an explicit open targets this slot.
/// - `transparentBegan` / `transparentEnded`: one of Tessera's own
///   excursions, which neither hides nor shows while it lasts.
/// - `tick`, and `snapshot`, which reads without advancing.
///
/// A reduction that changed nothing answers `{"version":1,"unchanged":true}`.
enum TmuxShowEdgesWire {
    static let version = 1
    static let unchangedResponse = Data(#"{"version":1,"unchanged":true}"#.utf8)

    static func reduce(_ tracker: inout TmuxShowEdgeTracker, _ request: TmuxShowEdgesRequest) -> Data? {
        // Platform clocks count up from boot; a negative one is an adapter bug.
        guard request.version == version, let now = request.nowMillis, now >= 0 else { return nil }
        let before = tracker
        let edges: [TmuxShowEdgeTracker.Edge]
        switch request.event {
        case "displayed":
            guard let displayed = request.displayed else { return nil }
            edges = tracker.displayed(displayed, now: now)
        case "explicitOpen":
            edges = tracker.explicitOpen(now: now)
        case "transparentBegan":
            edges = tracker.transparentBegan(now: now)
        case "transparentEnded":
            edges = tracker.transparentEnded(now: now)
        case "tick":
            edges = tracker.tick(now: now)
        case "snapshot":
            return encode(tracker, edges: [])
        default:
            return nil
        }
        if edges.isEmpty, tracker == before { return unchangedResponse }
        return encode(tracker, edges: edges)
    }

    private static func encode(_ tracker: TmuxShowEdgeTracker, edges: [TmuxShowEdgeTracker.Edge]) -> Data? {
        let response = TmuxShowEdgesResponse(
            version: version,
            edges: edges.map(TmuxShowEdgeDTO.init),
            displayed: tracker.displayed,
            isShown: tracker.isShown,
            showPending: tracker.showPending,
            transparent: tracker.transparentSince != nil,
            nextDeadlineMillis: tracker.nextDeadline
        )
        guard let encoded = try? JSONEncoder().encode(response),
              encoded.count <= TmuxShowEdgesABI.maximumPayloadBytes
        else { return nil }
        return encoded
    }
}

struct TmuxShowEdgesRequest: Decodable {
    let version: Int
    let event: String
    let nowMillis: Int64?
    /// `displayed` (required).
    let displayed: Bool?
}

struct TmuxShowEdgeDTO: Encodable {
    /// `hide` or `show`.
    let kind: String
    /// `show`: `show` or `explicitOpen`.
    let source: String?
    /// `show`: the user's step, which the session's intent window runs from.
    let stepAtMillis: Int64?

    init(_ edge: TmuxShowEdgeTracker.Edge) {
        switch edge {
        case .hide:
            (kind, source, stepAtMillis) = ("hide", nil, nil)
        case .show(let source, let stepAt):
            (kind, self.source, stepAtMillis) = ("show", source.rawValue, stepAt)
        }
    }
}

struct TmuxShowEdgesResponse: Encodable {
    let version: Int
    /// In order: a hide always precedes the show that follows it.
    let edges: [TmuxShowEdgeDTO]
    let displayed: Bool
    /// A show was emitted and no hide has been (a debouncing hide counts).
    let isShown: Bool
    let showPending: Bool
    let transparent: Bool
    let nextDeadlineMillis: Int64?
}

private final class CTmuxShowEdges: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = TmuxShowEdgeTracker()

    func reduce(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(TmuxShowEdgesRequest.self, from: data) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var candidate = tracker
        guard let response = TmuxShowEdgesWire.reduce(&candidate, request) else { return nil }
        tracker = candidate
        return response
    }
}

private enum CTmuxShowEdgesRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var trackers: [UInt: CTmuxShowEdges] = [:]

    static func insert(_ tracker: CTmuxShowEdges) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        trackers[token] = tracker
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withTracker<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ body: (CTmuxShowEdges) -> T
    ) -> T? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        guard let tracker = trackers[token] else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return body(tracker)
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return }
        lock.lock()
        trackers.removeValue(forKey: token)
        lock.unlock()
    }
}

@_cdecl("tessera_tmux_show_edges_create")
public func tesseraTmuxShowEdgesCreate() -> UnsafeMutableRawPointer {
    CTmuxShowEdgesRegistry.insert(CTmuxShowEdges())
}

/// Apply one bounded JSON event and return one bounded JSON edge envelope.
/// The tracker is mutated exactly once per call; there is no size-query
/// first pass.
@_cdecl("tessera_tmux_show_edges_reduce")
public func tesseraTmuxShowEdgesReduce(
    handle: UnsafeMutableRawPointer?,
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let requestBytes,
          requestCount > 0,
          requestCount <= TmuxShowEdgesABI.maximumPayloadBytes,
          let outputBytes,
          outputCapacity >= TmuxShowEdgesABI.maximumPayloadBytes
    else { return -1 }
    let request = Data(bytes: requestBytes, count: requestCount)
    guard let response = CTmuxShowEdgesRegistry.withTracker(handle, { tracker in
        tracker.reduce(request)
    }) ?? nil,
          response.count <= TmuxShowEdgesABI.maximumPayloadBytes
    else { return -1 }
    response.copyBytes(to: outputBytes, count: response.count)
    return Int32(response.count)
}

@_cdecl("tessera_tmux_show_edges_max_payload_bytes")
public func tesseraTmuxShowEdgesMaxPayloadBytes() -> Int {
    TmuxShowEdgesABI.maximumPayloadBytes
}

@_cdecl("tessera_tmux_show_edges_destroy")
public func tesseraTmuxShowEdgesDestroy(
    handle: UnsafeMutableRawPointer?
) {
    CTmuxShowEdgesRegistry.remove(handle)
}
