import Foundation

/// The whole show-rule authority policy for one tmux session, shared by both
/// platforms (`docs/reviews/takeover-authority-review-2026-10-05.md` §6.9).
///
/// It wraps `TmuxGridAuthorityLifecycleReducer`, which keeps the claim and
/// intent rules, and adds everything both adapters used to re-implement
/// around it (and had drifted on):
///
/// - **Reads.** Each `queryAuthority(id:)` effect is one
///   `show-options -qv @tessera_authority` the adapter sends and answers with
///   `queryReplied`/`queryFailed`. The newest read decides; reads for the
///   same intent coalesce, so a show costs at most one round trip. A reply
///   that predates the current intent re-reads. A failed read retries three
///   times after 0.25·n s. A read with no reply for 5 s marks the channel
///   unresponsive (a half-open side channel): never re-sent on the stuck
///   queue, and a late reply clears it.
/// - **Own-stamp hold.** Only a read naming our own stamp depends on
///   geometry. It waits (at most 10 s) for the evidence events to classify
///   it, then is judged with the best evidence available. A different live
///   stamp while it waits drops it and re-reads.
/// - **Geometry hold (D3).** Ordinary geometry is withheld from attach until
///   a read resolves it, and while the session is hidden; an unstamped
///   session may only advertise a bare client size.
/// - **Stamp-less peers.** A layout edge on the window tmux names active,
///   off our advertised size under `latest`, yields to "another device".
/// - **Clocks.** The R3 intent window, the claim's 3 s presentation budget,
///   the hold's bound, read retries, the overdue check, the stamp-less
///   re-judge: all are deadlines on the caller's millisecond clock (one that
///   keeps running while the device sleeps), checked first on every event.
///   `nextDeadline` says when to call `tick` next. Nothing here reads a
///   clock.
/// - **Claim replay.** A user's claim killed by an adapter failure replays
///   when the surface can paint again (`TmuxAuthorityClaimReplay`).
/// - **Projection.** After every event: `presentation`, `gatesTyping`,
///   `mutationRefusal`, `geometryHold`, `nextDeadline`; and on demand,
///   `carriedShow(now:)`.
///
/// Adapter contract with `TmuxShowEdgeTracker`, which feeds `shown` and
/// `hidden`:
///
/// - **Wake: the tracker first.** After a sleep or a resume, the adapter
///   gives the tracker the slot's displayed state (`displayed(_:now:)`) and
///   a `tick(now:)`, and delivers the edges they return here, before any
///   session event of the wake (`foregrounded`, `channelLiveness`,
///   `attached`, a reply). A hide the debounce owed while the device slept
///   must drop a pending show first; delivered after the wake's read, that
///   read would resolve the show and claim behind a lock screen.
/// - **No `displayed(false)` inside a transparent interval** (one of the
///   app's own excursions): the interval stands for the slot being displayed.
/// - **`displayed(true)` again after the transparency cap.** A cap that ran
///   out leaves the slot not displayed until the adapter reports it, so the
///   return from a long excursion is a show like any other.
/// - **A session created while the app is inactive hears `backgrounded`
///   first**, before `attached`. A session starts active; told nothing, the
///   attach's read would size the grid from the background (M6).
///
/// A value type mutated in place, free of platform types, so it can later be
/// hosted inside the runtime engine. An event that changes nothing returns
/// an empty effect array, which does not allocate; trace text is built only
/// by `describeTransition`, which callers invoke only for a change.
public struct TmuxGridAuthoritySession: Equatable, Sendable {
    public typealias Reducer = TmuxGridAuthorityLifecycleReducer

    public struct Configuration: Equatable, Sendable {
        /// R3: how long an intent lasts after the user's last step.
        public var intentWindowMillis: Int64
        /// Safety bound for holding an own-stamp reply for evidence.
        public var replyHoldMillis: Int64
        /// A read unanswered this long marks the channel unresponsive.
        public var queryOverdueMillis: Int64
        public var queryRetryLimit: Int
        /// Retry n waits n times this.
        public var queryRetryStepMillis: Int64
        /// How long a claim's progress presentation may stay up (S4′).
        public var claimPresentationMillis: Int64
        public var replayBudget: Int
        public var replayWindowMillis: Int64

        public init(
            intentWindowMillis: Int64 = TmuxAuthorityIntentClock.defaultWindowMillis,
            replyHoldMillis: Int64 = 10_000,
            queryOverdueMillis: Int64 = 5_000,
            queryRetryLimit: Int = 3,
            queryRetryStepMillis: Int64 = 250,
            claimPresentationMillis: Int64 = 3_000,
            replayBudget: Int = TmuxAuthorityClaimReplay.defaultBudget,
            replayWindowMillis: Int64 = TmuxAuthorityClaimReplay.defaultWindowMillis
        ) {
            self.intentWindowMillis = intentWindowMillis
            self.replyHoldMillis = replyHoldMillis
            self.queryOverdueMillis = queryOverdueMillis
            self.queryRetryLimit = queryRetryLimit
            self.queryRetryStepMillis = queryRetryStepMillis
            self.claimPresentationMillis = claimPresentationMillis
            self.replayBudget = replayBudget
            self.replayWindowMillis = replayWindowMillis
        }
    }

    /// Which prompt pauses the R3 clock.
    public enum PromptScope: String, Codable, Equatable, Sendable {
        /// This session's own password/OTP challenge: always pauses.
        case session
        /// A connect-path prompt (host key, Face ID, the credential sheet)
        /// that can belong to any connecting session: pauses only while this
        /// session's control channel is down, since a live session is not
        /// waiting on it.
        case connect
    }

    /// What ordinary geometry (keyboard, rotation, font, split-screen) may
    /// do right now. A visible claim owns geometry through its own fence;
    /// a late claim advertises nothing (§6.10 rule 2).
    public enum GeometryHold: String, Codable, Equatable, Sendable {
        /// Send nothing: authority is unresolved, a peer holds the grid, or
        /// the session is hidden.
        case withheld
        /// No stamp at all on the server (M3): advertise this client's size
        /// with a bare `refresh-client -C`, never a stamp, a latest fence or
        /// a window force, so a fresh server is not pinned at 80x24.
        case advertiseOnly
        /// This device owns the grid: ordinary owner resizes flow. While a
        /// visible claim runs, churn uses its own fence and is reported via
        /// `claimAdvertisedGeometry`, never the ordinary owner path.
        case owner
    }

    /// What a read that released the geometry hold asks the adapter to send.
    public enum GeometryRelease: String, Codable, Equatable, Sendable {
        /// Nothing beyond what changes from here on.
        case none
        /// The client size fact and a bare `refresh-client -C`, with no
        /// stamp: a reattach found our stamp at our size, and this
        /// connection has not advertised that size yet (P6).
        case advertise
        /// One ordinary owner resize at the local size, never a claim and
        /// never a stamp write: the window still has a size we owned, or a
        /// non-`latest` policy kept it off our grid while the hold withheld a
        /// local change (L4).
        case ownerReplay
    }

    /// An unfinished show a successor session object should resume when it
    /// replaces this one in the same slot. Never a tap: a tap was bound to
    /// the veil of a connection that no longer exists.
    public struct CarriedShow: Equatable, Sendable {
        public let source: Reducer.ShowSource
        /// The user's step, so the successor keeps only what is left of the
        /// R3 window.
        public let stepAt: Int64

        public init(source: Reducer.ShowSource, stepAt: Int64) {
            self.source = source
            self.stepAt = stepAt
        }
    }

    public enum Event: Equatable, Sendable {
        /// A control channel attached: first connect, reconnect,
        /// replacement or restore alike. Reads, never claims (R5).
        case attached
        /// The control transport went away.
        case resetTransport(preservingPeer: Bool)
        /// This device's stamp identity changed; set `localDeviceID` first.
        /// The old identity's claim, held reply and ownership end with it.
        case identityChanged
        /// Whether the attached control channel can carry a command now (a
        /// mosh side-channel gap the adapter knows about before it resets).
        case channelLiveness(Bool)
        /// A show edge or an explicit open (R1). `stepAt` is the user's
        /// step, which precedes delivery for a show carried from a replaced
        /// session object or buffered before the session registered. In the
        /// background (a wake's edge before `foregrounded`) it records its
        /// intent for the foreground read and restarts no claim.
        case shown(source: Reducer.ShowSource, stepAt: Int64)
        /// This session object replaced the one behind a slot that is shown:
        /// it takes over the shown state with no show of its own.
        case adoptShown
        /// A hide edge (R3): drops an unsent intent and any parked replay.
        case hidden
        /// The veil gesture (R4). Ignored while hidden; in the background
        /// its intent waits for the foreground read.
        case requestTakeBack
        /// The pending-state cancel: ends the intent now, as its expiry
        /// would. Not a hide.
        case cancelIntent
        /// A prompt answered or Retry: the R3 window restarts.
        case userStep
        case prompt(scope: PromptScope, active: Bool)
        /// The app left the foreground: ordinary geometry is withheld, and a
        /// pending gesture is not resolved, until the foreground read (M6).
        /// Not a hide; the show tracker decides that.
        case backgrounded
        /// A non-claiming re-derive after the app returns to the foreground.
        case foregrounded
        /// A raw live subscription edge; classification belongs to this session.
        case stampObserved(raw: String)
        /// An authority observation from a query or other shared policy evidence.
        case observedAuthority(TmuxGridAuthoritySnapshot)
        /// A stamp echo naming this device, with its generation.
        case ownStampObserved(generation: UInt64)
        /// The reply to `queryAuthority(id:)`: the option's raw value.
        case queryReplied(id: UInt64, raw: String)
        case queryFailed(id: UInt64)
        /// The window list's hydration and the window tmux names active.
        case windowFacts(hydrated: Bool, activeWindow: TmuxAuthorityGeometryEvidence.ActiveWindow?)
        /// The client size this device would advertise now.
        case localSize(TmuxGridSize?)
        /// `show-options -wA -v -t @<windowID> window-size`. `fenceID` names
        /// the claim fence the read was queued behind: only its own read
        /// tells that fence how the window is sized.
        case windowSizePolicyReplied(windowID: Int, raw: String, fenceID: UInt64? = nil)
        /// The adapter pushed an ordinary client size. While a claim exists,
        /// report its geometry through `claimAdvertisedGeometry` instead.
        case sizeAdvertised(TmuxGridSize)
        /// An ordinary window recovery started, or ended with or without
        /// proving the window ours.
        case ordinaryRecovery(active: Bool, proven: Bool)
        /// A render surface could carry a claim's repaint now (mounted, on an
        /// attached terminal, the app in the foreground).
        case paintable(Bool)
        /// The control client's tmux session changed on the same channel:
        /// resolved after a reconnect queued its read, or switched.
        /// `replacedKnownSession` is false for a first resolution, whose
        /// owned grids still describe this device's windows. A switch resets
        /// the session as `resetTransport(preservingPeer: false)` does; the
        /// adapter then reports `attached` again.
        case controlSessionChanged(replacedKnownSession: Bool)
        /// A fence for the live claim went out on `windowID` (the window
        /// tmux names current when it runs): `claimFence` is a new one, and
        /// nothing an older fence saw counts. Tag its replies with
        /// `claimFence.id`.
        case claimFenceSent(generation: UInt64, windowID: Int)
        /// tmux answered the fence `fenceID`: everything queued before it
        /// has run.
        case claimFenceAcknowledged(fenceID: UInt64)
        /// A side-channel window force sent for the fence `fenceID` awaits
        /// its proof (`outstanding`), or has it.
        case claimFenceForce(fenceID: UInt64, outstanding: Bool)
        /// The adapter applied a layout to its model: confirm the fence if
        /// it has settled. Sent where a confirmation's repaint may start,
        /// once the render path has seen the same layout.
        case confirmClaimFence
        /// Geometry sent for a visible claim, with its own fence. A late
        /// claim's report changes nothing, including advertise bookkeeping.
        case claimAdvertisedGeometry(generation: UInt64, size: TmuxGridSize)
        /// A claimed-window observation under `latest`; a settle probe marks
        /// the latest fence landed before classifying the size (§6.10).
        case claimObservedGeometry(generation: UInt64, size: TmuxGridSize, settleProbe: Bool)
        case claimGeometryLost(generation: UInt64)
        case claimStalled(generation: UInt64, canProgress: Bool)
        case repaintSucceeded(generation: UInt64)
        case stampCommitSucceeded(generation: UInt64)
        case settleClaim(generation: UInt64)
        /// `.adapterFailure` parks a gesture's claim for replay. A claim
        /// that never sent its commands (a viewport not yet measured) and
        /// is abandoned at a hide or cancel (L2) is aborted `.superseded`,
        /// which is never replayed.
        case abortClaim(generation: UInt64, reason: Reducer.AbortReason)
        /// A deadline passed; see `nextDeadline`.
        case tick
    }

    public enum Effect: Equatable, Sendable {
        /// Send `show-options -qv @tessera_authority` tagged `id`.
        case queryAuthority(id: UInt64)
        case beginClaim(Reducer.Claim)
        case requestRepaint(generation: UInt64)
        case commitAuthorityStamp(generation: UInt64)
        case authorityChanged(TmuxGridAuthoritySnapshot)
        /// The deadline only hides. If a claim is still live, the adapter
        /// must run its rule 6 stall check: report `claimStalled` with
        /// `canProgress: false` when no own command or repaint is in flight.
        case hideReclaimPresentation
        case claimAborted(Reducer.AbortReason)
        case claimSettled(generation: UInt64)
        /// A read resolved the geometry hold (or asked for an advertise
        /// without one). `.none` sends nothing now: ordinary changes flow
        /// from here on, as `geometryHold` says.
        case releaseGeometry(GeometryRelease)
        /// The lifecycle yielded to the stamp-less fallback (a foreign layout
        /// edge, or our stamp over a foreign size). Follows the
        /// `authorityChanged` it explains; the adapter projects that verdict.
        case raiseStamplessPeer
        /// A read went unanswered past the overdue bound. Mosh side channels
        /// reconnect; inline transports only log (keepalive owns them).
        case controlChannelUnresponsive
        /// Send this generation's fence again (inline a targetless
        /// `select-window`, side channel the window force at its target).
        /// The policy and earlier ack stand; the new settle probe proves
        /// landing again. Mirrors the reducer's §6.10 rule 4 instruction.
        case refenceClaim(generation: UInt64)
    }

    /// One `show-options` read and the replies it is waiting for.
    public struct QueryTracker: Equatable, Sendable {
        public struct Read: Equatable, Sendable {
            public let id: UInt64
            /// The pending intent at issue; a reply cannot decide a newer one.
            public let intentToken: UInt64?
            public let issuedAt: Int64
        }

        /// An own-stamp reply waiting for geometry evidence.
        public struct HeldReply: Equatable, Sendable {
            public let readID: UInt64
            public let intentToken: UInt64?
            public let observed: TmuxGridAuthoritySnapshot
            public let deadline: Int64
        }

        public fileprivate(set) var nextID: UInt64 = 0
        /// Ids at or below this belong to a connection that was reset.
        public fileprivate(set) var floorID: UInt64 = 0
        /// The read whose reply decides; older ones are superseded.
        public fileprivate(set) var current: Read?
        /// Issue time of the oldest read still unanswered.
        public fileprivate(set) var unansweredSince: Int64?
        public fileprivate(set) var failures = 0
        public fileprivate(set) var retryAt: Int64?
        public fileprivate(set) var held: HeldReply?
        /// A read went unanswered past the bound: the queue is stuck.
        public fileprivate(set) var overdue = false
        /// A read the channel could not carry yet.
        public fileprivate(set) var wanted = false
    }

    /// The fence a live claim sent last, and what it has proved. The
    /// session calls the reducer's `fenceSucceeded` from it alone, the same
    /// way on both platforms: tmux answered the fence, the window's policy
    /// was read behind it, and under `latest` the fenced window stands at
    /// the claim's target, with no settle probe saying otherwise and no
    /// window force still unproved. Under any other policy the window never
    /// follows a client, so the acknowledgement alone confirms.
    public struct ClaimFence: Equatable, Sendable {
        public let generation: UInt64
        public let id: UInt64
        /// The window the fence made us `latest` on.
        public let windowID: Int
        public fileprivate(set) var acknowledged = false
        /// This fence's own read of the window's policy; nil until it lands.
        public fileprivate(set) var policyIsLatest: Bool?
        /// The settle probe found the window off the target. A layout at the
        /// target, a new advertisement or a re-fence clears it.
        public fileprivate(set) var probeOffTarget = false
        /// A side-channel window force for this fence awaits its proof.
        public fileprivate(set) var forceOutstanding = false
    }

    private struct ClaimPresentation: Equatable, Sendable {
        let generation: UInt64
        let deadline: Int64
    }

    public let configuration: Configuration
    /// This device's stamp identity; reads naming it are `.mine`.
    public var localDeviceID: String? {
        didSet {
            if oldValue != localDeviceID { lastObservedStampRaw = nil }
        }
    }
    /// Subscription replays are memoized even when identity or parsing rejects
    /// them. A connection reset, identity change or our next write re-arms it.
    private var lastObservedStampRaw: String?

    public private(set) var reducer = Reducer()
    public private(set) var query = QueryTracker()
    public private(set) var evidence = TmuxAuthorityGeometryEvidence()
    /// The live claim's latest fence; nil outside a claim's geometry phase
    /// before its first fence.
    public private(set) var claimFence: ClaimFence?
    private var lastClaimFenceID: UInt64 = 0
    public private(set) var stamplessJudge = TmuxStamplessPeerJudge()
    public private(set) var replay: TmuxAuthorityClaimReplay
    public private(set) var intentClock: TmuxAuthorityIntentClock
    /// Between a hide edge and the next show. Every session starts hidden:
    /// it is sized and veiled only once it has been shown.
    public private(set) var hidden = true
    public private(set) var paintable = false
    public private(set) var channelLive = true
    public private(set) var sessionPromptActive = false
    public private(set) var connectPromptActive = false
    /// D3: set from attach, a background and every read until one resolves
    /// authority.
    public private(set) var heldForRead = true
    /// Between `backgrounded` and `foregrounded` (M6): nothing is sized or
    /// claimed, and nothing releases the hold until the foreground read.
    public private(set) var inBackground = false
    public private(set) var ordinaryRecoveryActive = false
    /// The client size last pushed on this connection, and when.
    public private(set) var lastAdvertisedSize: TmuxGridSize?
    public private(set) var lastAdvertisedAt: Int64?
    private var claimPresentation: ClaimPresentation?
    private var claimStepAt: Int64?
    /// One claim-end verdict, retained while a read or parked replay defers it.
    /// Keep the live claim's complete advertised membership, not its bounded
    /// diagnostic projection. A new claim or hide leaves the next read to decide.
    private struct ClaimEndJudgement: Equatable, Sendable {
        let abortedClaim: Reducer.Claim?
        let settled: Bool
        let lastAdvertisedSize: TmuxGridSize?
        var recoveryReadRequested = false
    }
    private var claimEndJudgement: ClaimEndJudgement?
    /// The user's step behind a claim a peer contested. Its own stamp can
    /// still land last and continue it as `ownWriteWon`, which is the same
    /// gesture: R3 keeps timing it from that step.
    private var contestedClaimStepAt: Int64?

    // MARK: Projection, recomputed after every event

    public private(set) var presentation: TmuxGridAuthorityPresentation = .none
    public private(set) var gatesTyping = false
    public private(set) var mutationRefusal: TmuxGridAuthorityPresentation.MutationRefusal?
    public private(set) var geometryHold: GeometryHold = .withheld
    /// When `tick` next has something to decide; nil when nothing is pending.
    public private(set) var nextDeadline: Int64?

    public init(localDeviceID: String? = nil, configuration: Configuration = .init(), initialGeneration: UInt64 = 0) {
        self.reducer = Reducer(initialGeneration: initialGeneration)
        self.localDeviceID = localDeviceID
        self.configuration = configuration
        self.intentClock = TmuxAuthorityIntentClock(windowMillis: configuration.intentWindowMillis)
        self.replay = TmuxAuthorityClaimReplay(
            budget: configuration.replayBudget,
            windowMillis: configuration.replayWindowMillis
        )
        derive()
    }

    /// The control channel can carry a read or a claim now.
    public var channelIsLive: Bool {
        reducer.channelAttached && channelLive && !query.overdue
    }

    /// §6.10 rule 2: only a live claim with visible presentation may send
    /// geometry. A late claim stays busy but finishes on its existing acks.
    public var claimMayAdvertiseGeometry: Bool {
        !hidden && !inBackground && reducer.claimMayAdvertiseGeometry
    }

    /// Whether a prompt pauses the R3 clock now.
    public var intentClockPaused: Bool {
        sessionPromptActive || (connectPromptActive && !channelIsLive)
    }

    // MARK: - Reduction

    /// Applies one event at `now` (milliseconds on the session's clock) and
    /// returns the adapter's instructions. Deadlines that passed before
    /// `now` fire first, in the order they protect: an intent whose window
    /// ran out during sleep never lets the wake's read decide it. A hide or
    /// a background is the exception: it applies before them, because a
    /// bound that came due unobserved (a sleep, a late tick), such as a held
    /// reply's, could otherwise resolve a gesture with a claim behind a lock
    /// screen; they fire after it.
    @discardableResult
    public mutating func reduce(_ event: Event, now: Int64) -> [Effect] {
        // Replayed subscription values are a pure no-op, including clocks and
        // trace state; deadlines have their own tick. Record rejected values
        // too, so pane fan-out never repeatedly parses an invalid stamp.
        var liveStamp: (raw: String, stamp: TmuxGridAuthorityStamp)?
        if case .stampObserved(let raw) = event {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != lastObservedStampRaw else { return [] }
            lastObservedStampRaw = trimmed
            guard localDeviceID != nil,
                  let stamp = TmuxGridAuthorityStamp.parse(trimmed) else { return [] }
            liveStamp = (trimmed, stamp)
        }
        var effects: [Effect] = []
        if event != .hidden, event != .backgrounded {
            // A reply or a failure proves the queue moves, however late it
            // lands: the overdue bound must not fire on the very answer that
            // clears it (its adapter would drop a channel that just
            // replied). The pass after `handle` still judges a newer read.
            fireDueDeadlines(now: now, judgeOverdue: !event.answersARead, into: &effects)
        }
        if let observed = liveStamp {
            let outstanding = query.current
            let localID = localDeviceID.map(TmuxGridAuthorityStamp.sanitizeToken)
            handle(.observedAuthority(classify(raw: observed.raw)), now: now, into: &effects)
            if observed.stamp.deviceID == localID {
                handle(.ownStampObserved(generation: observed.stamp.generation), now: now, into: &effects)
            }
            // A read sent before this edge may be answered after it: Android
            // reduces a reply on Main and a later read's stamps in the
            // runtime callback. Its older value would then replace this one,
            // and no later edge repeats it. Only a read issued now decides.
            if let outstanding, query.current == outstanding {
                query.current = nil
                requestRead(now: now, into: &effects)
            }
        } else {
            handle(event, now: now, into: &effects)
        }
        intentClock.setPaused(intentClockPaused, now: now)
        if replay.parked != nil { attemptReplay(now: now, into: &effects) }
        // The event can re-arm a bound that is already due (a late reply
        // to an older read leaves only the newer one unanswered, issued long
        // ago): nothing may be left due once a reduction returns. An
        // overdue read found here can pause the clock for a connect prompt.
        fireDueDeadlines(now: now, into: &effects)
        intentClock.setPaused(intentClockPaused, now: now)
        if claimEndJudgement != nil { runClaimEndJudge(now: now, into: &effects) }
        derive()
        return effects
    }

    /// How this device reads a stamp value: the classification a
    /// subscription edge gets, for a read that reduces it as one.
    public func classify(raw: String) -> TmuxGridAuthoritySnapshot {
        .classify(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            localDeviceID: localDeviceID.map(TmuxGridAuthorityStamp.sanitizeToken)
        )
    }

    private mutating func handle(_ event: Event, now: Int64, into effects: inout [Effect]) {
        switch event {
        case .attached:
            heldForRead = true
            // An attach is a live channel: a liveness gap reported for the
            // old one must not hold this attach's read back.
            channelLive = true
            reduceLifecycle(now: now, into: &effects) { $0.attached() }

        case .resetTransport(let preservingPeer):
            lastObservedStampRaw = nil
            claimEndJudgement = nil
            query = QueryTracker(nextID: query.nextID, floorID: query.nextID)
            heldForRead = true
            claimPresentation = nil
            evidence.windowListHydrated = false
            evidence.activeWindow = nil
            evidence.policy = nil
            lastAdvertisedSize = nil
            lastAdvertisedAt = nil
            contestedClaimStepAt = nil
            stamplessJudge.reset()
            ordinaryRecoveryActive = false
            reduceLifecycle(now: now, into: &effects) { $0.resetTransport(preservingPeer: preservingPeer) }

        case .channelLiveness(let live):
            let healed = live && !channelLive
            channelLive = live
            // A read the channel could not carry goes out now; so does one
            // for a gesture that waited for the channel. A tap records no
            // read of its own while the channel is down, and would otherwise
            // spin "takes control when reconnected" until R3 ends it.
            if query.wanted || (healed && reducer.pendingIntent != nil) {
                requestRead(now: now, into: &effects)
            }
            // An owned edge left for a channel that could carry its replay.
            if healed { runStamplessJudge(now: now, into: &effects) }

        case .shown(let source, let stepAt):
            hidden = false
            claimEndJudgement = nil
            replay.reset()
            let step = min(stepAt, now)
            // A carried step that already outlived its window is dropped;
            // the session is displayed all the same, so it re-derives as a
            // foreground does: a read answered while hidden released
            // nothing, and layouts from then are judged behind a fresh read
            // (R5: never a claim).
            guard now.clampedSubtracting(step) < configuration.intentWindowMillis else {
                if reducer.claim == nil, reducer.pendingIntent == nil, !reducer.authority.isPeer {
                    requestRead(now: now, into: &effects)
                }
                return
            }
            // Nothing begins a claim into the background (M6): a show there
            // leaves its intent for the foreground read.
            let claimNow = !inBackground
            reduceLifecycle(now: now, newIntentStep: step, into: &effects) {
                $0.shown(source: source, claimNow: claimNow)
            }

        case .adoptShown:
            hidden = false
            // A read answered while hidden released nothing; there is no
            // show read to decide now, so ask (R5: never a claim).
            if heldForRead, reducer.claim == nil, !reducer.authority.isPeer {
                requestRead(now: now, into: &effects)
            }

        case .hidden:
            hidden = true
            claimEndJudgement = nil
            replay.reset()
            // A hide ends the gesture a contested claim belonged to, as it
            // drops a parked replay: its own stamp landing later must not
            // fence a hidden session (`ownWriteWon`).
            dropOwnWriteContinuation()
            reduceLifecycle(now: now, into: &effects) { $0.hidden() }
            hideClaimPresentation(now: now, into: &effects)

        case .requestTakeBack:
            // A hidden session shows no veil to tap: a key routed to it takes
            // nothing back, and restarts no claim.
            guard !hidden else { return }
            replay.reset()
            // In the background the tap waits, as on a channel that cannot
            // carry its claim, for the foreground read (M6).
            let live = channelLive && !query.overdue && !inBackground
            reduceLifecycle(now: now, into: &effects) { $0.requestTakeBack(channelLive: live) }

        case .cancelIntent:
            replay.reset()
            if let token = reducer.pendingIntent?.token {
                reduceLifecycle(now: now, into: &effects) { $0.intentExpired(token: token) }
            }

        case .userStep:
            intentClock.userStep(now: now)

        case .prompt(let scope, let active):
            switch scope {
            case .session: sessionPromptActive = active
            case .connect: connectPromptActive = active
            }

        case .backgrounded:
            heldForRead = true
            inBackground = true
            claimEndJudgement = nil
            hideClaimPresentation(now: now, into: &effects)

        case .identityChanged:
            // What the old identity began ends with it. Left alone, its claim
            // would settle, its held reply project, its parked replay or
            // contested write continue: `.mine` under the new id. Its stamp
            // is a peer's now, which only a read issued after the change
            // classifies.
            replay.reset()
            dropOwnWriteContinuation()
            query.held = nil
            query.current = nil
            if let claim = reducer.claim {
                reduceLifecycle(now: now, into: &effects) { $0.abortClaim(generation: claim.generation, reason: .superseded) }
            }
            claimEndJudgement = nil
            if localDeviceID == nil, let token = reducer.pendingIntent?.token {
                // A device that no longer takes part has no gesture to claim with.
                reduceLifecycle(now: now, into: &effects) { $0.intentExpired(token: token) }
            }
            if case .mine = reducer.authority {
                reduceLifecycle(now: now, into: &effects) { $0.observedAuthority(.unknown) }
            }
            requestRead(now: now, into: &effects)

        case .foregrounded:
            inBackground = false
            reduceLifecycle(now: now, into: &effects) { $0.foregrounded() }
            // A gesture's read answered in the background was left unread, and
            // a gesture made there sent none: this read decides it.
            if query.wanted || reducer.pendingIntent != nil { requestRead(now: now, into: &effects) }

        case .stampObserved:
            break // Prepared and classified once by reduce, above.

        case .observedAuthority(let observed):
            if let held = query.held, observed != .unknown, observed != held.observed {
                // A newer write landed while an own-stamp reply waited for
                // evidence: that reply no longer describes the server.
                query.held = nil
                requestRead(now: now, into: &effects)
            }
            reduceLifecycle(now: now, into: &effects) { $0.observedAuthority(observed) }

        case .ownStampObserved(let generation):
            // Its continuation is a fresh fence: never into a hidden or
            // background session, whenever the contest came.
            guard !hidden, !inBackground else {
                dropOwnWriteContinuation()
                return
            }
            reduceLifecycle(now: now, into: &effects) { $0.observedOwnAuthorityStamp(generation: generation) }

        case .queryReplied(let id, let raw):
            handleReply(id: id, raw: raw, now: now, into: &effects)

        case .queryFailed(let id):
            handleFailure(id: id, now: now, into: &effects)

        case .windowFacts(let hydrated, let activeWindow):
            guard evidence.windowListHydrated != hydrated || evidence.activeWindow != activeWindow else { return }
            evidence.windowListHydrated = hydrated
            evidence.activeWindow = activeWindow
            evidenceChanged(now: now, into: &effects)

        case .localSize(let size):
            guard evidence.localSize != size else { return }
            evidence.localSize = size
            evidenceChanged(now: now, into: &effects)

        case .windowSizePolicyReplied(let windowID, let raw, let fenceID):
            evidence.policy = .init(windowID: windowID, rawReply: raw)
            // A layout that landed while the policy was unknown is judged
            // again under the known policy.
            stamplessJudge.forgetJudgedEdge()
            evidenceChanged(now: now, into: &effects)
            // Only the read queued behind a fence speaks for it: a cached
            // policy can predate the claim.
            if let fenceID, var fence = claimFence, fence.id == fenceID, fence.windowID == windowID {
                fence.policyIsLatest = evidence.policy?.isLatest
                claimFence = fence
                confirmClaimFenceIfSettled(now: now, into: &effects)
            }

        case .sizeAdvertised(let size):
            guard reducer.claim == nil else { return }
            noteAdvertised(size, now: now)
            // An ordinary owner resize: the window now has, or is about to
            // have, this size, which a later read reports as owned.
            if case .mine = reducer.authority {
                evidence.owned.record(size)
            }

        case .ordinaryRecovery(let active, let proven):
            let wasActive = ordinaryRecoveryActive
            ordinaryRecoveryActive = active
            // One that could not prove the window ours alone judges the
            // layout edge its run held back; nothing else need arrive.
            if wasActive, !active {
                if !proven { runStamplessJudge(now: now, into: &effects) }
                releaseHeldReply(final: false, now: now, into: &effects)
            }

        case .paintable(let value):
            paintable = value

        case .controlSessionChanged(let replacedKnownSession):
            guard replacedKnownSession else {
                // A read issued before the session resolved cannot speak for it.
                if query.current != nil || query.held != nil {
                    query.current = nil
                    query.held = nil
                    requestRead(now: now, into: &effects)
                }
                return
            }
            // Authority is a session option, so the old session's verdict,
            // a claim on its windows and the grids this device owned there
            // say nothing about the new one: a transport reset that keeps no
            // peer. The adapter attaches again, after resolving the new
            // session's scope, and that attach reads (§6.18).
            evidence.owned.removeAll()
            handle(.resetTransport(preservingPeer: false), now: now, into: &effects)

        case .claimFenceSent(let generation, let windowID):
            // Only geometry the claim advertised can be fenced, and only
            // before it confirmed: a confirmed claim's repaint would
            // otherwise outlive the fence it confirmed under.
            guard let claim = reducer.claim, claim.generation == generation,
                  claim.phase == .awaitingFence, claim.targetGrid != nil
            else { return }
            lastClaimFenceID &+= 1
            claimFence = ClaimFence(generation: generation, id: lastClaimFenceID, windowID: windowID)
        case .claimFenceAcknowledged(let fenceID):
            // A re-fence (§6.10 rule 4) answers under the same fence: its
            // acknowledgement stood, and the window may be back.
            guard var fence = claimFence, fence.id == fenceID else { return }
            fence.acknowledged = true
            claimFence = fence
            confirmClaimFenceIfSettled(now: now, into: &effects)
        case .claimFenceForce(let fenceID, let outstanding):
            guard var fence = claimFence, fence.id == fenceID, fence.forceOutstanding != outstanding else { return }
            fence.forceOutstanding = outstanding
            claimFence = fence
            if !outstanding { confirmClaimFenceIfSettled(now: now, into: &effects) }
        case .confirmClaimFence:
            confirmClaimFenceIfSettled(now: now, into: &effects)
        case .claimAdvertisedGeometry(let generation, let size):
            // The reducer accepts only positive geometry for this visible
            // generation. Its transition has no effects, even on acceptance.
            let accepted = reducer.claim?.generation == generation
                && claimMayAdvertiseGeometry && size.columns > 0 && size.rows > 0
            let before = reducer.claim
            reduceLifecycle(now: now, into: &effects) {
                $0.claimAdvertisedGeometry(generation: generation, columns: size.columns, rows: size.rows)
            }
            if accepted {
                noteAdvertised(size, now: now)
                // A fence sent before this geometry cannot confirm it: a
                // non-`latest` policy would expose the terminal before the
                // new size reached tmux. The advertisement's own fence
                // follows. Our own grid again, unchanged, keeps the fence.
                if before?.targetGrid != reducer.claim?.targetGrid || before?.phase != reducer.claim?.phase {
                    claimFence = nil
                } else {
                    claimFence?.probeOffTarget = false
                }
            }
        case .claimObservedGeometry(let generation, let size, let settleProbe):
            let target = reducer.claim?.generation == generation ? reducer.claim?.targetGrid : nil
            reduceLifecycle(now: now, into: &effects) {
                $0.claimObservedGeometry(generation: generation, columns: size.columns, rows: size.rows, settleProbe: settleProbe)
            }
            if let target, var fence = claimFence, fence.generation == generation {
                let atTarget = target.columns == size.columns && target.rows == size.rows
                // The settle probe reads where the fence's geometry landed;
                // a later layout back at the target outdates its verdict.
                if settleProbe { fence.probeOffTarget = !atTarget } else if atTarget { fence.probeOffTarget = false }
                claimFence = fence
                if settleProbe, atTarget { confirmClaimFenceIfSettled(now: now, into: &effects) }
            }
        case .claimGeometryLost(let generation):
            reduceLifecycle(now: now, into: &effects) { $0.claimGeometryLost(generation: generation) }
        case .claimStalled(let generation, let canProgress):
            reduceLifecycle(now: now, into: &effects) { $0.claimStalled(generation: generation, canProgress: canProgress) }
        case .repaintSucceeded(let generation):
            reduceLifecycle(now: now, into: &effects) { $0.repaintSucceeded(generation: generation) }
        case .stampCommitSucceeded(let generation):
            reduceLifecycle(now: now, into: &effects) { $0.stampCommitSucceeded(generation: generation) }
        case .settleClaim(let generation):
            reduceLifecycle(now: now, into: &effects) { $0.settleClaim(generation: generation) }
        case .abortClaim(let generation, let reason):
            reduceLifecycle(now: now, into: &effects) { $0.abortClaim(generation: generation, reason: reason) }

        case .tick:
            break
        }
    }

    // MARK: - Deadlines

    /// A sent claim keeps its ack chain while off screen, but it cannot
    /// regain permission to fence without a new gesture.
    private mutating func hideClaimPresentation(now: Int64, into effects: inout [Effect]) {
        guard let claim = reducer.claim else { return }
        reduceLifecycle(now: now, into: &effects) { $0.presentationTimedOut(generation: claim.generation) }
    }

    private mutating func fireDueDeadlines(now: Int64, judgeOverdue: Bool = true, into effects: inout [Effect]) {
        // R3 first: the wake's read must not resolve an intent whose window
        // ran out while the device slept.
        if let token = intentClock.expiredToken(now: now) {
            reduceLifecycle(now: now, into: &effects) { $0.intentExpired(token: token) }
        }
        if let presentation = claimPresentation, now >= presentation.deadline {
            claimPresentation = nil
            reduceLifecycle(now: now, into: &effects) { $0.presentationTimedOut(generation: presentation.generation) }
        }
        if let held = query.held, now >= held.deadline {
            releaseHeldReply(final: true, now: now, into: &effects)
        }
        if judgeOverdue, !query.overdue, let since = query.unansweredSince,
           now.clampedSubtracting(since) >= configuration.queryOverdueMillis {
            query.overdue = true
            effects.append(.controlChannelUnresponsive)
        }
        if let retryAt = query.retryAt, now >= retryAt {
            query.retryAt = nil
            requestRead(now: now, retry: true, into: &effects)
        }
        if stamplessJudge.takeDueRejudge(now: now) {
            runStamplessJudge(now: now, into: &effects)
        }
    }

    // MARK: - Reads

    /// Puts a read on the wire for the current intent (or its absence),
    /// unless one for the same intent is already outstanding or held. A
    /// fresh request (a show, a foreground, an attach) gets the full retry
    /// budget again; only `retry` continues the count.
    private mutating func requestRead(now: Int64, retry: Bool = false, into effects: inout [Effect]) {
        guard reducer.channelAttached else { return }
        heldForRead = true
        let token = reducer.pendingIntent?.token
        if let current = query.current, current.intentToken == token { return }
        if let held = query.held, held.intentToken == token { return }
        guard channelLive, !query.overdue else {
            // Never re-sent on a stuck or absent queue: the channel's return
            // (or the late reply) sends it.
            query.wanted = true
            return
        }
        if !retry { query.failures = 0 }
        query.nextID &+= 1
        let read = QueryTracker.Read(id: query.nextID, intentToken: token, issuedAt: now)
        // The newest read wins: an older reply is dropped unread, and an
        // older held reply no longer decides anything.
        query.current = read
        query.held = nil
        query.wanted = false
        query.retryAt = nil
        if query.unansweredSince == nil { query.unansweredSince = now }
        effects.append(.queryAuthority(id: read.id))
    }

    /// Any reply proves the queue moves again.
    private mutating func noteQueueMoved(replyID: UInt64, now: Int64, into effects: inout [Effect]) {
        query.overdue = false
        if let current = query.current, replyID < current.id {
            // tmux answers in order: only the newer read is still unanswered.
            query.unansweredSince = current.issuedAt
        } else {
            query.unansweredSince = nil
        }
        if query.wanted { requestRead(now: now, into: &effects) }
    }

    private mutating func handleReply(id: UInt64, raw: String, now: Int64, into effects: inout [Effect]) {
        guard id > query.floorID, id <= query.nextID else { return }
        noteQueueMoved(replyID: id, now: now, into: &effects)
        guard let read = query.current, read.id == id else { return }
        query.current = nil
        query.failures = 0
        query.retryAt = nil
        let value = Self.firstValue(raw)
        let observed: TmuxGridAuthoritySnapshot = value.isEmpty
            ? .unknown
            : .classify(rawValue: value, localDeviceID: localDeviceID.map(TmuxGridAuthorityStamp.sanitizeToken))
        if let intent = reducer.pendingIntent, read.intentToken != intent.token {
            // Issued before the current gesture: it cannot decide it.
            requestRead(now: now, into: &effects)
            return
        }
        if case .mine = observed {
            guard let geometry = classifyReadGeometry(final: false, readHadIntent: read.intentToken != nil) else {
                query.held = .init(
                    readID: id,
                    intentToken: read.intentToken,
                    observed: observed,
                    deadline: now.clampedAdding(configuration.replyHoldMillis)
                )
                return
            }
            deliver(observed, unstamped: false, geometry: geometry, readHadIntent: read.intentToken != nil, now: now, into: &effects)
        } else {
            // Peer and unknown verdicts do not depend on geometry.
            deliver(observed, unstamped: value.isEmpty, geometry: .unknown, readHadIntent: read.intentToken != nil, now: now, into: &effects)
        }
    }

    private mutating func handleFailure(id: UInt64, now: Int64, into effects: inout [Effect]) {
        guard id > query.floorID, id <= query.nextID else { return }
        noteQueueMoved(replyID: id, now: now, into: &effects)
        guard let read = query.current, read.id == id else { return }
        query.current = nil
        query.failures += 1
        // Geometry stays withheld; past the retries it fails closed until the
        // next show, foreground or attach asks again.
        query.retryAt = query.failures <= configuration.queryRetryLimit
            ? now.clampedAdding(configuration.queryRetryStepMillis.clampedMultiplying(by: Int64(query.failures)))
            : nil
    }

    /// Re-judges a held own-stamp reply once evidence may have arrived, or
    /// forces it out with the best evidence available at the bound.
    private mutating func releaseHeldReply(final: Bool, now: Int64, into effects: inout [Effect]) {
        guard let held = query.held, let geometry = classifyReadGeometry(final: final, readHadIntent: held.intentToken != nil) else { return }
        query.held = nil
        if let intent = reducer.pendingIntent, held.intentToken != intent.token {
            requestRead(now: now, into: &effects)
            return
        }
        deliver(held.observed, unstamped: false, geometry: geometry, readHadIntent: held.intentToken != nil, now: now, into: &effects)
    }

    /// Rule 7's complete claim membership also applies to the read that
    /// deferred it. These grids are our advertisements, not proven owned
    /// geometry: follow the stamp without manufacturing a peer or replay.
    private func classifyReadGeometry(final: Bool, readHadIntent: Bool) -> Reducer.QueryGeometry? {
        let geometry = evidence.classify(final: final)
        if geometry == .foreignSize, ordinaryRecoveryActive,
           !readHadIntent, reducer.pendingIntent == nil {
            return final ? .unknown : nil
        }
        if geometry == .foreignSize, let claim = claimEndJudgement?.abortedClaim,
           let size = evidence.judgedWindow?.size {
            let grid = Reducer.Grid(columns: size.columns, rows: size.rows)
            if grid == claim.targetGrid || claim.hasAdvertisedGrid(grid) { return .unknown }
        }
        return geometry
    }

    /// Feeds one read into the reducer, then releases or keeps the geometry
    /// hold. The reply always reaches the reducer whatever the presentation:
    /// being hidden gates geometry and repaint, never authority (D4). Hidden
    /// or in the background it releases nothing and sends nothing: the next
    /// show's (or adoption's) read, or the foreground read, does (M6).
    /// The one exception: in the background a read that would resolve a
    /// pending gesture is left unread, so it never claims from there.
    private mutating func deliver(
        _ observed: TmuxGridAuthoritySnapshot,
        unstamped: Bool,
        geometry: Reducer.QueryGeometry,
        readHadIntent: Bool,
        now: Int64,
        into effects: inout [Effect]
    ) {
        if inBackground, reducer.pendingIntent != nil {
            // The foreground asks again while the gesture lasts (R3).
            query.wanted = true
            return
        }
        let wasHeld = heldForRead
        let hadClaimEndJudgement = claimEndJudgement != nil
        let replayRequested = reduceLifecycle(now: now, into: &effects) {
            $0.receivedAuthorityQuery(observed, geometry: geometry)
        }
        // Decide rule 7 before emitting any write. Settlement's churn tail
        // runs after the read's release, so both paths share one release.
        let ended = hadClaimEndJudgement ? judgeClaimEnd(now: now, into: &effects) : nil
        if reducer.claim == nil, reducer.pendingIntent == nil, replay.parked == nil, !hidden, !inBackground {
            if case .mine = reducer.authority {
                // Our window: ordinary geometry may flow again.
                if geometry == .atLocalSize, let local = evidence.localSize {
                    evidence.owned.record(local)
                }
                heldForRead = false
                // An owned edge either path already replayed over stays ours
                // as it is: a read per layout must not loop the replay
                // against a client that keeps restoring it.
                let ownedEdge = evidence.judgedWindow.flatMap { window in
                    window.size.map { TmuxStamplessPeerJudge.Edge(windowID: window.id, size: $0) }
                }
                let replayOwned = replayRequested
                    && !(ownedEdge.map(stamplessJudge.replayedOwnedEdges.contains) ?? false)
                let release: GeometryRelease
                if replayOwned {
                    release = .ownerReplay
                } else if replayRequested {
                    release = .none
                } else if wasHeld, geometry == .atLocalSize, !evidence.judgedWindowMatchesLocalSize {
                    // Under a non-`latest` policy the window never equals
                    // our grid, so `.atLocalSize` released a hold that may
                    // have withheld a real local change (L4).
                    release = .ownerReplay
                } else if !readHadIntent, geometry == .atLocalSize,
                          let local = evidence.localSize, lastAdvertisedSize != local {
                    // A reattach found our stamp at our size: tell tmux this
                    // connection's size once, with no stamp (P6 skips it when
                    // this connection already did).
                    release = .advertise
                } else {
                    release = .none
                }
                if release != .none, !channelIsLive {
                    // A channel that cannot carry the resize (a side-channel
                    // gap) would lose it, and nothing would send it again:
                    // keep the hold, and read again once it heals.
                    requestRead(now: now, into: &effects)
                } else {
                    if release != .none { noteReleaseAdvertises(now: now) }
                    if wasHeld || release != .none { effects.append(.releaseGeometry(release)) }
                    // That arrival is answered: neither path replays it again.
                    if replayOwned, let ownedEdge { stamplessJudge.noteOwnedReplay(ownedEdge) }
                }
            } else if reducer.authority == .unknown, observed == .unknown, unstamped {
                // No stamp at all (a fresh session, kill-server, reboot):
                // nobody holds the grid, and a hold kept here would pin the
                // window at 80x24 forever (M3).
                heldForRead = false
                if wasHeld {
                    noteReleaseAdvertises(now: now)
                    effects.append(.releaseGeometry(.advertise))
                }
            }
        }
        // A fresh read must precede geometry evidence: judge the current
        // layout afresh against it.
        if let ended {
            finishClaimEnd(ended, now: now, into: &effects)
        } else if hadClaimEndJudgement {
            // Still deferred (for example a parked failure).
        } else {
            stamplessJudge.forgetJudgedEdge()
            runStamplessJudge(now: now, into: &effects)
        }
    }

    /// A release that advertises sends the local size as part of handling
    /// this effect, so it counts from now: the stamp-less judge that runs
    /// next measures the window against the size on its way, inside its echo
    /// window, rather than against a size this connection never sent (a
    /// reattach or a foreground after a background resize). The adapter's
    /// `sizeAdvertised` report confirms it later.
    private mutating func noteReleaseAdvertises(now: Int64) {
        guard let local = evidence.localSize else { return }
        noteAdvertised(local, now: now)
        if reducer.claim == nil, case .mine = reducer.authority {
            evidence.owned.record(local)
        }
    }

    /// An advertisement is evidence of a size on its way, not ownership
    /// proved by a running claim. Only settlement records the claim's target.
    private mutating func noteAdvertised(_ size: TmuxGridSize, now: Int64) {
        lastAdvertisedSize = size
        lastAdvertisedAt = now
        stamplessJudge.forgetOwnedReplays(of: size)
    }

    /// Ends a contested gesture's `ownWriteWon` continuation.
    private mutating func dropOwnWriteContinuation() {
        contestedClaimStepAt = nil
        reducer.dropOwnWriteContinuation()
    }

    private mutating func evidenceChanged(now: Int64, into effects: inout [Effect]) {
        if query.held != nil { releaseHeldReply(final: false, now: now, into: &effects) }
        runStamplessJudge(now: now, into: &effects)
    }

    // MARK: - Stamp-less peer

    private mutating func runStamplessJudge(now: Int64, into effects: inout [Effect]) {
        if claimEndJudgement != nil {
            runClaimEndJudge(now: now, into: &effects)
            return
        }
        let window = evidence.judgedWindow.flatMap { window in
            window.size.map { TmuxStamplessPeerJudge.Edge(windowID: window.id, size: $0) }
        }
        var ownerMayReplay = false
        if case .mine = reducer.authority {
            ownerMayReplay = reducer.claim == nil && !heldForRead && channelIsLive && evidence.localSize != nil
        }
        let judged = TmuxStamplessPeerJudge.Evidence(
            blocked: hidden
                || inBackground
                || !reducer.channelAttached
                // A read pending in any form decides before the window's
                // size is evidence against this device (and its release
                // replays ours). One that settled without releasing the hold
                // blocks nothing: no later read would come to unblock it.
                || query.current != nil
                || query.held != nil
                || query.wanted
                || query.retryAt != nil
                || reducer.claim != nil
                || replay.parked != nil
                || ordinaryRecoveryActive,
            window: window,
            policyIsLatest: window.flatMap { evidence.policy(for: $0.windowID)?.isLatest },
            local: lastAdvertisedSize ?? evidence.localSize,
            alreadyPeer: reducer.authority.isPeer,
            lastLocalReplayAt: lastAdvertisedAt,
            owned: evidence.owned,
            ownerMayReplay: ownerMayReplay
        )
        switch stamplessJudge.judge(judged, now: now) {
        case .nothing:
            return
        case .replayOwnedGeometry:
            // L4 for a layout edge: one ordinary owner resize at the local
            // size, as the read path sends for `atLastOwnedSize`.
            noteReleaseAdvertises(now: now)
            effects.append(.releaseGeometry(.ownerReplay))
            return
        case .stamplessPeer:
            break
        }
        raiseStamplessPeer(now: now, into: &effects)
    }

    /// Rule 7 and settlement use the local grid, without the claim's replay
    /// suppression or its ordinary geometry hold. Only an outstanding read
    /// defers this one verdict. A parked failure is decided by replay instead.
    private mutating func runClaimEndJudge(now: Int64, into effects: inout [Effect]) {
        guard let ended = judgeClaimEnd(now: now, into: &effects) else { return }
        finishClaimEnd(ended, now: now, into: &effects)
    }

    private mutating func judgeClaimEnd(now: Int64, into effects: inout [Effect]) -> ClaimEndJudgement? {
        guard let ended = claimEndJudgement else { return nil }
        guard !hidden, !inBackground, reducer.channelAttached,
              reducer.claim == nil else {
            claimEndJudgement = nil
            return nil
        }
        // Retain the abort's membership if its parked replay expires instead
        // of starting another claim. Replay remains its only active mechanism.
        guard replay.parked == nil,
              query.current == nil, query.held == nil, query.retryAt == nil,
              !(ended.recoveryReadRequested && query.wanted) else { return nil }
        claimEndJudgement = nil
        let window = evidence.judgedWindow.flatMap { window in
            window.size.map { TmuxStamplessPeerJudge.Edge(windowID: window.id, size: $0) }
        }
        let judged = TmuxStamplessPeerJudge.Evidence(
            blocked: false,
            window: window,
            policyIsLatest: window.flatMap { evidence.policy(for: $0.windowID)?.isLatest },
            local: evidence.localSize,
            alreadyPeer: reducer.authority.isPeer,
            lastLocalReplayAt: nil,
            owned: evidence.owned
        )
        if stamplessJudge.judgeAfterClaimEnd(judged, abortedClaim: ended.abortedClaim, now: now) == .stamplessPeer {
            raiseStamplessPeer(now: now, into: &effects)
        }
        return ended
    }

    private mutating func finishClaimEnd(_ ended: ClaimEndJudgement, now: Int64, into effects: inout [Effect]) {
        // Rule 2's tail follows the verdict: never resize a peer's grid.
        if ended.settled, case .mine = reducer.authority,
           let local = evidence.localSize, let advertised = ended.lastAdvertisedSize,
           local != advertised,
           !effects.contains(where: { if case .releaseGeometry(let release) = $0 { return release != .none }; return false }) {
            guard channelIsLive else {
                requestRead(now: now, into: &effects)
                return
            }
            noteReleaseAdvertises(now: now)
            effects.append(.releaseGeometry(.ownerReplay))
        } else if !ended.settled, case .mine = reducer.authority, heldForRead, !ended.recoveryReadRequested {
            // A no-peer verdict must not strand ordinary geometry. Read once
            // to release it, preserving the abort's advertised exclusions.
            var pending = ended
            pending.recoveryReadRequested = true
            claimEndJudgement = pending
            requestRead(now: now, into: &effects)
        }
    }

    private mutating func raiseStamplessPeer(now: Int64, into effects: inout [Effect]) {
        let fallback = Reducer.stamplessPeer
        reduceLifecycle(now: now, into: &effects) {
            $0.observedAuthority(.peer(
                deviceID: fallback.deviceID,
                displayName: fallback.displayName,
                generation: fallback.generation
            ))
        }
    }

    // MARK: - Claim fence

    /// Whether the live claim's fence (`ClaimFence`) has settled, in any
    /// phase. An adapter that retired a confirmed claim's repaint (a layout
    /// changed its shape) re-arms it only while this holds.
    ///
    /// It gates the confirmation, not the stamp: a confirmed claim leaves its
    /// repaint phase only through a loss or a re-target (which drop the
    /// repaint) or the repaint itself, and each adapter checks the window
    /// against the target again before it stamps. A force at the claim's
    /// own target sent after the confirmation (a hydration's) can only keep
    /// the window there.
    ///
    /// Only a window tmux itself named active, in a hydrated list, is the
    /// fenced window's evidence: a model's provisional pick says nothing
    /// about where the fence landed.
    public var claimFenceSettled: Bool {
        guard let claim = reducer.claim,
              let fence = claimFence, fence.generation == claim.generation,
              fence.acknowledged, let latest = fence.policyIsLatest,
              let target = claim.targetGrid
        else { return false }
        guard latest else { return true }
        guard !fence.probeOffTarget, !fence.forceOutstanding,
              let window = evidence.judgedWindow, window.id == fence.windowID
        else { return false }
        return window.size == TmuxGridSize(columns: target.columns, rows: target.rows)
    }

    /// Confirms the live claim's fence (`ClaimFence`) once it has settled;
    /// a no-op otherwise. The repaint it requests follows from the
    /// reducer's `fenceSucceeded`.
    private mutating func confirmClaimFenceIfSettled(now: Int64, into effects: inout [Effect]) {
        guard let claim = reducer.claim, claim.phase == .awaitingFence, claimFenceSettled else { return }
        reduceLifecycle(now: now, into: &effects) { $0.fenceSucceeded(generation: claim.generation) }
    }

    // MARK: - Claim replay

    private mutating func attemptReplay(now: Int64, into effects: inout [Effect]) {
        let decision = replay.take(
            // Nothing begins a claim into the background (M6): a parked
            // gesture waits for the foreground as for a paintable surface.
            paintable: paintable && !inBackground,
            hidden: hidden,
            busy: reducer.claim != nil || reducer.pendingIntent != nil,
            authority: reducer.authority,
            now: now
        )
        switch decision {
        case .wait:
            break
        case .dropped:
            if !hidden, !inBackground, reducer.claim == nil, reducer.pendingIntent == nil,
               !reducer.authority.isPeer {
                requestRead(now: now, into: &effects)
            }
        // A replay is the same gesture: its intent and claim keep the
        // user's step, so R3 still ends it about 20 s after the user acted.
        case .show(let parked, let source):
            claimEndJudgement = nil
            reduceLifecycle(now: now, newIntentStep: parked.stepAt, into: &effects) { $0.shown(source: source) }
        case .takeBack(let parked):
            claimEndJudgement = nil
            let live = channelLive && !query.overdue
            reduceLifecycle(now: now, newIntentStep: parked.stepAt, into: &effects) {
                $0.requestTakeBack(channelLive: live)
            }
        }
    }

    // MARK: - Reducer plumbing

    /// Runs one reducer transition and translates its effects. The intent
    /// clock follows the reducer's pending intent; a new one starts its
    /// window at `newIntentStep` (the gesture's time) or now. Returns
    /// whether the reducer asked for an owned-geometry replay.
    @discardableResult
    private mutating func reduceLifecycle(
        now: Int64,
        newIntentStep: Int64? = nil,
        into effects: inout [Effect],
        _ body: (inout Reducer) -> [Reducer.Effect]
    ) -> Bool {
        let priorClaim = reducer.claim
        let priorIntentStep: Int64? = reducer.pendingIntent != nil && intentClock.token == reducer.pendingIntent?.token
            ? (intentClock.paused ? now : intentClock.stepAt)
            : nil
        let reduced = body(&reducer)
        intentClock.track(reducer.pendingIntent?.token, stepAt: newIntentStep ?? now)
        guard !reduced.isEmpty else { return false }
        var replayRequested = false
        for effect in reduced {
            switch effect {
            case .queryAuthority:
                requestRead(now: now, into: &effects)
            case .beginClaim(let claim):
                claimEndJudgement = nil
                claimFence = nil
                if claim.reason == .ownWriteWon, let contested = contestedClaimStepAt {
                    claimStepAt = contested
                } else {
                    claimStepAt = priorIntentStep ?? newIntentStep ?? now
                }
                contestedClaimStepAt = nil
                claimPresentation = claim.presentationVisible
                    ? ClaimPresentation(
                        generation: claim.generation,
                        deadline: now.clampedAdding(configuration.claimPresentationMillis)
                    )
                    : nil
                effects.append(.beginClaim(claim))
            case .requestRepaint(let generation):
                effects.append(.requestRepaint(generation: generation))
            case .commitAuthorityStamp(let generation):
                lastObservedStampRaw = nil
                effects.append(.commitAuthorityStamp(generation: generation))
            case .refenceClaim(let generation):
                effects.append(.refenceClaim(generation: generation))
            case .authorityChanged(let authority):
                effects.append(.authorityChanged(authority))
                if reducer.claim == nil,
                   case .peer(let deviceID, _, _) = authority,
                   deviceID == Reducer.stamplessPeer.deviceID {
                    effects.append(.raiseStamplessPeer)
                }
            case .hideReclaimPresentation:
                if reducer.claim == nil || reducer.claim?.presentationVisible == false {
                    claimPresentation = nil
                }
                effects.append(.hideReclaimPresentation)
            case .claimAborted(let reason):
                let stepAt = claimStepAt ?? now
                switch reason {
                case .contestedByPeer:
                    // A peer's verdict ends the gesture: never replayed. Its
                    // own stamp landing last continues it (`ownWriteWon`),
                    // except in a hidden or background session, which a
                    // claim (S4') can still be running in.
                    replay.reset()
                    if hidden || inBackground {
                        dropOwnWriteContinuation()
                    } else {
                        contestedClaimStepAt = stepAt
                    }
                case .adapterFailure:
                    if let priorClaim {
                        _ = replay.park(priorClaim, stepAt: stepAt, hidden: hidden, now: now)
                    }
                case .geometryLost:
                    replay.reset()
                case .superseded:
                    break
                case .transportReset:
                    // The next attach reads.
                    break
                }
                effects.append(.claimAborted(reason))
                // Replace the old abort reread with rule 7. A parked
                // adapter failure has exactly one mechanism: replay's fresh
                // read, even while it waits for a paintable surface.
                if reason != .transportReset {
                    claimEndJudgement = .init(abortedClaim: priorClaim, settled: false, lastAdvertisedSize: nil)
                }
            case .claimSettled(let generation):
                replay.reset()
                // M6: the foreground read releases a background settlement.
                // A dead channel retains the hold even before local churn;
                // healing reads once and releases the latest local grid.
                if !inBackground {
                    if channelIsLive { heldForRead = false }
                    else { requestRead(now: now, into: &effects) }
                }
                // The claim pushed this size and the server confirmed it.
                if let size = priorClaim?.targetGrid.map({ TmuxGridSize(columns: $0.columns, rows: $0.rows) })
                    ?? lastAdvertisedSize ?? evidence.localSize {
                    evidence.owned.record(size)
                }
                effects.append(.claimSettled(generation: generation))
                claimEndJudgement = .init(
                    abortedClaim: nil,
                    settled: true,
                    lastAdvertisedSize: priorClaim?.advertisedGrids.last.map { TmuxGridSize(columns: $0.columns, rows: $0.rows) }
                )
            case .replayOwnedGeometry:
                replayRequested = true
            }
        }
        // A claim that ends unsettled never releases the ordinary hold by
        // itself: rule 7 judges it, a peer's verdict leaves
        // the grid to that peer, and a transport reset to the next attach.
        if reducer.claim == nil {
            claimStepAt = nil
            claimPresentation = nil
            claimFence = nil
        }
        return replayRequested
    }

    // MARK: - Projection

    private mutating func derive() {
        let live = channelIsLive
        let presentation = TmuxGridAuthorityPresentation.derive(reducer: reducer, hidden: hidden, channelLive: live)
        if presentation != self.presentation { self.presentation = presentation }
        let lastKnown = TmuxGridAuthorityPresentation.lastKnownHolder(reducer: reducer)
        gatesTyping = presentation.gatesTyping(lastKnown: lastKnown)
        mutationRefusal = presentation.mutationRefusal(lastKnown: lastKnown)

        let hold: GeometryHold
        if reducer.claim != nil {
            hold = claimMayAdvertiseGeometry ? .owner : .withheld
        } else if hidden || heldForRead || inBackground {
            hold = .withheld
        } else {
            switch reducer.authority {
            case .mine: hold = .owner
            case .unknown: hold = .advertiseOnly
            case .peer: hold = .withheld
            }
        }
        geometryHold = hold

        var deadline = intentClock.deadline
        func consider(_ candidate: Int64?) {
            guard let candidate else { return }
            deadline = deadline.map { min($0, candidate) } ?? candidate
        }
        consider(claimPresentation?.deadline)
        consider(query.held?.deadline)
        if !query.overdue, let since = query.unansweredSince {
            consider(since.clampedAdding(configuration.queryOverdueMillis))
        }
        consider(query.retryAt)
        consider(stamplessJudge.nextDeadline)
        consider(replay.nextDeadline)
        nextDeadline = deadline
    }

    /// The unfinished show a successor session object in the same slot
    /// should resume (see `CarriedShow`), at `now`: a pending show or
    /// explicit open, a running show claim, or a parked show replay. While a
    /// prompt pauses the clock its step is `now`, since answering restarts
    /// the full window. A function of `now` rather than stored state, so an
    /// idle tick under a prompt stays a no-op.
    public func carriedShow(now: Int64) -> CarriedShow? {
        guard !hidden else { return nil }
        if let intent = reducer.pendingIntent {
            let stepAt = intentClock.paused ? now : intentClock.stepAt
            switch intent.source {
            case .show: return .init(source: .show, stepAt: stepAt)
            case .explicitOpen: return .init(source: .explicitOpen, stepAt: stepAt)
            case .tap: return nil
            }
        }
        if let claim = reducer.claim, let source = claim.reason.showSource {
            return .init(source: source, stepAt: claimStepAt ?? now)
        }
        if let parked = replay.parked, let source = parked.reason.showSource {
            return .init(source: source, stepAt: parked.stepAt)
        }
        return nil
    }

    /// The first non-empty line of a reply, trimmed.
    private static func firstValue(_ raw: String) -> String {
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

extension TmuxGridAuthorityLifecycleReducer.ClaimReason {
    /// The show a claim of this reason continues, or nil for a take-back.
    var showSource: TmuxGridAuthorityLifecycleReducer.ShowSource? {
        switch self {
        case .show: return .show
        case .explicitOpen: return .explicitOpen
        case .userTakeBack, .ownWriteWon: return nil
        }
    }
}

// MARK: - Diagnostics trace

public extension TmuxGridAuthoritySession {
    /// One bounded, privacy-neutral line for a reduction that changed
    /// something, identical on both platforms; nil for a no-op. Raw replies
    /// are never included.
    static func describeTransition(
        event: Event,
        before: Self,
        after: Self,
        effects: [Effect]
    ) -> String? {
        guard before != after || !effects.isEmpty else { return nil }
        var parts = ["event=\(event.traceLabel)"]
        func transition(_ name: String, _ old: String, _ new: String, always: Bool = false) {
            if old != new {
                parts.append("\(name)=\(old)->\(new)")
            } else if always {
                parts.append("\(name)=\(new)")
            }
        }
        transition("authority", before.reducer.authority.traceLabel, after.reducer.authority.traceLabel, always: true)
        transition("claim", before.reducer.claim.traceLabel, after.reducer.claim.traceLabel, always: true)
        if before.reducer.pendingIntent != nil || after.reducer.pendingIntent != nil {
            transition("intent", before.reducer.pendingIntent.traceLabel, after.reducer.pendingIntent.traceLabel, always: true)
        }
        if before.reducer.channelAttached != after.reducer.channelAttached || before.channelIsLive != after.channelIsLive {
            parts.append("channel=\(after.reducer.channelAttached ? (after.channelIsLive ? "live" : "stalled") : "down")")
        }
        transition("hidden", "\(before.hidden)", "\(after.hidden)")
        transition("presentation", before.presentation.traceLabel, after.presentation.traceLabel)
        transition("hold", before.geometryHold.rawValue, after.geometryHold.rawValue)
        transition("read", before.query.traceLabel, after.query.traceLabel)
        transition("fence", before.claimFence.traceLabel, after.claimFence.traceLabel)
        transition("replay", before.replay.traceLabel, after.replay.traceLabel)
        if before.intentClockPaused != after.intentClockPaused {
            parts.append("clock=\(after.intentClockPaused ? "paused" : "running")")
        }
        if !effects.isEmpty {
            parts.append("effects=[" + effects.map(\.traceLabel).joined(separator: ",") + "]")
        }
        return parts.joined(separator: " ")
    }
}

extension TmuxGridAuthoritySession.Event {
    /// A reply or failure for an authority read: tmux answered something.
    var answersARead: Bool {
        switch self {
        case .queryReplied, .queryFailed: return true
        default: return false
        }
    }
}

public extension TmuxGridAuthoritySession.Event {
    var traceLabel: String {
        switch self {
        case .attached: return "attached"
        case .resetTransport(let preserving): return "resetTransport(preservingPeer=\(preserving))"
        case .identityChanged: return "identityChanged"
        case .channelLiveness(let live): return "channelLiveness(\(live))"
        case .shown(let source, _): return "shown(\(source.rawValue))"
        case .adoptShown: return "adoptShown"
        case .hidden: return "hidden"
        case .requestTakeBack: return "requestTakeBack"
        case .cancelIntent: return "cancelIntent"
        case .userStep: return "userStep"
        case .prompt(let scope, let active): return "prompt(\(scope.rawValue) \(active ? "up" : "down"))"
        case .backgrounded: return "backgrounded"
        case .foregrounded: return "foregrounded"
        case .stampObserved: return "stampObserved"
        case .observedAuthority(let authority): return "observedAuthority(\(authority.traceLabel))"
        case .ownStampObserved(let generation): return "ownStampObserved(g\(generation))"
        case .queryReplied(let id, _): return "queryReplied(r\(id))"
        case .queryFailed(let id): return "queryFailed(r\(id))"
        case .windowFacts(let hydrated, let window):
            let label = window.map { "@\($0.id) \($0.size?.description ?? "-")\($0.authoritative ? "" : " provisional")" } ?? "none"
            return "windowFacts(\(hydrated ? "hydrated" : "hydrating") \(label))"
        case .localSize(let size): return "localSize(\(size?.description ?? "none"))"
        case .windowSizePolicyReplied(let windowID, _, let fenceID):
            return "windowSizePolicy(@\(windowID)\(fenceID.map { " f\($0)" } ?? ""))"
        case .sizeAdvertised(let size): return "sizeAdvertised(\(size))"
        case .ordinaryRecovery(let active, let proven):
            return active ? "ordinaryRecovery(started)" : "ordinaryRecovery(\(proven ? "proven" : "unproven"))"
        case .paintable(let value): return "paintable(\(value))"
        case .controlSessionChanged(let replaced): return "controlSessionChanged(\(replaced ? "switched" : "resolved"))"
        case .claimFenceSent(let generation, let windowID): return "claimFenceSent(g\(generation) @\(windowID))"
        // The 22-character wire event name has the shape of a bare mosh
        // key, so the diagnostic redactor would erase it. Keep the label short.
        case .claimFenceAcknowledged(let fenceID): return "claimFenceAck(f\(fenceID))"
        case .claimFenceForce(let fenceID, let outstanding):
            return "claimFenceForce(f\(fenceID) \(outstanding ? "outstanding" : "proven"))"
        case .confirmClaimFence: return "confirmClaimFence"
        case .claimAdvertisedGeometry(let generation, let size): return "claimAdvertisedGeometry(g\(generation) \(size))"
        case .claimObservedGeometry(let generation, let size, let probe): return "claimObservedGeometry(g\(generation) \(size) probe=\(probe))"
        case .claimGeometryLost(let generation): return "claimGeometryLost(g\(generation))"
        case .claimStalled(let generation, let progress): return "claimStalled(g\(generation) canProgress=\(progress))"
        case .repaintSucceeded(let generation): return "repaintSucceeded(g\(generation))"
        case .stampCommitSucceeded(let generation): return "stampCommitSucceeded(g\(generation))"
        case .settleClaim(let generation): return "settleClaim(g\(generation))"
        case .abortClaim(let generation, let reason): return "abortClaim(g\(generation) \(reason.wireName))"
        case .tick: return "tick"
        }
    }
}

public extension TmuxGridAuthoritySession.Effect {
    var traceLabel: String {
        switch self {
        case .queryAuthority(let id): return "queryAuthority(r\(id))"
        case .beginClaim(let claim):
            return "beginClaim(g\(claim.generation) \(claim.reason.rawValue) visible=\(claim.presentationVisible))"
        case .requestRepaint(let generation): return "requestRepaint(g\(generation))"
        case .commitAuthorityStamp(let generation): return "commitAuthorityStamp(g\(generation))"
        case .refenceClaim(let generation): return "refenceClaim(g\(generation))"
        case .authorityChanged(let authority): return "authorityChanged(\(authority.traceLabel))"
        case .hideReclaimPresentation: return "hideReclaimPresentation"
        case .claimAborted(let reason):
            if case .contestedByPeer(let peer) = reason { return "claimAborted(contestedByPeer \(peer.traceLabel))" }
            return "claimAborted(\(reason.wireName))"
        case .claimSettled(let generation): return "claimSettled(g\(generation))"
        case .releaseGeometry(let release): return "releaseGeometry(\(release.rawValue))"
        case .raiseStamplessPeer: return "raiseStamplessPeer"
        case .controlChannelUnresponsive: return "controlChannelUnresponsive"
        }
    }
}

public extension Optional where Wrapped == TmuxGridAuthoritySession.ClaimFence {
    /// `none`, or `f<id>(@<window>` plus `ack`, the policy it read
    /// (`latest`/`fixed`), `offTarget` and `force`, then `)`.
    var traceLabel: String {
        guard let fence = self else { return "none" }
        var label = "f\(fence.id)(@\(fence.windowID)"
        if fence.acknowledged { label += " ack" }
        if let latest = fence.policyIsLatest { label += latest ? " latest" : " fixed" }
        if fence.probeOffTarget { label += " offTarget" }
        if fence.forceOutstanding { label += " force" }
        return label + ")"
    }
}

public extension TmuxGridAuthoritySession.QueryTracker {
    /// `none`, or `r<id>` for the deciding read, `+held`, `+retry`,
    /// `+wanted`, `+overdue`.
    var traceLabel: String {
        var label = current.map { "r\($0.id)" } ?? "none"
        if let held { label += "+held(r\(held.readID))" }
        if retryAt != nil { label += "+retry\(failures)" }
        if wanted { label += "+wanted" }
        if overdue { label += "+overdue" }
        return label
    }
}

public extension TmuxAuthorityClaimReplay {
    /// `none`, or `parked(g<generation> <reason>)`, plus `x<count>` once any
    /// replay was spent.
    var traceLabel: String {
        var label = parked.map { "parked(g\($0.generation) \($0.reason.rawValue))" } ?? "none"
        if count > 0 { label += " x\(count)" }
        return label
    }
}
