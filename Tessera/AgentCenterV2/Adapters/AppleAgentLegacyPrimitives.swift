import Foundation
import Observation
import TesseraCore

enum AgentStatus: Int, Codable, CaseIterable, Comparable, Sendable {
    case waitingForInput = 0
    case justFinished = 1
    case working = 2
    case idle = 3
    case unavailable = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum AgentLifecycleIntegrationState: Equatable, Sendable {
    case checking
    case notChecked
    case checkUnavailable
    case notInstalled
    case installedInactive
    case active
    case outdated(version: Int?)
}

enum AgentIntegrationForeground: Equatable, Sendable {
    case shell
    case unsupportedShell
    case agent
    case other
}

private struct AgentCurrentIntegrationTargetUnavailableError: Error {}

struct AgentCurrentIntegrationTarget: Equatable, Sendable {
    let location: AgentLocation
    let foreground: AgentIntegrationForeground
    let processIDs: Set<Int>
    /// `nil` means the per-process check failed. Do not collapse that into an
    /// inactive result: offering to source into an unverified target is both
    /// misleading and unsafe.
    let shellIntegrationActive: Bool?
    let agentIntegrationActive: Bool
    let agentRequiresLifecycleHook: Bool?

    init(
        location: AgentLocation,
        foreground: AgentIntegrationForeground,
        processIDs: Set<Int>,
        shellIntegrationActive: Bool?,
        agentIntegrationActive: Bool,
        agentRequiresLifecycleHook: Bool? = nil
    ) {
        self.location = location
        self.foreground = foreground
        self.processIDs = processIDs
        self.shellIntegrationActive = shellIntegrationActive
        self.agentIntegrationActive = agentIntegrationActive
        self.agentRequiresLifecycleHook = agentRequiresLifecycleHook
    }
}

enum AgentIntegrationFixAction: Equatable, Sendable {
    case installAndApply
    case installOnly
    case apply
    case persistAndApply
    case check
    case retry
}

struct AgentIntegrationWarningState: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case checking
        case ready
        case notInstalled
        case outdated
        case inactiveShell
        case insideAgent
        case awayFromShell
        case unsupportedShell
        case busyProgram
        case manualCheckRequired
        case repairing
        case unavailable
        case appUpdateRequired
    }

    let kind: Kind
    /// Notice copy is stored as `LocalizedStringResource`, not `String`, so
    /// every literal below is a key string extraction can see. A `String`
    /// here would silently keep the whole notice set out of the catalog.
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let actionLabel: LocalizedStringResource?
    let action: AgentIntegrationFixAction?
    let secondaryActionLabel: LocalizedStringResource?
    let secondaryAction: AgentIntegrationFixAction?

    init(
        kind: Kind,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        actionLabel: LocalizedStringResource?,
        action: AgentIntegrationFixAction?,
        secondaryActionLabel: LocalizedStringResource? = nil,
        secondaryAction: AgentIntegrationFixAction? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
        self.secondaryActionLabel = secondaryActionLabel
        self.secondaryAction = secondaryAction
    }

    /// Resolves a confirmation captured before the foreground process changed.
    /// Installing files may safely gain current-shell activation only when the
    /// fresh state proves this exact target is now an empty supported shell;
    /// conversely, an agent launch narrows install-and-apply to files-only.
    func effectiveAction(
        for requested: AgentIntegrationFixAction?
    ) -> AgentIntegrationFixAction? {
        semanticDecision.effectiveAction(for: requested?.semanticAction)?.appleAction
    }

    func supports(_ candidate: AgentIntegrationFixAction?) -> Bool {
        effectiveAction(for: candidate) != nil
    }

    var showsWarning: Bool {
        semanticDecision.showsWarning
    }

    var isRepairing: Bool { kind == .repairing }

    static let checking = Self(
        kind: .checking,
        title: "Checking agent integration",
        message: "",
        actionLabel: nil,
        action: nil
    )

    static let ready = Self(
        kind: .ready,
        title: "Agent integration ready",
        message: "",
        actionLabel: nil,
        action: nil
    )

    static let repairing = Self(
        kind: .repairing,
        title: "Fixing agent integration",
        message: "This keeps future agent status accurate in Agent Center.",
        actionLabel: nil,
        action: nil
    )

    static let checkingOnDemand = Self(
        kind: .repairing,
        title: "Checking agent integration",
        message: "Reading the integration state for this terminal.",
        actionLabel: nil,
        action: nil
    )

    static func resolved(
        installation: AgentLifecycleHostInstallation,
        target: AgentCurrentIntegrationTarget
    ) -> Self {
        let decision = AgentIntegrationDecisionReducer.resolve(
            .init(
                installation: installation.semanticKind,
                foreground: target.foreground.semanticKind,
                shellIntegrationActive: target.shellIntegrationActive,
                agentIntegrationActive: target.agentIntegrationActive,
                agentRequiresLifecycleHook: target.agentRequiresLifecycleHook
            )
        )
        switch decision.kind {
        case .notInstalled:
            let canApply = decision.primaryAction == .installAndApply
            let insideHookAgent = target.foreground == .agent
                && target.agentRequiresLifecycleHook != false
            return Self(
                kind: .notInstalled,
                title: "Agent integration not installed",
                message: insideHookAgent
                    ? "Installs Tessera's helpers now. If this agent has not loaded the lifecycle hooks, relaunch it to enable status reporting."
                    : target.foreground == .agent
                    ? "Installs Tessera's Agent Center helpers. OpenCode or Pi inventory refreshes automatically when installation completes."
                    : canApply
                    ? "Installs Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
                    : "Installs Tessera's local hook files. Return to a shell prompt afterward to enable this terminal.",
                actionLabel: canApply ? "Install and enable" : "Install integration",
                action: decision.primaryAction?.appleAction
            )
        case .outdated:
            let canApply = decision.primaryAction == .installAndApply
            let insideHookAgent = target.foreground == .agent
                && target.agentRequiresLifecycleHook != false
            return Self(
                kind: .outdated,
                title: "Agent integration needs an update",
                message: insideHookAgent
                    ? "Updates Tessera's helpers immediately without interrupting this agent. Existing hooks use the new scripts on their next event. If lifecycle status remains unavailable, relaunch the agent to load its hooks."
                    : target.foreground == .agent
                    ? "Updates Tessera's Agent Center helpers. OpenCode or Pi inventory refreshes automatically when installation completes."
                    : canApply
                    ? "Updates Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
                    : "Updates Tessera's local hook files. Return to a shell prompt afterward to enable this terminal.",
                actionLabel: canApply ? "Update and enable" : "Update integration",
                action: decision.primaryAction?.appleAction
            )
        case .ready:
            return .ready
        case .inactiveShell:
            return Self(
                kind: .inactiveShell,
                title: "Agent integration inactive here",
                message: "Loads Tessera's shell marker here. Enable automatically also saves the guarded activation line in this shell's startup file for future windows.",
                actionLabel: "Enable in this shell",
                action: decision.primaryAction?.appleAction,
                secondaryActionLabel: "Enable automatically",
                secondaryAction: decision.secondaryAction?.appleAction
            )
        case .insideAgent:
            return Self(
                kind: .insideAgent,
                title: "Agent lifecycle not yet confirmed",
                message: "The helpers are installed, but no trusted lifecycle event has arrived from this agent yet. Tessera rechecks as you use it. If status remains unavailable, relaunch the agent to load its hooks.",
                actionLabel: nil,
                action: nil
            )
        case .unsupportedShell:
            return Self(
                kind: .unsupportedShell,
                title: "Open bash or zsh to enable integration",
                message: "Tessera preserves other shell configurations and only sources its provider shims into bash or zsh.",
                actionLabel: nil,
                action: nil
            )
        case .busyProgram:
            return Self(
                kind: .busyProgram,
                title: "Integration check paused",
                message: "Tessera will recheck when the foreground program returns to its shell.",
                actionLabel: nil,
                action: nil
            )
        case .unavailable:
            return .unavailable(
                "The terminal-specific check failed. Tessera will retry after the next command."
            )
        case .appUpdateRequired:
            return Self(
                kind: .appUpdateRequired,
                title: "Update Tessera for this host",
                message: "This host's Agent Center integration comes from a newer Tessera. Update this app to keep agent status accurate.",
                actionLabel: nil,
                action: nil
            )
        case .checking, .awayFromShell, .manualCheckRequired, .repairing:
            assertionFailure("Resolved integration observations produced an orchestration-only state")
            return .unavailable()
        }
    }

    static let manualCheckRequired = Self(
        kind: .manualCheckRequired,
        title: "Check agent integration",
        message: "Plain mosh needs a secondary SSH check; your key may ask to unlock.",
        actionLabel: "Check now",
        action: .check
    )

    static func unavailable(_ detail: LocalizedStringResource? = nil) -> Self {
        Self(
            kind: .unavailable,
            title: "Could not verify agent integration",
            message: detail ?? "Retry the check without changing the host.",
            actionLabel: "Retry",
            action: .retry
        )
    }
}

private extension AgentLifecycleHostInstallation {
    var semanticKind: AgentIntegrationInstallationKind {
        switch self {
        case .missing: .missing
        case .current: .current
        case .outdated: .outdated
        case .requiresAppUpdate: .requiresAppUpdate
        }
    }
}

private extension AgentIntegrationForeground {
    var semanticKind: AgentIntegrationForegroundKind {
        switch self {
        case .shell: .shell
        case .unsupportedShell: .unsupportedShell
        case .agent: .agent
        case .other: .other
        }
    }
}

private extension AgentIntegrationFixAction {
    var semanticAction: AgentIntegrationDecisionAction {
        switch self {
        case .installAndApply: .installAndApply
        case .installOnly: .installOnly
        case .apply: .apply
        case .persistAndApply: .persistAndApply
        case .check: .check
        case .retry: .retry
        }
    }
}

private extension AgentIntegrationDecisionAction {
    var appleAction: AgentIntegrationFixAction {
        switch self {
        case .installAndApply: .installAndApply
        case .installOnly: .installOnly
        case .apply: .apply
        case .persistAndApply: .persistAndApply
        case .check: .check
        case .retry: .retry
        }
    }
}

private extension AgentIntegrationWarningState {
    var semanticDecision: AgentIntegrationDecision {
        AgentIntegrationDecision(
            kind: kind.semanticKind,
            primaryAction: action?.semanticAction,
            secondaryAction: secondaryAction?.semanticAction
        )
    }
}

private extension AgentIntegrationWarningState.Kind {
    var semanticKind: AgentIntegrationDecisionKind {
        switch self {
        case .checking: .checking
        case .ready: .ready
        case .notInstalled: .notInstalled
        case .outdated: .outdated
        case .inactiveShell: .inactiveShell
        case .insideAgent: .insideAgent
        case .awayFromShell: .awayFromShell
        case .unsupportedShell: .unsupportedShell
        case .busyProgram: .busyProgram
        case .manualCheckRequired: .manualCheckRequired
        case .repairing: .repairing
        case .unavailable: .unavailable
        case .appUpdateRequired: .appUpdateRequired
        }
    }
}

struct AgentLifecycleEvent: Equatable, Sendable {
    /// Released installer revisions 2, 3, 4, 6, 7, and 8 emitted the retained
    /// PID-bound lifecycle envelope. (Revision 5 was never released.) Installer
    /// revision 9 adds only bounded optional thread/subagent fields.
    /// Keep those events readable while an agent that predates an update is
    /// still running; the exact current file revision is verified independently
    /// by the host installation probe.
    static let compatibleVersions = AgentLifecycleEnvelope.compatibleVersions
    static let supportedVersion = AgentLifecycleEnvelope.currentVersion

    let version: Int
    let provider: String
    let event: String
    let state: AgentStatus
    let reason: String
    let timestampNanoseconds: UInt64
    let providerSessionID: String
    let turnID: String
    let notificationType: String
    let permissionMode: String
    let agentPID: Int?
    let transcriptRef: String?
    let agentID: String?
    let agentType: String?
    let rootAgentID: String?

    init(
        version: Int,
        provider: String,
        event: String,
        state: AgentStatus,
        reason: String,
        timestampNanoseconds: UInt64,
        providerSessionID: String,
        turnID: String,
        notificationType: String,
        permissionMode: String,
        agentPID: Int?,
        transcriptRef: String? = nil,
        agentID: String? = nil,
        agentType: String? = nil,
        rootAgentID: String? = nil
    ) {
        self.version = version
        self.provider = provider
        self.event = event
        self.state = state
        self.reason = reason
        self.timestampNanoseconds = timestampNanoseconds
        self.providerSessionID = providerSessionID
        self.turnID = turnID
        self.notificationType = notificationType
        self.permissionMode = permissionMode
        self.agentPID = agentPID
        self.transcriptRef = transcriptRef
        self.agentID = agentID
        self.agentType = agentType
        self.rootAgentID = rootAgentID
    }

    var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampNanoseconds) / 1_000_000_000)
    }

    static func supportsHookPayload(provider: String, version: Int) -> Bool {
        guard let providerID = AgentProviderID(rawValue: provider) else { return false }
        return AgentLifecycleHookEvent.supportsHookPayload(providerID: providerID, version: version)
    }

    var processName: String {
        switch provider.lowercased() {
        case "claude": "claude"
        case "codex": "codex"
        default: provider.lowercased()
        }
    }

    var provesRunningAgentIntegration: Bool {
        switch event {
        case "SessionStart", "SubagentStart", "SubagentStop",
             "UserPromptSubmit", "PreToolUse", "PostToolUse",
             "PermissionRequest", "Notification", "Stop", "StopFailure":
            true
        default:
            false
        }
    }

    /// A child finishing does not say whether the root agent is still working
    /// or has already stopped. Claude can deliver SubagentStop after the root
    /// Stop event, so it is liveness evidence but must never replace the most
    /// recent pane-level state.
    var isStatusNeutral: Bool {
        event == "SubagentStop"
    }

    /// Reads only the non-sensitive schema revision for diagnostics. This is
    /// deliberately separate from `decode`: malformed, future, or obsolete
    /// payloads remain rejected even though their declared revision can be
    /// reported without logging the payload itself.
    static func declaredVersion(json: String) -> Int? {
        struct WireHeader: Decodable { let version: Int }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WireHeader.self, from: data).version
    }

    static func decode(json: String) -> Self? {
        guard let data = json.data(using: .utf8),
              let wire = AgentLifecycleHookEvent.decode(data)
        else { return nil }
        let state: AgentStatus = switch wire.status {
        case .waitingForInput: .waitingForInput
        case .working: .working
        case .idle: .idle
        case .finished: .justFinished
        case .unavailable: .unavailable
        }

        return Self(
            version: wire.version,
            provider: wire.providerID.rawValue,
            event: wire.event.rawValue,
            state: state,
            reason: wire.reason ?? "",
            timestampNanoseconds: wire.timestampNanoseconds,
            providerSessionID: wire.providerSessionID ?? "",
            turnID: wire.turnID ?? "",
            notificationType: wire.notificationType ?? "",
            permissionMode: wire.permissionMode ?? "",
            agentPID: wire.agentPID,
            transcriptRef: wire.transcriptRef,
            agentID: wire.agentID,
            agentType: wire.agentType,
            rootAgentID: wire.rootAgentID
        )
    }
}

/// Streaming parser for Tessera's private semantic lifecycle OSC. Hooks write
/// `OSC 1337;TesseraAgentState=<base64-json> BEL` to the owning terminal. The
/// scanner is intentionally transport-blind: raw SSH/mosh bytes and tmux pane
/// output both enter through AgentCenter.noteOutput.
/// Hot path: runs over every `%output` payload of an integrated pane. The
/// normal-state scan is a raw-pointer skip loop, OSC accumulation lives in a
/// stored buffer (an enum payload would copy-on-rewrap per byte — measured
/// microseconds per byte in Debug builds), and an OSC whose payload diverges
/// from the Tessera prefix stops buffering immediately: terminal-title OSCs
/// (which chatty TUIs emit constantly) diverge on their first byte, so they
/// skip straight to the terminator instead of accumulating.
/// Recognition is deliberately 7-bit only (`ESC ]`, never C1 0x9D): 0x9D is
/// also the trailing byte of a curly quote (E2 80 9D), so treating it as an
/// OSC opener let ordinary prose park the scanner in skip mode and swallow
/// the next genuine agent-state OSC. Skip mode is byte-capped for the same
/// reason — an unterminated opener (e.g. cat-ing a binary) must not disable
/// lifecycle events for the rest of the session.
struct AgentLifecycleOSCScanner: Sendable {
    private enum State: Sendable {
        case normal
        case escape
        case osc
        case oscSkip
        case oscEscape
        case oscSkipEscape
    }

    private static let prefix = Array("1337;TesseraAgentState=".utf8)
    private var state: State = .normal
    private var oscBuffer: [UInt8] = []
    private var skippedOSCBytes = 0
    private let maximumOSCBytes = 16 * 1024
    private(set) var candidateChunkCount = 0

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [AgentLifecycleEvent] {
        if case .normal = state,
           !containsOSCCandidate(bytes) {
            return []
        }
        candidateChunkCount &+= 1
        var events: [AgentLifecycleEvent] = []
        bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            let count = buffer.count
            while i < count {
                let byte = buffer[i]
                switch state {
                case .normal:
                    if byte == 0x1B {
                        state = .escape
                        i += 1
                    } else {
                        i += 1
                        while i < count {
                            let b = buffer[i]
                            if b == 0x1B { break }
                            i += 1
                        }
                    }

                case .escape:
                    if byte == 0x5D { beginOSC() }
                    else { state = byte == 0x1B ? .escape : .normal }
                    i += 1

                case .osc:
                    if byte == 0x07 {
                        finishOSC(into: &events)
                        i += 1
                    } else if byte == 0x1B {
                        state = .oscEscape
                        i += 1
                    } else {
                        let runStart = i
                        i += 1
                        while i < count {
                            let b = buffer[i]
                            if b == 0x07 || b == 0x1B { break }
                            i += 1
                        }
                        oscBuffer.append(
                            contentsOf: UnsafeBufferPointer(rebasing: buffer[runStart..<i])
                        )
                        if !payloadCouldMatchPrefix() {
                            enterSkip()
                        } else if oscBuffer.count > maximumOSCBytes {
                            state = .normal
                            oscBuffer.removeAll(keepingCapacity: true)
                        }
                    }

                case .oscSkip:
                    if byte == 0x07 {
                        state = .normal
                        i += 1
                    } else if byte == 0x1B {
                        state = .oscSkipEscape
                        i += 1
                    } else {
                        let runStart = i
                        i += 1
                        while i < count {
                            let b = buffer[i]
                            if b == 0x07 || b == 0x1B { break }
                            i += 1
                        }
                        skippedOSCBytes += i - runStart
                        if skippedOSCBytes > maximumOSCBytes {
                            state = .normal
                        }
                    }

                case .oscEscape:
                    if byte == 0x5C {
                        finishOSC(into: &events)
                    } else {
                        oscBuffer.append(0x1B)
                        oscBuffer.append(byte)
                        if !payloadCouldMatchPrefix() {
                            enterSkip()
                        } else if oscBuffer.count > maximumOSCBytes {
                            state = .normal
                            oscBuffer.removeAll(keepingCapacity: true)
                        } else {
                            state = .osc
                        }
                    }
                    i += 1

                case .oscSkipEscape:
                    if byte == 0x5C {
                        state = .normal
                    } else {
                        skippedOSCBytes += 2
                        state = skippedOSCBytes > maximumOSCBytes ? .normal : .oscSkip
                    }
                    i += 1
                }
            }
        }
        return events
    }

    private mutating func beginOSC() {
        state = .osc
        oscBuffer.removeAll(keepingCapacity: true)
    }

    private mutating func enterSkip() {
        state = .oscSkip
        oscBuffer.removeAll(keepingCapacity: true)
        skippedOSCBytes = 0
    }

    /// True while the buffered payload is still a viable prefix of
    /// `1337;TesseraAgentState=`. Bounded — never compares more than the
    /// prefix length regardless of payload size.
    private func payloadCouldMatchPrefix() -> Bool {
        let checkCount = min(oscBuffer.count, Self.prefix.count)
        for index in 0..<checkCount where oscBuffer[index] != Self.prefix[index] {
            return false
        }
        return true
    }

    private func containsOSCCandidate(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            let count = buffer.count
            while i < count {
                let byte = buffer[i]
                if byte == 0x1B {
                    if i + 1 == count { return true }
                    if buffer[i + 1] == 0x5D { return true }
                }
                i += 1
            }
            return false
        }
    }

    private mutating func finishOSC(into events: inout [AgentLifecycleEvent]) {
        defer {
            state = .normal
            oscBuffer.removeAll(keepingCapacity: true)
        }
        guard oscBuffer.starts(with: Self.prefix) else { return }
        let encoded = String(decoding: oscBuffer.dropFirst(Self.prefix.count), as: UTF8.self)
        guard let data = Data(base64Encoded: encoded),
              let json = String(data: data, encoding: .utf8),
              let event = AgentLifecycleEvent.decode(json: json)
        else { return }
        events.append(event)
    }
}

struct AgentInstanceID: Hashable, Sendable {
    let sessionID: UUID
    /// nil is the one foreground process in a raw SSH/mosh session.
    let paneID: Int?
}

struct AgentLocation: Hashable, Sendable {
    let sessionID: UUID
    let hostName: String
    let transportLabel: String
    let tmuxSessionName: String?
    let windowID: Int?
    let windowName: String?
    let paneID: Int?

    var addressText: String {
        guard let paneID else {
            return String(
                localized: "\(hostName) · raw session",
                comment: "Agent location when the session is not running under tmux"
            )
        }
        var parts = [hostName]
        if let tmuxSessionName, !tmuxSessionName.isEmpty { parts.append(tmuxSessionName) }
        if let windowID {
            if let windowName, !windowName.isEmpty {
                parts.append(String(
                    localized: "window \(windowID) “\(windowName)”",
                    comment: "Agent location: tmux window number and its name"
                ))
            } else {
                parts.append(String(
                    localized: "window \(windowID)",
                    comment: "Agent location: tmux window number"
                ))
            }
        }
        // `%21` is tmux's own pane identifier syntax, not prose.
        parts.append("pane %\(paneID)")
        return parts.joined(separator: " · ")
    }
}

struct AgentPromptOption: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let responseMacro: String
    let isDefault: Bool
}

extension AgentPromptOption {
    /// Shared negative-intent heuristic: input attribution uses it to decide
    /// idle-vs-working after an answered prompt, and SwipePad uses it to tint
    /// petals. One definition so the two features can never disagree. The
    /// static form exists for label strings that aren't parsed options
    /// (SwipePad binding labels).
    var isNegativeLabel: Bool { Self.isNegativeLabel(label) }

    static func isNegativeLabel(_ label: String) -> Bool {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
        // "No, and tell Codex what to do differently" / "No, quit" style
        // labels are refusals too — match "no" as a leading word, not just
        // the exact label, but never as a prefix of another word ("note…").
        // English-only by scope: both supported agents render English menus;
        // revisit if a localized provider ships.
        return lowered == "no"
            || lowered.hasPrefix("no,")
            || lowered.hasPrefix("no ")
            || lowered.contains("deny")
            || lowered.contains("cancel")
            || lowered.contains("reject")
    }
}

struct AgentPrompt: Equatable, Sendable {
    /// The normalized visible prompt segment. Kept verbatim so stale-prompt
    /// checking does not depend on process-randomized `Hasher` output.
    let signature: String
    let summary: String
    let options: [AgentPromptOption]
}

/// Exact hook-proven agent allowed to suppress terminal scrolling. Keeping the
/// identity with the display name lets presentation revalidate the same pane
/// before showing feedback; a stale gesture callback can never blame an agent
/// that has already stopped or moved.
struct AgentScrollPrevention: Equatable, Sendable {
    let agentID: AgentInstanceID
    let agentName: String
}

/// Transport-owned observation returned to the shared detector. A tmux source
/// produces one target per pane; a raw source produces one target with nil ids.
struct AgentProbeTarget: Equatable, Sendable {
    let location: AgentLocation
    let processNames: [String]
    let processIDs: Set<Int>
    let visibleText: String?
    /// The normalized terminal row that currently owns the cursor. Real
    /// sources provide this so an old composer line elsewhere in the viewport
    /// cannot make a working agent look idle. nil keeps synthetic/custom
    /// sources compatible with viewport-only matching.
    let currentInputLine: String?
    let cursorRow: Int?
    let cursorColumn: Int?
    let cursorVisible: Bool?
    let screenEvidence: TerminalScreenEvidence?
    let lifecycleEvent: AgentLifecycleEvent?
    let bracketedPasteEnabled: Bool
    /// When the remote process read behind `processIDs` began. Discovery may
    /// reuse a read for a moment, so a PID missing from an older read is not
    /// yet evidence that the process is foreign to the pane. `.distantPast`
    /// when no read was made; nil (synthetic sources) counts as current.
    let processSnapshotTakenAt: Date?

    init(
        location: AgentLocation,
        processNames: [String],
        processIDs: Set<Int> = [],
        visibleText: String?,
        currentInputLine: String? = nil,
        cursorRow: Int? = nil,
        cursorColumn: Int? = nil,
        cursorVisible: Bool? = nil,
        screenEvidence: TerminalScreenEvidence? = nil,
        lifecycleEvent: AgentLifecycleEvent? = nil,
        bracketedPasteEnabled: Bool,
        processSnapshotTakenAt: Date? = nil
    ) {
        self.location = location
        self.processNames = processNames
        self.processIDs = processIDs
        self.visibleText = visibleText
        self.currentInputLine = currentInputLine
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
        self.screenEvidence = screenEvidence
        self.lifecycleEvent = lifecycleEvent
        self.bracketedPasteEnabled = bracketedPasteEnabled
        self.processSnapshotTakenAt = processSnapshotTakenAt
    }
}

enum AgentDiscoveryResult: Sendable {
    case success([AgentProbeTarget])
    /// The carrier could not produce an authoritative snapshot. Keep the last
    /// good cards and retry instead of treating this as “zero agents”.
    case unavailable
}

struct AgentSessionOccupancySnapshot: Equatable, Sendable {
    let panes: [AgentOccupancyObservation.Pane]
    let allPaneIDs: [String]?

    init(panes: [AgentOccupancyObservation.Pane], allPaneIDs: [String]? = nil) {
        self.panes = panes
        self.allPaneIDs = allPaneIDs
    }
}

enum AgentInputKey: Sendable, Equatable {
    case enter
    case escape
}

/// Carrier seam. Detection, status, safety, and UI are shared; session views
/// supply only discovery/snapshot/send/jump operations appropriate to their
/// current raw or tmux transport.
@MainActor
struct AgentSessionSource {
    /// Distinguishes successive transport owners that intentionally reuse a
    /// LiveSession ID (notably jump-host mosh -> SSH fallback).
    let registrationID: UUID
    let sessionID: UUID
    let discover: @MainActor () async -> AgentDiscoveryResult
    let discoverForLifecycle: @MainActor (Int?) async -> AgentDiscoveryResult
    /// Fresh process inventory, independent of foreground input and captures.
    let observeOccupancy: (@MainActor ([AgentTerminalBinding]) async -> AgentSessionOccupancySnapshot?)?
    /// Cheap output-pulse path for an already-known target. It captures only
    /// that pane/viewport and deliberately avoids process-tree discovery.
    let observe: @MainActor (AgentLocation) async -> AgentProbeTarget?
    /// Strong post-send snapshot. tmux sources always capture the remote pane
    /// instead of trusting a potentially lagging mosh-rendered surface.
    let verifySend: @MainActor (AgentLocation) async -> AgentProbeTarget?
    let inspect: @MainActor (AgentLocation) async -> AgentProbeTarget?
    /// Preserve the leased process in bounded snapshots used for action safety.
    let inspectInputTarget: @MainActor (AgentLocation, Int?) async -> AgentProbeTarget?
    let lifecycleIntegrationCacheKey: String
    let automaticallyProbeLifecycleIntegration: Bool
    let probeLifecycleIntegrationOnCurrentCarrier: (@MainActor () async throws -> AgentLifecycleHostInstallation?)?
    let probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)?
    let installLifecycleIntegration: (@MainActor () async throws -> Void)?
    let automaticallyInspectCurrentIntegration: @MainActor () -> Bool
    let inspectCurrentIntegration: (@MainActor () async -> AgentCurrentIntegrationTarget?)?
    let applyLifecycleIntegrationToCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)?
    let persistLifecycleIntegrationInCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)?
    let send: @MainActor (AgentLocation, [UInt8]) async -> Bool
    /// The refusals `send` makes before its first byte, as a content-free
    /// reason; nil when it would write. `send` alone cannot tell them apart
    /// from an unacknowledged write. nil keeps synthetic sources unchanged.
    let sendRefusal: (@MainActor (AgentLocation, [UInt8]) -> String?)?
    /// tmux must encode Enter/Escape according to the pane's negotiated
    /// keyboard mode. nil keeps synthetic and raw-only sources compatible.
    let sendKey: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)?
    let jump: @MainActor (AgentLocation) -> Void
    /// Opens a bounded child exec on the already-authenticated carrier. The
    /// closure must never connect or prompt merely because Agent Center asks.
    let projectorExecAvailability: @MainActor (
        AgentTerminalBinding,
        @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability
    /// A session-owned, read-only carrier for inventory/search before any live
    /// agent has been detected.  It is deliberately not an action route: the
    /// coordinator accepts it only for projector work and keeps mutations on
    /// a discovered, PID-proven terminal binding.
    let readCarrier: (@MainActor () -> AgentTerminalBinding?)?
    /// Returns only an exact tmux pane's current remote working directory.
    /// nil is truthful for raw carriers: launch/fork is tmux-only.
    let validatedRemoteDirectories: (@MainActor (AgentTerminalBinding) async -> [String])?
    /// Explicit transport capability rather than a best-effort launch probe.
    /// Raw SSH/Mosh stays false even if it can observe an agent.
    let supportsTmuxLaunch: @MainActor () -> Bool
    /// Starts a validated semantic helper in an acknowledged tmux placement.
    /// nil is truthful for raw sessions and synthetic/test carriers.
    let launchAgent: (@MainActor (AgentLaunchPlan) async throws -> AgentLaunchReceipt)?
    /// Drops process reads `discover` may reuse, so its next pass reads the
    /// host again. nil for sources that never reuse one.
    let invalidateProcessSnapshots: (@MainActor () -> Void)?

    init(
        registrationID: UUID,
        sessionID: UUID,
        discover: @escaping @MainActor () async -> AgentDiscoveryResult,
        discoverForLifecycle: (@MainActor (Int?) async -> AgentDiscoveryResult)? = nil,
        observeOccupancy: (@MainActor ([AgentTerminalBinding]) async -> AgentSessionOccupancySnapshot?)? = nil,
        observe: @escaping @MainActor (AgentLocation) async -> AgentProbeTarget?,
        verifySend: (@MainActor (AgentLocation) async -> AgentProbeTarget?)? = nil,
        inspect: @escaping @MainActor (AgentLocation) async -> AgentProbeTarget?,
        inspectInputTarget: (@MainActor (AgentLocation, Int?) async -> AgentProbeTarget?)? = nil,
        lifecycleIntegrationCacheKey: String? = nil,
        automaticallyProbeLifecycleIntegration: Bool = false,
        probeLifecycleIntegrationOnCurrentCarrier: (@MainActor () async throws -> AgentLifecycleHostInstallation?)? = nil,
        probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)? = nil,
        installLifecycleIntegration: (@MainActor () async throws -> Void)? = nil,
        automaticallyInspectCurrentIntegration: @escaping @MainActor () -> Bool = { true },
        inspectCurrentIntegration: (@MainActor () async -> AgentCurrentIntegrationTarget?)? = nil,
        applyLifecycleIntegrationToCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)? = nil,
        persistLifecycleIntegrationInCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)? = nil,
        send: @escaping @MainActor (AgentLocation, [UInt8]) async -> Bool,
        sendRefusal: (@MainActor (AgentLocation, [UInt8]) -> String?)? = nil,
        sendKey: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)? = nil,
        jump: @escaping @MainActor (AgentLocation) -> Void,
        projectorExecAvailability: @escaping @MainActor (
            AgentTerminalBinding,
            @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
        ) -> AppleAgentExecAvailability = { _, _ in .unavailable(.staleCarrier) },
        readCarrier: (@MainActor () -> AgentTerminalBinding?)? = nil,
        validatedRemoteDirectories: (@MainActor (AgentTerminalBinding) async -> [String])? = nil,
        supportsTmuxLaunch: @escaping @MainActor () -> Bool = { false },
        launchAgent: (@MainActor (AgentLaunchPlan) async throws -> AgentLaunchReceipt)? = nil,
        invalidateProcessSnapshots: (@MainActor () -> Void)? = nil
    ) {
        self.registrationID = registrationID
        self.sessionID = sessionID
        self.discover = discover
        self.discoverForLifecycle = discoverForLifecycle ?? { _ in await discover() }
        self.observeOccupancy = observeOccupancy
        self.observe = observe
        self.verifySend = verifySend ?? observe
        self.inspect = inspect
        self.inspectInputTarget = inspectInputTarget ?? { location, _ in await inspect(location) }
        self.lifecycleIntegrationCacheKey = lifecycleIntegrationCacheKey ?? sessionID.uuidString
        self.automaticallyProbeLifecycleIntegration = automaticallyProbeLifecycleIntegration
        self.probeLifecycleIntegrationOnCurrentCarrier = probeLifecycleIntegrationOnCurrentCarrier
        self.probeLifecycleIntegration = probeLifecycleIntegration
        self.installLifecycleIntegration = installLifecycleIntegration
        self.automaticallyInspectCurrentIntegration = automaticallyInspectCurrentIntegration
        self.inspectCurrentIntegration = inspectCurrentIntegration
        self.applyLifecycleIntegrationToCurrentShell = applyLifecycleIntegrationToCurrentShell
        self.persistLifecycleIntegrationInCurrentShell = persistLifecycleIntegrationInCurrentShell
        self.send = send
        self.sendRefusal = sendRefusal
        self.sendKey = sendKey
        self.jump = jump
        self.projectorExecAvailability = projectorExecAvailability
        self.readCarrier = readCarrier
        self.validatedRemoteDirectories = validatedRemoteDirectories
        self.supportsTmuxLaunch = supportsTmuxLaunch
        self.launchAgent = launchAgent
        self.invalidateProcessSnapshots = invalidateProcessSnapshots
    }
}

enum AgentPromptParser {
    struct Result: Equatable {
        let text: String
        let prompt: AgentPrompt?
        let blockingPromptDetected: Bool
        let isIdlePrompt: Bool
        /// The profile's patterns ran out of `regexBudgetMilliseconds`, so
        /// nothing was detected and nothing was ruled out either.
        var timedOut = false
    }

    /// CPU time. Generous for a full screen of the built-in patterns (about a
    /// millisecond), yet short enough that no pattern can hold the main actor
    /// near a watchdog.
    static let regexBudgetMilliseconds: UInt64 = 200

    static func parse(
        visibleText: String,
        profile: SwipePadProfile,
        currentInputLine: String? = nil
    ) -> Result {
        let text = AgentTerminalText.normalized(visibleText)
        guard let rules = profile.agentDetection else {
            return Result(
                text: text,
                prompt: nil,
                blockingPromptDetected: false,
                isIdlePrompt: false
            )
        }

        // Claude/Codex's actionable grammar lives in TesseraAgentCore so the
        // Android bridge executes the identical provider-owned macros.  Keep
        // the legacy generic parser below as a detection-only compatibility
        // fallback for custom profiles and cursor-less historical snapshots.
        let provider: AgentProviderID? = profile.id == SwipePadProfile.builtInClaudeCodeID
            ? .claude
            : profile.id == SwipePadProfile.builtInCodexCLIID ? .codex : nil
        if let provider,
           let request = AgentPromptObservationRequest(
                providerID: provider,
                visibleText: text,
                currentCursorLine: currentInputLine
           ),
           let observed = AgentPromptGrammar.observe(request) {
            if observed.kind == .deferred {
                return Result(text: text, prompt: nil, blockingPromptDetected: false, isIdlePrompt: false)
            }
            let options = observed.options.compactMap { option -> AgentPromptOption? in
                guard !option.acceptsText, let id = Int(option.id) else { return nil }
                return AgentPromptOption(
                    id: id,
                    label: option.label,
                    responseMacro: option.responseMacro,
                    isDefault: option.isDefault
                )
            }
            if !options.isEmpty {
                return Result(
                    text: text,
                    prompt: AgentPrompt(
                        signature: observed.signature,
                        summary: observed.signature
                            .split(separator: "\u{1F}")
                            .last
                            .map(String.init) ?? String(localized: "input requested"),
                        options: options
                    ),
                    blockingPromptDetected: true,
                    isIdlePrompt: false
                )
            }
            return Result(text: text, prompt: nil, blockingPromptDetected: observed.blocksComposer, isIdlePrompt: false)
        }

        let budget = AgentRegexBudget(milliseconds: regexBudgetMilliseconds)
        let started = DispatchTime.now().uptimeNanoseconds
        let candidateBlockingMatch = latestMatch(
            patterns: rules.blockingPromptPatterns,
            text: text,
            budget: budget
        )
        let viewportIdleMatch = latestMatch(
            patterns: rules.idlePromptPatterns,
            text: text,
            budget: budget
        )
        let currentLineIsIdle = currentInputLine.map {
            latestMatch(
                patterns: rules.idlePromptPatterns,
                text: AgentTerminalText.normalized($0),
                budget: budget
            ) != nil
        }
        let currentLineOwnsBlockingPrompt: Bool? = currentInputLine.map { rawLine in
            let line = AgentTerminalText.normalized(rawLine)
            guard !line.isEmpty else { return true }
            if latestMatch(patterns: rules.blockingPromptPatterns, text: line, budget: budget) != nil {
                return true
            }
            if let optionRegex = AgentRegexCache.regex(
                rules.menuOptionPattern
            ), budget.firstMatch(optionRegex, in: line) != nil {
                return true
            }
            let lowercased = line.lowercased()
            return lowercased.contains("press enter")
                || lowercased.contains("enter to confirm")
                || lowercased.contains("enter to continue")
                || lowercased.contains("esc to cancel")
                || lowercased.contains("esc to go back")
        }
        // A real source's cursor row is authoritative. If it is a composer,
        // it is newer than any stale approval text still visible above it; if
        // it is not, ignore older composer-looking rows in the viewport.
        let idleMatch = currentInputLine == nil ? viewportIdleMatch : nil
        let blockingMatch: NSTextCheckingResult? = {
            guard let candidateBlockingMatch else { return nil }
            if currentLineIsIdle == true { return nil }
            // Real sources know the row that owns the terminal cursor. A
            // permission menu left in scrollback while Codex's automatic
            // policy classifier is working must not remain actionable. Blank
            // cursor rows stay inconclusive because both providers sometimes
            // hide or park the cursor while drawing a modal.
            if currentLineOwnsBlockingPrompt == false { return nil }
            guard let idleMatch else { return candidateBlockingMatch }
            return candidateBlockingMatch.range.location > idleMatch.range.location
                ? candidateBlockingMatch
                : nil
        }()
        let prompt: AgentPrompt?
        if let match = blockingMatch {
            let start = Range(match.range, in: text)?.lowerBound ?? text.startIndex
            let segment = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let options = parseOptions(in: segment, rules: rules, provider: provider, budget: budget)
            let summary = promptSummary(in: segment)
            prompt = options.isEmpty ? nil : AgentPrompt(
                signature: stablePromptSignature(
                    text: text,
                    blockingStart: start,
                    segment: segment,
                    rules: rules,
                    budget: budget
                ),
                summary: summary,
                options: options
            )
        } else {
            prompt = nil
        }

        if budget.isExhausted {
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DiagnosticLogStore.appendAgentCenter(
                "prompt-parse budget-exhausted builtIn=\(profile.isBuiltIn) chars=\(text.utf16.count) elapsedMs=\(elapsedMs)"
            )
            return Result(
                text: text,
                prompt: nil,
                blockingPromptDetected: false,
                isIdlePrompt: false,
                timedOut: true
            )
        }

        return Result(
            text: text,
            prompt: prompt,
            blockingPromptDetected: blockingMatch != nil,
            isIdlePrompt: prompt == nil
                && blockingMatch == nil
                && (currentLineIsIdle ?? (idleMatch != nil))
        )
    }

    private static func parseOptions(
        in segment: String,
        rules: AgentDetectionRules,
        provider: AgentProviderID?,
        budget: AgentRegexBudget
    ) -> [AgentPromptOption] {
        guard let regex = AgentRegexCache.regex(rules.menuOptionPattern)
        else { return [] }
        let matches = budget.matches(regex, in: segment, limit: 9)
        let options = matches.compactMap { match -> AgentPromptOption? in
            guard match.numberOfRanges >= 4,
                  let indexRange = Range(match.range(at: 2), in: segment),
                  let index = Int(segment[indexRange]),
                  let labelRange = Range(match.range(at: 3), in: segment)
            else { return nil }

            let marker: String = {
                guard match.range(at: 1).location != NSNotFound,
                      let range = Range(match.range(at: 1), in: segment)
                else { return "" }
                return String(segment[range])
            }()
            let shortcut: String = {
                guard match.numberOfRanges >= 5,
                      match.range(at: 4).location != NSNotFound,
                      let range = Range(match.range(at: 4), in: segment)
                else { return "" }
                return String(segment[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }()
            guard let provider,
                  let macro = AgentPromptGrammar.responseMacro(provider: provider, index: String(index), shortcut: shortcut)
            else { return nil }
            // Preserve legacy display spelling; bytes are selected only by Core.
            let response = macro == "\u{1b}" ? "esc" : macro.replacingOccurrences(of: "\r", with: "↵")
            var label = String(segment[labelRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortcut.isEmpty, label.hasSuffix("(\(shortcut))") {
                label = String(label.dropLast(shortcut.count + 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return AgentPromptOption(
                id: index,
                label: label,
                responseMacro: response,
                isDefault: !marker.isEmpty
            )
        }
        return options.count == matches.count ? options : []
    }

    private static func latestMatch(
        patterns: [String],
        text: String,
        budget: AgentRegexBudget
    ) -> NSTextCheckingResult? {
        patterns.compactMap { pattern -> NSTextCheckingResult? in
            guard let regex = AgentRegexCache.regex(pattern) else { return nil }
            return budget.matches(regex, in: text).last
        }.max { lhs, rhs in lhs.range.location < rhs.range.location }
    }

    private static func promptSummary(in segment: String) -> String {
        let lines = segment.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first ?? String(localized: "input requested")
    }

    /// Provider footers, timers, and redraw hints after the final option are
    /// not prompt identity. The command/tool context is: Claude commonly puts
    /// it before a generic “Do you want to proceed?” line, while Codex puts it
    /// between the question and menu. Keep both so the same generic menu for a
    /// newer command can never satisfy the stale-prompt guard.
    private static func stablePromptSignature(
        text: String,
        blockingStart: String.Index,
        segment: String,
        rules: AgentDetectionRules,
        budget: AgentRegexBudget
    ) -> String {
        let precedingContext = text[..<blockingStart]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)

        var stableSegment = segment
        if let regex = AgentRegexCache.regex(rules.menuOptionPattern),
           let finalOption = budget.matches(regex, in: segment).last,
           let range = Range(finalOption.range, in: segment) {
            stableSegment = String(segment[..<range.upperBound])
        }

        return (precedingContext + stableSegment
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
            .map { selectionNeutralPromptLine(String($0), rules: rules, budget: budget) }
            .joined(separator: "\u{1F}")
    }

    private static func selectionNeutralPromptLine(
        _ line: String,
        rules: AgentDetectionRules,
        budget: AgentRegexBudget
    ) -> String {
        guard let regex = AgentRegexCache.regex(rules.menuOptionPattern),
        let match = budget.firstMatch(regex, in: line),
        match.numberOfRanges >= 2,
        match.range(at: 1).location != NSNotFound,
        let markerRange = Range(match.range(at: 1), in: line)
        else { return line }

        var neutral = line
        neutral.removeSubrange(markerRange)
        return neutral.trimmingCharacters(in: .whitespaces)
    }
}

enum AgentTerminalText {
    /// Removes ANSI CSI/OSC/DCS strings and keeps printable Unicode plus line
    /// structure. Sources should pass a current viewport rather than an output
    /// transcript; this normalizer intentionally is not a terminal emulator.
    static func normalized(_ raw: String, maximumCharacters: Int = 16_000) -> String {
        enum State { case text, escape, csi, osc, oscEscape, dcs, dcsEscape }
        var state = State.text
        var output = String.UnicodeScalarView()
        // Viewport rows arrive padded to the terminal width. Blanks wait here
        // until something printable follows on the same row, so a row's
        // trailing padding never reaches the output and a mostly empty screen
        // collapses to a few newlines: line-anchored prompt patterns
        // backtrack across whitespace runs, and thousands of padding spaces
        // made them run for minutes on the main actor.
        var blanks = String.UnicodeScalarView()

        for scalar in raw.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                if value == 0x1B {
                    state = .escape
                } else if value == 0x0D || value == 0x0A {
                    // A captured viewport is already row-oriented: CR and LF
                    // both end a row. The collapse below keeps at most one
                    // empty row between rows, including a CRLF pair's.
                    blanks.removeAll(keepingCapacity: true)
                    output.append("\n")
                } else if value == 0x09 || value == 0x20 {
                    blanks.append(scalar)
                } else if value > 0x20 {
                    output.append(contentsOf: blanks)
                    blanks.removeAll(keepingCapacity: true)
                    output.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B: state = .csi       // [
                case 0x5D: state = .osc       // ]
                case 0x50, 0x5E, 0x5F: state = .dcs // P, ^, _
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(value) { state = .text }
            case .osc:
                if value == 0x07 { state = .text }
                else if value == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = value == 0x5C ? .text : .osc
            case .dcs:
                if value == 0x1B { state = .dcsEscape }
            case .dcsEscape:
                state = value == 0x5C ? .text : .dcs
            }
        }

        var text = String(output)
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if text.count > maximumCharacters {
            text = String(text.suffix(maximumCharacters))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tail(_ text: String, lines: Int = 5) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(lines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cards are summaries, not terminal replicas. Select the most recent
    /// meaningful rows across the viewport so a large blank composer frame
    /// does not erase the task/status context that is still on screen.
    static func cardExcerpt(_ text: String, lines: Int = 5) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }

    static func taskSummary(
        _ text: String,
        excludingCurrentInputLine currentInputLine: String? = nil
    ) -> String? {
        let excluded = currentInputLine.map {
            normalized($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).reversed() {
            let fullLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard fullLine != excluded else { continue }
            var line = fullLine
            guard let marker = line.first,
                  marker == "›" || marker == "❯"
            else { continue }
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  line.range(of: #"^\d+\."#, options: .regularExpression) == nil
            else { continue }
            return String(line.prefix(180))
        }
        return nil
    }
}
