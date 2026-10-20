import Foundation
import TesseraSessionCore
import TmuxControlCore

/// Pack two positive 32-bit cell dimensions for the narrow JNI utility ABI.
/// Zero remains the invalid-input sentinel.
private func packedTmuxSize(columns: Int, rows: Int) -> UInt64 {
    (UInt64(UInt32(columns)) << 32) | UInt64(UInt32(rows))
}

/// The layout tree a compact client handed over: tmux's own cell grammar
/// without the checksum (`WxH,X,Y{…}`). Nil for no layout, for one over the
/// parser's cap (`WindowLayout.maxByteLength`, the only definition of that
/// limit: callers pass whatever they encoded), or for one that does not
/// parse; the sizing then falls back to the window/focus rectangles.
private func compactSizingLayout(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> WindowLayout? {
    guard let bytes, count > 0, count <= WindowLayout.maxByteLength else { return nil }
    return WindowLayout.parse(cellBytes: Array(UnsafeBufferPointer(start: bytes, count: count)))
}

private func compactSizingRect(columns: Int32, rows: Int32) -> CellRect? {
    columns > 0 && rows > 0
        ? .init(width: Int(columns), height: Int(rows), x: 0, y: 0)
        : nil
}

@_cdecl("tessera_tmux_compact_layout_client_size")
public func tesseraTmuxCompactLayoutClientSize(
    viewportColumns: Int32,
    viewportRows: Int32,
    layoutBytes: UnsafePointer<UInt8>?,
    layoutCount: Int,
    focusPaneID: Int32,
    windowColumns: Int32,
    windowRows: Int32,
    focusColumns: Int32,
    focusRows: Int32
) -> UInt64 {
    guard viewportColumns > 0, viewportRows > 0, layoutCount >= 0 else { return 0 }
    let size = TmuxCompactClientSizing.clientSize(
        viewport: (Int(viewportColumns), Int(viewportRows)),
        layout: compactSizingLayout(layoutBytes, layoutCount),
        focusPaneId: focusPaneID >= 0 ? PaneId(Int(focusPaneID)) : nil,
        windowRect: compactSizingRect(columns: windowColumns, rows: windowRows),
        focusRect: compactSizingRect(columns: focusColumns, rows: focusRows)
    )
    return packedTmuxSize(columns: size.columns, rows: size.rows)
}

/// `TmuxCompactClientSizing.reprojection`. `memo` points at the caller's two
/// opaque words (both 0 for a fresh tmux client), read and replaced on
/// success. Returns 0 hold, 1 reproject, 2 hold a stopped resize cycle, or 3
/// for the call that stopped it (2 thereafter, so a caller reports each stop
/// once), and -1 for invalid input with the memo untouched.
@_cdecl("tessera_tmux_compact_layout_reprojection")
public func tesseraTmuxCompactLayoutReprojection(
    viewportColumns: Int32,
    viewportRows: Int32,
    lastColumns: Int32,
    lastRows: Int32,
    layoutBytes: UnsafePointer<UInt8>?,
    layoutCount: Int,
    focusPaneID: Int32,
    windowColumns: Int32,
    windowRows: Int32,
    focusColumns: Int32,
    focusRows: Int32,
    memo: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    guard viewportColumns > 0, viewportRows > 0, layoutCount >= 0, let memo else { return -1 }
    let lastSize: (columns: Int, rows: Int)? = lastColumns > 0 && lastRows > 0
        ? (Int(lastColumns), Int(lastRows))
        : nil
    let before = TmuxCompactReprojectionMemo(rawValue: (memo[0], memo[1]))
    var updated = before
    let decision = TmuxCompactClientSizing.reprojection(
        viewport: (Int(viewportColumns), Int(viewportRows)),
        lastClientSize: lastSize,
        layout: compactSizingLayout(layoutBytes, layoutCount),
        focusPaneId: focusPaneID >= 0 ? PaneId(Int(focusPaneID)) : nil,
        windowRect: compactSizingRect(columns: windowColumns, rows: windowRows),
        focusRect: compactSizingRect(columns: focusColumns, rows: focusRows),
        memo: &updated
    )
    let words = updated.rawValue
    memo[0] = words.0
    memo[1] = words.1
    if decision == .holdCycle, !before.isHoldingCycle {
        return 3
    }
    return decision.rawValue
}

private struct TmuxABIBell: Codable {
    let windowID: WindowId
    let isActiveWindow: Bool
    let windowName: String?
}

/// One pane lifecycle payload from the `@tessera_agent_state` feed.
///
/// `json` is the remote hook's own frame and is never parsed here: this is a
/// carrier, and the same bytes reach Agent Center from the OSC transport.
private struct TmuxABIPaneAgentState: Codable {
    let windowID: WindowId
    let paneID: PaneId
    let json: String
}

private struct TmuxABIPlatformWireCommand: Codable {
    let tag: UInt64
    let command: String
}

/// Names one runtime snapshot: the engine revision within an epoch. A
/// replacement engine restarts its revision, and a resync must not be
/// mistaken for anything sent before it, so both move the epoch.
private struct TmuxABISnapshotKey: Codable, Equatable {
    let epoch: UInt64
    let revision: UInt64
}

private struct TmuxABIEvent: Encodable {
    /// 3: `snapshot` is elided when it has not changed since the last
    /// snapshot this handle queued (v2 repeated it in every event), and every
    /// envelope names its snapshot by `snapshotKey`.
    static let currentVersion = 3

    let version: Int
    /// Present only when the runtime snapshot changed since the last snapshot
    /// this handle put on the callback queue, and never on a wire-only event
    /// after the handle's first. An adapter keeps the last snapshot it decoded
    /// and reads an absent one as "the one I decoded under this same key".
    /// Encoding the whole topology in every `%output` event was the largest
    /// per-event cost on Android.
    let snapshot: TmuxSnapshot?
    /// The runtime's key when the event was emitted; `emit` stamps it on every
    /// envelope, so it is nil only before then. On a state event it names the
    /// snapshot the adapter holds once it has decoded the event, carried or
    /// not: a held snapshot under another key means a carrying event never
    /// reached the decoder, which must then ask for a resync. A wire-only
    /// event never carries the snapshot after the first, and the engine can
    /// move without emitting, so its key may be ahead of the held one and is
    /// not compared.
    let snapshotKey: TmuxABISnapshotKey?
    let bells: [TmuxABIBell]
    /// Lifecycle payloads tmux published for panes of the attached session.
    ///
    /// A client only paints the window it is showing, so output-scanned
    /// lifecycle covers one pane at a time. This feed is what lets a platform
    /// see an agent working in a window nobody is looking at.
    let agentStates: [TmuxABIPaneAgentState]
    /// Render work is an ordered, byte-free instruction list. `feed` effects
    /// retain their payloads inside this handle and name them by
    /// `RenderBytesRef`; putting the same payload in this JSON would base64
    /// expand large captures and reintroduce a second renderer input path.
    let renderEffects: [RenderEffect]
    /// Changed raw authority stamps, once each and in wire arrival order.
    /// Classification belongs to the shared authority session.
    let authorityStamps: [String]
    /// The attached authority session's response to what this read
    /// reduced in wire order (`tessera_tmux_runtime_feed_at`), shaped as
    /// `tessera_tmux_authority_lifecycle_reduce` answers. Absent when that
    /// changed nothing, and then `authorityStamps` is empty too.
    var authoritySession: TmuxAuthoritySessionResponse? = nil
    /// True when the attached session reduced this read's control-session
    /// changes, window facts and stamps at their steps: the adapter reports
    /// none of them again. Absent otherwise.
    var authorityReducedInFeed: Bool? = nil
    /// True when the control client moved from one known session to another
    /// during this read, reduced in the feed or not: the adapter resolves
    /// the new session's scope, hydrates and subscribes again (§6.18).
    var controlSessionSwitched: Bool? = nil
    let peerDepartureObserved: Bool
    /// Fixed topology queries the adapter must put on the control channel.
    /// tmux announces a created window and then never describes it, so the
    /// shared runtime asks; the reply is tagged and folds itself back in, so
    /// the adapter only transports the string. Empty in almost every batch.
    let topologyQueries: [String]
    /// `refresh-client -B` commands the adapter must put on the control
    /// channel in order, ignoring their replies: the feeds
    /// `set_subscriptions` asked for, registered as panes and windows appear
    /// and dropped as they close. Absent when empty, which is almost every
    /// event. A large change continues in further events.
    var subscriptionCommands: [String]? = nil
    /// Opt-in platform writes use the same callback queue as ledger writes.
    /// This field appears only in a platform-command-only event, which
    /// publishes no state of its own: adapters transport the commands, and
    /// decode nothing else except the snapshot a handle's first event may
    /// carry.
    let platformWireCommands: [TmuxABIPlatformWireCommand]?
    /// Test-only: the snapshot a v2 event would have carried, present only
    /// on a handle that `tesseraTmuxRuntimeEmbedTestOracleSnapshot` armed.
    /// Absent from every production envelope.
    var testOracleSnapshot: TmuxSnapshot? = nil
    /// OSC 7501 monitor revision, stamped on every envelope including shards.
    var programStatusRevision: UInt64 = 0

    var isWireOnly: Bool { platformWireCommands != nil }

    /// The envelope `emit` sends: stamped with the key it decided under and
    /// carrying the snapshot only when the adapter needs it.
    func stamped(
        snapshotKey: TmuxABISnapshotKey,
        programStatusRevision: UInt64,
        snapshot: TmuxSnapshot?,
        testOracleSnapshot: TmuxSnapshot?
    ) -> TmuxABIEvent {
        TmuxABIEvent(
            version: version,
            snapshot: snapshot,
            snapshotKey: snapshotKey,
            bells: bells,
            agentStates: agentStates,
            renderEffects: renderEffects,
            authorityStamps: authorityStamps,
            authoritySession: authoritySession,
            authorityReducedInFeed: authorityReducedInFeed,
            controlSessionSwitched: controlSessionSwitched,
            peerDepartureObserved: peerDepartureObserved,
            topologyQueries: topologyQueries,
            subscriptionCommands: subscriptionCommands,
            platformWireCommands: platformWireCommands,
            testOracleSnapshot: testOracleSnapshot,
            programStatusRevision: programStatusRevision
        )
    }
}

/// `RenderFact` owns its own small request schema because it is supplied to a
/// stateful handle rather than embedded in a versioned callback envelope.  Do
/// not accept an unversioned request: a stale Android adapter must fail before
/// it can advance the render ledger.
private struct TmuxABIRenderFactVersion: Decodable {
    let version: Int
}

/// The adapter-owned render-ledger switches, as the bits of
/// `tessera_tmux_runtime_set_render_ledger_options`. Each one names the
/// `TmuxRenderLedger.Configuration` field it sets; the rest of the ledger's
/// configuration is the core's and is not exposed.
struct TmuxABIRenderLedgerOptions: OptionSet, Equatable {
    let rawValue: UInt32

    static let suppressesUnchangedClientSizeReplay = Self(rawValue: 1 << 0)
    static let inlineClientSizeReplayBelongsToClaim = Self(rawValue: 1 << 1)
    static let pipelinesVisibleCapture = Self(rawValue: 1 << 2)
    static let defined: Self = [
        .suppressesUnchangedClientSizeReplay,
        .inlineClientSizeReplayBelongsToClaim,
        .pipelinesVisibleCapture,
    ]

    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Nil for any undefined bit: an adapter built against a later header
    /// must not have a switch it believes it set silently ignored.
    init?(exactly rawValue: UInt32) {
        guard rawValue & ~Self.defined.rawValue == 0 else { return nil }
        self.init(rawValue: rawValue)
    }

    func applied(to configuration: TmuxRenderLedger.Configuration) -> TmuxRenderLedger.Configuration {
        var configuration = configuration
        configuration.suppressesUnchangedClientSizeReplay = contains(.suppressesUnchangedClientSizeReplay)
        configuration.inlineClientSizeReplayBelongsToClaim = contains(.inlineClientSizeReplayBelongsToClaim)
        configuration.pipelinesVisibleCapture = contains(.pipelinesVisibleCapture)
        return configuration
    }
}

/// The result document of
/// `tessera_tmux_runtime_project_authority_releasing`: the render work
/// the authority projection released, in the order a callback would have carried it.
private struct TmuxABIClaimSettlement: Encodable {
    let renderEffects: [RenderEffect]
}

private final class CTmuxABIRuntime: @unchecked Sendable {
    /// The ABI callback is synchronous and a render-surface-state effect may
    /// synchronously submit its fact before that callback returns. A recursive
    /// operation lock therefore does two things an ordinary `NSLock` cannot:
    /// it preserves accepted-operation/callback order across threads and it
    /// permits that one-turn re-entry without deadlocking the control reader.
    ///
    /// Keeping this lock through `callback` is deliberate. Releasing it before
    /// emit lets a second feed publish later wire work first, which corrupts
    /// the command FIFO's tag ordering.
    private let lock = NSRecursiveLock()
    private var runtime: TmuxRuntimeEngine
    private var programStatus = ProgramStatusMonitor(answersQueries: false)
    /// Bumped at a transport reset and every resync, so a key from before
    /// either boundary can never match a later one.
    private var snapshotEpoch: UInt64 = 0
    private var currentSnapshotKey: TmuxABISnapshotKey {
        TmuxABISnapshotKey(epoch: snapshotEpoch, revision: runtime.revision)
    }
    /// The snapshot the adapter will hold once every queued payload has been
    /// delivered. A state event carries the snapshot only when it differs;
    /// nil forces the next one to carry it again.
    ///
    /// It is committed when a payload is queued, not when it is decoded: the
    /// JNI shim can drop a callback (thread attach or buffer allocation) and a
    /// decode can fail. Every envelope's `snapshotKey` lets the adapter notice
    /// that, and `resyncSnapshot` answers it.
    private var lastQueuedSnapshotKey: TmuxABISnapshotKey?
    /// Monotonic: some payload has carried a snapshot. A handle's first
    /// payload is always delivered synchronously, because no callback is
    /// running yet for it to queue behind, so from then on the adapter holds
    /// a snapshot and a wire-only event never needs one.
    private var hasQueuedSnapshot = false
    private var renderLedger = TmuxRenderLedger()
    /// The adapter's authority session, which `feed(_:nowMillis:)` reduces
    /// a read's stamps into. Kept, like the ledger, across transports.
    private var authoritySession: CTmuxAuthorityLifecycle?
    /// The last feed's session result, until the next feed or attach: the
    /// session has moved on whether or not the event reached the adapter,
    /// so one it never adopted is delivered again (`redeliverSessionResult`),
    /// over the session that produced it and no other.
    private final class RetainedSessionResult {
        let session: CTmuxAuthorityLifecycle
        let response: TmuxAuthoritySessionResponse
        /// The read switched sessions: the adapter's half of that switch
        /// (scope, hydration) was in the lost event too.
        let controlSessionSwitched: Bool

        init(session: CTmuxAuthorityLifecycle, response: TmuxAuthoritySessionResponse, controlSessionSwitched: Bool) {
            self.session = session
            self.response = response
            self.controlSessionSwitched = controlSessionSwitched
        }
    }

    private var retainedSessionResult: RetainedSessionResult?
    /// The snapshot revision this runtime last reduced into the hosted
    /// session (in a feed). Revisions only grow, so a read it left to the
    /// adapter leaves the snapshot past it.
    private var sessionReducedThroughRevision: UInt64?
    /// The hosted session already holds what the current snapshot says. An
    /// event outside a feed (a resync, a fact's) says so, or an adapter that
    /// lost the read's event would take its session change for a switch it
    /// never reduced and reset the session a second time.
    private var sessionHoldsSnapshot: Bool {
        authoritySession != nil && sessionReducedThroughRevision == runtime.snapshot.revision
    }
    /// Last parser snapshot known to describe a complete control connection.
    ///
    /// The parser itself is transport-scoped and is replaced after
    /// `transportLost`, but the render ledger is logical-session-scoped. Keep
    /// the last complete topology until the replacement parser has observed an
    /// active window again; otherwise the attach fact (and the policy facts
    /// which immediately follow it) would overwrite the ledger's retained
    /// owner target with the new parser's intentionally empty snapshot.
    private var ledgerSnapshot: TmuxSnapshot
    private var isAwaitingPostResetTopology = false
    private var controlModeDetector = TmuxControlModeDetector()
    private var inputModeDecided = false
    private struct RetainedRenderBytes {
        let bytes: [UInt8]
    }
    /// References that were actually delivered in an ABI callback. This
    /// prevents callers from guessing ledger-internal ids. Once promised, a
    /// ref remains readable until it is taken, the transport is lost, or the
    /// runtime handle is destroyed.
    private var retainedRenderBytes: [RenderBytesRef: RetainedRenderBytes] = [:]
    private var retainedRenderByteCount = 0
    /// A normal adapter consumes refs promptly after its callback. The byte
    /// budget protects a stalled or buggy consumer, but a ref that was already
    /// promised may never be evicted merely because later callbacks produced
    /// more refs: the public contract keeps it readable until take, transport
    /// loss, or handle destruction.
    private static let maximumRetainedRenderByteCount = 2 * SharedABI.maximumRenderBytes
    /// A byte-only limit does not bound metadata for tiny pane-output events.
    /// Keep a separate resource ceiling without evicting any ref already
    /// promised to the adapter.
    private static let maximumRetainedRenderReferenceCount = 4_096
    /// A re-entrant fact may create effects while its parent event callback is
    /// still borrowing bytes. Queue that next event instead of recursively
    /// invoking the callback: adapters retain their simple non-overlapping
    /// callback contract and the operation lock still makes the order FIFO.
    private struct PendingCallbackPayload {
        let data: Data
        let references: Set<RenderBytesRef>
        let transportGeneration: UInt64
        let platformCommandTags: Set<UInt64>
        /// Later payloads may have elided an unchanged snapshot on the strength
        /// of this one, so dropping it undelivered must force a resend.
        let carriesSnapshot: Bool
    }
    private struct PreparedEffects {
        let effects: [RenderEffect]
        let accepted: Bool
        var suppressedPaneBells: [TmuxBellEvent] = []
    }
    private var pendingCallbackPayloads: [PendingCallbackPayload] = []
    private var pendingCallbackByteCount = 0
    /// Re-entrant callbacks are deliberately queued, so they need their own
    /// bounded resource contract independent of retained render bytes.
    private static let maximumPendingCallbackPayloadCount = 4_096
    private static let maximumPendingCallbackByteCount = 8 * SharedABI.maximumInputBytes
    private var isDeliveringCallback = false
    /// Callback partitions belong to the transport that created their byte
    /// references. A re-entrant transport loss must suppress every not-yet-
    /// delivered partition from the old transport before it can expose refs
    /// that the loss edge has just revoked.
    private var callbackTransportGeneration: UInt64 = 0
    /// Render-ledger FIFO tag for the one coalesced authoritative order query.
    /// The tag, rather than arbitrary later output, decides when reconciliation
    /// may complete and when a dirty follow-up can be issued.
    private var orderRefreshTag: UInt64?
    /// Registry removal prevents new lookups; this flag also rejects a lookup
    /// that raced with removal and suppresses callback payloads queued by a
    /// re-entrant operation before destruction.
    private var isDestroyed = false
    private let callback: TesseraCoreABIEventCallback
    private let context: UnsafeMutableRawPointer?
    /// Test-only; see `TmuxABIEvent.testOracleSnapshot`.
    private var embedsTestOracleSnapshot = false

    init(
        callback: @escaping TesseraCoreABIEventCallback,
        context: UnsafeMutableRawPointer?
    ) {
        let runtime = TmuxRuntimeEngine()
        self.runtime = runtime
        programStatus.isEnabled = false
        ledgerSnapshot = runtime.snapshot
        self.callback = callback
        self.context = context
    }

    func setProgramStatusEnabled(_ enabled: Bool) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -2 }
        programStatus.isEnabled = enabled
        let prepared = prepare(renderLedger.reduce(
            .programStatusPaneOutput(enabled: enabled), snapshot: ledgerSnapshot
        ))
        guard !prepared.effects.isEmpty else { return prepared.accepted ? 0 : -1 }
        let emitted = emit(makeEvent(
            bells: [], renderEffects: prepared.effects,
            authorityStamps: [], peerDepartureObserved: false
        ))
        return prepared.accepted && emitted ? 0 : -1
    }

    /// Replace the feeds the runtime keeps registered. Whatever that changes
    /// for the panes already known goes out at once, in an event's
    /// `subscriptionCommands`; later topology changes ride feed events.
    func setSubscriptions(_ requests: TmuxSubscriptionRequests) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -2 }
        runtime.subscriptionRequests = requests
        return emitQueuedSubscriptionCommands() ? 0 : -1
    }

    /// Registrations grow with the pane count, so an event carries at most
    /// this many command bytes and the rest follow in events of their own.
    /// Escaped into JSON beside a snapshot, a chunk stays far below the
    /// 1 MiB callback ceiling.
    private static let subscriptionCommandBytesPerEvent = 64 * 1024

    /// Drain the runtime's queued registrations in bounded events. The queue
    /// lives in the runtime, so a drain from inside a callback (a reentrant
    /// `set_subscriptions`) takes the older commands first and order holds.
    private func emitQueuedSubscriptionCommands() -> Bool {
        while true {
            let commands = runtime.takePendingSubscriptionCommands(
                maximumBytes: Self.subscriptionCommandBytesPerEvent
            )
            guard !commands.isEmpty else { return true }
            guard emit(makeEvent(
                bells: [], renderEffects: [], authorityStamps: [],
                peerDepartureObserved: false, subscriptionCommands: commands
            )) else { return false }
        }
    }

    func copyProgramStatus(_ output: UnsafeMutablePointer<UInt8>?, capacity: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -2 }
        return ProgramStatusABIDocument(programStatus.snapshot()).copy(to: output, capacity: capacity)
    }

    func acknowledgeProgramStatus(paneID: Int64, through: UInt64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -2 }
        guard paneID >= 0, let pane = Int(exactly: paneID) else { return -1 }
        let before = programStatus.revision
        programStatus.acknowledge(terminal: .pane(PaneId(pane)), through: through)
        return programStatus.revision != before ? 1 : 0
    }

    enum FeedResult: Equatable {
        case rejected
        case accepted
        /// Accepted, and its event carried the attached session's result.
        case acceptedWithSessionResult
    }

    /// Feed one read. Given `nowMillis` on the session's clock, an attached
    /// authority session (`attachAuthoritySession`) reduces the read's stamp
    /// edges itself; otherwise the event carries them raw.
    func feed(_ data: Data, nowMillis: Int64? = nil) -> Bool {
        feedReporting(data, nowMillis: nowMillis) != .rejected
    }

    func feedReporting(_ data: Data, nowMillis: Int64?) -> FeedResult {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return .rejected }
        retainedSessionResult = nil
        let coreBytes: [UInt8]
        if inputModeDecided {
            coreBytes = Array(data)
        } else if data.first == 0x25 { // "%"
            // Recorded protocol traces and side-channel sockets can begin directly with a
            // control line, while an inline `tmux -CC` process emits the DCS prologue first.
            inputModeDecided = true
            coreBytes = Array(data)
        } else {
            let detection = controlModeDetector.feed(data)
            if detection.enteredControlMode { inputModeDecided = true }
            coreBytes = detection.controlBytes
        }
        guard !coreBytes.isEmpty else {
            return .accepted
        }
        let entry = runtime.snapshot
        let batch = runtime.feed(Data(coreBytes))
        let programStatusRevision = programStatus.revision
        programStatus.observe(batch: batch)
        let lastSwitch = Self.lastKnownSessionSwitch(in: batch, from: entry.sessionID)
        var stepsReduced: PreparedEffects?
        var sessionOutcome: TmuxAuthoritySessionWire.FeedPass.Outcome = .unchanged
        var hostingSession: CTmuxAuthorityLifecycle?
        if let nowMillis, let session = sessionReducingSteps(of: batch, at: nowMillis, entry: entry) {
            hostingSession = session
            _ = session.withSession { session in
                var pass = TmuxAuthoritySessionWire.FeedPass(session, now: nowMillis)
                var controlSession = entry.sessionID
                // Each change at its step, as iOS reports each message's
                // facts: an intermediate layout can resolve a held reply or
                // raise a stampless peer the read's last layout would not.
                // Past the budget a storm coalesces: the facts in force when
                // a stamp or an attach is judged, and the read's last.
                var factsBudget = Self.maximumWindowFactsChangesReducedPerRead
                func reportWindowFacts(of snapshot: TmuxSnapshot) {
                    let facts = TmuxAuthorityGeometryEvidence.WindowFacts(of: snapshot)
                    guard facts != session.evidence.windowFacts else { return }
                    factsBudget -= 1
                    pass.reduce(&session, .windowFacts(hydrated: facts.hydrated, activeWindow: facts.activeWindow))
                }
                stepsReduced = reduceSteps(of: batch, reducingStep: { step in
                    if step.snapshot.sessionID != controlSession {
                        let switched = controlSession != nil && step.snapshot.sessionID != nil
                        controlSession = step.snapshot.sessionID
                        pass.reduce(&session, .controlSessionChanged(replacedKnownSession: switched))
                        if switched {
                            // The adapter's re-attach after a switch, here at
                            // its step as iOS hydrates at the message: the new
                            // session's facts, then its attach read.
                            reportWindowFacts(of: step.snapshot)
                            pass.reduce(&session, .attached)
                        }
                    }
                    if step.authorityStamp != nil || factsBudget > 0 {
                        reportWindowFacts(of: step.snapshot)
                    }
                    if let raw = step.authorityStamp {
                        pass.reduce(&session, .stampObserved(raw: raw))
                    }
                    return session.reducer.authority
                }, finish: {
                    // After the steps: an order refresh's reply can hydrate
                    // the list once its step is in.
                    reportWindowFacts(of: runtime.snapshot)
                    return session.reducer.authority
                })
                sessionOutcome = pass.outcome(session)
            }
        }
        let reducedInWireOrder = stepsReduced != nil
        if reducedInWireOrder { sessionReducedThroughRevision = runtime.snapshot.revision }
        let prepared = stepsReduced ?? reduceSteps(of: batch)
        var renderEffects = prepared.effects
        takeOrderRefreshEffect().map { renderEffects.append($0) }
        let authoritySession: TmuxAuthoritySessionResponse?
        var sessionAccepted = true
        switch sessionOutcome {
        case .unchanged:
            authoritySession = nil
        case .changed(let response):
            authoritySession = response
        case .oversized:
            // Unreachable within the per-read bound: a few effects per edge.
            // The session has moved on without its adapter, which fences.
            authoritySession = nil
            sessionAccepted = false
        }
        // Retained before the event goes out: a callback that feeds or
        // attaches again forgets it, and its forgetting must stand.
        let retained = authoritySession.flatMap { response in
            hostingSession.map {
                RetainedSessionResult(session: $0, response: response, controlSessionSwitched: lastSwitch != nil)
            }
        }
        if let retained { retainedSessionResult = retained }
        // Raw pane bells duplicate the no-output client's bell subscription.
        var bells = batch.bells
        for bell in prepared.suppressedPaneBells {
            if let index = bells.firstIndex(of: bell) { bells.remove(at: index) }
        }
        // Ordinary monitor bytes have no platform work; avoid JSON/JNI per output.
        let monitorOutputOnly = renderLedger.isProgramStatusPaneOutput
            && batch.messages.allSatisfy { message in
                switch message {
                case .output, .extendedOutput, .bell: return true
                default: return false
                }
            }
            && bells.isEmpty && renderEffects.isEmpty && authoritySession == nil
            && programStatus.revision == programStatusRevision
            && runtime.snapshot.revision == entry.revision
        if monitorOutputOnly {
            return prepared.accepted && sessionAccepted ? .accepted : .rejected
        }
        let emitted = emit(makeEvent(
            bells: bells.map {
                TmuxABIBell(
                    windowID: $0.windowID,
                    isActiveWindow: $0.isActiveWindow,
                    windowName: $0.windowName
                )
            },
            agentStates: batch.agentStates.map {
                TmuxABIPaneAgentState(
                    windowID: $0.windowID,
                    paneID: $0.paneID,
                    json: $0.json
                )
            },
            renderEffects: renderEffects,
            // Stamps before the read's last switch spoke for a session the
            // switch reset: the adapter would reduce them over the new one.
            authorityStamps: reducedInWireOrder ? [] : lastSwitch.map { index in
                batch.orderedSteps[(index + 1)...].compactMap(\.authorityStamp)
            } ?? batch.authorityStamps,
            authoritySession: authoritySession,
            authorityReducedInFeed: reducedInWireOrder,
            controlSessionSwitched: lastSwitch != nil,
            peerDepartureObserved: batch.messages.contains { message in
                if case .clientDetached = message { return true }
                return false
            },
            topologyQueries: runtime.takePendingWindowDetailQueries(),
            subscriptionCommands: runtime.takePendingSubscriptionCommands(
                maximumBytes: Self.subscriptionCommandBytesPerEvent
            )
        )) && emitQueuedSubscriptionCommands()
        guard prepared.accepted, sessionAccepted, emitted else {
            if let retained, retainedSessionResult === retained { retainedSessionResult = nil }
            return .rejected
        }
        return retained == nil ? .accepted : .acceptedWithSessionResult
    }

    /// Deliver the last feed's session result again, with the session's
    /// state now, in a state event that carries the current snapshot (the
    /// lost event may have carried a newer one). For an adapter whose
    /// session did not adopt it during that feed: a dropped callback or an
    /// undecodable event. Only outside a callback, whose own reductions a
    /// queued answer would overtake.
    func redeliverSessionResult(nowMillis: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed, nowMillis >= 0, !isDeliveringCallback,
              let lost = retainedSessionResult,
              lost.session === authoritySession,
              let response = lost.session.withSession({ session in
                  TmuxAuthoritySessionWire.redelivery(of: lost.response, session, now: nowMillis)
              }) ?? nil
        else { return false }
        retainedSessionResult = nil
        snapshotEpoch &+= 1
        return emit(makeEvent(
            bells: [],
            renderEffects: [],
            authorityStamps: [],
            authoritySession: response,
            // Reduced in that feed: the adapter must not reduce its switch again.
            authorityReducedInFeed: true,
            controlSessionSwitched: lost.controlSessionSwitched,
            peerDepartureObserved: false
        ))
    }

    /// The attached session, when it should reduce this read in wire
    /// order, as iOS reduces each message: a read with stamp edges, or one
    /// that moved the topology (a session change, window facts). Not an
    /// output-only read, which says nothing to the session. Otherwise the
    /// adapter reduces the read's facts and edges after the whole read, as
    /// before:
    /// - a read re-entered from a callback would queue its response behind
    ///   that callback, which can reduce the session again first;
    /// - more edges than one session request carries, or more session
    ///   changes than a user makes (each resets the session and attaches it,
    ///   and the response must stay inside its bound).
    private func sessionReducingSteps(
        of batch: TmuxRuntimeBatch,
        at nowMillis: Int64,
        entry: TmuxSnapshot
    ) -> CTmuxAuthorityLifecycle? {
        guard nowMillis >= 0,
              let authoritySession,
              !isDeliveringCallback,
              batch.authorityStamps.count <= Self.maximumStampsReducedPerRead,
              Self.sessionChanges(in: batch, from: entry.sessionID) <= Self.maximumSessionChangesReducedPerRead,
              !batch.authorityStamps.isEmpty
                || batch.orderedSteps.contains(where: { $0.snapshot.revision != entry.revision })
                || runtime.snapshot.revision != entry.revision
        else { return nil }
        return authoritySession
    }

    private static func sessionChanges(in batch: TmuxRuntimeBatch, from entrySessionID: SessionId?) -> Int {
        var session = entrySessionID
        var changes = 0
        for step in batch.orderedSteps where step.snapshot.sessionID != session {
            changes += 1
            session = step.snapshot.sessionID
        }
        return changes
    }

    /// The step at which the read's last switch from one known control
    /// session to another took effect, if it had one.
    private static func lastKnownSessionSwitch(in batch: TmuxRuntimeBatch, from entrySessionID: SessionId?) -> Int? {
        var session = entrySessionID
        var last: Int?
        for (index, step) in batch.orderedSteps.enumerated() where step.snapshot.sessionID != session {
            if session != nil, step.snapshot.sessionID != nil { last = index }
            session = step.snapshot.sessionID
        }
        return last
    }

    /// Reduce every step of `batch` into the render ledger in wire order.
    /// Each step goes to `reduceStep` first, which reduces what it said to
    /// the hosting session and returns the session's verdict after it (nil:
    /// no session hosts this read); `finish` does the same once every step
    /// is in. A new verdict judges that step and every later one, and the
    /// work the ledger owed it is released there. The runtime publishes only
    /// the read's last verdict: an intermediate one would cost a topology
    /// rebuild and a snapshot nobody reads.
    private func reduceSteps(
        of batch: TmuxRuntimeBatch,
        reducingStep reduceStep: (TmuxRuntimeBatch.OrderedStep) -> TmuxGridAuthoritySnapshot? = { _ in nil },
        finish: () -> TmuxGridAuthoritySnapshot? = { nil }
    ) -> PreparedEffects {
        var renderEffects: [RenderEffect] = []
        var preparationAccepted = true
        var suppressedPaneBells: [TmuxBellEvent] = []
        // Steps were snapshotted under the authority the read began with.
        var authority = runtime.authority
        var projected: TmuxGridAuthoritySnapshot?
        defer { if let projected { _ = runtime.projectAuthority(projected) } }
        func judge(under verdict: TmuxGridAuthoritySnapshot?) {
            guard let verdict, verdict != authority else { return }
            authority = verdict
            projected = verdict
            ledgerSnapshot = retainedTopology(withAuthority: verdict)
            let released = prepare(renderLedger.noteAuthority(snapshot: ledgerSnapshot))
            renderEffects.append(contentsOf: released.effects)
            preparationAccepted = preparationAccepted && released.accepted
        }
        for step in batch.orderedSteps {
            judge(under: reduceStep(step))
            let snapshot = projected.map { Self.snapshot(step.snapshot, withAuthority: $0) } ?? step.snapshot
            if !isAwaitingPostResetTopology {
                ledgerSnapshot = snapshot
            } else if step.isActiveWindowAuthoritative,
                      let activeWindowID = step.snapshot.activeWindowID,
                      step.snapshot.windows.contains(where: { $0.id == activeWindowID }) {
                // Initial tmux notifications may be split across reads. Do not
                // let a session-only or window-only prefix erase the retained
                // target; only an accepted session-window notification or
                // fixed active query makes the replacement authoritative.
                ledgerSnapshot = snapshot
                isAwaitingPostResetTopology = false
            }
            if renderLedger.isProgramStatusPaneOutput,
               case .message(.bell(let paneID)) = step.event,
               let window = step.snapshot.windows.first(where: { window in
                   window.panes.contains { $0.id == PaneId(paneID) }
               }) {
                suppressedPaneBells.append(.init(
                    windowID: window.id, isActiveWindow: window.id == step.snapshot.activeWindowID,
                    windowName: window.name
                ))
            }
            let prepared = prepare(renderLedger.reduce(
                step.event,
                snapshot: ledgerSnapshot
            ))
            for effect in prepared.effects {
                if case .commandReply(let tag, let success, let lines, _) = effect,
                   tag == orderRefreshTag {
                    runtime.completeOrderRefresh(
                        succeeded: success && didIngestOrderRefresh(
                            lines: lines,
                            snapshot: step.snapshot
                        )
                    )
                    orderRefreshTag = nil
                }
            }
            renderEffects.append(contentsOf: prepared.effects)
            preparationAccepted = preparationAccepted && prepared.accepted
        }
        judge(under: finish())
        return .init(effects: renderEffects, accepted: preparationAccepted,
                     suppressedPaneBells: suppressedPaneBells)
    }

    /// Stamp edges one read may reduce in wire order: the adapter's own
    /// per-request batch (`SharedTmuxAuthoritySession.MAXIMUM_STAMPS_PER_REQUEST`),
    /// which keeps the read's one response well inside the session's bound.
    private static let maximumStampsReducedPerRead = 32
    private static let maximumSessionChangesReducedPerRead = 4
    /// Window-facts changes one read reports at their own steps before the
    /// rest coalesce; with the stamp bound, well inside the response bound.
    private static let maximumWindowFactsChangesReducedPerRead = 32

    /// See `tessera_tmux_runtime_attach_authority_session`.
    func attachAuthoritySession(_ session: CTmuxAuthorityLifecycle?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return false }
        authoritySession = session
        retainedSessionResult = nil
        sessionReducedThroughRevision = nil
        return true
    }

    /// Enqueue a platform-originated command in the same FIFO as ledger
    /// captures. The adapter must make this call and enqueue the physical wire
    /// write atomically under the same transport-order lock as every feed/fact
    /// admission that can emit `sendCommand`; it later receives the matching
    /// `commandReply(tag:...)` effect.
    func enqueuePlatformCommand(_ command: String) -> Int64? {
        guard !command.isEmpty,
              !command.utf8.contains(0)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return nil }
        let submission = renderLedger.enqueuePlatformCommand(command)
        return Int64(exactly: submission.tag)
    }

    func enqueuePlatformCommandList(_ commands: [String]) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed,
              let submission = renderLedger.enqueuePlatformCommandList(commands)
        else { return nil }
        return Int64(exactly: submission.tag)
    }

    /// Reserve and deliver the wire command in one ordered runtime operation.
    /// A fact submitted from a callback can already have reserved ledger FIFO
    /// entries while its callback is still queued. Delivering this command
    /// through that queue keeps physical writes in the same order as replies.
    func queuePlatformCommand(_ command: String) -> Int64? {
        guard !command.isEmpty, !command.utf8.contains(0) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return nil }
        let submission = renderLedger.enqueuePlatformCommand(command)
        return emitPlatformCommand(submission)
    }

    func queuePlatformCommandList(_ commands: [String]) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed,
              let submission = renderLedger.enqueuePlatformCommandList(commands)
        else { return nil }
        return emitPlatformCommand(submission)
    }

    private func emitPlatformCommand(_ submission: RenderCommandSubmission) -> Int64? {
        guard let tag = Int64(exactly: submission.tag) else {
            _ = renderLedger.cancelUnwrittenPlatformCommands(tags: [submission.tag])
            return nil
        }
        let emitted = emit(makeEvent(
            bells: [],
            renderEffects: [],
            authorityStamps: [],
            peerDepartureObserved: false,
            platformWireCommands: [.init(tag: submission.tag, command: submission.command)]
        ))
        guard emitted else {
            _ = renderLedger.cancelUnwrittenPlatformCommands(tags: [submission.tag])
            return nil
        }
        return tag
    }

    /// Reduce one platform observation. Facts are deliberately handled under
    /// the same operation lock as parser events, so a state reply cannot cross
    /// a later tmux response or an effect batch can never observe a half-applied
    /// ledger transition.
    func submit(_ fact: RenderFact) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return false }
        var effects: [RenderEffect]
        switch fact {
        case .unwrittenCommandsCancelled(let tags):
            guard renderLedger.cancelUnwrittenPlatformCommands(tags: tags) else { return false }
            // A reentrant caller may cancel a command before its queued wire
            // callback is delivered. Removing only its FIFO slot would leave
            // an uncorrelated physical write behind.
            let cancelledTags = Set(tags)
            pendingCallbackPayloads.removeAll { payload in
                guard !payload.platformCommandTags.isDisjoint(with: cancelledTags) else { return false }
                pendingCallbackByteCount -= payload.data.count
                // Unreachable today: a wire-only payload carries a snapshot
                // only as a handle's first payload, which is never queued.
                if payload.carriesSnapshot { lastQueuedSnapshotKey = nil }
                return true
            }
            return true
        case .reorderBegan(let token, let order):
            guard runtime.beginReorder(token: token, expecting: order) else { return false }
            effects = []
        case .reorderConfirmed(let token):
            guard runtime.confirmReorder(token: token) else { return false }
            effects = []
        case .reorderAbandoned(let token):
            guard runtime.abandonReorder(token: token) else { return false }
            effects = []
        case .orderRefreshCompleted:
            // This ABI owns the refresh command's render-ledger FIFO tag and
            // completes it from the matching reply in `feed`. An uncorrelated
            // platform fact could strand that FIFO entry or clear newer work.
            return false
        default:
            effects = renderLedger.reduce(fact, snapshot: ledgerSnapshot)
        }
        takeOrderRefreshEffect().map { effects.append($0) }
        switch fact {
        case .transportLost:
            programStatus.noteTransportLost()
            callbackTransportGeneration &+= 1
            discardAllRetainedRenderBytes()
            discardStalePendingCallbackPayloads()
        default:
            break
        }
        let prepared = prepare(effects)
        let emitted = emit(makeEvent(
            bells: [],
            renderEffects: prepared.effects,
            authorityStamps: [],
            peerDepartureObserved: false
        ))
        if case .transportLost = fact {
            // A replacement `tmux -CC` stream starts a new DCS/parser and
            // command-correlation lifetime.  Keep the render ledger itself:
            // its prior owners are exactly what make side-channel reattach to
            // the same window/pane emit a new epoch bind instead of treating
            // the old transcript as current.
            runtime.reset()
            sessionReducedThroughRevision = nil
            snapshotEpoch &+= 1
            orderRefreshTag = nil
            isAwaitingPostResetTopology = true
            controlModeDetector = TmuxControlModeDetector()
            inputModeDecided = false
        }
        return prepared.accepted && emitted
    }

    private func takeOrderRefreshEffect() -> RenderEffect? {
        guard orderRefreshTag == nil,
              let command = runtime.takePendingOrderRefreshCommand()
        else { return nil }
        let submission = renderLedger.enqueuePlatformCommand(command)
        orderRefreshTag = submission.tag
        return .sendCommand(command)
    }

    private func didIngestOrderRefresh(lines: [String], snapshot: TmuxSnapshot) -> Bool {
        TmuxRuntimeHydrationQuery.didIngestWindowList(lines: lines, snapshot: snapshot)
    }

    /// Two-pass raw copy-out for a byte ref emitted in a preceding effect.
    /// Querying (a null output pointer) never consumes the ref; a successful
    /// copy does. The ABI promises at most one public payload ceiling per ref.
    func takeRenderBytes(
        _ reference: RenderBytesRef,
        outputBytes: UnsafeMutablePointer<UInt8>?,
        outputCapacity: Int
    ) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -1 }
        guard let retained = retainedRenderBytes[reference],
              retained.bytes.count <= SharedABI.maximumRenderBytes,
              retained.bytes.count <= Int(Int32.max)
        else {
            removeRetainedRenderBytes(reference)
            return -1
        }
        let bytes = retained.bytes
        guard let outputBytes else { return Int32(bytes.count) }
        guard outputCapacity >= bytes.count else { return -1 }
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                outputBytes.update(
                    from: baseAddress.assumingMemoryBound(to: UInt8.self),
                    count: bytes.count
                )
            }
        }
        removeRetainedRenderBytes(reference)
        return Int32(bytes.count)
    }

    /// Stamp the event with the current snapshot key under the operation lock.
    private func emit(_ stateless: TmuxABIEvent) -> Bool {
        guard !isDestroyed else { return false }
        // The snapshot is attached here, not by the caller, because whether it
        // is needed depends on what the queue already promised the adapter,
        // and that is only committed once these payloads are accepted.
        let snapshotKey = currentSnapshotKey
        let carriesSnapshot = stateless.isWireOnly
            ? !hasQueuedSnapshot
            : snapshotKey != lastQueuedSnapshotKey
        let event = stateless.stamped(
            snapshotKey: snapshotKey,
            programStatusRevision: programStatus.revision,
            snapshot: carriesSnapshot ? runtime.snapshot : nil,
            testOracleSnapshot: embedsTestOracleSnapshot ? runtime.snapshot : nil
        )
        let eventReferences = renderReferences(in: event.renderEffects)
        guard let payloads = callbackPayloads(for: event) else {
            discardRetainedRenderBytes(eventReferences)
            return false
        }
        let payloadByteCount = payloads.reduce(into: 0) { total, payload in
            total += payload.data.count
        }
        guard payloads.count <= Self.maximumPendingCallbackPayloadCount - pendingCallbackPayloads.count,
              payloadByteCount <= Self.maximumPendingCallbackByteCount - pendingCallbackByteCount
        else {
            // The calling feed/fact returns rejected and the adapter fences
            // rather than allowing callback re-entry to allocate without a
            // bound. Refs from this rejected event were never promised.
            discardRetainedRenderBytes(eventReferences)
            return false
        }
        // Queue the complete partition before invoking the first callback.
        // Every referenced payload remains claimable after delivery until the
        // adapter takes it or the whole transport/handle lifetime ends.
        pendingCallbackPayloads.append(contentsOf: payloads)
        pendingCallbackByteCount += payloadByteCount
        if carriesSnapshot {
            lastQueuedSnapshotKey = snapshotKey
            hasQueuedSnapshot = true
        }
        guard !isDeliveringCallback else { return true }
        isDeliveringCallback = true
        defer { isDeliveringCallback = false }
        while !isDestroyed, !pendingCallbackPayloads.isEmpty {
            let payload = pendingCallbackPayloads.removeFirst()
            pendingCallbackByteCount -= payload.data.count
            payload.data.withUnsafeBytes { raw in
                callback(
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    context
                )
            }
            guard !isDestroyed else {
                pendingCallbackPayloads.removeAll(keepingCapacity: false)
                pendingCallbackByteCount = 0
                return false
            }
        }
        return true
    }

    /// Encode one logical callback event into one or more independently valid
    /// envelopes. The public 1 MiB ceiling applies per callback, while effect
    /// order and one-shot authority edges remain identical to the unsplit
    /// event.
    private func callbackPayloads(for event: TmuxABIEvent) -> [PendingCallbackPayload]? {
        if let payload = callbackPayload(for: event) { return [payload] }

        /// One-shot edges ride the first envelope of a split and are absent
        /// from every later one, exactly as they would be in an unsplit event.
        /// The snapshot rides with them: later envelopes inherit it, as an
        /// unchanged snapshot always is.
        func shard(
            bells: [TmuxABIBell],
            agentStates: [TmuxABIPaneAgentState],
            renderEffects: [RenderEffect],
            carriesOneShotEdges: Bool
        ) -> TmuxABIEvent {
            TmuxABIEvent(
                version: event.version,
                snapshot: carriesOneShotEdges ? event.snapshot : nil,
                snapshotKey: event.snapshotKey,
                bells: bells,
                agentStates: agentStates,
                renderEffects: renderEffects,
                authorityStamps: carriesOneShotEdges ? event.authorityStamps : [],
                authoritySession: carriesOneShotEdges ? event.authoritySession : nil,
                authorityReducedInFeed: carriesOneShotEdges ? event.authorityReducedInFeed : nil,
                controlSessionSwitched: carriesOneShotEdges ? event.controlSessionSwitched : nil,
                peerDepartureObserved:
                    carriesOneShotEdges && event.peerDepartureObserved,
                topologyQueries: carriesOneShotEdges ? event.topologyQueries : [],
                subscriptionCommands: carriesOneShotEdges ? event.subscriptionCommands : nil,
                platformWireCommands: carriesOneShotEdges ? event.platformWireCommands : nil,
                testOracleSnapshot: event.testOracleSnapshot,
                programStatusRevision: event.programStatusRevision
            )
        }

        func split(_ first: TmuxABIEvent, _ second: TmuxABIEvent) -> [PendingCallbackPayload]? {
            guard let head = callbackPayloads(for: first),
                  let tail = callbackPayloads(for: second)
            else { return nil }
            return head + tail
        }

        // Metadata is small and render work is not, so separating them first
        // usually ends the recursion in one step.
        if !event.renderEffects.isEmpty,
           !event.bells.isEmpty || !event.agentStates.isEmpty {
            return split(
                shard(
                    bells: event.bells,
                    agentStates: event.agentStates,
                    renderEffects: [],
                    carriesOneShotEdges: true
                ),
                shard(
                    bells: [],
                    agentStates: [],
                    renderEffects: event.renderEffects,
                    carriesOneShotEdges: false
                )
            )
        }

        if event.renderEffects.count > 1 {
            let midpoint = event.renderEffects.count / 2
            return split(
                shard(
                    bells: event.bells,
                    agentStates: event.agentStates,
                    renderEffects: Array(event.renderEffects[..<midpoint]),
                    carriesOneShotEdges: true
                ),
                shard(
                    bells: [],
                    agentStates: [],
                    renderEffects: Array(event.renderEffects[midpoint...]),
                    carriesOneShotEdges: false
                )
            )
        }

        if event.bells.count > 1 {
            let midpoint = event.bells.count / 2
            return split(
                shard(
                    bells: Array(event.bells[..<midpoint]),
                    agentStates: event.agentStates,
                    renderEffects: event.renderEffects,
                    carriesOneShotEdges: true
                ),
                shard(
                    bells: Array(event.bells[midpoint...]),
                    agentStates: [],
                    renderEffects: [],
                    carriesOneShotEdges: false
                )
            )
        }

        if event.agentStates.count > 1 {
            let midpoint = event.agentStates.count / 2
            return split(
                shard(
                    bells: event.bells,
                    agentStates: Array(event.agentStates[..<midpoint]),
                    renderEffects: event.renderEffects,
                    carriesOneShotEdges: true
                ),
                shard(
                    bells: [],
                    agentStates: Array(event.agentStates[midpoint...]),
                    renderEffects: [],
                    carriesOneShotEdges: false
                )
            )
        }

        if !event.bells.isEmpty, !event.agentStates.isEmpty {
            return split(
                shard(
                    bells: event.bells,
                    agentStates: [],
                    renderEffects: event.renderEffects,
                    carriesOneShotEdges: true
                ),
                shard(
                    bells: [],
                    agentStates: event.agentStates,
                    renderEffects: [],
                    carriesOneShotEdges: false
                )
            )
        }

        // A single effect, bell or lifecycle payload — or the snapshot itself
        // — exceeds the ABI limit; there is no lossless partition. The caller
        // receives a rejected feed and must fence/recover its control path.
        return nil
    }

    private func callbackPayload(for event: TmuxABIEvent) -> PendingCallbackPayload? {
        guard let encoded = try? SharedABI.encoder.encode(event),
              encoded.count <= SharedABI.maximumInputBytes
        else { return nil }
        return .init(
            data: encoded,
            references: renderReferences(in: event.renderEffects),
            transportGeneration: callbackTransportGeneration,
            platformCommandTags: Set(event.platformWireCommands?.map(\.tag) ?? []),
            carriesSnapshot: event.snapshot != nil
        )
    }

    private func renderReferences(in effects: [RenderEffect]) -> Set<RenderBytesRef> {
        Set(effects.compactMap { effect -> RenderBytesRef? in
            guard case .feed(_, _, let reference, _) = effect else { return nil }
            return reference
        })
    }

    enum ClaimSettlement {
        /// The canonical `TmuxABIClaimSettlement` document for the caller.
        case settled(Data)
        /// Bounded callback delivery refused the released work.
        case rejected
        case destroyed
    }

    /// Project the session's verdict and release what the ledger deferred
    /// while a peer held the grid (P7 repaints, P8 history). Called from a
    /// callback, the work queues behind its earlier FIFO slots and the
    /// returned document is empty; otherwise the adapter writes it under
    /// its transport-order lock. The next state event carries the projection.
    func projectAuthorityReleasingRenderWork(
        _ authority: TmuxGridAuthoritySnapshot,
        outputCapacity: Int
    ) -> ClaimSettlement {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return .destroyed }
        guard runtime.projectAuthority(authority) else {
            return settlement(TmuxABIClaimSettlement(renderEffects: []))
        }
        // Keep a replacement transport's retained target: projection changes
        // authority alone, including before it has named an active window.
        ledgerSnapshot = retainedTopology(withAuthority: authority)
        return releaseRenderWorkOwedToAuthority(outputCapacity: outputCapacity)
    }

    /// Hands the ledger the authority now in `ledgerSnapshot` and returns
    /// what it releases, or queues it behind the payloads a callback holds
    /// (see `projectAuthorityReleasingRenderWork`). Caller holds `lock`.
    private func releaseRenderWorkOwedToAuthority(outputCapacity: Int) -> ClaimSettlement {
        let nothingReleased = TmuxABIClaimSettlement(renderEffects: [])
        let prepared = prepare(renderLedger.noteAuthority(snapshot: ledgerSnapshot))
        guard !prepared.effects.isEmpty else { return settlement(nothingReleased) }
        let released = TmuxABIClaimSettlement(renderEffects: prepared.effects)
        if !isDeliveringCallback, prepared.accepted,
           let encoded = try? SharedABI.encoder.encode(released),
           encoded.count <= outputCapacity {
            return .settled(encoded)
        }
        // Inside a callback, or (unreachable today: the release carries no
        // payload and a handful of commands per surface) work that does not
        // fit the result: the ordinary queue delivers it. Outside a callback
        // that delivery happens before this call returns.
        let emitted = emit(makeEvent(
            bells: [],
            renderEffects: prepared.effects,
            authorityStamps: [],
            peerDepartureObserved: false
        ))
        guard emitted, prepared.accepted else { return .rejected }
        return settlement(nothingReleased)
    }

    /// The retained topology a replacement transport keeps until it names
    /// its active window, with `authority` in place of the one it carried.
    private func retainedTopology(withAuthority authority: TmuxGridAuthoritySnapshot) -> TmuxSnapshot {
        Self.snapshot(ledgerSnapshot, withAuthority: authority)
    }

    private static func snapshot(
        _ retained: TmuxSnapshot,
        withAuthority authority: TmuxGridAuthoritySnapshot
    ) -> TmuxSnapshot {
        TmuxSnapshot(
            sessionID: retained.sessionID,
            sessionName: retained.sessionName,
            activeWindowID: retained.activeWindowID,
            isActiveWindowAuthoritative: retained.isActiveWindowAuthoritative,
            windows: retained.windows,
            authority: authority,
            capabilities: retained.capabilities,
            isReorderPending: retained.isReorderPending,
            authoritativeWindowOrder: retained.authoritativeWindowOrder,
            isWindowListHydrated: retained.isWindowListHydrated,
            revision: retained.revision
        )
    }

    private func settlement(_ document: TmuxABIClaimSettlement) -> ClaimSettlement {
        guard let encoded = try? SharedABI.encoder.encode(document) else { return .rejected }
        return .settled(encoded)
    }

    /// See `tessera_tmux_runtime_set_render_ledger_options`. Only the
    /// adapter-owned switches change; any queued or in-flight render work
    /// keeps the decisions it was made under.
    @discardableResult
    func setRenderLedgerOptions(_ options: TmuxABIRenderLedgerOptions) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return false }
        renderLedger.updateConfiguration(options.applied(to: renderLedger.configuration))
        return true
    }

    /// Test seam: the ledger configuration the options produced.
    var renderLedgerConfiguration: TmuxRenderLedger.Configuration {
        lock.lock()
        defer { lock.unlock() }
        return renderLedger.configuration
    }


    /// The adapter cannot account for the snapshot it holds: a carrying event
    /// never reached its decoder or failed to decode, so every elided event
    /// after it would reuse an older snapshot until the revision next moved,
    /// which may be never. Answer with a state event that carries the current
    /// snapshot. Re-entered from a callback, it is queued behind the payloads
    /// already queued, so snapshots still reach the adapter in order.
    ///
    /// The epoch moves, rather than `lastQueuedSnapshotKey` merely being
    /// forgotten, so no later key can match one from before the request: if
    /// this answer is lost too, the next event still shows it. The answer has
    /// no effects and leaves every one-shot edge to the next real event.
    func resyncSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return false }
        snapshotEpoch &+= 1
        return emit(makeEvent(
            bells: [],
            renderEffects: [],
            authorityStamps: [],
            peerDepartureObserved: false
        ))
    }

    func embedTestOracleSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        embedsTestOracleSnapshot = true
    }

    /// Destruction is a callback-lifetime barrier. A concurrent caller waits
    /// for the operation lock held across callback delivery; a callback that
    /// destroys its own handle re-enters this recursive lock, suppresses every
    /// queued payload, and lets only the callback already on the stack finish.
    func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return }
        isDestroyed = true
        pendingCallbackPayloads.removeAll(keepingCapacity: false)
        pendingCallbackByteCount = 0
        discardAllRetainedRenderBytes()
    }

    private func makeEvent(
        bells: [TmuxABIBell],
        agentStates: [TmuxABIPaneAgentState] = [],
        renderEffects: [RenderEffect],
        authorityStamps: [String],
        authoritySession: TmuxAuthoritySessionResponse? = nil,
        authorityReducedInFeed: Bool? = nil,
        controlSessionSwitched: Bool = false,
        peerDepartureObserved: Bool,
        topologyQueries: [String] = [],
        subscriptionCommands: [String] = [],
        platformWireCommands: [TmuxABIPlatformWireCommand]? = nil
    ) -> TmuxABIEvent {
        TmuxABIEvent(
            version: TmuxABIEvent.currentVersion,
            snapshot: nil,
            snapshotKey: nil,
            bells: bells,
            agentStates: agentStates,
            renderEffects: renderEffects,
            authorityStamps: authorityStamps,
            authoritySession: authoritySession,
            // Outside a feed: whether the session holds this snapshot.
            authorityReducedInFeed: (authorityReducedInFeed ?? sessionHoldsSnapshot) ? true : nil,
            controlSessionSwitched: controlSessionSwitched ? true : nil,
            peerDepartureObserved: peerDepartureObserved,
            topologyQueries: topologyQueries,
            subscriptionCommands: subscriptionCommands.isEmpty ? nil : subscriptionCommands,
            platformWireCommands: platformWireCommands
        )
    }

    /// Move raw feed bytes out of the reducer immediately. One parser call may
    /// contain more than the ledger's bounded ref window; delaying this until
    /// the callback envelope is built would let later `%output` events evict
    /// earlier refs before the adapter ever had a chance to claim them.
    private func prepare(_ effects: [RenderEffect]) -> PreparedEffects {
        var accepted: [RenderEffect] = []
        var fullyAccepted = true
        for effect in effects {
            switch effect {
            case .feed(_, _, let reference, _):
                guard let bytes = renderLedger.takeRenderBytes(reference) else {
                    accepted.append(.diagnostic("render-ledger missing-bytes-ref id=\(reference.rawValue)"))
                    fullyAccepted = false
                    continue
                }
                guard bytes.count <= SharedABI.maximumRenderBytes else {
                    accepted.append(.diagnostic("render-ledger dropped-oversized-bytes count=\(bytes.count)"))
                    fullyAccepted = false
                    continue
                }
                guard retainRenderBytes(
                    reference: reference,
                    bytes: bytes
                ) else {
                    accepted.append(.diagnostic(
                        "render-ledger retained-resource-budget-exceeded bytes=\(bytes.count)"
                    ))
                    fullyAccepted = false
                    continue
                }
                accepted.append(effect)
            default:
                accepted.append(effect)
            }
        }
        return .init(effects: accepted, accepted: fullyAccepted)
    }

    private func retainRenderBytes(
        reference: RenderBytesRef,
        bytes: [UInt8]
    ) -> Bool {
        guard retainedRenderBytes[reference] == nil,
              bytes.count <= Self.maximumRetainedRenderByteCount
        else { return false }

        // Never evict a previously promised ref. If a broken
        // consumer exhausts either bounded resource budget, reject this new
        // batch; the adapter fences the desynchronised control channel, while
        // every ref from earlier accepted callbacks remains claimable.
        guard retainedRenderBytes.count < Self.maximumRetainedRenderReferenceCount,
              retainedRenderByteCount + bytes.count <= Self.maximumRetainedRenderByteCount
        else {
            return false
        }

        retainedRenderBytes[reference] = .init(bytes: bytes)
        retainedRenderByteCount += bytes.count
        return true
    }

    private func discardRetainedRenderBytes(_ references: Set<RenderBytesRef>) {
        guard !references.isEmpty else { return }
        for reference in references { removeRetainedRenderBytes(reference) }
    }

    private func removeRetainedRenderBytes(_ reference: RenderBytesRef) {
        guard let removed = retainedRenderBytes.removeValue(forKey: reference) else { return }
        retainedRenderByteCount -= removed.bytes.count
    }

    private func discardAllRetainedRenderBytes() {
        retainedRenderBytes.removeAll(keepingCapacity: true)
        retainedRenderByteCount = 0
    }

    private func discardStalePendingCallbackPayloads() {
        pendingCallbackPayloads.removeAll { payload in
            guard payload.transportGeneration != callbackTransportGeneration else { return false }
            // The adapter will never see this snapshot. Nothing still queued
            // relies on it (every queued payload is from the old transport),
            // but the next state event must not elide it.
            if payload.carriesSnapshot { lastQueuedSnapshotKey = nil }
            return true
        }
        pendingCallbackByteCount = pendingCallbackPayloads.reduce(into: 0) { total, payload in
            total += payload.data.count
        }
    }
}

private enum CTmuxABIRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var runtimes: [UInt: CTmuxABIRuntime] = [:]

    static func insert(_ runtime: CTmuxABIRuntime) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        runtimes[token] = runtime
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withRuntime<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ body: (CTmuxABIRuntime) -> T
    ) -> T? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        guard let runtime = runtimes[token] else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return body(runtime)
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) -> CTmuxABIRuntime? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        let runtime = runtimes.removeValue(forKey: token)
        lock.unlock()
        return runtime
    }
}

@_cdecl("tessera_tmux_runtime_create")
public func tesseraTmuxRuntimeCreate(
    callback: @escaping TesseraCoreABIEventCallback,
    context: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer {
    CTmuxABIRegistry.insert(CTmuxABIRuntime(callback: callback, context: context))
}

@_cdecl("tessera_tmux_runtime_feed")
public func tesseraTmuxRuntimeFeed(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> Int32 {
    guard let bytes, count > 0, count <= SharedABI.maximumInputBytes else { return -1 }
    guard let accepted = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.feed(Data(bytes: bytes, count: count))
    }) else { return -2 }
    return accepted ? 0 : -1
}

/// `tessera_tmux_runtime_feed` with the authority session's clock: an
/// attached session reduces the read's stamps in wire order.
@_cdecl("tessera_tmux_runtime_feed_at")
public func tesseraTmuxRuntimeFeedAt(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int,
    nowMillis: Int64
) -> Int32 {
    guard let bytes, count > 0, count <= SharedABI.maximumInputBytes, nowMillis >= 0 else { return -1 }
    guard let result = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.feedReporting(Data(bytes: bytes, count: count), nowMillis: nowMillis)
    }) else { return -2 }
    switch result {
    case .rejected: return -1
    case .accepted: return 0
    case .acceptedWithSessionResult: return 1
    }
}

/// See `tessera_tmux_runtime_redeliver_authority_result` in the header.
@_cdecl("tessera_tmux_runtime_redeliver_authority_result")
public func tesseraTmuxRuntimeRedeliverAuthorityResult(
    handle: UnsafeMutableRawPointer?,
    nowMillis: Int64
) -> Int32 {
    guard let redelivered = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.redeliverSessionResult(nowMillis: nowMillis)
    }) else { return -2 }
    return redelivered ? 0 : -1
}

/// See `tessera_tmux_runtime_attach_authority_session` in the header.
@_cdecl("tessera_tmux_runtime_attach_authority_session")
public func tesseraTmuxRuntimeAttachAuthoritySession(
    handle: UnsafeMutableRawPointer?,
    session: UnsafeMutableRawPointer?
) -> Int32 {
    let lifecycle = CTmuxAuthorityLifecycleRegistry.lifecycle(session)
    guard session == nil || lifecycle != nil else { return -1 }
    guard let attached = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.attachAuthoritySession(lifecycle)
    }), attached else { return -2 }
    return 0
}

/// Put a platform-originated command into the engine-owned response FIFO.
/// The positive return value is its reply tag; -1 rejects malformed command
/// text and -2 identifies a destroyed handle. The platform writes the same
/// text to its serialized control writer at the same locked admission edge.
@_cdecl("tessera_tmux_runtime_send_command")
public func tesseraTmuxRuntimeSendCommand(
    handle: UnsafeMutableRawPointer?,
    text: UnsafePointer<UInt8>?,
    count: Int
) -> Int64 {
    guard let command = SharedABI.requiredString(text, count),
          !command.utf8.contains(0)
    else { return -1 }
    guard let result: Int64? = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.enqueuePlatformCommand(command)
    }) else { return -2 }
    return result ?? -1
}

/// Opt-in ordered delivery; unlike send_command the adapter does not write
/// this text separately. The normal callback carries its exact reply tag.
@_cdecl("tessera_tmux_runtime_queue_command")
public func tesseraTmuxRuntimeQueueCommand(
    handle: UnsafeMutableRawPointer?,
    text: UnsafePointer<UInt8>?,
    count: Int
) -> Int64 {
    guard let command = SharedABI.requiredString(text, count),
          !command.utf8.contains(0)
    else { return -1 }
    guard let result: Int64? = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.queuePlatformCommand(command)
    }) else { return -2 }
    return result ?? -1
}

/// JSON array variants reserve one FIFO slot for the joined control line.
@_cdecl("tessera_tmux_runtime_send_command_list")
public func tesseraTmuxRuntimeSendCommandList(
    handle: UnsafeMutableRawPointer?,
    json: UnsafePointer<UInt8>?,
    count: Int
) -> Int64 {
    guard let data = SharedABI.requiredData(json, count),
          let commands = try? JSONDecoder().decode([String].self, from: data)
    else { return -1 }
    guard let result: Int64? = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.enqueuePlatformCommandList(commands)
    }) else { return -2 }
    return result ?? -1
}

@_cdecl("tessera_tmux_runtime_queue_command_list")
public func tesseraTmuxRuntimeQueueCommandList(
    handle: UnsafeMutableRawPointer?,
    json: UnsafePointer<UInt8>?,
    count: Int
) -> Int64 {
    guard let data = SharedABI.requiredData(json, count),
          let commands = try? JSONDecoder().decode([String].self, from: data)
    else { return -1 }
    guard let result: Int64? = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.queuePlatformCommandList(commands)
    }) else { return -2 }
    return result ?? -1
}

/// Submit one versioned, byte-free render fact. The engine folds it under the
/// same serialized operation lock as tmux wire events and emits any resulting
/// effects through the ordinary callback.
@_cdecl("tessera_tmux_runtime_submit_fact")
public func tesseraTmuxRuntimeSubmitFact(
    handle: UnsafeMutableRawPointer?,
    json: UnsafePointer<UInt8>?,
    count: Int
) -> Int32 {
    guard let data = SharedABI.requiredData(json, count),
          let version = try? JSONDecoder().decode(TmuxABIRenderFactVersion.self, from: data),
          version.version == 1,
          let fact = try? JSONDecoder().decode(RenderFact.self, from: data),
          let canonical = try? SharedABI.encoder.encode(fact),
          canonical == data
    else { return -1 }
    guard let accepted = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.submit(fact)
    }) else { return -2 }
    return accepted ? 0 : -1
}

/// Query then copy a retained feed payload. A null `out` queries its size and
/// leaves the reference live. A successful copy consumes it. The handle never
/// exposes a ref larger than the published ABI payload ceiling.
@_cdecl("tessera_tmux_runtime_take_render_bytes")
public func tesseraTmuxRuntimeTakeRenderBytes(
    handle: UnsafeMutableRawPointer?,
    bytesRef: UInt64,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard bytesRef > 0,
          bytesRef <= UInt64(Int64.max),
          outputCapacity >= 0
    else { return -1 }
    guard let result = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.takeRenderBytes(
            RenderBytesRef(bytesRef),
            outputBytes: outputBytes,
            outputCapacity: outputCapacity
        )
    }) else { return -2 }
    return result
}

/// Capacity and JSON are checked before the projection can change anything.
@_cdecl("tessera_tmux_runtime_project_authority_releasing")
public func tesseraTmuxRuntimeProjectAuthorityReleasing(
    handle: UnsafeMutableRawPointer?,
    authorityJSON: UnsafePointer<UInt8>?,
    authorityCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let outputBytes, outputCapacity >= SharedABI.maximumInputBytes,
          let data = SharedABI.requiredData(authorityJSON, authorityCount),
          let authority = try? JSONDecoder().decode(TmuxGridAuthoritySnapshot.self, from: data)
    else { return -1 }
    guard let outcome = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.projectAuthorityReleasingRenderWork(authority, outputCapacity: SharedABI.maximumInputBytes)
    }) else { return -2 }
    switch outcome {
    case .destroyed: return -2
    case .rejected: return -1
    case .settled(let document):
        return SharedABI.copyOut(Array(document), outputBytes, outputCapacity)
    }
}

/// See `tessera_tmux_runtime_set_render_ledger_options` in the header.
@_cdecl("tessera_tmux_runtime_set_render_ledger_options")
public func tesseraTmuxRuntimeSetRenderLedgerOptions(
    handle: UnsafeMutableRawPointer?,
    options: UInt32
) -> Int32 {
    guard let options = TmuxABIRenderLedgerOptions(exactly: options) else { return -1 }
    guard let accepted = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.setRenderLedgerOptions(options)
    }) else { return -2 }
    return accepted ? 0 : -1
}

/// Answer an adapter whose held snapshot no longer matches the stream's
/// `snapshotKey` with a state event that carries the current snapshot.
@_cdecl("tessera_tmux_runtime_resync_snapshot")
public func tesseraTmuxRuntimeResyncSnapshot(
    handle: UnsafeMutableRawPointer?
) -> Int32 {
    guard let accepted = CTmuxABIRegistry.withRuntime(handle, { runtime in
        runtime.resyncSnapshot()
    }) else { return -2 }
    return accepted ? 0 : -1
}

/// See `tessera_tmux_runtime_set_program_status_enabled` in the header.
@_cdecl("tessera_tmux_runtime_set_program_status_enabled")
public func tesseraTmuxRuntimeSetProgramStatusEnabled(handle: UnsafeMutableRawPointer?, enabled: Int32) -> Int32 {
    CTmuxABIRegistry.withRuntime(handle) { $0.setProgramStatusEnabled(enabled != 0) } ?? -2
}

/// See `tessera_tmux_runtime_set_subscriptions` in the header.
@_cdecl("tessera_tmux_runtime_set_subscriptions")
public func tesseraTmuxRuntimeSetSubscriptions(
    handle: UnsafeMutableRawPointer?, feeds: UInt32, authorityOwnerSessionID: Int64
) -> Int32 {
    let known: UInt32 = 0b1111
    guard feeds & ~known == 0, authorityOwnerSessionID >= -1,
          let owner = Int(exactly: authorityOwnerSessionID) else { return -1 }
    let requests = TmuxSubscriptionRequests(
        bell: feeds & 1 != 0,
        paneMetadata: feeds & 2 != 0,
        windowOrder: feeds & 4 != 0,
        authority: feeds & 8 == 0 ? nil : owner < 0 ? .ownSession : .owner(SessionId(owner))
    )
    return CTmuxABIRegistry.withRuntime(handle) { $0.setSubscriptions(requests) } ?? -2
}

/// See `tessera_tmux_runtime_copy_program_status` in the header.
@_cdecl("tessera_tmux_runtime_copy_program_status")
public func tesseraTmuxRuntimeCopyProgramStatus(
    handle: UnsafeMutableRawPointer?, outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    CTmuxABIRegistry.withRuntime(handle) { $0.copyProgramStatus(outputBytes, capacity: outputCapacity) } ?? -2
}

/// See `tessera_tmux_runtime_acknowledge_program_status` in the header.
@_cdecl("tessera_tmux_runtime_acknowledge_program_status")
public func tesseraTmuxRuntimeAcknowledgeProgramStatus(
    handle: UnsafeMutableRawPointer?, paneID: Int64, through: UInt64
) -> Int32 {
    CTmuxABIRegistry.withRuntime(handle) { $0.acknowledgeProgramStatus(paneID: paneID, through: through) } ?? -2
}

@_cdecl("tessera_tmux_runtime_destroy")
public func tesseraTmuxRuntimeDestroy(handle: UnsafeMutableRawPointer?) {
    CTmuxABIRegistry.remove(handle)?.destroy()
}

/// Test-only and deliberately not exported: every later envelope of this
/// handle also carries `testOracleSnapshot`, the snapshot a v2 event embedded
/// unconditionally, so a fuzz test can hold the elided stream to it.
/// Production never calls it, so the field never appears in its envelopes.
@discardableResult
func tesseraTmuxRuntimeEmbedTestOracleSnapshot(handle: UnsafeMutableRawPointer?) -> Bool {
    CTmuxABIRegistry.withRuntime(handle) { runtime in
        runtime.embedTestOracleSnapshot()
    } != nil
}

/// Test-only and deliberately not exported: the render-ledger configuration
/// a handle's options produced, so a test can prove the knob sets exactly the
/// fields it names.
func tesseraTmuxRuntimeRenderLedgerConfiguration(
    handle: UnsafeMutableRawPointer?
) -> TmuxRenderLedger.Configuration? {
    CTmuxABIRegistry.withRuntime(handle) { runtime in
        runtime.renderLedgerConfiguration
    }
}
