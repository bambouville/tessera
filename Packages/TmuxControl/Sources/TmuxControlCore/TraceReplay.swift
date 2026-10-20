/// Deterministic replay facade over the same production runtime engine used by
/// platform adapters. Keeping trace conformance on this path prevents a second
/// topology/authority implementation from drifting away from live behavior.
public struct TmuxTraceReplayer: Sendable {
    private var engine = TmuxRuntimeEngine()
    private var authoritySession: TmuxGridAuthoritySession

    public init(localDeviceID: String? = nil) {
        authoritySession = TmuxGridAuthoritySession(localDeviceID: localDeviceID)
    }

    public mutating func reset() {
        engine.reset()
        authoritySession.reduce(.resetTransport(preservingPeer: false), now: 0)
        engine.projectAuthority(authoritySession.reducer.authority)
    }

    @discardableResult
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> TmuxSnapshot {
        let batch = engine.feed(bytes)
        for raw in batch.authorityStamps {
            authoritySession.reduce(.stampObserved(raw: raw), now: 0)
        }
        engine.projectAuthority(authoritySession.reducer.authority)
        return Self.vectorSnapshot(engine.snapshot)
    }

    public mutating func replay(_ chunks: [[UInt8]]) -> [TmuxSnapshot] {
        chunks.map { feed($0) }
    }

    public var snapshot: TmuxSnapshot { Self.vectorSnapshot(engine.snapshot) }

    private static func vectorSnapshot(_ snapshot: TmuxSnapshot) -> TmuxSnapshot {
        .init(
            sessionID: snapshot.sessionID,
            sessionName: snapshot.sessionName,
            activeWindowID: snapshot.activeWindowID,
            windows: snapshot.windows,
            authority: snapshot.authority
        )
    }
}
