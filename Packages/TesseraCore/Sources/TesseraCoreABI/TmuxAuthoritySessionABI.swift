import Foundation
import TmuxControlCore

/// Version 2 of the lifecycle ABI: the same `tessera_tmux_authority_lifecycle_*`
/// handle drives the whole show-rule session (`TmuxGridAuthoritySession`)
/// instead of the bare reducer. The session owns the authority reads, the
/// geometry hold, the intent clock, claim replay and the projection both
/// platforms render, so an adapter reports facts and performs effects.
///
/// - A handle accepts version 2 requests only; other versions are rejected
///   before mutation.
/// - Every request carries `nowMillis` on the adapter's one monotonic clock,
///   which keeps running while the device sleeps. The session owns no timer:
///   the adapter sends `tick` at `nextDeadlineMillis`.
/// - A reduction that changed nothing answers `{"version":2,"unchanged":true}`,
///   encoded once, so ticks and repeated facts cost no projection.
/// - `carriedShow` is evaluated at the request's `nowMillis`. An adapter that
///   replaces the session object reads it then, with `snapshot`.
enum TmuxAuthoritySessionWire {
    static let version = 2
    static let unchangedResponse = Data(#"{"version":2,"unchanged":true}"#.utf8)

    /// Applies `request` to `session` and returns the bounded response, or
    /// nil when the request is malformed or the response would not fit.
    /// The caller commits `session` only when this returns a response.
    static func reduce(
        _ session: inout TmuxGridAuthoritySession,
        _ request: TmuxAuthoritySessionRequest
    ) -> Data? {
        // Platform clocks count up from boot; a negative one is an adapter
        // bug, rejected before it can reach the session's arithmetic.
        guard request.version == version, let now = request.nowMillis, now >= 0 else { return nil }
        if request.event == "snapshot" {
            return encode(session, now: now, effects: [], trace: nil)
        }
        let events: [TmuxGridAuthoritySession.Event]
        if request.event == "stampObserved", let rawValues = request.rawValues {
            guard request.raw == nil, !rawValues.isEmpty else { return nil }
            events = rawValues.map { .stampObserved(raw: $0) }
        } else {
            guard request.rawValues == nil, let event = request.sessionEvent(now: now) else { return nil }
            events = [event]
        }
        let before = session
        var effects: [TmuxGridAuthoritySession.Effect] = []
        var traces: [String] = []
        // The first event's trace also shows an identity this request set.
        var firstPrior = before
        if let localDeviceID = request.localDeviceID {
            let previous = session.localDeviceID
            session.localDeviceID = localDeviceID
            // As iOS's identity setter does: what the old identity began
            // (its claim and fence, a held reply) ends before this event.
            if let previous, previous != localDeviceID {
                let changed = session
                let reduced = session.reduce(.identityChanged, now: now)
                effects.append(contentsOf: reduced)
                if let trace = TmuxGridAuthoritySession.describeTransition(
                    event: .identityChanged, before: changed, after: session, effects: reduced
                ) {
                    traces.append(trace)
                }
                firstPrior = session
            }
        }
        for (index, event) in events.enumerated() {
            let prior = index == 0 ? firstPrior : session
            let reduced = session.reduce(event, now: now)
            effects.append(contentsOf: reduced)
            if let trace = TmuxGridAuthoritySession.describeTransition(
                event: event, before: prior, after: session, effects: reduced
            ) {
                traces.append(trace)
            }
        }
        if effects.isEmpty, session == before { return unchangedResponse }
        return encode(session, now: now, effects: effects,
            trace: traces.isEmpty ? nil : traces.joined(separator: "\n"))
    }

    private static func encode(
        _ session: TmuxGridAuthoritySession,
        now: Int64,
        effects: [TmuxGridAuthoritySession.Effect],
        trace: String?
    ) -> Data? {
        encodeWithinBound(response(session, now: now, effects: effects.map(TmuxAuthoritySessionEffectDTO.init), trace: trace))
    }

    static func encodeWithinBound(_ response: TmuxAuthoritySessionResponse) -> Data? {
        guard let encoded = try? JSONEncoder().encode(response),
              encoded.count <= TmuxAuthorityLifecycleABI.maximumPayloadBytes
        else { return nil }
        return encoded
    }

    /// `response` with `trace`, or without it when that alone breaks the
    /// payload bound: a trace is a diagnostic, dropped before the state
    /// and effects are. Nil when even those do not fit.
    private static func boundedResponse(
        _ session: TmuxGridAuthoritySession,
        now: Int64,
        effects: [TmuxAuthoritySessionEffectDTO],
        trace: String?
    ) -> TmuxAuthoritySessionResponse? {
        let traced = response(session, now: now, effects: effects, trace: trace)
        if encodeWithinBound(traced) != nil { return traced }
        guard trace != nil else { return nil }
        let untraced = response(session, now: now, effects: effects, trace: nil)
        return encodeWithinBound(untraced) != nil ? untraced : nil
    }

    /// A feed's result its adapter never adopted, delivered again: the
    /// session's state now, with the effects and trace the lost one carried.
    /// The adapter judges each effect against that state, as it judges one
    /// a nested reduction may have superseded.
    static func redelivery(
        of lost: TmuxAuthoritySessionResponse,
        _ session: TmuxGridAuthoritySession,
        now: Int64
    ) -> TmuxAuthoritySessionResponse? {
        boundedResponse(session, now: now, effects: lost.effects, trace: lost.trace)
    }

    private static func response(
        _ session: TmuxGridAuthoritySession,
        now: Int64,
        effects: [TmuxAuthoritySessionEffectDTO],
        trace: String?
    ) -> TmuxAuthoritySessionResponse {
        let reducer = session.reducer.snapshot
        let authority = reducer.authority.dto
        return TmuxAuthoritySessionResponse(
            version: version,
            authorityKind: authority.kind,
            authorityDeviceID: authority.deviceID,
            authorityDisplayName: authority.displayName,
            authorityGeneration: authority.generation,
            claim: reducer.claim.map(TmuxAuthorityLifecycleClaimDTO.init),
            claimFence: session.claimFence.map(TmuxAuthoritySessionClaimFenceDTO.init),
            hasAttached: reducer.hasAttached,
            channelAttached: reducer.channelAttached,
            channelLive: session.channelIsLive,
            nextGeneration: reducer.nextGeneration,
            claimMayAdvertiseGeometry: session.claimMayAdvertiseGeometry,
            pendingIntent: reducer.pendingIntent.map(TmuxAuthorityLifecycleIntentDTO.init),
            hidden: session.hidden,
            presentation: .init(session.presentation),
            gatesTyping: session.gatesTyping,
            mutationRefusal: session.mutationRefusal?.rawValue,
            geometryHold: session.geometryHold.rawValue,
            carriedShow: session.carriedShow(now: now).map(TmuxAuthoritySessionCarriedShowDTO.init),
            nextDeadlineMillis: session.nextDeadline,
            currentQueryID: session.query.current?.id,
            effects: effects,
            trace: trace
        )
    }

    /// The reductions a runtime makes into its attached session while it
    /// feeds one read (`tessera_tmux_runtime_feed_at`), each at its step,
    /// answered together as `reduce` answers a batch: the final state,
    /// every effect in order and the traces joined.
    struct FeedPass {
        enum Outcome {
            case unchanged
            case changed(TmuxAuthoritySessionResponse)
            /// Past the payload bound even without its trace.
            case oversized
        }

        private let before: TmuxGridAuthoritySession
        private let now: Int64
        private var effects: [TmuxGridAuthoritySession.Effect] = []
        private var traces: [String] = []

        init(_ session: TmuxGridAuthoritySession, now: Int64) {
            before = session
            self.now = now
        }

        mutating func reduce(_ session: inout TmuxGridAuthoritySession, _ event: TmuxGridAuthoritySession.Event) {
            let prior = session
            let reduced = session.reduce(event, now: now)
            effects.append(contentsOf: reduced)
            if let trace = TmuxGridAuthoritySession.describeTransition(
                event: event, before: prior, after: session, effects: reduced
            ) {
                traces.append(trace)
            }
        }

        /// The pass's response. A trace is a diagnostic: one too long for
        /// the bound is dropped before the state and effects are.
        func outcome(_ session: TmuxGridAuthoritySession) -> Outcome {
            if effects.isEmpty, session == before { return .unchanged }
            return TmuxAuthoritySessionWire.boundedResponse(session, now: now,
                effects: effects.map(TmuxAuthoritySessionEffectDTO.init),
                trace: traces.isEmpty ? nil : traces.joined(separator: "\n")).map(Outcome.changed) ?? .oversized
        }
    }
}

/// Every field but `version` and `event` is optional on the wire; each event
/// requires the ones it names and rejects a request without them.
struct TmuxAuthoritySessionRequest: Decodable {
    let version: Int
    let event: String
    /// Required for every version 2 request; never negative.
    let nowMillis: Int64?
    /// Updates the session's stamp identity before the event when present.
    let localDeviceID: String?
    /// `stampObserved`: the raw subscription value.
    let raw: String?
    /// Batched subscription edges: reduce in arrival order in one Android ABI call.
    let rawValues: [String]?
    /// `ownStampObserved`, `claimFenceSent`, the claim acknowledgements,
    /// `settle` and `abort`.
    let generation: UInt64?
    /// `abort`: `adapterFailure` (the default, replayed for a gesture's
    /// claim), `superseded` (an unsent claim given up at a hide or cancel,
    /// never replayed) or `transportReset`.
    let reason: String?
    /// `observedAuthority`: `unknown`, `mine` or `peer`. A
    /// peer's device ID and name are bounded as the stamp parser bounds them
    /// (128 and 64 Characters); a longer one is rejected.
    let authorityKind: String?
    let authorityDeviceID: String?
    let authorityDisplayName: String?
    let authorityGeneration: UInt64?
    /// `resetTransport`; absent means false.
    let preservingPeer: Bool?
    /// `shown`: `show` (the default) or `explicitOpen`.
    let source: String?
    /// `shown`: the user's step, in `0...nowMillis`; absent means
    /// `nowMillis`.
    let stepAtMillis: Int64?
    /// `channelLiveness` (required).
    let channelLive: Bool?
    /// `prompt` (required): `session` or `connect`.
    let scope: String?
    /// `prompt` and `ordinaryRecovery` (required).
    let active: Bool?
    /// `ordinaryRecovery`; absent means false.
    let proven: Bool?
    /// `queryReplied` and `queryFailed` (required): the id from
    /// `queryAuthority`.
    let queryID: UInt64?
    /// `queryReplied` (required): the option's raw reply.
    let rawAuthorityValue: String?
    /// `windowFacts` (required).
    let windowListHydrated: Bool?
    /// `windowFacts`: the active window, absent when there is none; then no
    /// other window field may be present. `windowSizePolicyReplied`
    /// (required): the window the policy was read for. `claimFenceSent`
    /// (required): the window tmux names current when the fence runs.
    let windowID: Int?
    /// `windowFacts`: the active window's grid, both or neither.
    let windowColumns: Int?
    let windowRows: Int?
    /// `windowFacts`, required with `windowID`: tmux itself named the window
    /// active, rather than a model's provisional pick.
    let windowAuthoritative: Bool?
    /// `localSize` (both or neither; neither means unmeasured) and
    /// `sizeAdvertised`, `claimAdvertisedGeometry` and
    /// `claimObservedGeometry` (required).
    let columns: Int?
    let rows: Int?
    /// `claimObservedGeometry`; absent means false.
    let settleProbe: Bool?
    /// `claimStalled` (required).
    let canProgress: Bool?
    /// `windowSizePolicyReplied` (required): the option's raw reply.
    let rawPolicy: String?
    /// `paintable` (required).
    let paintable: Bool?
    /// `controlSessionChanged` (required).
    let replacedKnownSession: Bool?
    /// `claimFenceAcknowledged` and `claimFenceForce` (required), and
    /// `windowSizePolicyReplied` for a read queued behind that fence: the
    /// response's `claimFence.id`.
    let fenceID: UInt64?
    /// `claimFenceForce` (required): the force still awaits its proof.
    let outstanding: Bool?
}

struct TmuxAuthoritySessionClaimFenceDTO: Encodable {
    let generation: UInt64
    let id: UInt64
    let windowID: Int
    let acknowledged: Bool
    /// Absent until the fence's own policy read lands.
    let policyIsLatest: Bool?
    let probeOffTarget: Bool
    let forceOutstanding: Bool

    init(_ fence: TmuxGridAuthoritySession.ClaimFence) {
        generation = fence.generation
        id = fence.id
        windowID = fence.windowID
        acknowledged = fence.acknowledged
        policyIsLatest = fence.policyIsLatest
        probeOffTarget = fence.probeOffTarget
        forceOutstanding = fence.forceOutstanding
    }
}

struct TmuxAuthoritySessionPresentationDTO: Encodable {
    /// `none`, `resuming`, `veiled` or `reclaiming`.
    let kind: String
    let peerName: String?
    let awaitingConnection: Bool?

    init(_ presentation: TmuxGridAuthorityPresentation) {
        switch presentation {
        case .none:
            (kind, peerName, awaitingConnection) = ("none", nil, nil)
        case .resuming(let awaiting):
            (kind, peerName, awaitingConnection) = ("resuming", nil, awaiting)
        case .veiled(let name):
            (kind, peerName, awaitingConnection) = ("veiled", name, nil)
        case .reclaiming(let name, let awaiting):
            (kind, peerName, awaitingConnection) = ("reclaiming", name, awaiting)
        }
    }
}

struct TmuxAuthoritySessionCarriedShowDTO: Encodable {
    let source: String
    let stepAtMillis: Int64

    init(_ carried: TmuxGridAuthoritySession.CarriedShow) {
        source = carried.source.rawValue
        stepAtMillis = carried.stepAt
    }
}

struct TmuxAuthoritySessionEffectDTO: Encodable {
    let kind: String
    /// `queryAuthority`: tag the read with it and report its reply or
    /// failure with the same id.
    let queryID: UInt64?
    let generation: UInt64?
    /// `beginClaim`: the claim reason. `claimAborted`: the abort reason.
    let reason: String?
    let presentationVisible: Bool?
    /// `releaseGeometry`: `none`, `advertise` or `ownerReplay`.
    let release: String?
    let authorityKind: String?
    let authorityDeviceID: String?
    let authorityDisplayName: String?
    let authorityGeneration: UInt64?

    init(_ effect: TmuxGridAuthoritySession.Effect) {
        var kind: String
        var queryID: UInt64?
        var generation: UInt64?
        var reason: String?
        var presentationVisible: Bool?
        var release: String?
        var authority: (kind: String, deviceID: String?, displayName: String?, generation: UInt64?)?

        switch effect {
        case .queryAuthority(let id):
            kind = "queryAuthority"
            queryID = id
        case .beginClaim(let claim):
            kind = "beginClaim"
            generation = claim.generation
            reason = claim.reason.rawValue
            presentationVisible = claim.presentationVisible
        case .requestRepaint(let value):
            kind = "requestRepaint"
            generation = value
        case .commitAuthorityStamp(let value):
            kind = "commitAuthorityStamp"
            generation = value
        case .refenceClaim(let value):
            kind = "refenceClaim"
            generation = value
        case .authorityChanged(let snapshot):
            kind = "authorityChanged"
            authority = snapshot.dto
        case .hideReclaimPresentation:
            kind = "hideReclaimPresentation"
        case .claimAborted(let abort):
            kind = "claimAborted"
            reason = abort.wireName
            if case .contestedByPeer(let peer) = abort {
                authority = ("peer", peer.deviceID, peer.displayName, peer.generation)
            }
        case .claimSettled(let value):
            kind = "claimSettled"
            generation = value
        case .releaseGeometry(let value):
            kind = "releaseGeometry"
            release = value.rawValue
        case .raiseStamplessPeer:
            kind = "raiseStamplessPeer"
        case .controlChannelUnresponsive:
            kind = "controlChannelUnresponsive"
        }

        self.kind = kind
        self.queryID = queryID
        self.generation = generation
        self.reason = reason
        self.presentationVisible = presentationVisible
        self.release = release
        authorityKind = authority?.kind
        authorityDeviceID = authority?.deviceID
        authorityDisplayName = authority?.displayName
        authorityGeneration = authority?.generation
    }
}

struct TmuxAuthoritySessionResponse: Encodable {
    let version: Int
    let authorityKind: String
    let authorityDeviceID: String?
    let authorityDisplayName: String?
    let authorityGeneration: UInt64?
    let claim: TmuxAuthorityLifecycleClaimDTO?
    /// The live claim's latest fence and what it has proved; absent before
    /// its first fence and outside a claim.
    let claimFence: TmuxAuthoritySessionClaimFenceDTO?
    let hasAttached: Bool
    /// True between `attached` and `resetTransport`.
    let channelAttached: Bool
    /// Attached, not reported dead, and no read overdue: a read or a claim
    /// can be carried now.
    let channelLive: Bool
    let nextGeneration: UInt64
    /// §6.10 rule 2: a live claim with visible presentation may send geometry.
    let claimMayAdvertiseGeometry: Bool
    let pendingIntent: TmuxAuthorityLifecycleIntentDTO?
    let hidden: Bool
    let presentation: TmuxAuthoritySessionPresentationDTO
    /// Keys go to the shell only when this is false (M7).
    let gatesTyping: Bool
    /// `yielded` or `reclaiming` when a size or layout mutation must be
    /// refused (D7); absent when mutations may proceed.
    let mutationRefusal: String?
    /// `withheld`, `advertiseOnly` or `owner`.
    let geometryHold: String
    let carriedShow: TmuxAuthoritySessionCarriedShowDTO?
    /// When to send `tick`; absent when nothing is pending.
    let nextDeadlineMillis: Int64?
    /// The read whose reply decides; absent when none is outstanding. One
    /// reduction can replace a due retry with a newer read, so an adapter
    /// sends a `queryAuthority` only while its id is still this one.
    let currentQueryID: UInt64?
    let effects: [TmuxAuthoritySessionEffectDTO]
    /// `TmuxGridAuthoritySession.describeTransition`; absent for `snapshot`.
    let trace: String?
}

extension TmuxAuthoritySessionRequest {
    /// The event this request names, or nil when a field it requires is
    /// missing or malformed.
    func sessionEvent(now: Int64) -> TmuxGridAuthoritySession.Event? {
        switch event {
        case "attached":
            return .attached
        case "resetTransport":
            return .resetTransport(preservingPeer: preservingPeer ?? false)
        case "channelLiveness":
            return channelLive.map { .channelLiveness($0) }
        case "shown":
            let source: TmuxGridAuthorityLifecycleReducer.ShowSource
            switch self.source {
            case nil, "show": source = .show
            case "explicitOpen": source = .explicitOpen
            default: return nil
            }
            let stepAt = stepAtMillis ?? now
            // A step after `now`, or before the clock began, is an adapter
            // clock bug rather than a gesture.
            guard stepAt >= 0, stepAt <= now else { return nil }
            return .shown(source: source, stepAt: stepAt)
        case "adoptShown":
            return .adoptShown
        case "hidden":
            return .hidden
        case "requestTakeBack":
            return .requestTakeBack
        case "cancelIntent":
            return .cancelIntent
        case "userStep":
            return .userStep
        case "prompt":
            guard let scope = scope.flatMap(TmuxGridAuthoritySession.PromptScope.init(rawValue:)),
                  let active
            else { return nil }
            return .prompt(scope: scope, active: active)
        case "backgrounded":
            return .backgrounded
        case "foregrounded":
            return .foregrounded
        case "observedAuthority":
            return sessionAuthority.map { .observedAuthority($0) }
        case "stampObserved":
            return raw.map { .stampObserved(raw: $0) }
        case "ownStampObserved":
            return generation.map { .ownStampObserved(generation: $0) }
        case "queryReplied":
            guard let queryID, let rawAuthorityValue else { return nil }
            return .queryReplied(id: queryID, raw: rawAuthorityValue)
        case "queryFailed":
            return queryID.map { .queryFailed(id: $0) }
        case "windowFacts":
            guard let windowListHydrated else { return nil }
            guard let windowID else {
                guard windowColumns == nil, windowRows == nil, windowAuthoritative == nil else { return nil }
                return .windowFacts(hydrated: windowListHydrated, activeWindow: nil)
            }
            guard let windowAuthoritative,
                  case .some(let size) = Self.size(columns: windowColumns, rows: windowRows)
            else { return nil }
            return .windowFacts(
                hydrated: windowListHydrated,
                activeWindow: .init(id: windowID, size: size, authoritative: windowAuthoritative)
            )
        case "localSize":
            guard case .some(let size) = Self.size(columns: columns, rows: rows) else { return nil }
            return .localSize(size)
        case "windowSizePolicyReplied":
            guard let windowID, let rawPolicy else { return nil }
            return .windowSizePolicyReplied(windowID: windowID, raw: rawPolicy, fenceID: fenceID)
        case "sizeAdvertised":
            guard case .some(.some(let size)) = Self.size(columns: columns, rows: rows) else { return nil }
            return .sizeAdvertised(size)
        case "ordinaryRecovery":
            guard let active else { return nil }
            return .ordinaryRecovery(active: active, proven: proven ?? false)
        case "paintable":
            return paintable.map { .paintable($0) }
        case "controlSessionChanged":
            return replacedKnownSession.map { .controlSessionChanged(replacedKnownSession: $0) }
        case "claimFenceSent":
            guard let generation, let windowID else { return nil }
            return .claimFenceSent(generation: generation, windowID: windowID)
        case "claimFenceAcknowledged":
            return fenceID.map { .claimFenceAcknowledged(fenceID: $0) }
        case "claimFenceForce":
            guard let fenceID, let outstanding else { return nil }
            return .claimFenceForce(fenceID: fenceID, outstanding: outstanding)
        case "confirmClaimFence":
            return .confirmClaimFence
        case "claimAdvertisedGeometry":
            guard let generation, case .some(.some(let size)) = Self.size(columns: columns, rows: rows) else { return nil }
            return .claimAdvertisedGeometry(generation: generation, size: size)
        case "claimObservedGeometry":
            guard let generation, case .some(.some(let size)) = Self.size(columns: columns, rows: rows) else { return nil }
            return .claimObservedGeometry(generation: generation, size: size, settleProbe: settleProbe ?? false)
        case "claimGeometryLost":
            return generation.map { .claimGeometryLost(generation: $0) }
        case "claimStalled":
            guard let generation, let canProgress else { return nil }
            return .claimStalled(generation: generation, canProgress: canProgress)
        case "repaintSucceeded":
            return generation.map { .repaintSucceeded(generation: $0) }
        case "stampCommitSucceeded":
            return generation.map { .stampCommitSucceeded(generation: $0) }
        case "settle":
            return generation.map { .settleClaim(generation: $0) }
        case "abort":
            guard let generation else { return nil }
            let abortReason: TmuxGridAuthorityLifecycleReducer.AbortReason
            switch reason {
            case nil, "adapterFailure": abortReason = .adapterFailure
            case "superseded": abortReason = .superseded
            case "transportReset": abortReason = .transportReset
            // A contest is the session's own verdict, never an adapter's.
            default: return nil
            }
            return .abortClaim(generation: generation, reason: abortReason)
        case "tick":
            return .tick
        default:
            return nil
        }
    }

    /// A grid size given as both fields or neither: `.some(nil)` for
    /// neither, nil when only one is present or either is not positive.
    private static func size(columns: Int?, rows: Int?) -> TmuxGridSize?? {
        switch (columns, rows) {
        case (nil, nil):
            return .some(nil)
        case (let columns?, let rows?) where columns > 0 && rows > 0:
            return .some(TmuxGridSize(columns: columns, rows: rows))
        default:
            return nil
        }
    }

    private var sessionAuthority: TmuxGridAuthoritySnapshot? {
        switch authorityKind {
        case "unknown":
            return .unknown
        case "mine":
            return authorityGeneration.map { .mine(generation: $0) }
        case "peer":
            // The adapter's snapshot comes from the shared stamp parser,
            // which never yields more than these; a longer one is an adapter
            // bug that would otherwise surface as an oversized response.
            guard let authorityDeviceID, let authorityDisplayName, let authorityGeneration,
                  authorityDeviceID.count <= TmuxGridAuthorityStamp.maximumDeviceIDCharacters,
                  authorityDisplayName.count <= TmuxGridAuthorityStamp.maximumDisplayNameCharacters
            else { return nil }
            return .peer(deviceID: authorityDeviceID, displayName: authorityDisplayName, generation: authorityGeneration)
        default:
            return nil
        }
    }
}
