import Foundation

/// Portable policy for the authority hand-off around a shared tmux grid.
///
/// The reducer deliberately owns no tmux command channel, clock, terminal
/// surface, or view state. An adapter feeds it facts in wire order and performs
/// the returned effects. This keeps the safety rules identical while allowing
/// iOS and Android to retain their distinct capture/repaint implementations.
///
/// **The show rule** (`docs/reviews/takeover-authority-review-2026-10-05.md`
/// §6.9). Control of the shared grid moves only when the user shows a session
/// on this device (`shown`) or taps the veil (`requestTakeBack`). Each gesture
/// records one pending ``Intent`` (R1, R4). The intent resolves at the next
/// fresh authority read (R2): zero commands when this device already owns the
/// window at its size, otherwise one claim. It ends early on a hide or an
/// adapter-timed expiry (R3). A tap intent also ends when a read names a peer
/// other than the one its veil named. A show intent carries no baseline: stamp
/// data read after a show edge can predate the show (a buffered subscription
/// line from while the app was backgrounded, or one lagging on tmux's 1 s
/// subscription timer), so only the fresh read the show requested decides it.
/// Nothing else claims (R5): attach, reconnect, restore, foreground and a
/// peer's departure only read authority and follow the stamp.
public struct TmuxGridAuthorityLifecycleReducer: Equatable, Sendable {
    public enum ClaimReason: String, Codable, Equatable, Sendable {
        /// The session became displayed on this device. Adapters present this
        /// as a light "resuming" indicator rather than the veil spinner.
        case show
        /// An explicit open targeted this session (Handoff, a QR or pairing
        /// receipt, a notification route, Agent Center's "open terminal", a
        /// host connect that reuses the session). Presented like `show`.
        case explicitOpen
        /// A veil tap, Enter or printable key (R4). Presented on the veil.
        case userTakeBack
        /// A user claim was contested by a foreign stamp, and then this
        /// device's own already-queued stamp landed after it: our write won
        /// tmux's last-writer-wins race. The claim re-enters the full fence
        /// under a fresh generation. Presented on the veil, like a tap.
        case ownWriteWon
    }

    public enum ClaimPhase: String, Codable, Equatable, Sendable {
        /// The adapter must replay local geometry and acknowledge the fence.
        case awaitingFence
        /// The fence landed; the adapter must repaint the rendered surface.
        case awaitingRepaint
        /// Repaint completed; the adapter may write its authority stamp.
        case awaitingStampCommit
        /// The stamp command completed; the adapter may settle the claim.
        case awaitingSettlement
    }

    /// Codable peer identity retained only for the duration of a claim or an
    /// intent. The authority snapshot itself remains the canonical server
    /// observation.
    public struct Peer: Codable, Equatable, Sendable {
        public let deviceID: String
        public let displayName: String
        public let generation: UInt64

        public init(deviceID: String, displayName: String, generation: UInt64) {
            self.deviceID = deviceID
            self.displayName = displayName
            self.generation = generation
        }
    }

    /// The stamp-less fallback peer: a client that resized our window
    /// without writing a stamp (a laptop's bare `tmux attach`). The session's
    /// verdict is projected into the runtime so rendering names the same peer.
    public static let stamplessPeer = Peer(
        deviceID: "-",
        displayName: TmuxStamplessPeer.displayName,
        generation: 0
    )

    /// What caused a show gesture. A tap is not a show; it has its own event.
    public enum ShowSource: String, Codable, Equatable, Sendable {
        /// Displayed(s) went false→true outside a transparent interval.
        case show
        /// An explicit open that targets the session, even when it is
        /// already displayed.
        case explicitOpen
    }

    public enum IntentSource: String, Codable, Equatable, Sendable {
        case show
        case explicitOpen
        case tap
    }

    /// A user gesture that has not yet been turned into a claim (R1, R4).
    ///
    /// - `.show` and `.explicitOpen` intents never carry a baseline
    ///   (`baselineKnown == false`, `baseline == nil`). Live observations
    ///   while one is pending are projected but never end it; only the next
    ///   `receivedAuthorityQuery` reply, which tmux orders after everything
    ///   queued before the query, resolves it. Its only R3 guard is the
    ///   adapter's ~20 s expiry.
    /// - `.tap` intents carry the peer the tapped veil named
    ///   (`baselineKnown == true`). They wait only while no channel is live,
    ///   so the first observation after re-attach is current; a fresh read or
    ///   a live observation of a different peer ends them.
    public struct Intent: Codable, Equatable, Sendable {
        /// Unique and monotonic per reducer. The adapter's ~20 s expiry timer
        /// reports it back through `intentExpired(token:)`.
        public let token: UInt64
        public let source: IntentSource
        /// For a tap, the peer the tapped veil named. Always nil for a show.
        public let baseline: Peer?
        /// True exactly when the intent is bound to `baseline` (taps).
        public let baselineKnown: Bool

        /// Normalises the binding so the rule holds by construction, also for
        /// a decoded snapshot: a show never keeps a baseline, and a tap is
        /// bound only when it names a peer.
        public init(token: UInt64, source: IntentSource, baseline: Peer?, baselineKnown: Bool) {
            let bound = source == .tap && baselineKnown ? baseline : nil
            self.token = token
            self.source = source
            self.baseline = bound
            self.baselineKnown = bound != nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                token: try container.decode(UInt64.self, forKey: .token),
                source: try container.decode(IntentSource.self, forKey: .source),
                baseline: try container.decodeIfPresent(Peer.self, forKey: .baseline),
                baselineKnown: try container.decode(Bool.self, forKey: .baselineKnown)
            )
        }
    }

    /// The adapter's geometry evidence for an authority query reply, about the
    /// window this device renders.
    public enum QueryGeometry: String, Codable, Equatable, Sendable {
        /// The rendered window already has this device's current grid.
        case atLocalSize
        /// The window still has the size this device last pushed, but the
        /// local grid changed since (rotation, keyboard, font).
        case atLastOwnedSize
        /// Neither: some other client sized the window.
        case foreignSize
        /// The adapter cannot tell.
        case unknown
    }

    /// A terminal grid, in cells.
    public struct Grid: Codable, Equatable, Hashable, Sendable {
        public let columns: Int
        public let rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The most grids in a claim's ordered diagnostic/ABI snapshot. Keyboard
    /// animation advertises a grid per frame; membership remains complete
    /// for the claim's lifetime even when the oldest diagnostic entries go.
    public static let maximumAdvertisedGrids = 16

    public struct Claim: Codable, Equatable, Sendable {
        public let generation: UInt64
        public let reason: ClaimReason
        /// The peer that held the grid when this claim began. A newer foreign
        /// stamp supersedes this claim; a replay of this exact stamp does not.
        public fileprivate(set) var contestedPeer: Peer?
        public fileprivate(set) var phase: ClaimPhase
        /// Presentation timeout only changes this bit (S4′, §6.10 rule 1).
        /// The live claim and its generation remain valid, so its own late
        /// acks still settle it and nothing strands both clients behind
        /// their veils. A late claim advertises no new geometry
        /// (`claimMayAdvertiseGeometry`). A later show or tap restarts it
        /// under a new generation.
        public fileprivate(set) var presentationVisible: Bool
        /// The claim already fenced again after losing its geometry
        /// (§6.10 rule 4). One re-fence per generation.
        public fileprivate(set) var geometryRefenced: Bool = false
        /// Recent advertised grids, oldest first, bounded for diagnostics and
        /// the ABI. Classification uses complete lifetime membership below
        /// so an older keyboard frame never becomes a loss (§6.10 rule 3).
        public fileprivate(set) var advertisedGrids: [Grid] = []
        /// The advertised grid the claim confirms at.
        public fileprivate(set) var targetGrid: Grid?
        /// The settle probe of the claim's latest fence was answered, so its
        /// geometry has provably landed: a window at a size the claim never
        /// advertised is now a loss, not a stale layout (§6.10 rules 4–5).
        public fileprivate(set) var geometryLanded: Bool = false
        /// Kept in the live claim (including in-memory replacement snapshots),
        /// outside the bounded wire projection. The lifecycle ABI retains its
        /// reducer rather than recreating it from that diagnostic projection.
        fileprivate var advertisedGridMembership: Set<Grid> = []

        public func hasAdvertisedGrid(_ grid: Grid) -> Bool {
            advertisedGridMembership.contains(grid)
        }

        private enum CodingKeys: String, CodingKey {
            case generation, reason, contestedPeer, phase, presentationVisible
            case geometryRefenced, advertisedGrids, targetGrid, geometryLanded
        }
    }

    public enum AbortReason: Equatable, Sendable {
        case contestedByPeer(Peer)
        /// The adapter could not carry the claim further: a step failed, or
        /// the claim stalled with nothing of its own left in flight
        /// (`claimStalled`, §6.10 rule 6). Adapters may replay the gesture
        /// under R3 (§6.9).
        case adapterFailure
        case transportReset
        /// A show or tap restarted a claim whose presentation had timed out
        /// (S4′). Its late acks are ignored by generation.
        case superseded
        /// Another client sized the claimed window after this claim's own
        /// geometry landed, and the claim may not fence again: it already
        /// re-fenced once, or its presentation timed out (§6.10 rule 4).
        /// Ends the gesture; never replayed. The user taps again.
        case geometryLost
    }

    /// Pure instructions for an adapter. None performs transport or renderer
    /// work; all command text, process identity, and paint details remain at
    /// the platform boundary.
    public enum Effect: Equatable, Sendable {
        /// Read `@tessera_authority` afresh and report it through
        /// `receivedAuthorityQuery(_:geometry:)`. Adapters coalesce these.
        case queryAuthority
        case beginClaim(Claim)
        case requestRepaint(generation: UInt64)
        case commitAuthorityStamp(generation: UInt64)
        case authorityChanged(TmuxGridAuthoritySnapshot)
        case hideReclaimPresentation
        case claimAborted(AbortReason)
        case claimSettled(generation: UInt64)
        /// The stamp is ours and the window still has the size we last
        /// pushed, but the local grid changed meanwhile. Replay the local size
        /// as an ordinary owner resize: never a claim, never a stamp write.
        case replayOwnedGeometry
        /// The claim lost its geometry before its stamp went out
        /// (`claimObservedGeometry`, `claimGeometryLost`). Send the claim's
        /// fence again for this same generation: inline a bare, targetless
        /// `select-window`, on the side channel the shared resize/fence/unset
        /// sequence at the target. The window's policy is already read for this
        /// claim, and the earlier fence's acknowledgement stands. The claim
        /// is back in `awaitingFence`, confirms once the window is at its
        /// target, and lands again with this fence's settle probe.
        case refenceClaim(generation: UInt64)
    }

    /// Stable, portable persistence/ABI representation. Platform adapters can
    /// rebuild a reducer after a view/controller replacement without deriving
    /// authority from presentation state.
    public struct Snapshot: Codable, Equatable, Sendable {
        public let authority: TmuxGridAuthoritySnapshot
        public let claim: Claim?
        /// True once any control channel attached in this reducer's lifetime.
        public let hasAttached: Bool
        public let nextGeneration: UInt64
        public let expectedOwnStampGeneration: UInt64?
        /// True between `attached()` and `resetTransport(preservingPeer:)`.
        public let channelAttached: Bool
        /// True when `authority` reflects a server observation (or a peer
        /// verdict preserved across a reset). False on a cold reducer and
        /// after a reset that kept no peer.
        public let authorityObserved: Bool
        public let pendingIntent: Intent?
        public let nextIntentToken: UInt64

        public init(
            authority: TmuxGridAuthoritySnapshot,
            claim: Claim?,
            hasAttached: Bool,
            nextGeneration: UInt64,
            expectedOwnStampGeneration: UInt64? = nil,
            channelAttached: Bool? = nil,
            authorityObserved: Bool? = nil,
            pendingIntent: Intent? = nil,
            nextIntentToken: UInt64 = 0
        ) {
            self.authority = authority
            self.claim = claim
            self.hasAttached = hasAttached
            self.nextGeneration = nextGeneration
            self.expectedOwnStampGeneration = expectedOwnStampGeneration
            self.channelAttached = channelAttached ?? hasAttached
            self.authorityObserved = authorityObserved ?? (authority != .unknown)
            self.pendingIntent = pendingIntent
            self.nextIntentToken = nextIntentToken
        }
    }

    public private(set) var authority: TmuxGridAuthoritySnapshot
    public private(set) var claim: Claim?
    public private(set) var hasAttached: Bool
    public private(set) var channelAttached: Bool
    public private(set) var pendingIntent: Intent?
    private var authorityObserved: Bool
    private var nextGeneration: UInt64
    private var nextIntentToken: UInt64
    private var expectedOwnStampGeneration: UInt64?

    public init(
        authority: TmuxGridAuthoritySnapshot = .unknown,
        hasAttached: Bool = false,
        nextGeneration: UInt64? = nil,
        initialGeneration: UInt64 = 0,
        expectedOwnStampGeneration: UInt64? = nil,
        channelAttached: Bool? = nil
    ) {
        self.authority = authority
        self.hasAttached = hasAttached
        self.channelAttached = channelAttached ?? hasAttached
        self.authorityObserved = authority != .unknown
        self.nextGeneration = nextGeneration ?? initialGeneration
        self.nextIntentToken = 0
        self.expectedOwnStampGeneration = expectedOwnStampGeneration
    }

    public init(snapshot: Snapshot) {
        authority = snapshot.authority
        claim = snapshot.claim
        hasAttached = snapshot.hasAttached
        channelAttached = snapshot.channelAttached
        authorityObserved = snapshot.authorityObserved
        pendingIntent = snapshot.pendingIntent
        nextGeneration = snapshot.nextGeneration
        nextIntentToken = snapshot.nextIntentToken
        expectedOwnStampGeneration = snapshot.expectedOwnStampGeneration
    }

    public var snapshot: Snapshot {
        .init(
            authority: authority,
            claim: claim,
            hasAttached: hasAttached,
            nextGeneration: nextGeneration,
            expectedOwnStampGeneration: expectedOwnStampGeneration,
            channelAttached: channelAttached,
            authorityObserved: authorityObserved,
            pendingIntent: pendingIntent,
            nextIntentToken: nextIntentToken
        )
    }

    // MARK: - Channel lifecycle

    /// A control channel attached: the first one, a reconnect, a session
    /// replacement or a restore alike. Attaching never claims (R5); it only
    /// asks for a fresh authority read, which also resolves a pending intent.
    @discardableResult
    public mutating func attached() -> [Effect] {
        hasAttached = true
        channelAttached = true
        return [.queryAuthority]
    }

    /// A re-derive after the app returns to the foreground. Never a claim:
    /// the app layer reports real show edges separately through `shown`.
    /// A pending intent on a live channel already has its own fresh read
    /// outstanding, which decides it; a second read would only supersede it.
    @discardableResult
    public mutating func foregrounded() -> [Effect] {
        guard channelAttached, claim == nil, pendingIntent == nil else { return [] }
        return [.queryAuthority]
    }

    /// A control transport can disappear while a peer owns the grid. Preserve
    /// that verdict until the replacement attachment performs its explicit
    /// authority query; otherwise the overlay and input gate would flicker off
    /// during the dangerous reconnection interval. A pending intent survives
    /// the reset unchanged (R3): a show has no baseline to go stale, and a tap
    /// stays bound to the peer its veil named.
    @discardableResult
    public mutating func resetTransport(preservingPeer: Bool) -> [Effect] {
        let retainedPeer = preservingPeer ? authority.peer : nil
        let aborted = claim != nil
        claim = nil
        channelAttached = false
        authority = retainedPeer.map { peer in
            .peer(deviceID: peer.deviceID, displayName: peer.displayName, generation: peer.generation)
        } ?? .unknown
        authorityObserved = retainedPeer != nil
        expectedOwnStampGeneration = nil
        var effects: [Effect] = []
        if aborted { effects.append(.claimAborted(.transportReset)) }
        effects.append(.hideReclaimPresentation)
        effects.append(.authorityChanged(authority))
        return effects
    }

    // MARK: - User gestures

    /// A show edge for this session (R1), or an explicit open that targets
    /// it. Records an intent without a baseline and asks for a fresh read
    /// when the channel is live; without one, the next `attached()` asks. The
    /// reply resolves it (R2).
    ///
    /// - A claim that is visibly presenting already satisfies the show.
    /// - A claim whose presentation timed out is restarted under a new
    ///   generation (S4′), because the user asked again. With `claimNow`
    ///   false (the app in the background, where nothing may begin a claim)
    ///   it gives way to the show's intent instead, which a later read
    ///   decides, as a take-back on a channel that cannot carry it does.
    @discardableResult
    public mutating func shown(source: ShowSource = .show, claimNow: Bool = true) -> [Effect] {
        let intentSource: IntentSource = source == .show ? .show : .explicitOpen
        if let activeClaim = claim {
            guard !activeClaim.presentationVisible else { return [] }
            guard claimNow else {
                claim = nil
                expectedOwnStampGeneration = nil
                recordIntent(intentSource)
                return channelAttached ? [.claimAborted(.superseded), .queryAuthority] : [.claimAborted(.superseded)]
            }
            return beginClaim(reason: intentSource.claimReason, presentProgress: true)
        }
        recordIntent(intentSource)
        return channelAttached ? [.queryAuthority] : []
    }

    /// A hide edge. Cancels an unsent intent only; a claim already in flight
    /// finishes on its own (S4′).
    @discardableResult
    public mutating func hidden() -> [Effect] {
        pendingIntent = nil
        return []
    }

    /// The adapter's timer from the user's last step ran out (R3). Drops the
    /// pending intent only when the token still names it.
    @discardableResult
    public mutating func intentExpired(token: UInt64) -> [Effect] {
        guard pendingIntent?.token == token else { return [] }
        pendingIntent = nil
        return []
    }

    /// Admits the veil gesture (R4): a pointer tap, Enter or a printable key.
    /// It forms a `.tap` intent bound to the peer the veil names.
    ///
    /// - Live channel: the claim begins immediately.
    /// - `channelLive == false`, or no channel attached: the intent waits
    ///   for the next attach and fresh read.
    /// - A claim that is visibly presenting: no-op, so repeated taps cannot
    ///   grow a stalled control FIFO.
    /// - A claim whose presentation timed out: abandoned and restarted under
    ///   a new generation (S4′).
    ///
    /// - Parameter channelLive: false when the adapter knows its control
    ///   channel cannot carry a claim right now, even though the reducer
    ///   still considers it attached (for example a mosh side-channel gap
    ///   that has not been reported as a reset yet).
    @discardableResult
    public mutating func requestTakeBack(channelLive: Bool = true) -> [Effect] {
        guard authority.isPeer else { return [] }
        let live = channelAttached && channelLive
        if let activeClaim = claim {
            guard !activeClaim.presentationVisible else { return [] }
            guard live else {
                claim = nil
                expectedOwnStampGeneration = nil
                recordIntent(.tap)
                return [.claimAborted(.superseded)]
            }
            return beginClaim(reason: .userTakeBack, presentProgress: true)
        }
        guard live else {
            recordIntent(.tap)
            return []
        }
        return beginClaim(reason: .userTakeBack, presentProgress: true)
    }

    // MARK: - Authority evidence

    /// Resolves an explicit authority read (`show-options @tessera_authority`).
    /// With a pending intent the reply decides it (R2/R3); without one the
    /// device only follows the stamp and never claims (R5):
    ///
    /// | Intent | Observed | Geometry | Result |
    /// |---|---|---|---|
    /// | any | `.mine` | `atLocalSize` | resolve, 0 commands |
    /// | any | `.mine` | other | claim |
    /// | any | `.unknown` | any | claim |
    /// | show/open | `.peer(p)`, any p | any | claim contesting p |
    /// | tap on p | `.peer(p)` | any | claim contesting p |
    /// | tap on p | `.peer(q)`, q ≠ p | any | drop intent, yield to q |
    /// | no | `.peer` | any | yield |
    /// | no | `.mine` | `atLocalSize` | `.mine` |
    /// | no | `.mine` | `atLastOwnedSize` | `.mine` + `replayOwnedGeometry` |
    /// | no | `.mine` | `unknown` | `.mine`, no replay; a standing stamp-less yield stays |
    /// | no | `.mine` | `foreignSize` | yield to `stamplessPeer` (D5) |
    /// | no | `.unknown` | any | `.unknown` |
    ///
    /// Without an intent, `.unknown` geometry is no evidence either way
    /// (slow hydration, a window-size policy that never answered): it cannot
    /// contradict our own stamp, so it never manufactures "another device"
    /// over our window, and it cannot overturn a yield that positive
    /// evidence already raised. Only `.foreignSize` is evidence of a
    /// stamp-less sizer; the adapter's layout-edge detection remains the
    /// backstop for one that resizes later.
    ///
    /// A reply that lands while no channel is attached is stale and ignored.
    @discardableResult
    public mutating func receivedAuthorityQuery(
        _ observed: TmuxGridAuthoritySnapshot,
        geometry: QueryGeometry
    ) -> [Effect] {
        guard channelAttached else { return [] }
        authorityObserved = true
        if let activeClaim = claim {
            guard case let .peer(deviceID, displayName, generation) = observed else { return [] }
            let peer = Peer(deviceID: deviceID, displayName: displayName, generation: generation)
            let projection = project(observed)
            guard isNewerForeign(peer, than: activeClaim.contestedPeer) else { return projection }
            return abortContested(by: peer, observed: observed)
        }

        if let intent = pendingIntent {
            // The fresh read is the truth the claim (if any) contests.
            var effects = project(observed)
            switch observed {
            case .mine where geometry == .atLocalSize:
                // R2: already ours at our size. Resolve with zero commands.
                pendingIntent = nil
                return effects
            case .mine, .unknown:
                break
            case let .peer(deviceID, displayName, generation):
                let peer = Peer(deviceID: deviceID, displayName: displayName, generation: generation)
                if intent.baselineKnown, intent.baseline != peer {
                    // R3 for a tap: the veil the user tapped named another
                    // peer, which has since been displaced. Stay yielded
                    // rather than seize a device that is working.
                    pendingIntent = nil
                    return effects
                }
                // A show contests whichever peer the fresh read finds.
            }
            effects += beginClaim(reason: intent.source.claimReason, presentProgress: true)
            return effects
        }

        switch observed {
        case .peer, .unknown:
            return project(observed)
        case .mine:
            switch geometry {
            case .atLocalSize:
                return project(observed)
            case .atLastOwnedSize:
                var effects = project(observed)
                effects.append(.replayOwnedGeometry)
                return effects
            case .unknown:
                // No geometry evidence: follow our stamp, replay nothing.
                // A yield to the stamp-less fallback was raised on positive
                // evidence (a foreign size), which this read cannot refute.
                if authority.peer == Self.stamplessPeer { return [] }
                return project(observed)
            case .foreignSize:
                // Our stamp is still on the server, but some stamp-less client
                // (a laptop's bare `tmux attach`) sized the window after us.
                // Yield; reclaiming here would seize its grid (D5).
                let fallback = Self.stamplessPeer
                return project(.peer(
                    deviceID: fallback.deviceID,
                    displayName: fallback.displayName,
                    generation: fallback.generation
                ))
            }
        }
    }

    /// Folds a live Core-classified authority snapshot into the lifecycle.
    /// Own echoes remain advisory while a claim is active; only settlement can
    /// lift the veil. A foreign peer invalidates a claim only when it is newer
    /// than the peer captured at claim admission, and invalidates a pending
    /// tap intent when it differs from the peer the tapped veil named (R3).
    /// A pending show intent is never ended or rebased here: this line may
    /// have been queued before the show, so only the fresh read decides it.
    ///
    /// The same value is re-observed on every control-mode event that
    /// carries the stamp (one per pane on a subscription echo), so an
    /// unchanged observation is folded silently: adapters project the
    /// snapshot idempotently and would otherwise trace a no-op transition
    /// per event.
    @discardableResult
    public mutating func observedAuthority(_ observed: TmuxGridAuthoritySnapshot) -> [Effect] {
        // Live data never touches a show intent, so without a bound tap an
        // unchanged value is a pure no-op.
        if authority == observed, pendingIntent?.baselineKnown != true { return [] }
        switch observed {
        case let .peer(deviceID, displayName, generation):
            let peer = Peer(deviceID: deviceID, displayName: displayName, generation: generation)
            let projection = project(observed)
            // A tap waits only while no channel is live, so this is current:
            // a peer other than the tapped veil's displaced it (R3). A show
            // intent stays for its fresh read; this line may predate the show.
            if let intent = pendingIntent, intent.baselineKnown, intent.baseline != peer {
                pendingIntent = nil
            }
            guard let activeClaim = claim,
                  isNewerForeign(peer, than: activeClaim.contestedPeer)
            else { return projection }
            return abortContested(by: peer, observed: observed)

        case .mine:
            // A stamp echo is not evidence that tmux has accepted local
            // geometry. Keep rendering the yielded state until the adapter
            // reports its fence and repaint settled.
            guard claim == nil else { return [] }
            // Peer → mine is authorised only by settlement or by a fresh
            // query with geometry evidence. A replayed own stamp after a
            // stamp-less takeover must not lift the veil (D5).
            guard !authority.isPeer, authority != observed else { return [] }
            return project(observed)

        case .unknown:
            // A missing subscription value during a control reconnect cannot
            // lift a retained peer veil. The explicit query resolves it.
            guard claim == nil, !authority.isPeer, authority != observed else { return [] }
            let projection = project(observed)
            authorityObserved = false
            return projection
        }
    }

    /// A claim writes its own stamp on the same FIFO as its geometry. If a
    /// foreign stamp contests first but the already-queued own stamp lands
    /// afterwards, that exact echo is evidence our server write won. Re-enter
    /// the full fence under a fresh generation; never lift the veil directly.
    /// Only a contested user claim can arm this, so it continues a gesture.
    @discardableResult
    public mutating func observedOwnAuthorityStamp(generation: UInt64) -> [Effect] {
        guard authority.isPeer,
              claim == nil,
              expectedOwnStampGeneration == generation
        else { return [] }
        expectedOwnStampGeneration = nil
        return beginClaim(reason: .ownWriteWon, presentProgress: true)
    }

    /// Ends the gesture a contested claim belonged to without a transition:
    /// its own stamp landing later no longer continues it. The show-rule
    /// session calls this at a hide, and for a contest or an own stamp in a
    /// hidden or background session, none of which may be followed by a
    /// fence; `hidden()` itself keeps its meaning for version 1 adapters.
    public mutating func dropOwnWriteContinuation() {
        expectedOwnStampGeneration = nil
    }

    // MARK: - Claim chain

    /// Whether the adapter may advertise geometry for the claimed grid: a
    /// client-size replay, a fence or re-fence, a `resize-window` force
    /// (§6.10 rule 2). True only for a live claim whose presentation is
    /// still visible. A late claim finishes on the geometry it already
    /// advertised; local churn meanwhile waits for its settlement and the
    /// ordinary owner path. Every yield gate on both platforms uses this
    /// predicate, never `claim != nil`.
    public var claimMayAdvertiseGeometry: Bool {
        claim?.presentationVisible == true
    }

    /// The deadline releases only the progress presentation (S4′, §6.10
    /// rule 1). It never aborts the command chain or clears its generation:
    /// geometry this claim already sent may still be on the wire, and an
    /// abort would let it land unstamped, which veils the peer under D5
    /// while this device stays veiled. The claim becomes late: it
    /// advertises nothing more (`claimMayAdvertiseGeometry`), and settles
    /// on its own acks, or ends on a loss (`claimObservedGeometry`) or a
    /// stall (`claimStalled`).
    @discardableResult
    public mutating func presentationTimedOut(generation: UInt64) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.presentationVisible
        else { return [] }
        activeClaim.presentationVisible = false
        claim = activeClaim
        return [.hideReclaimPresentation]
    }

    /// The adapter advertised `grid` for this claim: the begin replay, or
    /// local churn while the claim may advertise (§6.10 rules 2–3). A late
    /// claim records nothing; its adapter must not have sent anything.
    ///
    /// - `awaitingFence`: the grid becomes the target, which has not landed.
    /// - `awaitingRepaint`: the same, and the claim returns to
    ///   `awaitingFence` (a re-target, which spends no re-fence): the
    ///   repaint in flight shows the old grid. The adapter drops it; the
    ///   replay carries its own fence.
    /// - The stamp phases: the grid is only recorded, so its echo is not a
    ///   loss. The stamp commits the grid the claim confirmed.
    ///
    /// Re-advertising the target (a visible claim fencing a window that
    /// became current) makes it land afresh.
    @discardableResult
    public mutating func claimAdvertisedGeometry(generation: UInt64, columns: Int, rows: Int) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.presentationVisible,
              columns > 0, rows > 0
        else { return [] }
        let grid = Grid(columns: columns, rows: rows)
        activeClaim.advertisedGridMembership.insert(grid)
        activeClaim.advertisedGrids.removeAll { $0 == grid }
        activeClaim.advertisedGrids.append(grid)
        switch activeClaim.phase {
        case .awaitingFence, .awaitingRepaint:
            activeClaim.phase = .awaitingFence
            activeClaim.targetGrid = grid
            activeClaim.geometryLanded = false
        case .awaitingStampCommit, .awaitingSettlement:
            break
        }
        let excess = activeClaim.advertisedGrids.count - Self.maximumAdvertisedGrids
        if excess > 0 {
            var dropped = 0
            activeClaim.advertisedGrids.removeAll { candidate in
                guard dropped < excess, candidate != activeClaim.targetGrid else { return false }
                dropped += 1
                return true
            }
        }
        claim = activeClaim
        return []
    }

    /// The adapter saw the claimed window at `columns`×`rows`: a layout
    /// notification, or (`settleProbe`) the answer to the settle probe
    /// written after the claim's latest fence was acknowledged, which marks
    /// its geometry landed first (§6.10 rule 5). Only under a `latest`
    /// window-size policy: under any other the size proves nothing.
    ///
    /// - At an advertised grid: our own geometry. At the target nothing
    ///   changes; elsewhere it is unsettled (rule 3).
    /// - At a size the claim never advertised, before landing: possibly a
    ///   stale layout (tmux can deliver a peer's resize from the same
    ///   server pass after our fence's reply). Unsettled.
    /// - At such a size after landing: a loss (rule 4). A visible claim
    ///   with its re-fence unspent fences once more (`refenceClaim`); a late
    ///   claim, or a second loss, aborts (`geometryLost`).
    ///
    /// An unsettled `awaitingRepaint` claim returns to `awaitingFence` with
    /// no effect: its repaint in flight cannot authorize the target, so the
    /// adapter drops it, and the claim confirms again once its own geometry
    /// brings the window back. A no-op once the stamp is on the wire.
    @discardableResult
    public mutating func claimObservedGeometry(
        generation: UInt64,
        columns: Int,
        rows: Int,
        settleProbe: Bool
    ) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingFence || activeClaim.phase == .awaitingRepaint
        else { return [] }
        if settleProbe { activeClaim.geometryLanded = true }
        let grid = Grid(columns: columns, rows: rows)
        if grid == activeClaim.targetGrid {
            claim = activeClaim
            return []
        }
        guard activeClaim.geometryLanded,
              !activeClaim.hasAdvertisedGrid(grid)
        else {
            activeClaim.phase = .awaitingFence
            claim = activeClaim
            return []
        }
        claim = activeClaim
        return loseGeometry()
    }

    /// The adapter decided by itself that the confirmed window was taken
    /// (`awaitingRepaint` only), with rule 4's consequences. Adapters on
    /// §6.10 report windows through `claimObservedGeometry` instead, which
    /// tells our own sizes and stale layouts apart from a loss.
    @discardableResult
    public mutating func claimGeometryLost(generation: UInt64) -> [Effect] {
        guard let activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingRepaint
        else { return [] }
        return loseGeometry()
    }

    /// The claim cannot progress (§6.10 rule 6): a repaint whose delivery
    /// retries ran out, a pane grid or active window that stays unavailable
    /// at confirmation, a current window that moved under a late claim, or
    /// a late claim with nothing of its own left in flight. A visible claim
    /// that a new fence can still move (`canProgress`) re-enters the
    /// geometry phase (`awaitingFence`; the adapter fences again or waits
    /// for its next observation). Anything else aborts as an adapter
    /// failure. A no-op once the stamp is on the wire: its reply always
    /// ends the claim.
    @discardableResult
    public mutating func claimStalled(generation: UInt64, canProgress: Bool) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingFence || activeClaim.phase == .awaitingRepaint
        else { return [] }
        guard canProgress, activeClaim.presentationVisible else {
            claim = nil
            expectedOwnStampGeneration = nil
            return [.hideReclaimPresentation, .claimAborted(.adapterFailure)]
        }
        activeClaim.phase = .awaitingFence
        claim = activeClaim
        return []
    }

    @discardableResult
    public mutating func fenceSucceeded(generation: UInt64) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingFence
        else { return [] }
        activeClaim.phase = .awaitingRepaint
        claim = activeClaim
        return [.requestRepaint(generation: generation)]
    }

    @discardableResult
    public mutating func repaintSucceeded(generation: UInt64) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingRepaint
        else { return [] }
        activeClaim.phase = .awaitingStampCommit
        claim = activeClaim
        return [.commitAuthorityStamp(generation: generation)]
    }

    @discardableResult
    public mutating func stampCommitSucceeded(generation: UInt64) -> [Effect] {
        guard var activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingStampCommit
        else { return [] }
        activeClaim.phase = .awaitingSettlement
        claim = activeClaim
        return []
    }

    @discardableResult
    public mutating func settleClaim(generation: UInt64) -> [Effect] {
        guard let activeClaim = claim,
              activeClaim.generation == generation,
              activeClaim.phase == .awaitingSettlement
        else { return [] }
        claim = nil
        authority = .mine(generation: generation)
        authorityObserved = true
        expectedOwnStampGeneration = nil
        return [
            .authorityChanged(authority),
            .hideReclaimPresentation,
            .claimSettled(generation: generation),
        ]
    }

    @discardableResult
    public mutating func abortClaim(generation: UInt64, reason: AbortReason = .adapterFailure) -> [Effect] {
        guard let activeClaim = claim, activeClaim.generation == generation else { return [] }
        claim = nil
        expectedOwnStampGeneration = nil
        return [.hideReclaimPresentation, .claimAborted(reason)]
    }

    // MARK: - Private

    /// §6.10 rule 4 for the live claim: one re-fence while visible, then
    /// `geometryLost`.
    private mutating func loseGeometry() -> [Effect] {
        guard var activeClaim = claim else { return [] }
        guard activeClaim.presentationVisible, !activeClaim.geometryRefenced else {
            claim = nil
            expectedOwnStampGeneration = nil
            return [.hideReclaimPresentation, .claimAborted(.geometryLost)]
        }
        activeClaim.phase = .awaitingFence
        activeClaim.geometryRefenced = true
        activeClaim.geometryLanded = false
        claim = activeClaim
        return [.refenceClaim(generation: activeClaim.generation)]
    }

    /// A tap binds the peer its veil names (`requestTakeBack` requires one);
    /// a show binds nothing.
    private mutating func recordIntent(_ source: IntentSource) {
        nextIntentToken &+= 1
        let veilPeer = source == .tap ? authority.peer : nil
        pendingIntent = Intent(
            token: nextIntentToken,
            source: source,
            baseline: veilPeer,
            baselineKnown: veilPeer != nil
        )
    }

    /// Sets the projection and reports it only when it changed.
    private mutating func project(_ observed: TmuxGridAuthoritySnapshot) -> [Effect] {
        guard authority != observed else { return [] }
        authority = observed
        if observed != .unknown { authorityObserved = true }
        return [.authorityChanged(observed)]
    }

    private mutating func abortContested(
        by peer: Peer,
        observed: TmuxGridAuthoritySnapshot
    ) -> [Effect] {
        guard let activeClaim = claim else { return [] }
        authority = observed
        authorityObserved = true
        expectedOwnStampGeneration = activeClaim.generation
        claim = nil
        return [
            .authorityChanged(observed),
            .hideReclaimPresentation,
            .claimAborted(.contestedByPeer(peer)),
        ]
    }

    /// Begins a claim, superseding any live one first so that every claim
    /// reaches exactly one terminal outcome. A claim consumes the intent.
    private mutating func beginClaim(reason: ClaimReason, presentProgress: Bool) -> [Effect] {
        var effects: [Effect] = []
        if claim != nil { effects.append(.claimAborted(.superseded)) }
        expectedOwnStampGeneration = nil
        pendingIntent = nil
        nextGeneration &+= 1
        let activeClaim = Claim(
            generation: nextGeneration,
            reason: reason,
            contestedPeer: authority.peer,
            phase: .awaitingFence,
            presentationVisible: presentProgress
        )
        claim = activeClaim
        effects.append(.beginClaim(activeClaim))
        return effects
    }

    private func isNewerForeign(
        _ candidate: Peer,
        than contested: Peer?
    ) -> Bool {
        guard let contested else { return true }
        // tmux's option write order is authoritative; generations are scoped
        // to one client/controller lifetime and can restart lower after a
        // reinstall or fresh connect. Only an exact identity+generation replay
        // is old evidence. Any changed stamp is a new foreign write.
        return candidate.deviceID != contested.deviceID
            || candidate.generation != contested.generation
    }
}

private extension TmuxGridAuthoritySnapshot {
    var peer: TmuxGridAuthorityLifecycleReducer.Peer? {
        guard case let .peer(deviceID, displayName, generation) = self else { return nil }
        return .init(deviceID: deviceID, displayName: displayName, generation: generation)
    }
}

public extension TmuxGridAuthorityLifecycleReducer.IntentSource {
    /// The claim an intent from this source begins.
    var claimReason: TmuxGridAuthorityLifecycleReducer.ClaimReason {
        switch self {
        case .show: return .show
        case .explicitOpen: return .explicitOpen
        case .tap: return .userTakeBack
        }
    }
}

// MARK: - Diagnostics trace

public extension TmuxGridAuthorityLifecycleReducer {
    /// One bounded, privacy-neutral line describing a single reduction, for
    /// the on-device diagnostics log of either platform. The line is the same
    /// on iOS and Android so a report from one device reads like the other.
    ///
    /// Returns nil for a no-op reduction (no state change and no effects), so
    /// callers can feed every reduction through and log only transitions.
    static func describeTransition(
        event: String,
        before: Snapshot,
        after: Snapshot,
        effects: [Effect]
    ) -> String? {
        let changed = before.authority != after.authority
            || before.claim != after.claim
            || before.pendingIntent != after.pendingIntent
            || before.hasAttached != after.hasAttached
            || before.channelAttached != after.channelAttached
            || before.authorityObserved != after.authorityObserved
        guard changed || !effects.isEmpty else { return nil }
        var parts = ["event=\(event)"]
        parts.append("authority=" + transition(before.authority.traceLabel, after.authority.traceLabel))
        parts.append("claim=" + transition(before.claim.traceLabel, after.claim.traceLabel))
        if before.pendingIntent != nil || after.pendingIntent != nil {
            parts.append("intent=" + transition(before.pendingIntent.traceLabel, after.pendingIntent.traceLabel))
        }
        if before.hasAttached != after.hasAttached {
            parts.append("attached=\(after.hasAttached)")
        }
        if before.channelAttached != after.channelAttached {
            parts.append("channel=\(after.channelAttached ? "live" : "down")")
        }
        if before.authorityObserved != after.authorityObserved {
            parts.append("observed=\(after.authorityObserved)")
        }
        parts.append("effects=[" + effects.map(\.traceLabel).joined(separator: ",") + "]")
        return parts.joined(separator: " ")
    }

    private static func transition(_ before: String, _ after: String) -> String {
        before == after ? before : "\(before)->\(after)"
    }
}

public extension TmuxGridAuthoritySnapshot {
    /// `unknown`, `mine#<generation>` or `peer(<deviceID>/<displayName>#<generation>)`.
    var traceLabel: String {
        switch self {
        case .unknown:
            return "unknown"
        case .mine(let generation):
            return "mine#\(generation)"
        case .peer(let deviceID, let displayName, let generation):
            return "peer(\(deviceID)/\(displayName)#\(generation))"
        }
    }
}

public extension TmuxGridAuthorityLifecycleReducer.Peer {
    var traceLabel: String { "\(deviceID)/\(displayName)#\(generation)" }
}

public extension TmuxGridAuthorityLifecycleReducer.Intent {
    /// `i<token>:<source>`, plus ` base=<peer>` for a tap bound to its veil.
    var traceLabel: String {
        guard baselineKnown, let baseline else { return "i\(token):\(source.rawValue)" }
        return "i\(token):\(source.rawValue) base=\(baseline.traceLabel)"
    }
}

public extension Optional where Wrapped == TmuxGridAuthorityLifecycleReducer.Intent {
    var traceLabel: String { self?.traceLabel ?? "none" }
}

public extension TmuxGridAuthorityLifecycleReducer.Claim {
    /// `g<generation>:<reason>/<phase>[(<target>)][/landed][/hidden][/refenced][ vs <contested peer>]`.
    /// No `@`: diagnostics redact a `word@word` token as a `user@host`
    /// endpoint, which once replaced `awaitingRepaint@56x45` (phase included)
    /// in every exported log.
    var traceLabel: String {
        var label = "g\(generation):\(reason.rawValue)/\(phase.rawValue)"
        if let targetGrid { label += "(\(targetGrid.columns)x\(targetGrid.rows))" }
        if geometryLanded { label += "/landed" }
        if !presentationVisible { label += "/hidden" }
        if geometryRefenced { label += "/refenced" }
        if let contestedPeer { label += " vs \(contestedPeer.traceLabel)" }
        return label
    }
}

extension TmuxGridAuthorityLifecycleReducer.Claim {
    /// `geometryRefenced`, `advertisedGrids`, `targetGrid` and
    /// `geometryLanded` are optional on the wire, so a snapshot encoded
    /// before they existed still decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(UInt64.self, forKey: .generation)
        reason = try container.decode(TmuxGridAuthorityLifecycleReducer.ClaimReason.self, forKey: .reason)
        contestedPeer = try container.decodeIfPresent(TmuxGridAuthorityLifecycleReducer.Peer.self, forKey: .contestedPeer)
        phase = try container.decode(TmuxGridAuthorityLifecycleReducer.ClaimPhase.self, forKey: .phase)
        presentationVisible = try container.decode(Bool.self, forKey: .presentationVisible)
        geometryRefenced = try container.decodeIfPresent(Bool.self, forKey: .geometryRefenced) ?? false
        advertisedGrids = try container.decodeIfPresent(
            [TmuxGridAuthorityLifecycleReducer.Grid].self, forKey: .advertisedGrids
        ) ?? []
        targetGrid = try container.decodeIfPresent(TmuxGridAuthorityLifecycleReducer.Grid.self, forKey: .targetGrid)
        geometryLanded = try container.decodeIfPresent(Bool.self, forKey: .geometryLanded) ?? false
        // Decoded wire snapshots contain only their bounded projection;
        // running reducers and in-memory snapshots keep full membership.
        advertisedGridMembership = Set(advertisedGrids)
        if let targetGrid { advertisedGridMembership.insert(targetGrid) }
    }
}

public extension Optional where Wrapped == TmuxGridAuthorityLifecycleReducer.Claim {
    var traceLabel: String { self?.traceLabel ?? "none" }
}

public extension TmuxGridAuthorityLifecycleReducer.AbortReason {
    /// The portable wire name used by the JSON ABI and the trace.
    var wireName: String {
        switch self {
        case .contestedByPeer: return "contestedByPeer"
        case .adapterFailure: return "adapterFailure"
        case .transportReset: return "transportReset"
        case .superseded: return "superseded"
        case .geometryLost: return "geometryLost"
        }
    }
}

public extension TmuxGridAuthorityLifecycleReducer.Effect {
    var traceLabel: String {
        switch self {
        case .queryAuthority:
            return "queryAuthority"
        case .beginClaim(let claim):
            return "beginClaim(g\(claim.generation) \(claim.reason.rawValue) visible=\(claim.presentationVisible))"
        case .requestRepaint(let generation):
            return "requestRepaint(g\(generation))"
        case .commitAuthorityStamp(let generation):
            return "commitAuthorityStamp(g\(generation))"
        case .authorityChanged(let authority):
            return "authorityChanged(\(authority.traceLabel))"
        case .hideReclaimPresentation:
            return "hideReclaimPresentation"
        case .claimAborted(let reason):
            if case .contestedByPeer(let peer) = reason {
                return "claimAborted(contestedByPeer \(peer.traceLabel))"
            }
            return "claimAborted(\(reason.wireName))"
        case .claimSettled(let generation):
            return "claimSettled(g\(generation))"
        case .replayOwnedGeometry:
            return "replayOwnedGeometry"
        case .refenceClaim(let generation):
            return "refenceClaim(g\(generation))"
        }
    }
}
