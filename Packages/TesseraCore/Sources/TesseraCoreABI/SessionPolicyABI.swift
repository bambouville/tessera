import Foundation
import TesseraSessionCore

/// The session-lifecycle seam: the foreground restore cohort, the terminal
/// resize coalescer, and the end-of-session / retry rules.
///
/// All three are pure state-in/state-out, so nothing here takes a handle. That
/// is deliberate — the platform already owns the clock, the store, and the
/// observable wrapper; what it must not own is a second copy of the decision.

// MARK: - Foreground restore cohort

/// One cohort entry, reduced to the two facts a verdict needs.
public struct ForegroundRestoreCandidateABI: Codable, Equatable, Sendable {
    public var liveSessionID: UUID
    public var persistedHostID: UUID?

    public init(liveSessionID: UUID, persistedHostID: UUID?) {
        self.liveSessionID = liveSessionID
        self.persistedHostID = persistedHostID
    }

    var core: ForegroundRestoreCandidate {
        ForegroundRestoreCandidate(
            liveSessionID: liveSessionID,
            persistedHostID: persistedHostID
        )
    }
}

/// The live facts about one running session.
///
/// `transportConfirmed` is null for a transport with no separate reachability
/// signal (SSH). Supplying `false` is what keeps a mosh session that is
/// `connected` but unreachable from being scored alive.
public struct ForegroundRestoreLiveStateABI: Codable, Equatable, Sendable {
    public var liveSessionID: UUID
    public var persistedHostID: UUID?
    public var state: RestoreLiveState
    public var transportConfirmed: Bool?

    public init(
        liveSessionID: UUID,
        persistedHostID: UUID?,
        state: RestoreLiveState,
        transportConfirmed: Bool? = nil
    ) {
        self.liveSessionID = liveSessionID
        self.persistedHostID = persistedHostID
        self.state = state
        self.transportConfirmed = transportConfirmed
    }

    var core: ForegroundRestoreLiveState {
        ForegroundRestoreLiveState(
            liveSessionID: liveSessionID,
            persistedHostID: persistedHostID,
            state: state,
            transportConfirmed: transportConfirmed
        )
    }
}

/// ```json
/// {"aliveFloorSeconds":0.75,
///  "candidate":{"liveSessionID":"…","persistedHostID":"…"},
///  "elapsedSinceWindowOpenedSeconds":1.2,
///  "live":{"liveSessionID":"…","persistedHostID":"…",
///          "state":"connected","transportConfirmed":false}}
/// ```
/// `live` is null when the session's tab is gone — which is a `dead` verdict,
/// because a transport death and a clean remote `exit` are indistinguishable
/// at this point and both want a reconnect offer.
public struct ForegroundRestoreVerdictABIRequest: Codable, Equatable, Sendable {
    public var candidate: ForegroundRestoreCandidateABI
    public var live: ForegroundRestoreLiveStateABI?
    public var elapsedSinceWindowOpenedSeconds: TimeInterval
    public var aliveFloorSeconds: TimeInterval

    public init(
        candidate: ForegroundRestoreCandidateABI,
        live: ForegroundRestoreLiveStateABI?,
        elapsedSinceWindowOpenedSeconds: TimeInterval,
        aliveFloorSeconds: TimeInterval
    ) {
        self.candidate = candidate
        self.live = live
        self.elapsedSinceWindowOpenedSeconds = elapsedSinceWindowOpenedSeconds
        self.aliveFloorSeconds = aliveFloorSeconds
    }
}

/// Classifies one cohort entry. Returns `dead` | `alive` | `pending` as UTF-8
/// under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_session_restore_verdict")
public func tesseraSessionRestoreVerdict(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ForegroundRestoreVerdictABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 8_192
    ) else { return -1 }
    let verdict = ForegroundRestoreCohort.verdict(
        for: request.candidate.core,
        live: request.live?.core,
        elapsedSinceWindowOpened: request.elapsedSinceWindowOpenedSeconds,
        aliveFloorSeconds: request.aliveFloorSeconds
    )
    return SharedABI.copyOut(verdict.rawValue, outputBytes, outputCapacity)
}

/// ```json
/// {"aliveFloorSeconds":0.75,
///  "cohort":[{"liveSessionID":"…","persistedHostID":"…"}],
///  "elapsedSinceWindowOpenedSeconds":1.2,
///  "live":[…],
///  "retiresDeadImmediately":true}
/// ```
/// `retiresDeadImmediately` is false under the `.ask` restore policy: there a
/// dead entry is *offered* rather than reconnected, so it keeps its cohort
/// place — and its snapshot protection — until the user answers.
public struct ForegroundRestoreEvaluateABIRequest: Codable, Equatable, Sendable {
    public var cohort: [ForegroundRestoreCandidateABI]
    public var live: [ForegroundRestoreLiveStateABI]
    public var elapsedSinceWindowOpenedSeconds: TimeInterval
    public var aliveFloorSeconds: TimeInterval
    public var retiresDeadImmediately: Bool

    public init(
        cohort: [ForegroundRestoreCandidateABI],
        live: [ForegroundRestoreLiveStateABI],
        elapsedSinceWindowOpenedSeconds: TimeInterval,
        aliveFloorSeconds: TimeInterval,
        retiresDeadImmediately: Bool
    ) {
        self.cohort = cohort
        self.live = live
        self.elapsedSinceWindowOpenedSeconds = elapsedSinceWindowOpenedSeconds
        self.aliveFloorSeconds = aliveFloorSeconds
        self.retiresDeadImmediately = retiresDeadImmediately
    }
}

/// `{"deadIDs":[…],"deadIndices":[…],"hasWork":true,"retiredIDs":[…]}`
///
/// `deadIndices` are positions in the supplied cohort, so a caller holding a
/// parallel array of its own snapshots can map back without assuming
/// `liveSessionID` is unique.
public struct ForegroundRestoreEvaluationABIResponse: Codable, Equatable, Sendable {
    public var deadIDs: [UUID]
    public var deadIndices: [Int]
    public var retiredIDs: [UUID]
    public var hasWork: Bool
}

/// Classifies a whole cohort in one pass. Returns the byte count under the
/// string contract, or -1 for invalid arguments.
@_cdecl("tessera_session_restore_evaluate")
public func tesseraSessionRestoreEvaluate(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ForegroundRestoreEvaluateABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let evaluation = ForegroundRestoreCohort.evaluate(
        cohort: request.cohort.map(\.core),
        live: request.live.map(\.core),
        elapsedSinceWindowOpened: request.elapsedSinceWindowOpenedSeconds,
        aliveFloorSeconds: request.aliveFloorSeconds,
        retiresDeadImmediately: request.retiresDeadImmediately
    )
    return SharedABI.copyOutJSON(
        ForegroundRestoreEvaluationABIResponse(
            deadIDs: evaluation.deadIDs,
            deadIndices: evaluation.deadIndices,
            retiredIDs: evaluation.retiredIDs,
            hasWork: evaluation.hasWork
        ),
        outputBytes,
        outputCapacity
    )
}

/// Whether the restore window is over. Returns `settled` | `backstop` | `open`
/// as UTF-8 under the string contract.
///
/// The backstop outranks settling, except under an unanswered restore prompt:
/// a sheet on screen is a verdict in progress, and ending the window under it
/// would strip the snapshots the sheet is offering while the user reads them.
@_cdecl("tessera_session_restore_window_closure")
public func tesseraSessionRestoreWindowClosure(
    remainingCohortCount: Int32,
    elapsedSinceWindowOpenedSeconds: Double,
    maxWindowSeconds: Double,
    hasUnansweredPrompt: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard remainingCohortCount >= 0 else { return -1 }
    let closure = ForegroundRestoreCohort.windowClosure(
        remainingCohortCount: Int(remainingCohortCount),
        elapsedSinceWindowOpened: elapsedSinceWindowOpenedSeconds,
        maxWindowSeconds: maxWindowSeconds,
        hasUnansweredPrompt: hasUnansweredPrompt != 0
    )
    return SharedABI.copyOut(closure.rawValue, outputBytes, outputCapacity)
}

/// How far the restore window's clock advances on one pass, in seconds.
///
/// A negative `lastChargeAtSeconds` means "no previous charge", which charges
/// nothing — the same as the Swift `nil`. Kotlin converts its millisecond
/// clock at the wrapper edge, per the core's seconds-as-Double rule.
@_cdecl("tessera_session_restore_charge_delta")
public func tesseraSessionRestoreChargeDelta(
    nowSeconds: Double,
    lastChargeAtSeconds: Double,
    hasLastChargeAt: Int32,
    isPrompting: Int32,
    maxTickSeconds: Double
) -> Double {
    ForegroundRestoreCohort.chargeDelta(
        nowSeconds: nowSeconds,
        lastChargeAtSeconds: hasLastChargeAt == 0 ? nil : lastChargeAtSeconds,
        isPrompting: isPrompting != 0,
        maxTickSeconds: maxTickSeconds
    )
}

/// What a snapshot write may do to the stored document. Returns `liveOnly` |
/// `keepCohort` | `mergeWithStored` as UTF-8 under the string contract.
@_cdecl("tessera_session_restore_persist_mode")
public func tesseraSessionRestorePersistMode(
    isActive: Int32,
    hasPreservedSnapshots: Int32,
    isWindowOpen: Int32,
    hasCohortEntries: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    let mode = ForegroundRestoreCohort.persistMode(
        isActive: isActive != 0,
        hasPreservedSnapshots: hasPreservedSnapshots != 0,
        isWindowOpen: isWindowOpen != 0,
        hasCohortEntries: hasCohortEntries != 0
    )
    return SharedABI.copyOut(mode.rawValue, outputBytes, outputCapacity)
}

/// `{"schemaVersion":1,"selectedSessionID":"…","sessionIDs":["…"]}`
public struct ForegroundRestoreDocumentABIRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionIDs: [UUID]
    public var selectedSessionID: UUID?

    public init(schemaVersion: Int, sessionIDs: [UUID], selectedSessionID: UUID?) {
        self.schemaVersion = schemaVersion
        self.sessionIDs = sessionIDs
        self.selectedSessionID = selectedSessionID
    }
}

/// One document-rule violation, flattened so Kotlin reads a tag plus at most
/// one payload rather than a Swift associated-value enum.
public struct ForegroundRestoreViolationABI: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unsupportedSchemaVersion
        case noSnapshots
        case tooManySnapshots
        case duplicateSessionID
        case selectedSessionNotPresent
    }

    public var kind: Kind
    public var count: Int?
    public var sessionID: UUID?
}

/// `{"isValid":false,"maxSnapshots":64,"schemaVersion":1,
///   "violations":[{"count":2,"kind":"tooManySnapshots"}]}`
///
/// `normalizedSelection` is present only when a selection survives.
///
/// `normalizedSelection` is the repair rule stated on its own: a dangling
/// selection is the one violation both platforms fix rather than reject,
/// because the sessions are still restorable and only the highlight is stale.
public struct ForegroundRestoreDocumentABIResponse: Codable, Equatable, Sendable {
    public var isValid: Bool
    public var violations: [ForegroundRestoreViolationABI]
    public var normalizedSelection: UUID?
    public var schemaVersion: Int
    public var maxSnapshots: Int
}

/// Validates a restore document against the shared rules. Returns the byte
/// count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_session_restore_document_rules")
public func tesseraSessionRestoreDocumentRules(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ForegroundRestoreDocumentABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let violations = ForegroundRestoreDocumentRules.violations(
        schemaVersion: request.schemaVersion,
        sessionIDs: request.sessionIDs,
        selectedSessionID: request.selectedSessionID
    ).map { violation -> ForegroundRestoreViolationABI in
        switch violation {
        case let .unsupportedSchemaVersion(version):
            return .init(kind: .unsupportedSchemaVersion, count: version, sessionID: nil)
        case .noSnapshots:
            return .init(kind: .noSnapshots, count: nil, sessionID: nil)
        case let .tooManySnapshots(count):
            return .init(kind: .tooManySnapshots, count: count, sessionID: nil)
        case let .duplicateSessionID(id):
            return .init(kind: .duplicateSessionID, count: nil, sessionID: id)
        case let .selectedSessionNotPresent(id):
            return .init(kind: .selectedSessionNotPresent, count: nil, sessionID: id)
        }
    }
    return SharedABI.copyOutJSON(
        ForegroundRestoreDocumentABIResponse(
            isValid: violations.isEmpty,
            violations: violations,
            normalizedSelection: ForegroundRestoreDocumentRules.normalizedSelection(
                sessionIDs: request.sessionIDs,
                selectedSessionID: request.selectedSessionID
            ),
            schemaVersion: ForegroundRestoreDocumentRules.currentSchemaVersion,
            maxSnapshots: ForegroundRestoreDocumentRules.maxSnapshots
        ),
        outputBytes,
        outputCapacity
    )
}

// MARK: - Foreground restore cold start

/// `{"hostID":"…","sessionID":"…"}` — one stored snapshot, reduced to what the
/// cold-start decision needs.
public struct ForegroundRestoreStartupCandidateABI: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var hostID: UUID

    public init(sessionID: UUID, hostID: UUID) {
        self.sessionID = sessionID
        self.hostID = hostID
    }

    var core: ForegroundRestoreStartupCandidate {
        ForegroundRestoreStartupCandidate(sessionID: sessionID, hostID: hostID)
    }
}

/// ```json
/// {"availableHostIDs":["…"],
///  "candidates":[{"hostID":"…","sessionID":"…"}],
///  "hasDocument":true,
///  "hostsLoaded":true,
///  "liveHostIDs":[],
///  "policy":"always",
///  "selectedSessionID":"…"}
/// ```
/// `hostsLoaded` and an empty `availableHostIDs` are deliberately separate
/// facts; collapsing them is the defect this call exists to end.
public struct ForegroundRestoreStartupABIRequest: Codable, Equatable, Sendable {
    public var candidates: [ForegroundRestoreStartupCandidateABI]
    public var hasDocument: Bool
    public var hostsLoaded: Bool
    public var availableHostIDs: [UUID]
    public var liveHostIDs: [UUID]
    public var selectedSessionID: UUID?
    public var policy: ForegroundRestorePolicy

    public init(
        candidates: [ForegroundRestoreStartupCandidateABI],
        hasDocument: Bool,
        hostsLoaded: Bool,
        availableHostIDs: [UUID],
        liveHostIDs: [UUID],
        selectedSessionID: UUID?,
        policy: ForegroundRestorePolicy
    ) {
        self.candidates = candidates
        self.hasDocument = hasDocument
        self.hostsLoaded = hostsLoaded
        self.availableHostIDs = availableHostIDs
        self.liveHostIDs = liveHostIDs
        self.selectedSessionID = selectedSessionID
        self.policy = policy
    }
}

/// `{"action":"restore","sessionIDs":["…"],"selectedSessionID":"…","skippedCount":1}`
/// or `{"action":"wait","reason":"hostsNotLoaded"}`.
///
/// A caller that treats `wait` as `skip` spends its one cold-start pass on a
/// question it could not yet answer — which is exactly how a launch racing the
/// host store cleared the document and restored nothing.
public struct ForegroundRestoreStartupABIResponse: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case wait
        case skip
        case restore
        case offer
    }

    public var action: Action
    public var reason: ForegroundRestoreStartupAction.Reason?
    public var sessionIDs: [UUID]
    public var selectedSessionID: UUID?
    public var skippedCount: Int
}

/// What a cold start should do, given everything it can see. Returns the byte
/// count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_session_restore_startup_action")
public func tesseraSessionRestoreStartupAction(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ForegroundRestoreStartupABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let action = ForegroundRestoreStartup.action(
        candidates: request.candidates.map(\.core),
        hasDocument: request.hasDocument,
        hostsLoaded: request.hostsLoaded,
        availableHostIDs: Set(request.availableHostIDs),
        liveHostIDs: Set(request.liveHostIDs),
        selectedSessionID: request.selectedSessionID,
        policy: request.policy
    )
    let response: ForegroundRestoreStartupABIResponse
    switch action {
    case let .wait(reason):
        response = .init(
            action: .wait, reason: reason, sessionIDs: [],
            selectedSessionID: nil, skippedCount: 0
        )
    case let .skip(reason):
        response = .init(
            action: .skip, reason: reason, sessionIDs: [],
            selectedSessionID: nil, skippedCount: 0
        )
    case let .restore(plan):
        response = .init(
            action: .restore, reason: nil, sessionIDs: plan.sessionIDs,
            selectedSessionID: plan.selectedSessionID, skippedCount: plan.skippedCount
        )
    case let .offer(plan):
        response = .init(
            action: .offer, reason: nil, sessionIDs: plan.sessionIDs,
            selectedSessionID: plan.selectedSessionID, skippedCount: plan.skippedCount
        )
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

/// The policy actually in force, given the shell being presented. Returns
/// `ask` | `always` | `never` as UTF-8 under the string contract, or -1 when
/// `stored_policy_bytes` is not one of those three.
@_cdecl("tessera_session_restore_effective_policy")
public func tesseraSessionRestoreEffectivePolicy(
    storedPolicyBytes: UnsafePointer<UInt8>?,
    storedPolicyCount: Int,
    usesCompactShell: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let raw = SharedABI.requiredString(storedPolicyBytes, storedPolicyCount),
          let stored = ForegroundRestorePolicy(rawValue: raw)
    else { return -1 }
    let effective = ForegroundRestorePresentation.effectivePolicy(
        stored: stored,
        usesCompactShell: usesCompactShell != 0
    )
    return SharedABI.copyOut(effective.rawValue, outputBytes, outputCapacity)
}

// MARK: - Foreground restore persist plan

/// ```json
/// {"cohortSessionIDs":["…"],
///  "currentSessionIDs":["…"],
///  "maxSnapshots":64,
///  "mode":"mergeWithStored",
///  "preferredSelection":"…",
///  "storedSelection":"…",
///  "storedSessionIDs":["…"]}
/// ```
public struct ForegroundRestorePersistPlanABIRequest: Codable, Equatable, Sendable {
    public var mode: ForegroundRestoreCohort.PersistMode
    public var currentSessionIDs: [UUID]
    public var cohortSessionIDs: [UUID]
    public var storedSessionIDs: [UUID]
    public var preferredSelection: UUID?
    public var storedSelection: UUID?
    public var maxSnapshots: Int

    public init(
        mode: ForegroundRestoreCohort.PersistMode,
        currentSessionIDs: [UUID],
        cohortSessionIDs: [UUID],
        storedSessionIDs: [UUID],
        preferredSelection: UUID?,
        storedSelection: UUID?,
        maxSnapshots: Int
    ) {
        self.mode = mode
        self.currentSessionIDs = currentSessionIDs
        self.cohortSessionIDs = cohortSessionIDs
        self.storedSessionIDs = storedSessionIDs
        self.preferredSelection = preferredSelection
        self.storedSelection = storedSelection
        self.maxSnapshots = maxSnapshots
    }
}

/// `{"entries":[{"sessionID":"…","source":"stored"}],"selectedSessionID":"…"}`
///
/// `source` tells the caller which of its own three collections to take the
/// record from. The core never sees the records themselves: they carry display
/// names, launch modes and tmux targets that mean nothing here.
public struct ForegroundRestorePersistPlanABIResponse: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionID: UUID
        public var source: ForegroundRestorePersistSource
    }

    public var entries: [Entry]
    public var selectedSessionID: UUID?
}

/// What one snapshot write contains, and what it selects. Returns the byte
/// count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_session_restore_persist_plan")
public func tesseraSessionRestorePersistPlan(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ForegroundRestorePersistPlanABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let entries = ForegroundRestorePersistPlan.entries(
        mode: request.mode,
        currentSessionIDs: request.currentSessionIDs,
        cohortSessionIDs: request.cohortSessionIDs,
        storedSessionIDs: request.storedSessionIDs,
        maxSnapshots: request.maxSnapshots
    )
    let selection = ForegroundRestorePersistPlan.selection(
        mode: request.mode,
        preferred: request.preferredSelection,
        writtenSessionIDs: entries.map(\.sessionID),
        storedSelection: request.storedSelection
    )
    return SharedABI.copyOutJSON(
        ForegroundRestorePersistPlanABIResponse(
            entries: entries.map { .init(sessionID: $0.sessionID, source: $0.source) },
            selectedSessionID: selection
        ),
        outputBytes,
        outputCapacity
    )
}

// MARK: - Terminal resize coalescer

/// The coalescer's whole state, carried across the ABI so the core stays
/// handle-free.
///
/// `{"lastDelivered":{"cols":80,"rows":24},"pending":null}`
public struct TerminalResizeCoalescerStateABI: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable {
        public var cols: Int
        public var rows: Int

        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }

        var core: TerminalResizeCoalescer.Size {
            TerminalResizeCoalescer.Size(cols: cols, rows: rows)
        }

        init(_ core: TerminalResizeCoalescer.Size) {
            self.init(cols: core.cols, rows: core.rows)
        }
    }

    public var lastDelivered: Size?
    public var pending: Size?

    public init(lastDelivered: Size? = nil, pending: Size? = nil) {
        self.lastDelivered = lastDelivered
        self.pending = pending
    }

    /// `TerminalResizeCoalescer`'s fields are `private(set)`, so the state is
    /// rebuilt by replaying it rather than assigned. `note` on a fresh
    /// coalescer sends and latches; a second `note` of the pending size parks
    /// it — the same two transitions that produced the state in the first
    /// place.
    ///
    /// Nil for a state the coalescer cannot actually reach, because replaying
    /// one would answer a different question than the caller asked. A wait
    /// with nothing delivered would replay as a *first* size and come back as
    /// `send`, and a wait for the delivered size would come back as `drop` —
    /// both plausible-looking answers to a state that never existed. A caller
    /// that reached one has a bug worth surfacing, not smoothing over.
    var core: TerminalResizeCoalescer? {
        var coalescer = TerminalResizeCoalescer()
        guard let lastDelivered else {
            return pending == nil ? coalescer : nil
        }
        _ = coalescer.note(lastDelivered.core)
        if let pending {
            guard pending != lastDelivered else { return nil }
            _ = coalescer.note(pending.core)
        }
        return coalescer
    }

    init(_ core: TerminalResizeCoalescer) {
        self.init(
            lastDelivered: core.lastDelivered.map(Size.init),
            pending: core.pending.map(Size.init)
        )
    }
}

/// `{"decision":"wait","state":{"lastDelivered":{…},"pending":{…}}}`
///
/// `decision` carries `TerminalResizeCoalescer.Decision`'s raw value —
/// `send` | `wait` | `drop`. The core enum is deliberately not made `Codable`
/// from here: a retroactive conformance on another module's type is exactly
/// the kind of second definition this boundary exists to prevent.
public struct TerminalResizeCoalescerNoteABIResponse: Codable, Equatable, Sendable {
    public var decision: String
    public var state: TerminalResizeCoalescerStateABI
}

/// `{"settled":true,"state":{…}}`
public struct TerminalResizeCoalescerSettleABIResponse: Codable, Equatable, Sendable {
    public var settled: Bool
    public var state: TerminalResizeCoalescerStateABI
}

/// `{"size":{"cols":80,"rows":24},"state":{…}}`
public struct TerminalResizeCoalescerABIRequest: Codable, Equatable, Sendable {
    public var state: TerminalResizeCoalescerStateABI
    public var size: TerminalResizeCoalescerStateABI.Size

    public init(
        state: TerminalResizeCoalescerStateABI,
        size: TerminalResizeCoalescerStateABI.Size
    ) {
        self.state = state
        self.size = size
    }
}

/// Notes a size the terminal view reported.
///
/// Returns `send` (nothing delivered yet — the session cannot start without
/// it), `wait` (hold for the settle window), or `drop` (the size came back to
/// what the remote already has), plus the new state. The first size SENDs; a
/// platform that schedules it instead has drifted.
@_cdecl("tessera_session_resize_note")
public func tesseraSessionResizeNote(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        TerminalResizeCoalescerABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 4_096
    ) else { return -1 }
    guard var coalescer = request.state.core else { return -1 }
    let decision = coalescer.note(request.size.core)
    return SharedABI.copyOutJSON(
        TerminalResizeCoalescerNoteABIResponse(
            decision: decision.rawValue,
            state: TerminalResizeCoalescerStateABI(coalescer)
        ),
        outputBytes,
        outputCapacity
    )
}

/// Settles an expired wait. `settled: false` means the wait was superseded, so
/// a stale timer cannot deliver an old size.
@_cdecl("tessera_session_resize_settle")
public func tesseraSessionResizeSettle(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        TerminalResizeCoalescerABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 4_096
    ) else { return -1 }
    guard var coalescer = request.state.core else { return -1 }
    let settled = coalescer.settle(request.size.core)
    return SharedABI.copyOutJSON(
        TerminalResizeCoalescerSettleABIResponse(
            settled: settled,
            state: TerminalResizeCoalescerStateABI(coalescer)
        ),
        outputBytes,
        outputCapacity
    )
}

/// The settle window in seconds (0.12). Long enough to swallow a modal's
/// 28 ms shrink-and-restore, short enough that a real resize is not
/// perceptibly late. A platform must take the window from here rather than
/// keep its own constant.
@_cdecl("tessera_session_resize_settle_seconds")
public func tesseraSessionResizeSettleSeconds() -> Double {
    TerminalResizeCoalescer.settleSeconds
}

// MARK: - End of session and retry

/// Whether the remote process itself ended, as opposed to the transport
/// carrying it.
///
/// `hasExitStatus == 0` is EOF-without-status: recoverable transport loss, so
/// the session stays reconnectable and its restore record stays. Any status —
/// including 0 — is a genuine remote exit. Returns 1, 0, or -1.
@_cdecl("tessera_session_remote_process_ended")
public func tesseraSessionRemoteProcessEnded(
    exitStatus: Int32,
    hasExitStatus: Int32
) -> Int32 {
    SessionEndClassification.remoteProcessEnded(
        exitStatus: hasExitStatus == 0 ? nil : Int(exitStatus)
    ) ? 1 : 0
}

/// Whether a session that ended this way keeps its restore record — the
/// inverse of a remote exit, spelled out because that is the decision the
/// persistence layer actually makes. Returns 1 or 0.
@_cdecl("tessera_session_retains_restore_record")
public func tesseraSessionRetainsRestoreRecord(
    exitStatus: Int32,
    hasExitStatus: Int32
) -> Int32 {
    SessionEndClassification.retainsRestoreRecord(
        exitStatus: hasExitStatus == 0 ? nil : Int(exitStatus)
    ) ? 1 : 0
}

/// Native mosh's two end events, which a single exit-status integer cannot
/// tell apart. Returns 1 or 0.
///
/// `isShutdownCompletion == 0` is a transport stop: the client noticed its own
/// socket stopped, which carries no authenticated remote-shell status, so the
/// `mosh-server` on the far side is still there to be re-attached. A shutdown
/// *completion* is client and server agreeing the session is over, and does
/// retire the restore record.
@_cdecl("tessera_session_mosh_remote_process_ended")
public func tesseraSessionMoshRemoteProcessEnded(isShutdownCompletion: Int32) -> Int32 {
    let ended = isShutdownCompletion == 0
        ? SessionEndClassification.remoteProcessEndedOnMoshTransportStop()
        : SessionEndClassification.remoteProcessEndedOnMoshShutdownCompletion()
    return ended ? 1 : 0
}

/// ```json
/// {"alreadyRecovering":false,"arguments":{"detail":"Broken pipe"},
///  "code":"transport_disconnected","explicitDisconnect":false,
///  "hadConnectedTransport":true}
/// ```
public struct SessionRetryABIRequest: Codable, Equatable, Sendable {
    public var explicitDisconnect: Bool
    public var hadConnectedTransport: Bool
    public var alreadyRecovering: Bool
    public var code: String
    public var arguments: [String: String]

    public init(
        explicitDisconnect: Bool,
        hadConnectedTransport: Bool,
        alreadyRecovering: Bool,
        code: String,
        arguments: [String: String]
    ) {
        self.explicitDisconnect = explicitDisconnect
        self.hadConnectedTransport = hadConnectedTransport
        self.alreadyRecovering = alreadyRecovering
        self.code = code
        self.arguments = arguments
    }
}

/// Whether a lost session should try again. Returns 1, 0, or -1 for invalid
/// arguments.
///
/// The rules fire in order: an explicit disconnect never retries; a transport
/// that never connected never retries unless a recovery is already in flight;
/// `transport_disconnected` always retries; otherwise the failure's `detail`
/// must name one of the eleven shared transient markers.
@_cdecl("tessera_session_should_retry")
public func tesseraSessionShouldRetry(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        SessionRetryABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 65_536
    ) else { return -1 }
    return SessionRetryPolicy.shouldRetry(
        explicitDisconnect: request.explicitDisconnect,
        hadConnectedTransport: request.hadConnectedTransport,
        alreadyRecovering: request.alreadyRecovering,
        code: request.code,
        arguments: request.arguments
    ) ? 1 : 0
}

/// Delay before a one-based attempt, in seconds. Attempts past the ladder's
/// end hold at its last rung (4.0 s) rather than growing without bound.
@_cdecl("tessera_session_retry_delay_seconds")
public func tesseraSessionRetryDelaySeconds(attempt: Int32) -> Double {
    SessionRetryPolicy.retryDelaySeconds(attempt: Int(attempt))
}

/// The shared attempt cap (5). A platform that carries its own ladder in
/// milliseconds converts from `tessera_session_retry_delay_seconds` at the
/// wrapper edge.
@_cdecl("tessera_session_retry_max_attempts")
public func tesseraSessionRetryMaxAttempts() -> Int32 {
    Int32(SessionRetryPolicy.maxAttempts)
}
