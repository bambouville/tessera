import Foundation
import TmuxControlCore

/// The session request and response are both capped at this size.  Unlike the
/// stateless command builders, a lifecycle reduction cannot be retried with a
/// larger response buffer because it advances state.  Keep the limit small
/// enough for every platform bridge to allocate it eagerly and reject an
/// oversized result before committing the candidate state.
public enum TmuxAuthorityLifecycleABI {
    public static let maximumPayloadBytes = 64 * 1024
}

struct TmuxAuthorityLifecyclePeerDTO: Codable {
    let deviceID: String
    let displayName: String
    let generation: UInt64
}

struct TmuxAuthorityLifecycleGridDTO: Codable {
    let columns: Int
    let rows: Int
}

struct TmuxAuthorityLifecycleClaimDTO: Codable {
    let generation: UInt64
    let reason: String
    let phase: String
    let presentationVisible: Bool
    let contestedPeer: TmuxAuthorityLifecyclePeerDTO?
    /// True once the claim fenced again after losing its geometry.
    let geometryRefenced: Bool
    /// Every grid the claim advertised, oldest first (§6.10 rule 3).
    let advertisedGrids: [TmuxAuthorityLifecycleGridDTO]
    /// The advertised grid the claim confirms at; absent until it has one.
    let targetGrid: TmuxAuthorityLifecycleGridDTO?
    /// The settle probe of the claim's latest fence answered (§6.10 rule 5).
    let geometryLanded: Bool
}

struct TmuxAuthorityLifecycleIntentDTO: Codable {
    let token: UInt64
    let source: String
    let baselineKnown: Bool
    let baseline: TmuxAuthorityLifecyclePeerDTO?
}

final class CTmuxAuthorityLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var session: TmuxGridAuthoritySession
    /// A runtime the session is attached to keeps this object, so the
    /// handle's destruction must also stop that runtime reducing it.
    private var isDestroyed = false

    init(initialGeneration: UInt64 = TmuxGridAuthorityStamp.generationBase(
        unixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
    )) {
        session = TmuxGridAuthoritySession(initialGeneration: initialGeneration)
    }

    func reduce(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(TmuxAuthoritySessionRequest.self, from: data),
              request.version == TmuxAuthoritySessionWire.version
        else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return nil }
        // A rejected request or an oversized response leaves the committed
        // session untouched. Commit only after its bounded reply is encoded.
        var candidate = session
        guard let response = TmuxAuthoritySessionWire.reduce(&candidate, request) else { return nil }
        session = candidate
        return response
    }

    /// Runs `body` on the session under its lock; nil once the handle is
    /// destroyed. An attached runtime reduces a read's stamps this way
    /// (`tessera_tmux_runtime_feed_at`), holding the session for the whole
    /// read so its response describes only its own reductions. `body` must
    /// not call back into this object.
    func withSession<T>(_ body: (inout TmuxGridAuthoritySession) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return nil }
        return body(&session)
    }

    func destroy() {
        lock.lock()
        isDestroyed = true
        lock.unlock()
    }
}

enum CTmuxAuthorityLifecycleRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var lifecycles: [UInt: CTmuxAuthorityLifecycle] = [:]

    static func insert(_ lifecycle: CTmuxAuthorityLifecycle) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        lifecycles[token] = lifecycle
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withLifecycle<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ body: (CTmuxAuthorityLifecycle) -> T
    ) -> T? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        guard let lifecycle = lifecycles[token] else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return body(lifecycle)
    }

    /// The live lifecycle behind `handle`, for a runtime to attach.
    static func lifecycle(_ handle: UnsafeMutableRawPointer?) -> CTmuxAuthorityLifecycle? {
        withLifecycle(handle) { $0 }
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return }
        lock.lock()
        let removed = lifecycles.removeValue(forKey: token)
        lock.unlock()
        removed?.destroy()
    }
}

@_cdecl("tessera_tmux_authority_lifecycle_create")
public func tesseraTmuxAuthorityLifecycleCreate() -> UnsafeMutableRawPointer {
    CTmuxAuthorityLifecycleRegistry.insert(CTmuxAuthorityLifecycle())
}

/// Explicit seed for deterministic host tests; production uses the clock-seeded factory.
@_cdecl("tessera_tmux_authority_lifecycle_create_seeded")
public func tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: Int64) -> UnsafeMutableRawPointer? {
    guard initialGeneration >= 0 else { return nil }
    return CTmuxAuthorityLifecycleRegistry.insert(CTmuxAuthorityLifecycle(initialGeneration: UInt64(initialGeneration)))
}

/// Apply one bounded JSON event and return one bounded JSON snapshot/effect
/// envelope. The session is mutated exactly once per accepted call; unlike command
/// builders, this API does not support a size-query first pass.
@_cdecl("tessera_tmux_authority_lifecycle_reduce")
public func tesseraTmuxAuthorityLifecycleReduce(
    handle: UnsafeMutableRawPointer?,
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let requestBytes,
          requestCount > 0,
          requestCount <= TmuxAuthorityLifecycleABI.maximumPayloadBytes,
          let outputBytes,
          outputCapacity >= TmuxAuthorityLifecycleABI.maximumPayloadBytes
    else { return -1 }
    let request = Data(bytes: requestBytes, count: requestCount)
    guard let response = CTmuxAuthorityLifecycleRegistry.withLifecycle(handle, { lifecycle in
        lifecycle.reduce(request)
    }) ?? nil,
          response.count <= TmuxAuthorityLifecycleABI.maximumPayloadBytes
    else { return -1 }
    response.copyBytes(to: outputBytes, count: response.count)
    return Int32(response.count)
}

@_cdecl("tessera_tmux_authority_lifecycle_max_payload_bytes")
public func tesseraTmuxAuthorityLifecycleMaxPayloadBytes() -> Int {
    TmuxAuthorityLifecycleABI.maximumPayloadBytes
}

@_cdecl("tessera_tmux_authority_lifecycle_destroy")
public func tesseraTmuxAuthorityLifecycleDestroy(
    handle: UnsafeMutableRawPointer?
) {
    CTmuxAuthorityLifecycleRegistry.remove(handle)
}

extension TmuxGridAuthoritySnapshot {
    var dto: (kind: String, deviceID: String?, displayName: String?, generation: UInt64?) {
        switch self {
        case .unknown:
            return ("unknown", nil, nil, nil)
        case .mine(let generation):
            return ("mine", nil, nil, generation)
        case .peer(let deviceID, let displayName, let generation):
            return ("peer", deviceID, displayName, generation)
        }
    }
}

extension TmuxAuthorityLifecycleClaimDTO {
    init(_ claim: TmuxGridAuthorityLifecycleReducer.Claim) {
        generation = claim.generation
        reason = claim.reason.rawValue
        phase = claim.phase.rawValue
        presentationVisible = claim.presentationVisible
        contestedPeer = claim.contestedPeer.map(TmuxAuthorityLifecyclePeerDTO.init)
        geometryRefenced = claim.geometryRefenced
        advertisedGrids = claim.advertisedGrids.map(TmuxAuthorityLifecycleGridDTO.init)
        targetGrid = claim.targetGrid.map(TmuxAuthorityLifecycleGridDTO.init)
        geometryLanded = claim.geometryLanded
    }
}

private extension TmuxAuthorityLifecycleGridDTO {
    init(_ grid: TmuxGridAuthorityLifecycleReducer.Grid) {
        columns = grid.columns
        rows = grid.rows
    }
}

extension TmuxAuthorityLifecyclePeerDTO {
    init(_ peer: TmuxGridAuthorityLifecycleReducer.Peer) {
        deviceID = peer.deviceID
        displayName = peer.displayName
        generation = peer.generation
    }
}

extension TmuxAuthorityLifecycleIntentDTO {
    init(_ intent: TmuxGridAuthorityLifecycleReducer.Intent) {
        token = intent.token
        source = intent.source.rawValue
        baselineKnown = intent.baselineKnown
        baseline = intent.baseline.map(TmuxAuthorityLifecyclePeerDTO.init)
    }
}
