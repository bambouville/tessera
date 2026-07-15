import Foundation
import Observation

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

    init(
        location: AgentLocation,
        foreground: AgentIntegrationForeground,
        processIDs: Set<Int>,
        shellIntegrationActive: Bool?,
        agentIntegrationActive: Bool
    ) {
        self.location = location
        self.foreground = foreground
        self.processIDs = processIDs
        self.shellIntegrationActive = shellIntegrationActive
        self.agentIntegrationActive = agentIntegrationActive
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
    }

    let kind: Kind
    let title: String
    let message: String
    let actionLabel: String?
    let action: AgentIntegrationFixAction?
    let secondaryActionLabel: String?
    let secondaryAction: AgentIntegrationFixAction?

    init(
        kind: Kind,
        title: String,
        message: String,
        actionLabel: String?,
        action: AgentIntegrationFixAction?,
        secondaryActionLabel: String? = nil,
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
        guard let requested else { return nil }
        if requested == action || requested == secondaryAction { return requested }

        switch (requested, action) {
        case (.installOnly, .installAndApply):
            return .installAndApply
        case (.installOnly, .apply), (.installAndApply, .apply):
            return .apply
        case (.installAndApply, .installOnly):
            return .installOnly
        default:
            return nil
        }
    }

    func supports(_ candidate: AgentIntegrationFixAction?) -> Bool {
        effectiveAction(for: candidate) != nil
    }

    var showsWarning: Bool {
        kind != .checking && kind != .ready && kind != .busyProgram
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
        if target.foreground == .agent {
            switch installation {
            case .missing:
                return Self(
                    kind: .notInstalled,
                    title: "Agent integration not installed",
                    message: "Installs Tessera's hook files now. Relaunch this running agent afterward so it can report lifecycle status.",
                    actionLabel: "Install integration",
                    action: .installOnly
                )
            case .outdated:
                return Self(
                    kind: .outdated,
                    title: "Agent integration needs an update",
                    message: "Updates Tessera's hook files now. Relaunch this running agent afterward so it uses the new integration.",
                    actionLabel: "Update integration",
                    action: .installOnly
                )
            case .current:
                if target.agentIntegrationActive { return .ready }
                return Self(
                    kind: .insideAgent,
                    title: "Agent lifecycle hook inactive",
                    message: "The hook files are installed, but this running agent has not reported a trusted lifecycle event. In Codex, review Tessera's hook groups with /hooks; otherwise relaunch the agent.",
                    actionLabel: nil,
                    action: nil
                )
            }
        }

        switch installation {
        case .missing:
            let canApply = target.foreground == .shell
            return Self(
                kind: .notInstalled,
                title: "Agent integration not installed",
                message: canApply
                    ? "Installs Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
                    : "Installs Tessera's local hook files. Return to a shell prompt afterward to enable this terminal.",
                actionLabel: canApply ? "Install and enable" : "Install integration",
                action: canApply ? .installAndApply : .installOnly
            )
        case .outdated:
            let canApply = target.foreground == .shell
            return Self(
                kind: .outdated,
                title: "Agent integration needs an update",
                message: canApply
                    ? "Updates Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
                    : "Updates Tessera's local hook files. Return to a shell prompt afterward to enable this terminal.",
                actionLabel: canApply ? "Update and enable" : "Update integration",
                action: canApply ? .installAndApply : .installOnly
            )
        case .current:
            if target.shellIntegrationActive == true { return .ready }
            if target.foreground == .shell {
                guard target.shellIntegrationActive != nil else {
                    return .unavailable(
                        "The terminal-specific check failed. Tessera will retry after the next command."
                    )
                }
                return Self(
                    kind: .inactiveShell,
                    title: "Agent integration inactive here",
                    message: "Loads Tessera's shell marker here. Enable automatically also saves the guarded activation line in this shell's startup file for future windows.",
                    actionLabel: "Enable in this shell",
                    action: .apply,
                    secondaryActionLabel: "Enable automatically",
                    secondaryAction: .persistAndApply
                )
            }
            if target.foreground == .unsupportedShell {
                return Self(
                    kind: .unsupportedShell,
                    title: "Open bash or zsh to enable integration",
                    message: "Tessera preserves other shell configurations and only sources its provider shims into bash or zsh.",
                    actionLabel: nil,
                    action: nil
                )
            }
            return Self(
                kind: .busyProgram,
                title: "Integration check paused",
                message: "Tessera will recheck when the foreground program returns to its shell.",
                actionLabel: nil,
                action: nil
            )
        }
    }

    static let manualCheckRequired = Self(
        kind: .manualCheckRequired,
        title: "Check agent integration",
        message: "Plain mosh needs a secondary SSH check; your key may ask to unlock.",
        actionLabel: "Check now",
        action: .check
    )

    static func unavailable(_ detail: String? = nil) -> Self {
        Self(
            kind: .unavailable,
            title: "Could not verify agent integration",
            message: detail ?? "Retry the check without changing the host.",
            actionLabel: "Retry",
            action: .retry
        )
    }
}

struct AgentLifecycleEvent: Equatable, Sendable {
    /// Released installer revisions 2, 3, 4, 6, 7, and 8 emitted the same
    /// PID-bound lifecycle envelope. (Revision 5 was never released.) Installer
    /// updates changed launch/config behavior, not this retained wire contract.
    /// Keep those events readable while an agent that predates an update is
    /// still running; the exact current file revision is verified independently
    /// by the host installation probe.
    static let compatibleVersions: Set<Int> = [2, 3, 4, 6, 7, 8]
    static let supportedVersion = 8

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

    var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampNanoseconds) / 1_000_000_000)
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
        struct WireEvent: Decodable {
            let version: Int
            let provider: String
            let event: String
            let state: String
            let reason: String?
            let timestampNs: String
            let sessionId: String?
            let turnId: String?
            let notificationType: String?
            let permissionMode: String?
            let agentPid: Int?
        }

        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireEvent.self, from: data),
              compatibleVersions.contains(wire.version),
              wire.provider == "claude" || wire.provider == "codex",
              let timestampNanoseconds = UInt64(wire.timestampNs),
              let allowedStates = [
                  "SessionStart": ["idle"],
                  "SubagentStart": ["working"],
                  "SubagentStop": ["working"],
                  "UserPromptSubmit": ["working"],
                  "PreToolUse": ["working"],
                  "PostToolUse": ["working"],
                  "PermissionRequest": ["waitingForInput"],
                  "Notification": ["waitingForInput", "idle"],
                  "Stop": ["idle"],
                  "StopFailure": ["unavailable"],
                  "SessionEnd": ["unavailable"],
                  "WrapperExit": ["unavailable"],
              ][wire.event],
              allowedStates.contains(wire.state),
              wire.agentPid.map({ $0 > 1 }) ?? true
        else { return nil }

        let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        func validToken(_ value: String?, maximumLength: Int) -> Bool {
            guard let value else { return true }
            return value.count <= maximumLength
                && value.unicodeScalars.allSatisfy(tokenCharacters.contains)
        }
        guard validToken(wire.reason, maximumLength: 64),
              validToken(wire.sessionId, maximumLength: 256),
              validToken(wire.turnId, maximumLength: 256),
              validToken(wire.notificationType, maximumLength: 64),
              validToken(wire.permissionMode, maximumLength: 64)
        else { return nil }

        let state: AgentStatus
        switch wire.state {
        case "waitingForInput": state = .waitingForInput
        case "working": state = .working
        case "idle": state = .idle
        case "unavailable": state = .unavailable
        default: return nil
        }

        return Self(
            version: wire.version,
            provider: wire.provider,
            event: wire.event,
            state: state,
            reason: wire.reason ?? "",
            timestampNanoseconds: timestampNanoseconds,
            providerSessionID: wire.sessionId ?? "",
            turnID: wire.turnId ?? "",
            notificationType: wire.notificationType ?? "",
            permissionMode: wire.permissionMode ?? "",
            agentPID: wire.agentPid
        )
    }
}

/// Streaming parser for Tessera's private semantic lifecycle OSC. Hooks write
/// `OSC 1337;TesseraAgentState=<base64-json> BEL` to the owning terminal. The
/// scanner is intentionally transport-blind: raw SSH/mosh bytes and tmux pane
/// output both enter through AgentCenter.noteOutput.
struct AgentLifecycleOSCScanner: Sendable {
    private enum State: Sendable {
        case normal
        case escape
        case osc([UInt8])
        case oscEscape([UInt8])
    }

    private static let prefix = Array("1337;TesseraAgentState=".utf8)
    private var state: State = .normal
    private let maximumOSCBytes = 16 * 1024
    private(set) var candidateChunkCount = 0

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [AgentLifecycleEvent] {
        if case .normal = state,
           !containsOSCCandidate(bytes) {
            return []
        }
        candidateChunkCount &+= 1
        var events: [AgentLifecycleEvent] = []
        for byte in bytes {
            switch state {
            case .normal:
                if byte == 0x1B { state = .escape }
                else if byte == 0x9D { state = .osc([]) }
            case .escape:
                if byte == 0x5D { state = .osc([]) }
                else { state = byte == 0x1B ? .escape : .normal }
            case .osc(var buffer):
                if byte == 0x07 {
                    finish(buffer, into: &events)
                    state = .normal
                } else if byte == 0x1B {
                    state = .oscEscape(buffer)
                } else {
                    buffer.append(byte)
                    state = buffer.count <= maximumOSCBytes ? .osc(buffer) : .normal
                }
            case .oscEscape(var buffer):
                if byte == 0x5C {
                    finish(buffer, into: &events)
                    state = .normal
                } else {
                    buffer.append(0x1B)
                    buffer.append(byte)
                    state = buffer.count <= maximumOSCBytes ? .osc(buffer) : .normal
                }
            }
        }
        return events
    }

    private func containsOSCCandidate(_ bytes: ArraySlice<UInt8>) -> Bool {
        if bytes.contains(0x9D) { return true }
        var searchStart = bytes.startIndex
        while searchStart < bytes.endIndex,
              let escape = bytes[searchStart...].firstIndex(of: 0x1B) {
            let next = bytes.index(after: escape)
            if next == bytes.endIndex || bytes[next] == 0x5D { return true }
            searchStart = next
        }
        return false
    }

    private func finish(
        _ buffer: [UInt8],
        into events: inout [AgentLifecycleEvent]
    ) {
        guard buffer.starts(with: Self.prefix) else { return }
        let encoded = String(decoding: buffer.dropFirst(Self.prefix.count), as: UTF8.self)
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
        guard let paneID else { return "\(hostName) · raw session" }
        var parts = [hostName]
        if let tmuxSessionName, !tmuxSessionName.isEmpty { parts.append(tmuxSessionName) }
        if let windowID {
            if let windowName, !windowName.isEmpty {
                parts.append("window \(windowID) “\(windowName)”")
            } else {
                parts.append("window \(windowID)")
            }
        }
        parts.append("pane %\(paneID)")
        return parts.joined(separator: " · ")
    }
}

enum AgentAttentionKind: Int, CaseIterable, Comparable, Sendable {
    case needsInput = 0
    case justFinished = 1

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One unread, actionable transition for an exact agent location. This is
/// intentionally separate from `AgentStatus`: visiting the raw pane or tmux
/// window acknowledges it without erasing the real waiting/finished state.
struct AgentAttention: Identifiable, Equatable, Sendable {
    var id: AgentInstanceID { agentID }
    let agentID: AgentInstanceID
    let kind: AgentAttentionKind
    let occurredAt: Date
    let sequence: UInt64
}

struct AgentPromptOption: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let responseMacro: String
    let isDefault: Bool
}

struct AgentPrompt: Equatable, Sendable {
    /// The normalized visible prompt segment. Kept verbatim so stale-prompt
    /// checking does not depend on process-randomized `Hasher` output.
    let signature: String
    let summary: String
    let options: [AgentPromptOption]
}

struct AgentInstance: Identifiable, Equatable, Sendable {
    let id: AgentInstanceID
    let profileID: UUID
    let name: String
    /// Provider-owned conversation identifier. Only a short, local reference
    /// is rendered so otherwise-identical panes remain distinguishable.
    var providerSessionID: String?
    var location: AgentLocation
    var status: AgentStatus
    /// Most recently visible free-form user composer row. It is retained when
    /// a working TUI clears the composer so cards keep a human-meaningful task
    /// label without fetching or storing conversation history.
    var taskSummary: String?
    var outputTail: String?
    var prompt: AgentPrompt?
    var detectedAt: Date
    var statusChangedAt: Date
    /// Local observation time for the accepted root Stop event. This avoids
    /// letting remote clock skew stretch or erase the five-minute finished
    /// window while still allowing retained events to age naturally.
    var finishedAt: Date?
    /// Timestamp carried by the newest accepted provider lifecycle event.
    /// Unlike `statusChangedAt`, this advances for same-state events so Agent
    /// Center can keep each state group ordered by actual agent activity.
    var lastLifecycleEventAt: Date?
    var lastOutputAt: Date?
    var outputSequence: UInt64
    var bracketedPasteEnabled: Bool
    var sendInFlight: Bool
    var actionMessage: String?
    var actionIsError: Bool

    var providerSessionReference: String? {
        guard let providerSessionID,
              !providerSessionID.isEmpty else { return nil }
        return String(providerSessionID.prefix(8))
    }
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
    let lifecycleEvent: AgentLifecycleEvent?
    let bracketedPasteEnabled: Bool

    init(
        location: AgentLocation,
        processNames: [String],
        processIDs: Set<Int> = [],
        visibleText: String?,
        currentInputLine: String? = nil,
        lifecycleEvent: AgentLifecycleEvent? = nil,
        bracketedPasteEnabled: Bool
    ) {
        self.location = location
        self.processNames = processNames
        self.processIDs = processIDs
        self.visibleText = visibleText
        self.currentInputLine = currentInputLine
        self.lifecycleEvent = lifecycleEvent
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }
}

enum AgentDiscoveryResult: Sendable {
    case success([AgentProbeTarget])
    /// The carrier could not produce an authoritative snapshot. Keep the last
    /// good cards and retry instead of treating this as “zero agents”.
    case unavailable
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
    /// Cheap output-pulse path for an already-known target. It captures only
    /// that pane/viewport and deliberately avoids process-tree discovery.
    let observe: @MainActor (AgentLocation) async -> AgentProbeTarget?
    /// Strong post-send snapshot. tmux sources always capture the remote pane
    /// instead of trusting a potentially lagging mosh-rendered surface.
    let verifySend: @MainActor (AgentLocation) async -> AgentProbeTarget?
    let inspect: @MainActor (AgentLocation) async -> AgentProbeTarget?
    let lifecycleIntegrationCacheKey: String
    let automaticallyProbeLifecycleIntegration: Bool
    let probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)?
    let installLifecycleIntegration: (@MainActor () async throws -> Void)?
    let automaticallyInspectCurrentIntegration: @MainActor () -> Bool
    let inspectCurrentIntegration: (@MainActor () async -> AgentCurrentIntegrationTarget?)?
    let applyLifecycleIntegrationToCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)?
    let persistLifecycleIntegrationInCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)?
    let send: @MainActor (AgentLocation, [UInt8]) async -> Bool
    /// tmux must encode Enter/Escape according to the pane's negotiated
    /// keyboard mode. nil keeps synthetic and raw-only sources compatible.
    let sendKey: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)?
    let jump: @MainActor (AgentLocation) -> Void

    init(
        registrationID: UUID,
        sessionID: UUID,
        discover: @escaping @MainActor () async -> AgentDiscoveryResult,
        observe: @escaping @MainActor (AgentLocation) async -> AgentProbeTarget?,
        verifySend: (@MainActor (AgentLocation) async -> AgentProbeTarget?)? = nil,
        inspect: @escaping @MainActor (AgentLocation) async -> AgentProbeTarget?,
        lifecycleIntegrationCacheKey: String? = nil,
        automaticallyProbeLifecycleIntegration: Bool = true,
        probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)? = nil,
        installLifecycleIntegration: (@MainActor () async throws -> Void)? = nil,
        automaticallyInspectCurrentIntegration: @escaping @MainActor () -> Bool = { true },
        inspectCurrentIntegration: (@MainActor () async -> AgentCurrentIntegrationTarget?)? = nil,
        applyLifecycleIntegrationToCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)? = nil,
        persistLifecycleIntegrationInCurrentShell: (@MainActor (AgentCurrentIntegrationTarget) async -> Bool)? = nil,
        send: @escaping @MainActor (AgentLocation, [UInt8]) async -> Bool,
        sendKey: (@MainActor (AgentLocation, AgentInputKey) async -> Bool)? = nil,
        jump: @escaping @MainActor (AgentLocation) -> Void
    ) {
        self.registrationID = registrationID
        self.sessionID = sessionID
        self.discover = discover
        self.observe = observe
        self.verifySend = verifySend ?? observe
        self.inspect = inspect
        self.lifecycleIntegrationCacheKey = lifecycleIntegrationCacheKey ?? sessionID.uuidString
        self.automaticallyProbeLifecycleIntegration = automaticallyProbeLifecycleIntegration
        self.probeLifecycleIntegration = probeLifecycleIntegration
        self.installLifecycleIntegration = installLifecycleIntegration
        self.automaticallyInspectCurrentIntegration = automaticallyInspectCurrentIntegration
        self.inspectCurrentIntegration = inspectCurrentIntegration
        self.applyLifecycleIntegrationToCurrentShell = applyLifecycleIntegrationToCurrentShell
        self.persistLifecycleIntegrationInCurrentShell = persistLifecycleIntegrationInCurrentShell
        self.send = send
        self.sendKey = sendKey
        self.jump = jump
    }
}

enum AgentPromptParser {
    struct Result: Equatable {
        let text: String
        let prompt: AgentPrompt?
        let blockingPromptDetected: Bool
        let isIdlePrompt: Bool
    }

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

        let candidateBlockingMatch = latestMatch(
            patterns: rules.blockingPromptPatterns,
            text: text
        )
        let viewportIdleMatch = latestMatch(
            patterns: rules.idlePromptPatterns,
            text: text
        )
        let currentLineIsIdle = currentInputLine.map {
            latestMatch(
                patterns: rules.idlePromptPatterns,
                text: AgentTerminalText.normalized($0)
            ) != nil
        }
        let currentLineOwnsBlockingPrompt: Bool? = currentInputLine.map { rawLine in
            let line = AgentTerminalText.normalized(rawLine)
            guard !line.isEmpty else { return true }
            if latestMatch(patterns: rules.blockingPromptPatterns, text: line) != nil {
                return true
            }
            if let optionRegex = try? NSRegularExpression(
                pattern: rules.menuOptionPattern,
                options: [.caseInsensitive]
            ), optionRegex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil {
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
            let options = parseOptions(in: segment, rules: rules)
            let summary = promptSummary(in: segment)
            prompt = options.isEmpty ? nil : AgentPrompt(
                signature: stablePromptSignature(
                    text: text,
                    blockingStart: start,
                    segment: segment,
                    rules: rules
                ),
                summary: summary,
                options: options
            )
        } else {
            prompt = nil
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
        rules: AgentDetectionRules
    ) -> [AgentPromptOption] {
        guard let regex = try? NSRegularExpression(
            pattern: rules.menuOptionPattern,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(segment.startIndex..., in: segment)
        return regex.matches(in: segment, range: range).prefix(9).compactMap { match in
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
            let template = shortcut.isEmpty
                ? rules.fallbackResponseTemplate
                : rules.responseTemplate
            let response = template
                .replacingOccurrences(of: "{index}", with: String(index))
                .replacingOccurrences(of: "{shortcut}", with: shortcut)
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
    }

    private static func latestMatch(
        patterns: [String],
        text: String
    ) -> NSTextCheckingResult? {
        let fullRange = NSRange(text.startIndex..., in: text)
        return patterns.compactMap { pattern -> NSTextCheckingResult? in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { return nil }
            return regex.matches(in: text, range: fullRange).last
        }.max { lhs, rhs in lhs.range.location < rhs.range.location }
    }

    private static func promptSummary(in segment: String) -> String {
        let lines = segment.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first ?? "input requested"
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
        rules: AgentDetectionRules
    ) -> String {
        let precedingContext = text[..<blockingStart]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)

        var stableSegment = segment
        if let regex = try? NSRegularExpression(
            pattern: rules.menuOptionPattern,
            options: [.caseInsensitive]
        ),
           let finalOption = regex.matches(
                in: segment,
                range: NSRange(segment.startIndex..., in: segment)
           ).last,
           let range = Range(finalOption.range, in: segment) {
            stableSegment = String(segment[..<range.upperBound])
        }

        return (precedingContext + stableSegment
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
            .map { selectionNeutralPromptLine(String($0), rules: rules) }
            .joined(separator: "\u{1F}")
    }

    private static func selectionNeutralPromptLine(
        _ line: String,
        rules: AgentDetectionRules
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: rules.menuOptionPattern,
            options: [.caseInsensitive]
        ),
        let match = regex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ),
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

        for scalar in raw.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                if value == 0x1B {
                    state = .escape
                } else if value == 0x0D {
                    // A captured viewport is already row-oriented. Treat CR as
                    // a line boundary only when it is not followed by LF; the
                    // duplicate newlines are collapsed below.
                    output.append("\n")
                } else if value == 0x0A || value == 0x09 || value >= 0x20 {
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

@MainActor
@Observable
final class AgentCenter {
    private enum SubmissionSettleState {
        case readyForReturn
        case alreadySubmitted
    }

    private struct DiscardedLifecycleEvent {
        let timestampNanoseconds: UInt64
        let agentPID: Int?
    }

    /// First observation of one cursor-owned blocking prompt within the
    /// semantic lifecycle timeline. This handles both provider orderings:
    /// pixels may land just before or just after PermissionRequest. A prompt
    /// that survived a newer working/idle event is stale and cannot confirm it.
    private struct BlockingPromptEpoch {
        let signature: String
        let firstSeenLifecycleRevision: UInt64
    }

    private struct InactiveAgentDiagnosticIdentity: Equatable {
        let agentID: AgentInstanceID
        let processIDs: Set<Int>
    }

    private struct CachedHostIntegrationInstallation {
        let installation: AgentLifecycleHostInstallation
        let checkedAt: Date
    }

    private struct SharedHostInstall {
        let token: UUID
        let task: Task<Result<Void, Error>, Never>
    }

    private struct VisibleTarget: Equatable {
        let sessionID: UUID
        let windowID: Int?
        let paneID: Int?
    }

    private static let integrationProbeCacheLifetime: TimeInterval = 60

    private static func diagnosticSessionID(_ sessionID: UUID) -> String {
        String(sessionID.uuidString.prefix(8))
    }

    private static func diagnosticPaneID(_ paneID: Int?) -> String {
        paneID.map(String.init) ?? "raw"
    }

    private static func diagnosticInstallation(
        _ installation: AgentLifecycleHostInstallation
    ) -> String {
        switch installation {
        case .current: return "current"
        case .missing: return "missing"
        case .outdated(let version): return "outdated-\(version.map(String.init) ?? "unknown")"
        }
    }

    private static let diagnosticLifecycleEvents: Set<String> = [
        "SessionStart", "SubagentStart", "SubagentStop",
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SessionEnd", "WrapperExit",
    ]

    private static func diagnosticLifecycleEvent(_ event: String) -> String {
        diagnosticLifecycleEvents.contains(event) ? event : "other"
    }

    private static func diagnosticProvider(profileID: UUID) -> String {
        if profileID == SwipePadProfile.builtInClaudeCodeID { return "claude" }
        if profileID == SwipePadProfile.builtInCodexCLIID { return "codex" }
        return "custom"
    }

    private static func diagnosticProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": return "claude"
        case "codex": return "codex"
        default: return "other"
        }
    }

    private static func diagnosticPermissionMode(_ mode: String) -> String {
        switch mode {
        case "": return "missing"
        case "default": return "default"
        case "acceptEdits": return "accept-edits"
        case "auto": return "auto"
        case "plan": return "plan"
        case "dontAsk": return "dont-ask"
        case "bypassPermissions": return "bypass-permissions"
        default: return "other"
        }
    }

    /// Codex emits PermissionRequest before its automatic approval classifier
    /// has necessarily decided to involve the user. Claude notifications can
    /// follow the same ordering. These events prove integration/liveness, but
    /// terminal pixels must corroborate the user-blocking state.
    private static func requiresVisiblePromptConfirmation(
        _ event: AgentLifecycleEvent
    ) -> Bool {
        guard event.state == .waitingForInput else { return false }
        return event.event == "PermissionRequest"
            || (event.event == "Notification"
                && (event.notificationType == "permission_prompt"
                    || event.notificationType == "elicitation_dialog"
                    || event.reason == "permission"))
    }
    private(set) var isEnabled: Bool
    private(set) var agents: [AgentInstance] = []
    private(set) var unreadAttentions: [AgentAttention] = []
    private(set) var surfaceDemand = false
    private(set) var activityRevision: UInt64 = 0
    private(set) var observationBootstrapSessionIDs: Set<UUID> = []
    private(set) var currentIntegrationStates: [UUID: AgentIntegrationWarningState] = [:]

    @ObservationIgnored private var sources: [UUID: AgentSessionSource] = [:]
    @ObservationIgnored private var profiles: [SwipePadProfile] = SwipePadProfile.allBuiltIns
    @ObservationIgnored private var outputActivity: [AgentInstanceID: (Date, UInt64)] = [:]
    @ObservationIgnored private var lifecycleScanners: [AgentInstanceID: AgentLifecycleOSCScanner] = [:]
    @ObservationIgnored private var lifecycleEvents: [AgentInstanceID: AgentLifecycleEvent] = [:]
    @ObservationIgnored private var lifecycleArrivalRevisions: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var lifecyclePromptSubmitRevisions: [AgentInstanceID: UInt64] = [:]
    /// Permission hooks also fire while Codex's automatic policy classifier
    /// is deciding. A waiting state is accepted only after the corresponding
    /// visible blocking prompt has been observed for this exact event.
    @ObservationIgnored private var permissionPromptConfirmations: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var permissionPromptPendingSince: [AgentInstanceID: Date] = [:]
    /// Codex paints its plan-approval menu after Stop and exposes no separate
    /// hook for that UI. Keep a brief output-driven observation window so a
    /// first capture that beats the repaint is followed by the next paint
    /// chunk, even while Agent Center itself is not open.
    @ObservationIgnored private var postStopPromptPendingSince: [
        AgentInstanceID: Date
    ] = [:]
    @ObservationIgnored private var blockingPromptEpochs: [
        AgentInstanceID: BlockingPromptEpoch
    ] = [:]
    @ObservationIgnored private var latestNonBlockingLifecycleRevisions: [
        AgentInstanceID: UInt64
    ] = [:]
    @ObservationIgnored private var processIDs: [AgentInstanceID: Set<Int>] = [:]
    @ObservationIgnored private var discardedLifecycleEvents: [AgentInstanceID: DiscardedLifecycleEvent] = [:]
    @ObservationIgnored private var inputStatusOverrides: [AgentInstanceID: AgentStatus] = [:]
    @ObservationIgnored private var bracketedPasteModes: [AgentInstanceID: Bool] = [:]
    @ObservationIgnored private var terminalModeTails: [AgentInstanceID: [UInt8]] = [:]
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshDueAt: [UUID: Date] = [:]
    @ObservationIgnored private var refreshGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var observationTasks: [AgentInstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var observationGenerations: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var observationDueAt: [AgentInstanceID: Date] = [:]
    @ObservationIgnored private var lastDiscoveryAt: [UUID: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var sendTasks: [AgentInstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var completionExpiryTasks: [AgentInstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var completionExpiryGenerations: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var completionObservedAt: [AgentInstanceID: Date] = [:]
    @ObservationIgnored private var attentionDeliveryTasks: [AgentInstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attentionDeliveryGenerations: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var attentionSequence: UInt64 = 0
    @ObservationIgnored private var applicationIsActive = false
    @ObservationIgnored private var agentCenterSurfaceIsVisible = false
    @ObservationIgnored private var visibleTarget: VisibleTarget?
    @ObservationIgnored private var integrationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var integrationProbeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var integrationProbeRetryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentIntegrationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentIntegrationActivityTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentIntegrationActivityGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var currentIntegrationGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var lastCurrentIntegrationActivityRefreshAt: [UUID: Date] = [:]
    @ObservationIgnored private var currentIntegrationShellProbeFailures: [UUID: Int] = [:]
    @ObservationIgnored private var currentIntegrationTargetFailures: [UUID: Int] = [:]
    @ObservationIgnored private var currentIntegrationTargetIDs: [UUID: AgentInstanceID] = [:]
    @ObservationIgnored private var currentIntegrationForegrounds: [
        UUID: AgentIntegrationForeground
    ] = [:]
    /// Force one fresh host diagnostic per exact inactive agent incarnation.
    /// Subsequent convergence checks use the route cache instead of rerunning
    /// checksums/config probes while the same process remains in the pane.
    @ObservationIgnored private var inactiveAgentDiagnosticIdentities: [
        UUID: InactiveAgentDiagnosticIdentity
    ] = [:]
    /// A newly created tmux pane can become visible before its interactive
    /// shell finishes sourcing the correct rc file. Retry that one exact
    /// shell process on a short bounded schedule; never turn the steady-state
    /// inactive warning into a polling loop.
    @ObservationIgnored private var shellStartupConvergenceIdentities: [
        UUID: InactiveAgentDiagnosticIdentity
    ] = [:]
    @ObservationIgnored private var sharedHostInstalls: [String: SharedHostInstall] = [:]
    @ObservationIgnored private var integrationGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var integrationProbeGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var observationReadySessionIDs: Set<UUID> = []
    @ObservationIgnored private var hostIntegrationInstallations: [String: CachedHostIntegrationInstallation] = [:]
    @ObservationIgnored private var hostIntegrationProbeFailures: Set<String> = []
    @ObservationIgnored private var hostIntegrationProbeFailedAt: [String: Date] = [:]
    @ObservationIgnored private var hostIntegrationAutomaticRetryCounts: [String: Int] = [:]
    @ObservationIgnored private var sendGenerations: [AgentInstanceID: UInt64] = [:]
    @ObservationIgnored private var pendingJump: AgentInstanceID?
    @ObservationIgnored private let sendVerificationDelayNanoseconds: UInt64
    @ObservationIgnored private let justFinishedDuration: TimeInterval
    @ObservationIgnored private let completionAttentionDelayNanoseconds: UInt64
    @ObservationIgnored private let integrationProbeFailureBackoffNanoseconds: UInt64
    @ObservationIgnored private let currentIntegrationTargetRetryDelaysNanoseconds: [UInt64]
    #if DEBUG
    @ObservationIgnored private var harnessIntegrationStates: [AgentInstanceID: AgentLifecycleIntegrationState] = [:]
    #endif

    @ObservationIgnored var onJumpToSession: ((UUID) -> Void)?
    @ObservationIgnored var onWaitingForInput: ((AgentInstance) -> Void)?
    @ObservationIgnored var onAttention: ((AgentAttention, AgentInstance) -> Void)?
    @ObservationIgnored var onAttentionAcknowledged: ((AgentInstanceID) -> Void)?

    init(
        isEnabled: Bool = true,
        sendVerificationDelayNanoseconds: UInt64 = 2_000_000_000,
        justFinishedDuration: TimeInterval = 5 * 60,
        completionAttentionDelayNanoseconds: UInt64 = 250_000_000,
        integrationProbeFailureBackoffNanoseconds: UInt64 = 5_000_000_000,
        currentIntegrationTargetRetryDelaysNanoseconds: [UInt64] = [
            100_000_000,
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
        ]
    ) {
        self.isEnabled = isEnabled
        self.sendVerificationDelayNanoseconds = sendVerificationDelayNanoseconds
        self.justFinishedDuration = max(0, justFinishedDuration)
        self.completionAttentionDelayNanoseconds = completionAttentionDelayNanoseconds
        self.integrationProbeFailureBackoffNanoseconds =
            integrationProbeFailureBackoffNanoseconds
        self.currentIntegrationTargetRetryDelaysNanoseconds =
            currentIntegrationTargetRetryDelaysNanoseconds
    }

    var workingCount: Int { agents.count { $0.status == .working } }
    var waitingCount: Int { agents.count { $0.status == .waitingForInput } }
    /// Green chrome is an unread-attention signal, not the five-minute
    /// semantic completion state. Visiting a pane/window removes this count
    /// while its card can remain in `just finished` until normal expiry.
    var unreadJustFinishedCount: Int {
        unreadAttentions.count { $0.kind == .justFinished }
    }
    var sessionIDsWithAgents: Set<UUID> { Set(agents.map { $0.id.sessionID }) }

    var sortedAgents: [AgentInstance] {
        agents.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status < rhs.status }
            let lhsEventAt = lhs.lastLifecycleEventAt ?? lhs.statusChangedAt
            let rhsEventAt = rhs.lastLifecycleEventAt ?? rhs.statusChangedAt
            if lhsEventAt != rhsEventAt {
                return lhsEventAt > rhsEventAt
            }
            if lhs.statusChangedAt != rhs.statusChangedAt {
                return lhs.statusChangedAt > rhs.statusChangedAt
            }
            return lhs.location.addressText < rhs.location.addressText
        }
    }

    var sortedUnreadAttentions: [AgentAttention] {
        unreadAttentions.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.sequence > rhs.sequence
        }
    }

    func agentInstance(_ id: AgentInstanceID) -> AgentInstance? {
        agent(id)
    }

    func hasUnreadJustFinished(sessionID: UUID) -> Bool {
        unreadAttentions.contains {
            $0.kind == .justFinished && $0.agentID.sessionID == sessionID
        }
    }

    func hasUnreadJustFinished(sessionID: UUID, windowID: Int) -> Bool {
        unreadAttentions.contains { attention in
            guard attention.kind == .justFinished,
                  attention.agentID.sessionID == sessionID
            else { return false }
            return agent(attention.agentID)?.location.windowID == windowID
        }
    }

    /// Scene activity and selected terminal identity are supplied separately so
    /// a background transition cannot race a stale top-bar identity. Returning
    /// to the app acknowledges only agents on the raw pane or tmux window that
    /// is now visible.
    func setApplicationActive(_ active: Bool) {
        guard applicationIsActive != active else {
            if active { acknowledgeVisibleTarget(reason: "app-active-refresh") }
            return
        }
        applicationIsActive = active
        DiagnosticLogStore.appendAgentCenter(
            "attention-app-state active=\(active) unread=\(unreadAttentions.count)"
        )
        if active {
            reconcileCompletionExpiries(now: .now)
            if agentCenterSurfaceIsVisible {
                markAllAttentionsRead(reason: "agent-center-foreground")
            }
            acknowledgeVisibleTarget(reason: "app-foreground")
        }
    }

    /// Updates the one terminal surface the user can actually see. Inactive
    /// SessionViews may report their disappearance, so a clear is accepted
    /// only when it belongs to the same session as the current target.
    func setVisibleTarget(
        sessionID: UUID,
        windowID: Int?,
        paneID: Int?,
        isVisible: Bool
    ) {
        if isVisible {
            let target = VisibleTarget(
                sessionID: sessionID,
                windowID: windowID,
                paneID: paneID
            )
            if visibleTarget != target {
                DiagnosticLogStore.appendAgentCenter(
                    "attention-visible-target sid=\(Self.diagnosticSessionID(sessionID)) window=\(windowID.map(String.init) ?? "raw") pane=\(Self.diagnosticPaneID(paneID)) selected=true"
                )
            }
            visibleTarget = target
            acknowledgeVisibleTarget(reason: "pane-visited")
        } else if visibleTarget?.sessionID == sessionID {
            visibleTarget = nil
            DiagnosticLogStore.appendAgentCenter(
                "attention-visible-target sid=\(Self.diagnosticSessionID(sessionID)) window=\(windowID.map(String.init) ?? "raw") pane=\(Self.diagnosticPaneID(paneID)) selected=false"
            )
        }
    }

    func markAllAttentionsRead(reason: String = "agent-center") {
        attentionDeliveryTasks.values.forEach { $0.cancel() }
        attentionDeliveryTasks.removeAll()
        attentionDeliveryGenerations = attentionDeliveryGenerations.mapValues { $0 &+ 1 }
        let ids = unreadAttentions.map(\.agentID)
        guard !ids.isEmpty else { return }
        unreadAttentions.removeAll()
        for id in ids { onAttentionAcknowledged?(id) }
        DiagnosticLogStore.appendAgentCenter(
            "attention-ack reason=\(reason) scope=all count=\(ids.count)"
        )
    }

    func setAgentCenterSurfaceVisible(_ visible: Bool) {
        agentCenterSurfaceIsVisible = visible
        guard visible, applicationIsActive else { return }
        markAllAttentionsRead(reason: "agent-center-visible")
    }

    func syncProfiles(_ profiles: [SwipePadProfile]) {
        self.profiles = profiles
    }

    /// Keeps session registrations warm so enabling the experiment does not
    /// require reconnecting, while cancelling every discovery/action task and
    /// discarding all derived state when the feature is off.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        DiagnosticLogStore.appendAgentCenter(
            "feature-state enabled=\(enabled) sources=\(sources.count) protocol=\(AgentLifecycleEvent.supportedVersion)"
        )
        if enabled {
            observationBootstrapSessionIDs = Set(sources.keys)
            observationReadySessionIDs.removeAll()
            refreshAll()
            return
        }

        surfaceDemand = false
        pollTask?.cancel()
        pollTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        refreshDueAt.removeAll()
        observationTasks.values.forEach { $0.cancel() }
        observationTasks.removeAll()
        observationDueAt.removeAll()
        sendTasks.values.forEach { $0.cancel() }
        sendTasks.removeAll()
        completionExpiryTasks.values.forEach { $0.cancel() }
        completionExpiryTasks.removeAll()
        attentionDeliveryTasks.values.forEach { $0.cancel() }
        attentionDeliveryTasks.removeAll()
        integrationTasks.values.forEach { $0.cancel() }
        integrationTasks.removeAll()
        integrationProbeTasks.values.forEach { $0.cancel() }
        integrationProbeTasks.removeAll()
        integrationProbeRetryTasks.values.forEach { $0.cancel() }
        integrationProbeRetryTasks.removeAll()
        currentIntegrationTasks.values.forEach { $0.cancel() }
        currentIntegrationTasks.removeAll()
        currentIntegrationActivityTasks.values.forEach { $0.cancel() }
        currentIntegrationActivityTasks.removeAll()
        // A user-confirmed host install is route-shared and may already be
        // mutating remote files. Keep that unstructured operation alive; all
        // terminal-specific waiters are cancelled below, so disabling the
        // feature can never source text into a shell afterward. Re-enabling
        // joins the same install instead of racing it with a duplicate.
        integrationGenerations = integrationGenerations.mapValues { $0 &+ 1 }
        integrationProbeGenerations = integrationProbeGenerations.mapValues { $0 &+ 1 }
        currentIntegrationGenerations = currentIntegrationGenerations.mapValues { $0 &+ 1 }
        currentIntegrationActivityGenerations = currentIntegrationActivityGenerations.mapValues { $0 &+ 1 }
        refreshGenerations = refreshGenerations.mapValues { $0 &+ 1 }
        observationGenerations = observationGenerations.mapValues { $0 &+ 1 }
        sendGenerations = sendGenerations.mapValues { $0 &+ 1 }
        completionExpiryGenerations = completionExpiryGenerations.mapValues { $0 &+ 1 }
        attentionDeliveryGenerations = attentionDeliveryGenerations.mapValues { $0 &+ 1 }
        lastDiscoveryAt.removeAll()
        agents.removeAll()
        unreadAttentions.removeAll()
        outputActivity.removeAll()
        lifecycleScanners.removeAll()
        lifecycleEvents.removeAll()
        lifecycleArrivalRevisions.removeAll()
        lifecyclePromptSubmitRevisions.removeAll()
        permissionPromptConfirmations.removeAll()
        permissionPromptPendingSince.removeAll()
        postStopPromptPendingSince.removeAll()
        blockingPromptEpochs.removeAll()
        latestNonBlockingLifecycleRevisions.removeAll()
        processIDs.removeAll()
        discardedLifecycleEvents.removeAll()
        inputStatusOverrides.removeAll()
        bracketedPasteModes.removeAll()
        terminalModeTails.removeAll()
        completionObservedAt.removeAll()
        observationBootstrapSessionIDs.removeAll()
        observationReadySessionIDs.removeAll()
        currentIntegrationStates.removeAll()
        lastCurrentIntegrationActivityRefreshAt.removeAll()
        currentIntegrationShellProbeFailures.removeAll()
        currentIntegrationTargetFailures.removeAll()
        currentIntegrationTargetIDs.removeAll()
        currentIntegrationForegrounds.removeAll()
        inactiveAgentDiagnosticIdentities.removeAll()
        shellStartupConvergenceIdentities.removeAll()
        hostIntegrationProbeFailedAt.removeAll()
        hostIntegrationAutomaticRetryCounts.removeAll()
        pendingJump = nil
        visibleTarget = nil
        agentCenterSurfaceIsVisible = false
        activityRevision &+= 1
    }

    func register(_ source: AgentSessionSource) {
        let sid = Self.diagnosticSessionID(source.sessionID)
        let replacesSource = sources[source.sessionID].map {
            $0.registrationID != source.registrationID
        } ?? false
        if let current = sources[source.sessionID],
           current.registrationID != source.registrationID {
            currentIntegrationTasks.removeValue(forKey: source.sessionID)?.cancel()
            currentIntegrationActivityTasks.removeValue(forKey: source.sessionID)?.cancel()
            currentIntegrationActivityGenerations[source.sessionID] =
                (currentIntegrationActivityGenerations[source.sessionID] ?? 0) &+ 1
            currentIntegrationGenerations[source.sessionID] =
                (currentIntegrationGenerations[source.sessionID] ?? 0) &+ 1
            currentIntegrationStates.removeValue(forKey: source.sessionID)
            currentIntegrationShellProbeFailures.removeValue(forKey: source.sessionID)
            currentIntegrationTargetFailures.removeValue(forKey: source.sessionID)
            currentIntegrationTargetIDs.removeValue(forKey: source.sessionID)
            currentIntegrationForegrounds.removeValue(forKey: source.sessionID)
            inactiveAgentDiagnosticIdentities.removeValue(forKey: source.sessionID)
            shellStartupConvergenceIdentities.removeValue(forKey: source.sessionID)
            clearSessionState(sessionID: source.sessionID)
        }
        sources[source.sessionID] = source
        DiagnosticLogStore.appendAgentCenter(
            "source-register sid=\(sid) replacement=\(replacesSource) enabled=\(isEnabled) autoHostProbe=\(source.automaticallyProbeLifecycleIntegration) autoCurrentProbe=\(source.automaticallyInspectCurrentIntegration()) protocol=\(AgentLifecycleEvent.supportedVersion)"
        )
        guard isEnabled else { return }
        observationBootstrapSessionIDs.insert(source.sessionID)
        scheduleRefresh(sessionID: source.sessionID, delayNanoseconds: 0)
    }

    func unregister(sessionID: UUID, registrationID: UUID) {
        guard sources[sessionID]?.registrationID == registrationID else { return }
        DiagnosticLogStore.appendAgentCenter(
            "source-unregister sid=\(Self.diagnosticSessionID(sessionID)) agents=\(agents.count { $0.id.sessionID == sessionID })"
        )
        sources.removeValue(forKey: sessionID)
        observationBootstrapSessionIDs.remove(sessionID)
        observationReadySessionIDs.remove(sessionID)
        currentIntegrationTasks.removeValue(forKey: sessionID)?.cancel()
        currentIntegrationActivityTasks.removeValue(forKey: sessionID)?.cancel()
        currentIntegrationActivityGenerations[sessionID] =
            (currentIntegrationActivityGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationGenerations[sessionID] = (currentIntegrationGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationStates.removeValue(forKey: sessionID)
        lastCurrentIntegrationActivityRefreshAt.removeValue(forKey: sessionID)
        currentIntegrationShellProbeFailures.removeValue(forKey: sessionID)
        currentIntegrationTargetFailures.removeValue(forKey: sessionID)
        currentIntegrationTargetIDs.removeValue(forKey: sessionID)
        currentIntegrationForegrounds.removeValue(forKey: sessionID)
        inactiveAgentDiagnosticIdentities.removeValue(forKey: sessionID)
        shellStartupConvergenceIdentities.removeValue(forKey: sessionID)
        clearSessionState(sessionID: sessionID)
    }

    private func clearSessionState(sessionID: UUID) {
        refreshTasks.removeValue(forKey: sessionID)?.cancel()
        refreshDueAt.removeValue(forKey: sessionID)
        refreshGenerations[sessionID] = (refreshGenerations[sessionID] ?? 0) &+ 1
        for id in Array(observationTasks.keys).filter({ $0.sessionID == sessionID }) {
            observationTasks.removeValue(forKey: id)?.cancel()
            observationDueAt.removeValue(forKey: id)
            observationGenerations[id] = (observationGenerations[id] ?? 0) &+ 1
        }
        for id in Array(completionExpiryTasks.keys).filter({ $0.sessionID == sessionID }) {
            completionExpiryTasks.removeValue(forKey: id)?.cancel()
            completionExpiryGenerations[id] = (completionExpiryGenerations[id] ?? 0) &+ 1
        }
        for id in Array(attentionDeliveryTasks.keys).filter({ $0.sessionID == sessionID }) {
            attentionDeliveryTasks.removeValue(forKey: id)?.cancel()
            attentionDeliveryGenerations[id] = (attentionDeliveryGenerations[id] ?? 0) &+ 1
        }
        lastDiscoveryAt.removeValue(forKey: sessionID)
        let removedAgents = agents.contains { $0.id.sessionID == sessionID }
        agents.removeAll { $0.id.sessionID == sessionID }
        let acknowledged = unreadAttentions
            .filter { $0.agentID.sessionID == sessionID }
            .map(\.agentID)
        unreadAttentions.removeAll { $0.agentID.sessionID == sessionID }
        for id in acknowledged { onAttentionAcknowledged?(id) }
        outputActivity = outputActivity.filter { $0.key.sessionID != sessionID }
        lifecycleScanners = lifecycleScanners.filter { $0.key.sessionID != sessionID }
        lifecycleEvents = lifecycleEvents.filter { $0.key.sessionID != sessionID }
        lifecycleArrivalRevisions = lifecycleArrivalRevisions.filter {
            $0.key.sessionID != sessionID
        }
        lifecyclePromptSubmitRevisions = lifecyclePromptSubmitRevisions.filter {
            $0.key.sessionID != sessionID
        }
        permissionPromptConfirmations = permissionPromptConfirmations.filter {
            $0.key.sessionID != sessionID
        }
        permissionPromptPendingSince = permissionPromptPendingSince.filter {
            $0.key.sessionID != sessionID
        }
        postStopPromptPendingSince = postStopPromptPendingSince.filter {
            $0.key.sessionID != sessionID
        }
        blockingPromptEpochs = blockingPromptEpochs.filter {
            $0.key.sessionID != sessionID
        }
        latestNonBlockingLifecycleRevisions = latestNonBlockingLifecycleRevisions.filter {
            $0.key.sessionID != sessionID
        }
        processIDs = processIDs.filter { $0.key.sessionID != sessionID }
        discardedLifecycleEvents = discardedLifecycleEvents.filter {
            $0.key.sessionID != sessionID
        }
        inputStatusOverrides = inputStatusOverrides.filter { $0.key.sessionID != sessionID }
        bracketedPasteModes = bracketedPasteModes.filter { $0.key.sessionID != sessionID }
        terminalModeTails = terminalModeTails.filter { $0.key.sessionID != sessionID }
        completionObservedAt = completionObservedAt.filter { $0.key.sessionID != sessionID }
        for id in Array(sendTasks.keys).filter({ $0.sessionID == sessionID }) {
            sendTasks.removeValue(forKey: id)?.cancel()
            sendGenerations[id] = (sendGenerations[id] ?? 0) &+ 1
        }
        if removedAgents { activityRevision &+= 1 }
    }

    private static func isRootCompletion(_ event: AgentLifecycleEvent) -> Bool {
        event.event == "Stop" && event.state == .idle && !event.isStatusNeutral
    }

    private func completionDate(
        for event: AgentLifecycleEvent,
        agentID: AgentInstanceID,
        now: Date
    ) -> Date? {
        guard Self.isRootCompletion(event) else { return nil }
        if let observed = completionObservedAt[agentID] { return observed }
        // A retained event may predate this app process. Preserve its real age,
        // but never accept a remote future clock as a five-minute extension.
        return min(event.timestamp, now)
    }

    private func recordCompletionBoundary(
        _ event: AgentLifecycleEvent,
        agentID: AgentInstanceID,
        isStreamed: Bool,
        now: Date
    ) {
        if Self.isRootCompletion(event) {
            if isStreamed || completionObservedAt[agentID] == nil {
                completionObservedAt[agentID] = isStreamed
                    ? now
                    : min(event.timestamp, now)
            }
        } else if !event.isStatusNeutral {
            completionObservedAt.removeValue(forKey: agentID)
            cancelCompletionExpiry(agentID: agentID)
        }
    }

    private func completionIsFresh(_ completedAt: Date?, now: Date) -> Bool {
        guard let completedAt else { return false }
        let elapsed = now.timeIntervalSince(completedAt)
        return elapsed >= 0 && elapsed < justFinishedDuration
    }

    private func scheduleCompletionExpiry(
        agentID: AgentInstanceID,
        completedAt: Date
    ) {
        cancelCompletionExpiry(agentID: agentID)
        let deadline = completedAt.addingTimeInterval(justFinishedDuration)
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else {
            expireCompletion(agentID: agentID, completedAt: completedAt, now: .now)
            return
        }
        let generation = (completionExpiryGenerations[agentID] ?? 0) &+ 1
        completionExpiryGenerations[agentID] = generation
        let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
        DiagnosticLogStore.appendAgentCenter(
            "finished-expiry-scheduled sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) remainingMs=\(max(0, Int(delay * 1_000))) generation=\(generation)"
        )
        completionExpiryTasks[agentID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self?.completionExpiryGenerations[agentID] == generation
            else { return }
            self?.expireCompletion(
                agentID: agentID,
                completedAt: completedAt,
                now: .now
            )
        }
    }

    private func cancelCompletionExpiry(agentID: AgentInstanceID) {
        completionExpiryTasks.removeValue(forKey: agentID)?.cancel()
        completionExpiryGenerations[agentID] =
            (completionExpiryGenerations[agentID] ?? 0) &+ 1
    }

    private func expireCompletion(
        agentID: AgentInstanceID,
        completedAt: Date,
        now: Date
    ) {
        completionExpiryTasks.removeValue(forKey: agentID)
        guard let index = agents.firstIndex(where: { $0.id == agentID }),
              agents[index].status == .justFinished,
              agents[index].finishedAt == completedAt,
              now >= completedAt.addingTimeInterval(justFinishedDuration)
        else { return }
        let previous = agents[index]
        agents[index].status = .idle
        agents[index].statusChangedAt = completedAt.addingTimeInterval(justFinishedDuration)
        agents[index].finishedAt = nil
        let updated = agents[index]
        handleStatusTransition(
            from: previous,
            to: updated,
            source: "finished-expiry"
        )
        DiagnosticLogStore.appendAgentCenter(
            "status-transition sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) source=finished-expiry previous=justFinished next=idle elapsed=\(Int(now.timeIntervalSince(completedAt)))"
        )
        activityRevision &+= 1
    }

    private func reconcileCompletionExpiries(now: Date) {
        for agent in agents where agent.status == .justFinished {
            guard let completedAt = agent.finishedAt else { continue }
            if now >= completedAt.addingTimeInterval(justFinishedDuration) {
                expireCompletion(
                    agentID: agent.id,
                    completedAt: completedAt,
                    now: now
                )
            } else {
                scheduleCompletionExpiry(agentID: agent.id, completedAt: completedAt)
            }
        }
    }

    /// A raw transport renders one pane. A tmux window can render a full split
    /// grid, so every agent in the selected window is already in front of the
    /// user even when another pane currently owns keyboard focus.
    private func isVisible(_ agent: AgentInstance) -> Bool {
        guard applicationIsActive else { return false }
        if agentCenterSurfaceIsVisible { return true }
        guard let visibleTarget else { return false }
        return isVisible(agent, in: visibleTarget)
    }

    private func isVisible(
        _ agent: AgentInstance,
        in target: VisibleTarget
    ) -> Bool {
        guard target.sessionID == agent.id.sessionID else { return false }
        switch (target.windowID, agent.location.windowID) {
        case (.some(let visibleWindow), .some(let agentWindow)):
            return visibleWindow == agentWindow
        case (.none, .none):
            return target.paneID == agent.id.paneID
        case (.some, .none), (.none, .some):
            return false
        }
    }

    private func acknowledgeVisibleTarget(reason: String) {
        guard applicationIsActive, let visibleTarget else { return }
        let visibleAgents = agents.filter { isVisible($0, in: visibleTarget) }
        for agent in visibleAgents {
            cancelPendingAttention(agentID: agent.id)
            markAttentionRead(agentID: agent.id, reason: reason)
        }
    }

    private func cancelPendingAttention(agentID: AgentInstanceID) {
        let pending = attentionDeliveryTasks.removeValue(forKey: agentID)
        pending?.cancel()
        attentionDeliveryGenerations[agentID] =
            (attentionDeliveryGenerations[agentID] ?? 0) &+ 1
        if pending != nil {
            DiagnosticLogStore.appendAgentCenter(
                "attention-pending-cancelled sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID))"
            )
        }
    }

    private func markAttentionRead(agentID: AgentInstanceID, reason: String) {
        guard unreadAttentions.contains(where: { $0.agentID == agentID }) else { return }
        unreadAttentions.removeAll { $0.agentID == agentID }
        onAttentionAcknowledged?(agentID)
        DiagnosticLogStore.appendAgentCenter(
            "attention-ack sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) reason=\(reason)"
        )
    }

    private func handleStatusTransition(
        from previous: AgentInstance?,
        to agent: AgentInstance,
        source: String
    ) {
        let changed = previous?.status != agent.status
        if agent.status == .justFinished, let completedAt = agent.finishedAt {
            if previous?.status != .justFinished
                || previous?.finishedAt != completedAt
                || completionExpiryTasks[agent.id] == nil {
                scheduleCompletionExpiry(agentID: agent.id, completedAt: completedAt)
            }
        } else if previous?.status == .justFinished
                    || completionExpiryTasks[agent.id] != nil {
            cancelCompletionExpiry(agentID: agent.id)
        }

        guard changed else { return }
        switch agent.status {
        case .waitingForInput:
            onWaitingForInput?(agent)
            scheduleAttention(
                kind: .needsInput,
                agent: agent,
                occurredAt: agent.statusChangedAt,
                delayNanoseconds: 0,
                source: source
            )
        case .justFinished:
            scheduleAttention(
                kind: .justFinished,
                agent: agent,
                occurredAt: agent.finishedAt ?? agent.statusChangedAt,
                delayNanoseconds: completionAttentionDelayNanoseconds,
                source: source
            )
        case .working, .idle, .unavailable:
            cancelPendingAttention(agentID: agent.id)
            markAttentionRead(agentID: agent.id, reason: "state-changed")
        }
    }

    private func scheduleAttention(
        kind: AgentAttentionKind,
        agent: AgentInstance,
        occurredAt: Date,
        delayNanoseconds: UInt64,
        source: String
    ) {
        cancelPendingAttention(agentID: agent.id)
        if isVisible(agent) {
            markAttentionRead(agentID: agent.id, reason: "visible-at-transition")
            DiagnosticLogStore.appendAgentCenter(
                "attention-suppressed sid=\(Self.diagnosticSessionID(agent.id.sessionID)) pane=\(Self.diagnosticPaneID(agent.id.paneID)) kind=\(String(describing: kind)) reason=visible source=\(source)"
            )
            return
        }
        let generation = (attentionDeliveryGenerations[agent.id] ?? 0) &+ 1
        attentionDeliveryGenerations[agent.id] = generation
        guard delayNanoseconds > 0 else {
            publishAttention(
                kind: kind,
                agentID: agent.id,
                occurredAt: occurredAt,
                generation: generation,
                source: source
            )
            return
        }
        DiagnosticLogStore.appendAgentCenter(
            "attention-pending sid=\(Self.diagnosticSessionID(agent.id.sessionID)) pane=\(Self.diagnosticPaneID(agent.id.paneID)) kind=\(String(describing: kind)) delayMs=\(delayNanoseconds / 1_000_000) source=\(source)"
        )
        attentionDeliveryTasks[agent.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.publishAttention(
                kind: kind,
                agentID: agent.id,
                occurredAt: occurredAt,
                generation: generation,
                source: source
            )
        }
    }

    private func publishAttention(
        kind: AgentAttentionKind,
        agentID: AgentInstanceID,
        occurredAt: Date,
        generation: UInt64,
        source: String
    ) {
        guard attentionDeliveryGenerations[agentID] == generation,
              let agent = agent(agentID),
              (kind == .needsInput && agent.status == .waitingForInput)
                || (kind == .justFinished && agent.status == .justFinished)
        else { return }
        attentionDeliveryTasks.removeValue(forKey: agentID)
        if isVisible(agent) {
            markAttentionRead(agentID: agentID, reason: "visible-before-delivery")
            DiagnosticLogStore.appendAgentCenter(
                "attention-suppressed sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) kind=\(String(describing: kind)) reason=visible-after-delay source=\(source)"
            )
            return
        }
        attentionSequence &+= 1
        let attention = AgentAttention(
            agentID: agentID,
            kind: kind,
            occurredAt: occurredAt,
            sequence: attentionSequence
        )
        if let index = unreadAttentions.firstIndex(where: { $0.agentID == agentID }) {
            unreadAttentions[index] = attention
        } else {
            unreadAttentions.append(attention)
        }
        DiagnosticLogStore.appendAgentCenter(
            "attention-emitted sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) kind=\(String(describing: kind)) appActive=\(applicationIsActive) source=\(source) unread=\(unreadAttentions.count)"
        )
        onAttention?(attention, agent)
    }

    func setSurfaceDemand(_ active: Bool) {
        guard isEnabled else {
            surfaceDemand = false
            return
        }
        guard surfaceDemand != active else { return }
        surfaceDemand = active
        DiagnosticLogStore.appendAgentCenter(
            "surface-demand active=\(active) sources=\(sources.count) agents=\(agents.count)"
        )
        pollTask?.cancel()
        pollTask = nil
        guard active else { return }
        // Registration and output pulses already schedule discovery. Opening
        // the page must not cancel/restart those operations or hammer every
        // tmux control channel again when the user switches tabs quickly.
        refreshStaleSessions(olderThan: 30)
        let sessionsToPromote = refreshDueAt.compactMap { sessionID, dueAt in
            dueAt.timeIntervalSinceNow > 2 ? sessionID : nil
        }
        for sessionID in sessionsToPromote {
            scheduleRefresh(sessionID: sessionID, delayNanoseconds: 0)
        }
        // Opening the page should immediately hydrate every card from its
        // current viewport. This also corroborates a retained permission hook
        // without keeping background panes on a continuous capture loop.
        for agent in agents {
            scheduleObservation(agentID: agent.id, delayNanoseconds: 0)
        }
        for agent in agents where agent.status == .unavailable
            && sources[agent.id.sessionID]?.automaticallyProbeLifecycleIntegration == true
            && agentIDSupportedByLifecycleIntegration(agent.id) {
            scheduleLifecycleIntegrationProbe(sessionID: agent.id.sessionID)
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshStaleSessions(olderThan: 25)
            }
        }
    }

    /// Mosh uses a separate -CC side channel. Keep it alive while a central
    /// surface is visible, or after an agent has been found in that session so
    /// background waiting transitions remain observable.
    func shouldMaintainObservation(sessionID: UUID) -> Bool {
        isEnabled && (
            surfaceDemand
                || observationBootstrapSessionIDs.contains(sessionID)
                || agents.contains { $0.id.sessionID == sessionID }
        )
    }

    /// Mosh+tmux calls this after its side-channel has entered control mode.
    /// Keep the bootstrap demand latched through the resulting discovery so a
    /// quiet background pane cannot lose the carrier between ready and probe.
    func observationCarrierBecameReady(sessionID: UUID) {
        guard isEnabled, sources[sessionID] != nil else { return }
        observationReadySessionIDs.insert(sessionID)
        requestRefresh(sessionID: sessionID)
    }

    func noteOutput(
        sessionID: UUID,
        paneID: Int?,
        registrationID: UUID? = nil,
        data: ArraySlice<UInt8>? = nil
    ) {
        guard isEnabled else { return }
        if let registrationID,
           sources[sessionID]?.registrationID != registrationID {
            return
        }
        let id = AgentInstanceID(sessionID: sessionID, paneID: paneID)
        var receivedLifecycleEvent = false
        var receivedPromptBoundary = false
        if let data, !data.isEmpty {
            var scanner = lifecycleScanners[id] ?? AgentLifecycleOSCScanner()
            let events = scanner.feed(data)
            lifecycleScanners[id] = scanner
            for event in events {
                let accepted = applyLifecycleEvent(event, to: id, isStreamed: true)
                receivedLifecycleEvent = accepted || receivedLifecycleEvent
                // Codex has no native lifecycle event for its final plan
                // approval menu. Stop is the nearest semantic boundary: one
                // cheap pane snapshot here distinguishes an ordinary idle
                // composer from a newly painted, cursor-owned plan dialog.
                receivedPromptBoundary = receivedPromptBoundary
                    || (accepted && event.event == "Stop" && event.state == .idle)
            }
        }
        let isKnownAgent = agents.contains(where: { $0.id == id })
        if isKnownAgent, let data, !data.isEmpty {
            trackTerminalModes(agentID: id, data: data)
        }
        let prior = outputActivity[id]?.1 ?? 0
        outputActivity[id] = (.now, prior &+ 1)
        if isKnownAgent {
            // This method is on the terminal rendering hot path. Keep the raw
            // timestamp/sequence in ObservationIgnored storage and publish
            // only the debounced parsed snapshot; mutating `agents` or
            // `activityRevision` for every chunk invalidates ContentView,
            // every tab bar, and the palette hundreds of times per second.
            let hasSemanticState = lifecycleEvents[id] != nil
            let pendingPermissionConfirmation: (pending: Bool, age: TimeInterval) = {
                guard let event = lifecycleEvents[id],
                      Self.requiresVisiblePromptConfirmation(event),
                      permissionPromptConfirmations[id] != event.timestampNanoseconds,
                      let pendingSince = permissionPromptPendingSince[id]
                else { return (false, 0) }
                return (true, Date.now.timeIntervalSince(pendingSince))
            }()
            let pendingPostStopPrompt: Bool = {
                guard let pendingSince = postStopPromptPendingSince[id] else {
                    return false
                }
                let isFresh = Date.now.timeIntervalSince(pendingSince) <= 3
                if !isFresh {
                    postStopPromptPendingSince.removeValue(forKey: id)
                }
                return isFresh
            }()
            if !hasSemanticState
                || surfaceDemand
                || pendingPermissionConfirmation.pending
                || pendingPostStopPrompt
                || receivedPromptBoundary {
                let observationDelay: UInt64
                if receivedPromptBoundary {
                    observationDelay = 60_000_000
                } else if pendingPermissionConfirmation.pending,
                   pendingPermissionConfirmation.age <= 8 {
                    observationDelay = 60_000_000
                } else if pendingPostStopPrompt {
                    observationDelay = 60_000_000
                } else if surfaceDemand {
                    // Integrated lifecycle events already update status on the
                    // raw output path. Limit background-pane capture work to a
                    // readable excerpt cadence; unintegrated panes retain the
                    // faster visual fallback because pixels are all they have.
                    observationDelay = hasSemanticState
                        ? 1_500_000_000
                        : 1_000_000_000
                } else {
                    observationDelay = 2_000_000_000
                }
                scheduleObservation(
                    agentID: id,
                    delayNanoseconds: observationDelay
                )
            }
            // Hook lifecycle events validate liveness and status directly.
            // Keep process discovery as a slow exit/replacement check instead
            // of turning every burst of model output into remote list/capture
            // commands.
            if hasSemanticState {
                if receivedLifecycleEvent {
                    // A PID-bound provider event is a fresher liveness proof
                    // than another process-tree walk. Besides avoiding work,
                    // this prevents an immediate discovery snapshot from
                    // racing and cancelling the 60 ms post-Stop plan-menu
                    // observation before the provider paints that dialog.
                    lastDiscoveryAt[sessionID] = .now
                }
                let elapsed = Date.now.timeIntervalSince(lastDiscoveryAt[sessionID] ?? .distantPast)
                if refreshTasks[sessionID] == nil, elapsed >= 30 {
                    scheduleRefresh(sessionID: sessionID, delayNanoseconds: 0)
                }
                return
            }
            let elapsed = Date.now.timeIntervalSince(lastDiscoveryAt[sessionID] ?? .distantPast)
            if refreshTasks[sessionID] == nil {
                let minimumInterval = surfaceDemand ? 2.0 : 60.0
                let validationDelay = max(0.18, minimumInterval - elapsed)
                scheduleRefresh(
                    sessionID: sessionID,
                    delayNanoseconds: UInt64(validationDelay * 1_000_000_000)
                )
            }
        } else {
            if receivedLifecycleEvent { return }
            // Unknown-pane output is the discovery trigger. Keep the closed
            // surface path deliberately slow: raw mosh may need an SSH exec
            // side channel for process discovery, and a busy TUI must not turn
            // into a one-command-per-second poller.
            guard refreshTasks[sessionID] == nil else { return }
            let elapsed = Date.now.timeIntervalSince(lastDiscoveryAt[sessionID] ?? .distantPast)
            let minimumInterval = surfaceDemand ? 2.0 : 60.0
            let remaining = max(0, minimumInterval - elapsed)
            let delay = max(UInt64(180_000_000), UInt64(remaining * 1_000_000_000))
            scheduleRefresh(sessionID: sessionID, delayNanoseconds: delay)
        }
    }

    func noteLifecyclePayload(
        sessionID: UUID,
        paneID: Int,
        registrationID: UUID? = nil,
        json: String
    ) {
        guard isEnabled else { return }
        if let registrationID,
           sources[sessionID]?.registrationID != registrationID {
            return
        }
        guard let event = AgentLifecycleEvent.decode(json: json) else {
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-rejected sid=\(Self.diagnosticSessionID(sessionID)) pane=\(paneID) delivery=retained reason=decode-or-version"
            )
            return
        }
        let id = AgentInstanceID(sessionID: sessionID, paneID: paneID)
        // tmux format subscriptions may replay an unchanged pane option. The
        // accepted event is already retained in memory, so avoid duplicate
        // main-actor work and two diagnostic writes per subscription tick.
        if lifecycleEvents[id] == event { return }
        _ = applyLifecycleEvent(event, to: id, isStreamed: false)
    }

    func noteInput(
        sessionID: UUID,
        paneID: Int?,
        registrationID: UUID? = nil,
        bytes: [UInt8]
    ) {
        guard isEnabled else { return }
        if let registrationID,
           sources[sessionID]?.registrationID != registrationID {
            return
        }
        let id = AgentInstanceID(sessionID: sessionID, paneID: paneID)
        let includesLineBreak = bytes.contains(0x0D) || bytes.contains(0x0A)
        if includesLineBreak {
            let state = currentIntegrationStates[sessionID]
            let shouldRefreshCurrentIntegration = state == nil
                || state?.kind == .checking
                || state?.isRepairing == true
                || state?.showsWarning == true
            if shouldRefreshCurrentIntegration,
               (currentIntegrationTargetIDs[sessionID] == nil
                    || currentIntegrationTargetIDs[sessionID] == id) {
                scheduleCurrentIntegrationRefreshAfterActivity(
                    sessionID: sessionID,
                    delayNanoseconds: 0,
                    bypassThrottle: true,
                    convergenceDelaysNanoseconds: [
                        100_000_000,
                        250_000_000,
                        500_000_000,
                        1_000_000_000,
                        2_000_000_000,
                    ],
                    reason: "terminal-return"
                )
            }
        }
        guard let index = agents.firstIndex(where: { $0.id == id }),
              agents[index].status == .waitingForInput
        else { return }

        var selectedOption = agents[index].prompt?.options.first { option in
            MacroEncoder.encode(option.responseMacro) == bytes
        }
        guard includesLineBreak || selectedOption != nil else { return }
        if selectedOption == nil,
           includesLineBreak,
           bytes.allSatisfy({ $0 == 0x0D || $0 == 0x0A }) {
            // Claude's arrow-key menu redraw marks the highlighted row. A bare
            // Return then chooses that row, so use the latest parsed marker to
            // distinguish an accepted request from a rejected one.
            selectedOption = agents[index].prompt?.options.first(where: \.isDefault)
        }
        let negativeSelection = selectedOption.map {
            let label = $0.label.lowercased()
            return label == "no"
                || label.contains("deny")
                || label.contains("cancel")
                || label.contains("reject")
        } ?? false
        let nextStatus: AgentStatus
        if lifecycleEvents[id] != nil {
            nextStatus = negativeSelection ? .idle : .working
            inputStatusOverrides[id] = nextStatus
        } else {
            // Prompt text can prove that input is required, but without a
            // lifecycle hook Tessera cannot infer what happens after it is
            // answered. Return to unavailable instead of creating a guess
            // that could survive indefinitely.
            nextStatus = .unavailable
            inputStatusOverrides.removeValue(forKey: id)
        }
        let previous = agents[index]
        agents[index].status = nextStatus
        agents[index].statusChangedAt = .now
        agents[index].finishedAt = nil
        agents[index].prompt = nil
        permissionPromptConfirmations.removeValue(forKey: id)
        permissionPromptPendingSince.removeValue(forKey: id)
        postStopPromptPendingSince.removeValue(forKey: id)
        blockingPromptEpochs.removeValue(forKey: id)
        DiagnosticLogStore.appendAgentCenter(
            "approval-input sid=\(Self.diagnosticSessionID(sessionID)) pane=\(Self.diagnosticPaneID(paneID)) selection=\(selectedOption == nil ? "unparsed" : (negativeSelection ? "negative" : "positive")) lifecycleProof=\(lifecycleEvents[id] != nil) nextState=\(String(describing: nextStatus))"
        )
        handleStatusTransition(
            from: previous,
            to: agents[index],
            source: "approval-input"
        )
        activityRevision &+= 1
    }

    @discardableResult
    private func applyLifecycleEvent(
        _ event: AgentLifecycleEvent,
        to id: AgentInstanceID,
        isStreamed: Bool
    ) -> Bool {
        let sid = Self.diagnosticSessionID(id.sessionID)
        let pane = Self.diagnosticPaneID(id.paneID)
        let eventName = Self.diagnosticLifecycleEvent(event.event)
        let provider = Self.diagnosticProvider(event.provider)
        let delivery = isStreamed ? "stream" : "retained"
        if let agent = agents.first(where: { $0.id == id }),
           matchingProfile(processNames: [event.processName])?.id != agent.profileID {
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-rejected sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reason=profile-mismatch"
            )
            return false
        }
        if event.agentPID == nil, event.provesRunningAgentIntegration {
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-rejected sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reason=missing-pid action=rediscover"
            )
            scheduleRefresh(sessionID: id.sessionID, delayNanoseconds: 0)
            return false
        }
        if let agentPID = event.agentPID,
           let currentProcessIDs = processIDs[id],
           !currentProcessIDs.isEmpty,
           !currentProcessIDs.contains(agentPID) {
            let previousMatchesSnapshot = lifecycleEvents[id]?.agentPID.map {
                currentProcessIDs.contains($0)
            } ?? false
            let provesNewerStreamedIncarnation = isStreamed
                && previousMatchesSnapshot
                && event.timestampNanoseconds >= (lifecycleEvents[id]?.timestampNanoseconds ?? 0)
            scheduleRefresh(sessionID: id.sessionID, delayNanoseconds: 0)
            if provesNewerStreamedIncarnation {
                // The direct terminal stream has moved to a newer provider
                // process before the slower ps snapshot caught up. Discard
                // the old PID generation and let the immediate refresh bind
                // this event to the new process.
                processIDs[id] = []
                DiagnosticLogStore.appendAgentCenter(
                    "lifecycle-pid-rebind sid=\(sid) pane=\(pane) provider=\(provider) event=\(eventName) snapshotCount=\(currentProcessIDs.count) action=accept-new-stream-generation"
                )
            } else {
                lifecycleEvents.removeValue(forKey: id)
                inputStatusOverrides.removeValue(forKey: id)
                permissionPromptConfirmations.removeValue(forKey: id)
                permissionPromptPendingSince.removeValue(forKey: id)
                postStopPromptPendingSince.removeValue(forKey: id)
                blockingPromptEpochs.removeValue(forKey: id)
                latestNonBlockingLifecycleRevisions.removeValue(forKey: id)
                completionObservedAt.removeValue(forKey: id)
                if let index = agents.firstIndex(where: { $0.id == id }) {
                    let previous = agents[index]
                    agents[index].status = .unavailable
                    agents[index].statusChangedAt = .now
                    agents[index].finishedAt = nil
                    agents[index].prompt = nil
                    handleStatusTransition(
                        from: previous,
                        to: agents[index],
                        source: "lifecycle-pid-rejected"
                    )
                    activityRevision &+= 1
                }
                DiagnosticLogStore.appendAgentCenter(
                    "lifecycle-rejected sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reason=pid-not-in-snapshot snapshotCount=\(currentProcessIDs.count) action=unavailable-and-rediscover"
                )
                return false
            }
        }
        if let discarded = discardedLifecycleEvents[id] {
            let provesDifferentProcessAtSameTime = isStreamed
                && event.timestampNanoseconds == discarded.timestampNanoseconds
                && event.agentPID != nil
                && discarded.agentPID != nil
                && event.agentPID != discarded.agentPID
            guard event.timestampNanoseconds > discarded.timestampNanoseconds
                    || provesDifferentProcessAtSameTime
            else {
                DiagnosticLogStore.appendAgentCenter(
                    "lifecycle-rejected sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reason=discarded-generation"
                )
                return false
            }
            discardedLifecycleEvents.removeValue(forKey: id)
        }
        let wasActive = lifecycleEvents[id] != nil
        if let previous = lifecycleEvents[id] {
            if event.timestampNanoseconds < previous.timestampNanoseconds {
                DiagnosticLogStore.appendAgentCenter(
                    "lifecycle-rejected sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reason=older-than-current"
                )
                return false
            }
            if event.timestampNanoseconds == previous.timestampNanoseconds,
               event == previous {
                DiagnosticLogStore.appendAgentCenter(
                    "lifecycle-duplicate sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName)"
                )
                return false
            }
        }
        let acceptedAt = Date.now
        recordCompletionBoundary(
            event,
            agentID: id,
            isStreamed: isStreamed,
            now: acceptedAt
        )
        if event.isStatusNeutral {
            var currentCheck = "not-applicable"
            if let source = sources[id.sessionID] {
                let targetsCurrentPane = currentIntegrationTargetIDs[id.sessionID] == id
                if (id.paneID == nil && !source.automaticallyInspectCurrentIntegration())
                    || targetsCurrentPane {
                    // The PID-bound event still proves that this exact running
                    // agent owns an active hook. It just cannot answer whether
                    // the root turn stopped before or after the child did.
                    currentIntegrationStates[id.sessionID] = .ready
                    currentIntegrationForegrounds[id.sessionID] = .agent
                    currentCheck = "direct-ready"
                }
            }
            if agents.first(where: { $0.id == id }) == nil {
                scheduleRefresh(sessionID: id.sessionID, delayNanoseconds: 0)
            }
            if let index = agents.firstIndex(where: { $0.id == id }),
               agents[index].lastLifecycleEventAt.map({ event.timestamp > $0 }) ?? true {
                agents[index].lastLifecycleEventAt = event.timestamp
                activityRevision &+= 1
            }
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-observed sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) semantic=status-neutral action=preserve-authoritative-state previousEvent=\(Self.diagnosticLifecycleEvent(lifecycleEvents[id]?.event ?? "")) currentCheck=\(currentCheck)"
            )
            return true
        }
        lifecycleEvents[id] = event
        let lifecycleRevision = (lifecycleArrivalRevisions[id] ?? 0) &+ 1
        lifecycleArrivalRevisions[id] = lifecycleRevision
        if event.event == "UserPromptSubmit" {
            lifecyclePromptSubmitRevisions[id] = lifecycleRevision
        }
        if event.state != .waitingForInput {
            latestNonBlockingLifecycleRevisions[id] = lifecycleRevision
        }
        if event.provider == "codex",
           event.event == "Stop",
           event.state == .idle {
            postStopPromptPendingSince[id] = .now
        } else {
            postStopPromptPendingSince.removeValue(forKey: id)
        }
        inputStatusOverrides.removeValue(forKey: id)

        let requiresPromptConfirmation = Self.requiresVisiblePromptConfirmation(event)
        if requiresPromptConfirmation {
            if permissionPromptConfirmations[id] != event.timestampNanoseconds {
                if blockingPromptIsFreshForLatestSemanticBoundary(id) {
                    // Some provider builds paint the modal immediately before
                    // emitting PermissionRequest. Its first-seen lifecycle
                    // epoch proves it appeared after the last working/idle
                    // boundary, so do not require a second pixel change.
                    permissionPromptConfirmations[id] = event.timestampNanoseconds
                    permissionPromptPendingSince.removeValue(forKey: id)
                } else {
                    permissionPromptConfirmations.removeValue(forKey: id)
                    permissionPromptPendingSince[id] = .now
                }
            }
        } else {
            permissionPromptConfirmations.removeValue(forKey: id)
            permissionPromptPendingSince.removeValue(forKey: id)
        }

        var currentCheck = "not-applicable"
        if let source = sources[id.sessionID] {
            if id.paneID == nil,
               !source.automaticallyInspectCurrentIntegration(),
               event.provesRunningAgentIntegration {
                // Plain mosh deliberately avoids opening secondary SSH on its
                // own. A current protocol event from its one raw terminal is
                // already stronger evidence than another host-side poll.
                currentIntegrationStates[id.sessionID] = .ready
                currentIntegrationForegrounds[id.sessionID] = .agent
                currentCheck = "direct-ready"
            } else if let currentState = currentIntegrationStates[id.sessionID] {
                let currentTarget = currentIntegrationTargetIDs[id.sessionID]
                let targetsCurrentPane = currentTarget == nil || currentTarget == id
                let isRuntimeBoundary = !wasActive || [
                    "SessionStart", "SessionEnd",
                    "WrapperExit", "StopFailure",
                ].contains(event.event)
                if currentState.kind == .ready {
                    let isExitBoundary = [
                        "SessionEnd", "WrapperExit", "StopFailure",
                    ].contains(event.event)
                    if targetsCurrentPane,
                       isRuntimeBoundary,
                       (isExitBoundary || currentIntegrationTasks[id.sessionID] != nil) {
                        // A PID-bound launch/exit event is newer than a slow
                        // periodic pane read. Supersede that one stale read,
                        // while ordinary tool/status hooks remain probe-free.
                        scheduleCurrentIntegrationRefreshAfterActivity(
                            sessionID: id.sessionID,
                            delayNanoseconds: 60_000_000,
                            bypassThrottle: true,
                            supersedeRead: true,
                            reason: "lifecycle"
                        )
                        currentCheck = "superseded-stale-read"
                    } else {
                        currentCheck = "skipped-ready"
                    }
                    return finishApplyingLifecycleEvent(
                        event,
                        to: id,
                        wasActive: wasActive,
                        lifecycleRevision: lifecycleRevision,
                        delivery: delivery,
                        provider: provider,
                        eventName: eventName,
                        requiresPromptConfirmation: requiresPromptConfirmation,
                        currentCheck: currentCheck
                    )
                }
                guard targetsCurrentPane, isRuntimeBoundary else {
                    // Status/tool hooks on background panes must not inspect
                    // or supersede the foreground terminal's top-bar check.
                    return finishApplyingLifecycleEvent(
                        event,
                        to: id,
                        wasActive: wasActive,
                        lifecycleRevision: lifecycleRevision,
                        delivery: delivery,
                        provider: provider,
                        eventName: eventName,
                        requiresPromptConfirmation: requiresPromptConfirmation,
                        currentCheck: targetsCurrentPane
                            ? "skipped-non-boundary"
                            : "skipped-background"
                    )
                }
                scheduleCurrentIntegrationRefreshAfterActivity(
                    sessionID: id.sessionID,
                    delayNanoseconds: 60_000_000,
                    bypassThrottle: true,
                    supersedeRead: true,
                    reason: "lifecycle"
                )
                currentCheck = "scheduled"
            }
        }

        return finishApplyingLifecycleEvent(
            event,
            to: id,
            wasActive: wasActive,
            lifecycleRevision: lifecycleRevision,
            delivery: delivery,
            provider: provider,
            eventName: eventName,
            requiresPromptConfirmation: requiresPromptConfirmation,
            currentCheck: currentCheck
        )
    }

    @discardableResult
    private func finishApplyingLifecycleEvent(
        _ event: AgentLifecycleEvent,
        to id: AgentInstanceID,
        wasActive: Bool,
        lifecycleRevision: UInt64,
        delivery: String,
        provider: String,
        eventName: String,
        requiresPromptConfirmation: Bool,
        currentCheck: String
    ) -> Bool {
        let sid = Self.diagnosticSessionID(id.sessionID)
        let pane = Self.diagnosticPaneID(id.paneID)
        let promptConfirmed = permissionPromptConfirmations[id]
            == event.timestampNanoseconds
        let completedAt = completionDate(for: event, agentID: id, now: .now)
        let displayedState: AgentStatus
        if requiresPromptConfirmation && !promptConfirmed {
            displayedState = .working
        } else if completionIsFresh(completedAt, now: .now) {
            displayedState = .justFinished
        } else {
            displayedState = event.state
        }
        if let index = agents.firstIndex(where: { $0.id == id }) {
            let previous = agents[index]
            let previousStatus = previous.status
            var cardChanged = false
            if agents[index].lastLifecycleEventAt.map({ event.timestamp > $0 }) ?? true {
                agents[index].lastLifecycleEventAt = event.timestamp
                cardChanged = true
            }
            if previousStatus != displayedState {
                agents[index].status = displayedState
                agents[index].statusChangedAt = displayedState == .justFinished
                    ? (completedAt ?? .now) : event.timestamp
                cardChanged = true
            } else if !wasActive {
                // The visible status may remain unavailable, but the UI still
                // needs to reflect that this running process proved its hook.
                cardChanged = true
            }
            let nextFinishedAt = displayedState == .justFinished ? completedAt : nil
            if agents[index].finishedAt != nextFinishedAt {
                agents[index].finishedAt = nextFinishedAt
                cardChanged = true
            }
            handleStatusTransition(
                from: previous,
                to: agents[index],
                source: "lifecycle-\(delivery)"
            )
            if cardChanged {
                activityRevision &+= 1
            }
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-accepted sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reportedState=\(String(describing: event.state)) previousState=\(String(describing: previousStatus)) nextState=\(String(describing: displayedState)) permissionPrompt=\(requiresPromptConfirmation ? (promptConfirmed ? "confirmed" : "awaiting-visible") : "not-required") currentCheck=\(currentCheck) revision=\(lifecycleRevision) card=present"
            )
        } else if sources[id.sessionID] != nil {
            DiagnosticLogStore.appendAgentCenter(
                "lifecycle-accepted sid=\(sid) pane=\(pane) delivery=\(delivery) provider=\(provider) event=\(eventName) reportedState=\(String(describing: event.state)) nextState=\(String(describing: displayedState)) permissionPrompt=\(requiresPromptConfirmation ? (promptConfirmed ? "confirmed" : "awaiting-visible") : "not-required") currentCheck=\(currentCheck) revision=\(lifecycleRevision) card=awaiting-discovery"
            )
            scheduleRefresh(sessionID: id.sessionID, delayNanoseconds: 0)
        }

        if event.state == .unavailable {
            scheduleRefresh(sessionID: id.sessionID, delayNanoseconds: 0)
        }
        return true
    }

    func refreshAll() {
        guard isEnabled else { return }
        for sessionID in sources.keys {
            scheduleRefresh(sessionID: sessionID, delayNanoseconds: 0)
        }
    }

    private func refreshStaleSessions(olderThan minimumAge: TimeInterval) {
        let now = Date.now
        for sessionID in sources.keys where refreshTasks[sessionID] == nil {
            let elapsed = now.timeIntervalSince(lastDiscoveryAt[sessionID] ?? .distantPast)
            if elapsed >= minimumAge {
                scheduleRefresh(sessionID: sessionID, delayNanoseconds: 0)
            }
        }
    }

    func requestRefresh(sessionID: UUID) {
        guard isEnabled else { return }
        scheduleRefresh(sessionID: sessionID, delayNanoseconds: 0)
    }

    func answer(agentID: AgentInstanceID, optionID: Int) {
        guard isEnabled else { return }
        guard let agent = agent(agentID),
              let prompt = agent.prompt,
              let option = prompt.options.first(where: { $0.id == optionID })
        else { return }
        let bytes = MacroEncoder.encode(option.responseMacro)
        _ = performSend(
            agentID: agentID,
            stages: Self.stagedSubmission(bytes),
            expectedPrompt: prompt,
            echoNeedle: nil,
            requiresTailChange: false
        )
    }

    @discardableResult
    func sendMessage(
        agentID: AgentInstanceID,
        text: String,
        onVerified: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        guard let agent = agent(agentID) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var bytes = Array(trimmed.utf8)
        if agent.bracketedPasteEnabled {
            bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
        return performSend(
            agentID: agentID,
            // Bracketed paste and Return are deliberately separate writes.
            // Both Claude Code and Codex treat paste as composer insertion;
            // submission is a subsequent keyboard event.
            stages: [bytes, [0x0D]],
            expectedPrompt: nil,
            echoNeedle: trimmed,
            requiresTailChange: false,
            completion: onVerified
        )
    }

    func interrupt(agentID: AgentInstanceID) {
        guard isEnabled else { return }
        _ = performSend(
            agentID: agentID,
            stages: [[0x1B]],
            expectedPrompt: nil,
            echoNeedle: nil,
            requiresTailChange: true
        )
    }

    func jump(agentID: AgentInstanceID) {
        guard isEnabled else { return }
        cancelPendingAttention(agentID: agentID)
        markAttentionRead(agentID: agentID, reason: "jump")
        guard let agent = agent(agentID),
              let source = sources[agent.id.sessionID] else {
            DiagnosticLogStore.appendAgentCenter(
                "attention-jump sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) result=pending-discovery"
            )
            pendingJump = agentID
            onJumpToSession?(agentID.sessionID)
            requestRefresh(sessionID: agentID.sessionID)
            return
        }
        DiagnosticLogStore.appendAgentCenter(
            "attention-jump sid=\(Self.diagnosticSessionID(agent.id.sessionID)) window=\(agent.location.windowID.map(String.init) ?? "raw") pane=\(Self.diagnosticPaneID(agent.location.paneID)) result=dispatch"
        )
        pendingJump = nil
        onJumpToSession?(agent.id.sessionID)
        source.jump(agent.location)
    }

    func clearActionMessage(agentID: AgentInstanceID) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].actionMessage = nil
        agents[index].actionIsError = false
    }

    func currentIntegrationState(sessionID: UUID) -> AgentIntegrationWarningState {
        currentIntegrationStates[sessionID] ?? .checking
    }

    /// A PID-validated lifecycle event already answers the provider question
    /// that process-adaptive controls would otherwise rediscover with a full
    /// remote `ps` walk. Return only the exact pane's live proof; callers keep
    /// their normal process probe as the fallback for custom/unintegrated
    /// tools and immediately lose this hint on SessionEnd/WrapperExit.
    func activeLifecycleProcessName(
        sessionID: UUID,
        paneID: Int?
    ) -> String? {
        guard isEnabled else { return nil }
        let id = AgentInstanceID(sessionID: sessionID, paneID: paneID)
        guard let event = lifecycleEvents[id],
              event.provesRunningAgentIntegration,
              agents.contains(where: { agent in
                  agent.id == id
                      && matchingProfile(processNames: [event.processName])?.id
                          == agent.profileID
              })
        else { return nil }
        return event.processName
    }

    /// Checks only the visible terminal target. Session top bars call this on
    /// activation/pane changes and at a slow cadence; background sessions do
    /// not poll. Host installation is cached separately from per-shell state.
    func requestCurrentIntegrationRefresh(
        sessionID: UUID,
        forceHostProbe: Bool = false,
        supersedeCurrent: Bool = false,
        allowManualSideChannel: Bool = false,
        reason: String = "external"
    ) {
        let sid = Self.diagnosticSessionID(sessionID)
        guard isEnabled else {
            DiagnosticLogStore.appendAgentCenter(
                "current-refresh sid=\(sid) reason=\(reason) result=skipped stage=feature-disabled"
            )
            return
        }
        guard let source = sources[sessionID] else {
            DiagnosticLogStore.appendAgentCenter(
                "current-refresh sid=\(sid) reason=\(reason) result=skipped stage=source-missing"
            )
            return
        }
        guard source.inspectCurrentIntegration != nil,
              source.probeLifecycleIntegration != nil else {
            DiagnosticLogStore.appendAgentCenter(
                "current-refresh sid=\(sid) reason=\(reason) result=skipped stage=capability-missing"
            )
            return
        }

        if let currentTask = currentIntegrationTasks[sessionID] {
            guard supersedeCurrent else {
                DiagnosticLogStore.appendAgentCenter(
                    "current-refresh sid=\(sid) reason=\(reason) result=coalesced inFlight=true"
                )
                return
            }
            currentTask.cancel()
            currentIntegrationTasks.removeValue(forKey: sessionID)
            DiagnosticLogStore.appendAgentCenter(
                "current-refresh sid=\(sid) reason=\(reason) action=supersede-read"
            )
        }
        if supersedeCurrent {
            currentIntegrationTargetFailures.removeValue(forKey: sessionID)
        }

        if !allowManualSideChannel,
           !source.automaticallyInspectCurrentIntegration() {
            if currentIntegrationStates[sessionID] == nil
                || currentIntegrationStates[sessionID] == .checking {
                currentIntegrationStates[sessionID] = .manualCheckRequired
            }
            DiagnosticLogStore.appendAgentCenter(
                "current-refresh sid=\(sid) reason=\(reason) result=manual-check-required"
            )
            return
        }

        if currentIntegrationStates[sessionID] == nil {
            currentIntegrationStates[sessionID] = .checking
        }
        let registrationID = source.registrationID
        let generation = (currentIntegrationGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationGenerations[sessionID] = generation
        DiagnosticLogStore.appendAgentCenter(
            "current-refresh sid=\(sid) reason=\(reason) result=started generation=\(generation) forceHostProbe=\(forceHostProbe) manualSideChannel=\(allowManualSideChannel) priorState=\(String(describing: currentIntegrationStates[sessionID]?.kind ?? .checking))"
        )
        currentIntegrationTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.currentIntegrationGenerations[sessionID] == generation {
                    self.currentIntegrationTasks.removeValue(forKey: sessionID)
                }
            }
            do {
                let resolution = try await self.resolveCurrentIntegration(
                    source: source,
                    forceHostProbe: forceHostProbe
                )
                guard self.currentIntegrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: registrationID,
                    generation: generation
                ) else { return }
                if self.currentIntegrationStates[sessionID] != resolution.state {
                    self.currentIntegrationStates[sessionID] = resolution.state
                }
                self.currentIntegrationForegrounds[sessionID] = resolution.target.foreground
                self.currentIntegrationTargetFailures.removeValue(forKey: sessionID)
                DiagnosticLogStore.appendAgentCenter(
                    "current-refresh sid=\(sid) reason=\(reason) result=resolved generation=\(generation) foreground=\(String(describing: resolution.target.foreground)) shellProbe=\(resolution.target.shellIntegrationActive.map(String.init) ?? "unknown") agentRuntime=\(resolution.target.agentIntegrationActive) state=\(String(describing: resolution.state.kind))"
                )
                self.handleCurrentShellProbeResult(
                    resolution.target.shellIntegrationActive,
                    sessionID: sessionID
                )
                let startupIdentity = InactiveAgentDiagnosticIdentity(
                    agentID: AgentInstanceID(
                        sessionID: resolution.target.location.sessionID,
                        paneID: resolution.target.location.paneID
                    ),
                    processIDs: resolution.target.processIDs
                )
                if resolution.state.kind == .inactiveShell,
                   resolution.target.foreground == .shell,
                   self.shellStartupConvergenceIdentities[sessionID] != startupIdentity {
                    self.shellStartupConvergenceIdentities[sessionID] = startupIdentity
                    DiagnosticLogStore.appendAgentCenter(
                        "shell-startup-convergence sid=\(sid) pane=\(Self.diagnosticPaneID(resolution.target.location.paneID)) processCount=\(resolution.target.processIDs.count) result=scheduled"
                    )
                    self.scheduleCurrentIntegrationRefreshAfterActivity(
                        sessionID: sessionID,
                        bypassThrottle: true,
                        convergenceDelaysNanoseconds: [
                            150_000_000,
                            350_000_000,
                            700_000_000,
                            1_500_000_000,
                        ],
                        reason: "shell-startup"
                    )
                }
            } catch {
                guard self.currentIntegrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: registrationID,
                    generation: generation
                ) else { return }
                if error is AgentCurrentIntegrationTargetUnavailableError {
                    let failureCount = (self.currentIntegrationTargetFailures[sessionID] ?? 0) + 1
                    self.currentIntegrationTargetFailures[sessionID] = failureCount
                    DiagnosticLogStore.appendAgentCenter(
                        "current-refresh sid=\(sid) reason=\(reason) result=deferred generation=\(generation) attempt=\(failureCount) preservedState=\(String(describing: self.currentIntegrationStates[sessionID]?.kind ?? .checking))"
                    )
                    // Attach hydration and foreground repaint are transient.
                    // Preserve the last authoritative state; an initial check
                    // remains checking instead of becoming a false Retry.
                    if self.currentIntegrationStates[sessionID] == nil {
                        self.currentIntegrationStates[sessionID] = .checking
                    }
                    let delays = self.currentIntegrationTargetRetryDelaysNanoseconds
                    if failureCount <= delays.count {
                        self.scheduleCurrentIntegrationRefreshAfterActivity(
                            sessionID: sessionID,
                            delayNanoseconds: delays[failureCount - 1],
                            bypassThrottle: true,
                            reason: "target-retry"
                        )
                    } else {
                        DiagnosticLogStore.appendAgentCenter(
                            "current-refresh sid=\(sid) reason=\(reason) result=exhausted generation=\(generation) attempts=\(failureCount) priorState=\(String(describing: self.currentIntegrationStates[sessionID]?.kind ?? .checking))"
                        )
                        self.currentIntegrationStates[sessionID] = .unavailable(
                            "The terminal is connected, but its current pane did not become readable."
                        )
                    }
                    return
                }
                DiagnosticLogStore.appendAgentCenter(
                    "current-refresh sid=\(sid) reason=\(reason) result=failed generation=\(generation) failureType=\(String(describing: type(of: error)))"
                )
                self.currentIntegrationStates[sessionID] = .unavailable()
            }
        }
    }

    func fixCurrentIntegration(
        sessionID: UUID,
        action explicitAction: AgentIntegrationFixAction? = nil
    ) {
        guard isEnabled,
              let source = sources[sessionID],
              let requestedAction = explicitAction
                ?? currentIntegrationState(sessionID: sessionID).action,
              currentIntegrationState(sessionID: sessionID).supports(requestedAction)
        else { return }

        DiagnosticLogStore.appendAgentCenter(
            "current-repair sid=\(Self.diagnosticSessionID(sessionID)) requestedAction=\(String(describing: requestedAction)) state=\(String(describing: currentIntegrationState(sessionID: sessionID).kind))"
        )

        if requestedAction == .check || requestedAction == .retry {
            currentIntegrationTargetFailures.removeValue(forKey: sessionID)
            hostIntegrationProbeFailures.remove(source.lifecycleIntegrationCacheKey)
            hostIntegrationProbeFailedAt.removeValue(
                forKey: source.lifecycleIntegrationCacheKey
            )
            hostIntegrationAutomaticRetryCounts.removeValue(
                forKey: source.lifecycleIntegrationCacheKey
            )
            integrationProbeRetryTasks.removeValue(
                forKey: source.lifecycleIntegrationCacheKey
            )?.cancel()
            currentIntegrationStates[sessionID] = .checkingOnDemand
            requestCurrentIntegrationRefresh(
                sessionID: sessionID,
                forceHostProbe: requestedAction == .retry,
                supersedeCurrent: true,
                allowManualSideChannel: true,
                reason: "user-check"
            )
            return
        }
        // A user-confirmed mutation must never be dropped behind a periodic
        // read. Supersede only this terminal's waiter; route-shared installs
        // continue and the repair below will join them.
        currentIntegrationTasks.removeValue(forKey: sessionID)?.cancel()

        let registrationID = source.registrationID
        let repairSID = Self.diagnosticSessionID(sessionID)
        let generation = (currentIntegrationGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationGenerations[sessionID] = generation
        currentIntegrationStates[sessionID] = .repairing
        currentIntegrationTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.currentIntegrationGenerations[sessionID] == generation {
                    self.currentIntegrationTasks.removeValue(forKey: sessionID)
                }
            }
            do {
                // Re-check immediately before mutation. A pane switch or an
                // agent launch after the popover opened must prevent shell
                // setup text; an authorized host install may still continue.
                let preflight = try await self.resolveCurrentIntegration(
                    source: source,
                    forceHostProbe: false
                )
                guard self.currentIntegrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: registrationID,
                    generation: generation
                ) else { return }
                // The confirmation can outlive a foreground transition. Its
                // disclosure authorizes files-only when an agent starts, or
                // activation when this exact target becomes a verified empty
                // shell. A shared install may also narrow either install form
                // to apply-only. No other action transition is compatible.
                let effectiveAction = preflight.state.effectiveAction(
                    for: requestedAction
                )
                DiagnosticLogStore.appendAgentCenter(
                    "current-repair sid=\(repairSID) phase=preflight generation=\(generation) foreground=\(String(describing: preflight.target.foreground)) hostAction=\(String(describing: preflight.state.action)) effectiveAction=\(String(describing: effectiveAction)) shellProbe=\(preflight.target.shellIntegrationActive.map(String.init) ?? "unknown")"
                )
                guard let effectiveAction else {
                    guard self.currentIntegrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: registrationID,
                        generation: generation
                    ) else { return }
                    self.currentIntegrationStates[sessionID] = preflight.state
                    DiagnosticLogStore.appendAgentCenter(
                        "current-repair sid=\(repairSID) phase=preflight result=no-op state=\(String(describing: preflight.state.kind))"
                    )
                    return
                }

                var appliedToCurrentShell = false
                var settledResolution: (
                    state: AgentIntegrationWarningState,
                    target: AgentCurrentIntegrationTarget
                )?

                switch effectiveAction {
                case .installAndApply, .installOnly:
                    guard source.installLifecycleIntegration != nil else {
                        throw AgentLifecycleIntegrationInstallError.verificationFailed("")
                    }
                    DiagnosticLogStore.appendAgentCenter(
                        "current-repair sid=\(repairSID) phase=host-install result=started"
                    )
                    try await self.installHostIntegration(source: source)
                    guard self.currentIntegrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: registrationID,
                        generation: generation
                    ) else { return }
                    self.hostIntegrationInstallations[source.lifecycleIntegrationCacheKey] =
                        CachedHostIntegrationInstallation(installation: .current, checkedAt: .now)
                    self.hostIntegrationProbeFailures.remove(source.lifecycleIntegrationCacheKey)
                    self.hostIntegrationProbeFailedAt.removeValue(
                        forKey: source.lifecycleIntegrationCacheKey
                    )
                    self.hostIntegrationAutomaticRetryCounts.removeValue(
                        forKey: source.lifecycleIntegrationCacheKey
                    )
                    self.integrationProbeRetryTasks.removeValue(
                        forKey: source.lifecycleIntegrationCacheKey
                    )?.cancel()
                    DiagnosticLogStore.appendAgentCenter(
                        "current-repair sid=\(repairSID) phase=host-install result=verified"
                    )

                    // Installation can finish on either side of an agent/shell
                    // transition. Re-read the exact target after the host
                    // files are current, then activate only a freshly proven
                    // empty shell. This makes one confirmation sufficient
                    // without ever staging source text into an agent/program.
                    let postInstall = try await self.resolveCurrentIntegration(
                        source: source,
                        forceHostProbe: false
                    )
                    guard self.currentIntegrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: registrationID,
                        generation: generation
                    ) else { return }
                    if postInstall.state.action == .apply {
                        guard let apply = source.applyLifecycleIntegrationToCurrentShell else {
                            throw AgentLifecycleIntegrationInstallError.verificationFailed("")
                        }
                        if await apply(postInstall.target) {
                            guard self.currentIntegrationRequestIsCurrent(
                                sessionID: sessionID,
                                registrationID: registrationID,
                                generation: generation
                            ) else { return }
                            appliedToCurrentShell = true
                            DiagnosticLogStore.appendAgentCenter(
                                "current-repair sid=\(repairSID) phase=shell-apply result=transport-acknowledged timing=post-install"
                            )
                        } else {
                            guard self.currentIntegrationRequestIsCurrent(
                                sessionID: sessionID,
                                registrationID: registrationID,
                                generation: generation
                            ) else { return }
                            settledResolution = try await self.resolveCurrentIntegration(
                                source: source,
                                forceHostProbe: false
                            )
                            DiagnosticLogStore.appendAgentCenter(
                                "current-repair sid=\(repairSID) phase=shell-apply result=target-changed-or-unacknowledged timing=post-install state=\(String(describing: settledResolution?.state.kind ?? .checking))"
                            )
                        }
                    } else {
                        settledResolution = postInstall
                        DiagnosticLogStore.appendAgentCenter(
                            "current-repair sid=\(repairSID) phase=shell-apply result=not-applicable timing=post-install foreground=\(String(describing: postInstall.target.foreground)) state=\(String(describing: postInstall.state.kind))"
                        )
                    }
                case .apply:
                    guard let apply = source.applyLifecycleIntegrationToCurrentShell,
                          await apply(preflight.target),
                          self.currentIntegrationRequestIsCurrent(
                            sessionID: sessionID,
                            registrationID: registrationID,
                            generation: generation
                          )
                    else { throw AgentLifecycleIntegrationInstallError.verificationFailed("") }
                    DiagnosticLogStore.appendAgentCenter(
                        "current-repair sid=\(repairSID) phase=shell-apply result=transport-acknowledged"
                    )
                    appliedToCurrentShell = true
                case .persistAndApply:
                    guard let persist = source.persistLifecycleIntegrationInCurrentShell,
                          await persist(preflight.target),
                          self.currentIntegrationRequestIsCurrent(
                            sessionID: sessionID,
                            registrationID: registrationID,
                            generation: generation
                          )
                    else { throw AgentLifecycleIntegrationInstallError.verificationFailed("") }
                    DiagnosticLogStore.appendAgentCenter(
                        "current-repair sid=\(repairSID) phase=shell-persist-and-apply result=transport-acknowledged"
                    )
                    appliedToCurrentShell = true
                case .check, .retry:
                    break
                }

                let resolution = if appliedToCurrentShell {
                    try await self.resolveCurrentIntegrationAfterApply(source: source)
                } else if let settledResolution {
                    settledResolution
                } else {
                    try await self.resolveCurrentIntegration(
                        source: source,
                        forceHostProbe: false
                    )
                }
                guard self.currentIntegrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: registrationID,
                    generation: generation
                ) else { return }
                self.currentIntegrationStates[sessionID] = resolution.state
                DiagnosticLogStore.appendAgentCenter(
                    "current-repair sid=\(repairSID) phase=verify result=resolved state=\(String(describing: resolution.state.kind)) foreground=\(String(describing: resolution.target.foreground)) shellProbe=\(resolution.target.shellIntegrationActive.map(String.init) ?? "unknown") agentRuntime=\(resolution.target.agentIntegrationActive)"
                )
                self.handleCurrentShellProbeResult(
                    resolution.target.shellIntegrationActive,
                    sessionID: sessionID
                )
            } catch {
                guard self.currentIntegrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: registrationID,
                    generation: generation
                ) else { return }
                DiagnosticLogStore.appendAgentCenter(
                    "current-repair sid=\(repairSID) phase=verify result=failed failureType=\(String(describing: type(of: error)))"
                )
                self.currentIntegrationStates[sessionID] = .unavailable(
                    "Host files may have changed, but this shell was not enabled. Recheck from an empty shell prompt."
                )
            }
        }
    }

    /// Terminal writes are ordered but not instantaneous. Verify an explicit
    /// source action on a short bounded schedule and finish on the first exact
    /// current process marker/environment proof. This replaces the former one-shot
    /// 250 ms guess without turning normal steady state into rapid polling.
    private func resolveCurrentIntegrationAfterApply(
        source: AgentSessionSource
    ) async throws -> (state: AgentIntegrationWarningState, target: AgentCurrentIntegrationTarget) {
        let delays: [UInt64] = [100_000_000, 300_000_000, 700_000_000, 1_200_000_000]
        var lastResolution: (
            state: AgentIntegrationWarningState,
            target: AgentCurrentIntegrationTarget
        )?
        var lastError: Error?

        for (attempt, delay) in delays.enumerated() {
            try await Task.sleep(nanoseconds: delay)
            do {
                let resolution = try await resolveCurrentIntegration(
                    source: source,
                    forceHostProbe: false
                )
                lastResolution = resolution
                lastError = nil
                DiagnosticLogStore.appendAgentCenter(
                    "shell-apply-verify sid=\(Self.diagnosticSessionID(source.sessionID)) attempt=\(attempt + 1) result=resolved state=\(String(describing: resolution.state.kind)) shellProbe=\(resolution.target.shellIntegrationActive.map(String.init) ?? "unknown")"
                )
                if resolution.state == .ready {
                    return resolution
                }
                if resolution.target.shellIntegrationActive == nil { continue }
                if resolution.state.kind != .inactiveShell { return resolution }
            } catch {
                lastError = error
                DiagnosticLogStore.appendAgentCenter(
                    "shell-apply-verify sid=\(Self.diagnosticSessionID(source.sessionID)) attempt=\(attempt + 1) result=deferred failureType=\(String(describing: type(of: error)))"
                )
            }
        }

        if let lastResolution { return lastResolution }
        throw lastError ?? AgentLifecycleIntegrationInstallError.verificationFailed("")
    }

    private func resolveCurrentIntegration(
        source: AgentSessionSource,
        forceHostProbe: Bool
    ) async throws -> (state: AgentIntegrationWarningState, target: AgentCurrentIntegrationTarget) {
        try Task.checkCancellation()
        guard let inspect = source.inspectCurrentIntegration,
              var target = await inspect()
        else { throw AgentCurrentIntegrationTargetUnavailableError() }
        try Task.checkCancellation()

        let targetID = AgentInstanceID(
            sessionID: target.location.sessionID,
            paneID: target.location.paneID
        )
        currentIntegrationTargetIDs[source.sessionID] = targetID
        if let lifecycleEvent = lifecycleEvents[targetID],
           lifecycleEvent.provesRunningAgentIntegration,
           let lifecyclePID = lifecycleEvent.agentPID,
           target.processIDs.contains(lifecyclePID),
           target.foreground == .agent,
           !target.agentIntegrationActive {
            target = AgentCurrentIntegrationTarget(
                location: target.location,
                foreground: target.foreground,
                processIDs: target.processIDs,
                shellIntegrationActive: target.shellIntegrationActive,
                agentIntegrationActive: true
            )
            DiagnosticLogStore.appendAgentCenter(
                "current-resolution sid=\(Self.diagnosticSessionID(source.sessionID)) phase=runtime-merge result=streamed-pid-proof"
            )
        }

        let cacheKey = source.lifecycleIntegrationCacheKey
        let hasCurrentRuntimeProof = target.agentIntegrationActive
            || target.shellIntegrationActive == true
        let cachedContradictsRuntime = hasCurrentRuntimeProof
            && hostIntegrationInstallations[cacheKey]?.installation != .current
        // A visible provider with no PID-bound hook is the diagnostic failure
        // case. Bypass the short cache once per exact pane/process incarnation
        // so the in-app log captures the latest readiness/emission breadcrumb
        // without multiplying the expensive host probe during convergence.
        let inactiveDiagnosticIdentity = InactiveAgentDiagnosticIdentity(
            agentID: targetID,
            processIDs: target.processIDs
        )
        let needsInactiveAgentDiagnostics = target.foreground == .agent
            && !target.agentIntegrationActive
            && inactiveAgentDiagnosticIdentities[source.sessionID]
                != inactiveDiagnosticIdentity
        if target.foreground != .agent || target.agentIntegrationActive {
            inactiveAgentDiagnosticIdentities.removeValue(forKey: source.sessionID)
        }
        let effectiveForceHostProbe = forceHostProbe
            || cachedContradictsRuntime
            || needsInactiveAgentDiagnostics
        // An in-flight install is more authoritative than the short-lived
        // probe cache. In particular, disabling and immediately re-enabling
        // Agent Center must join the retained host install instead of
        // resurfacing the cached pre-install `.missing` result.
        if let standardInstall = integrationTasks[cacheKey] {
            DiagnosticLogStore.appendAgentCenter(
                "current-resolution sid=\(Self.diagnosticSessionID(source.sessionID)) phase=host-status source=in-flight-card-install"
            )
            await standardInstall.value
            guard let cached = hostIntegrationInstallations[cacheKey] else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("")
            }
            return (.resolved(installation: cached.installation, target: target), target)
        }
        if let sharedInstall = sharedHostInstalls[cacheKey] {
            DiagnosticLogStore.appendAgentCenter(
                "current-resolution sid=\(Self.diagnosticSessionID(source.sessionID)) phase=host-status source=in-flight-shared-install"
            )
            try await completeSharedHostInstall(
                sharedInstall,
                cacheKey: cacheKey
            )
            return (.resolved(installation: .current, target: target), target)
        }

        let installation: AgentLifecycleHostInstallation
        if !effectiveForceHostProbe,
           !hostIntegrationProbeFailures.contains(cacheKey),
           let cached = hostIntegrationInstallations[cacheKey],
           Date.now.timeIntervalSince(cached.checkedAt) < Self.integrationProbeCacheLifetime {
            installation = cached.installation
            DiagnosticLogStore.appendAgentCenter(
                "current-resolution sid=\(Self.diagnosticSessionID(source.sessionID)) phase=host-status source=cache installation=\(Self.diagnosticInstallation(installation)) runtimeProof=\(hasCurrentRuntimeProof)"
            )
        } else {
            guard source.probeLifecycleIntegration != nil else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("")
            }
            if effectiveForceHostProbe {
                hostIntegrationProbeFailures.remove(cacheKey)
                hostIntegrationProbeFailedAt.removeValue(forKey: cacheKey)
            }
            try Task.checkCancellation()
            scheduleLifecycleIntegrationProbe(
                sessionID: source.sessionID,
                force: effectiveForceHostProbe
            )
            if let sharedProbe = integrationProbeTasks[cacheKey] {
                await sharedProbe.value
            }
            guard let cached = hostIntegrationInstallations[cacheKey],
                  !hostIntegrationProbeFailures.contains(cacheKey)
            else { throw AgentLifecycleIntegrationInstallError.verificationFailed("") }
            installation = cached.installation
            DiagnosticLogStore.appendAgentCenter(
                "current-resolution sid=\(Self.diagnosticSessionID(source.sessionID)) phase=host-status source=probe installation=\(Self.diagnosticInstallation(installation)) forced=\(effectiveForceHostProbe) runtimeProof=\(hasCurrentRuntimeProof)"
            )
        }
        if needsInactiveAgentDiagnostics {
            inactiveAgentDiagnosticIdentities[source.sessionID] = inactiveDiagnosticIdentity
        }
        return (.resolved(installation: installation, target: target), target)
    }

    private func installHostIntegration(source: AgentSessionSource) async throws {
        let cacheKey = source.lifecycleIntegrationCacheKey
        if let standardInstall = integrationTasks[cacheKey] {
            await standardInstall.value
            guard hostIntegrationInstallations[cacheKey]?.installation == .current else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("")
            }
            return
        }

        try await runSharedHostInstall(source: source)
    }

    private func runSharedHostInstall(source: AgentSessionSource) async throws {
        let cacheKey = source.lifecycleIntegrationCacheKey
        let shared: SharedHostInstall
        if let existing = sharedHostInstalls[cacheKey] {
            shared = existing
        } else {
            guard let install = source.installLifecycleIntegration else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("")
            }
            integrationProbeTasks.removeValue(forKey: cacheKey)?.cancel()
            integrationProbeGenerations[cacheKey] =
                (integrationProbeGenerations[cacheKey] ?? 0) &+ 1
            let token = UUID()
            let task = Task { @MainActor () -> Result<Void, Error> in
                do {
                    try await install()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            shared = SharedHostInstall(token: token, task: task)
            sharedHostInstalls[cacheKey] = shared
        }

        try await completeSharedHostInstall(shared, cacheKey: cacheKey)
    }

    private func completeSharedHostInstall(
        _ shared: SharedHostInstall,
        cacheKey: String
    ) async throws {
        let result = await shared.task.value
        if sharedHostInstalls[cacheKey]?.token == shared.token {
            sharedHostInstalls.removeValue(forKey: cacheKey)
        }
        try result.get()
        hostIntegrationInstallations[cacheKey] = CachedHostIntegrationInstallation(
            installation: .current,
            checkedAt: .now
        )
        hostIntegrationProbeFailures.remove(cacheKey)
        hostIntegrationProbeFailedAt.removeValue(forKey: cacheKey)
        hostIntegrationAutomaticRetryCounts.removeValue(forKey: cacheKey)
        integrationProbeRetryTasks.removeValue(forKey: cacheKey)?.cancel()
    }

    private func currentIntegrationRequestIsCurrent(
        sessionID: UUID,
        registrationID: UUID,
        generation: UInt64
    ) -> Bool {
        isEnabled
            && !Task.isCancelled
            && currentIntegrationGenerations[sessionID] == generation
            && sources[sessionID]?.registrationID == registrationID
    }

    /// Stops only this terminal's inspection/repair waiter. Any route-shared
    /// host install keeps running so another visible terminal can join it,
    /// but a hidden terminal can no longer receive the follow-up source text.
    func cancelCurrentIntegrationRequest(sessionID: UUID) {
        currentIntegrationGenerations[sessionID] =
            (currentIntegrationGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationTasks.removeValue(forKey: sessionID)?.cancel()
    }

    /// User command submission and provider lifecycle events are the fast
    /// path for foreground transitions. Coalesce bursts and cap remote checks;
    /// the slow top-bar cadence remains only a recovery backstop.
    private func scheduleCurrentIntegrationRefreshAfterActivity(
        sessionID: UUID,
        delayNanoseconds: UInt64 = 180_000_000,
        bypassThrottle: Bool = false,
        supersedeRead: Bool = false,
        convergenceDelaysNanoseconds: [UInt64] = [],
        reason: String
    ) {
        guard isEnabled,
              currentIntegrationStates[sessionID] != nil,
              let source = sources[sessionID],
              source.automaticallyInspectCurrentIntegration()
        else { return }

        currentIntegrationActivityTasks.removeValue(forKey: sessionID)?.cancel()
        let generation = (currentIntegrationActivityGenerations[sessionID] ?? 0) &+ 1
        currentIntegrationActivityGenerations[sessionID] = generation
        let lastRefresh = lastCurrentIntegrationActivityRefreshAt[sessionID]
        DiagnosticLogStore.appendAgentCenter(
            "current-refresh-scheduled sid=\(Self.diagnosticSessionID(sessionID)) reason=\(reason) delayMs=\(delayNanoseconds / 1_000_000) bypassThrottle=\(bypassThrottle) supersedeRead=\(supersedeRead) convergenceAttempts=\(convergenceDelaysNanoseconds.count)"
        )
        currentIntegrationActivityTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.currentIntegrationActivityGenerations[sessionID] == generation {
                    self.currentIntegrationActivityTasks.removeValue(forKey: sessionID)
                }
            }

            if !convergenceDelaysNanoseconds.isEmpty {
                let initialKind = self.currentIntegrationStates[sessionID]?.kind
                for (attempt, convergenceDelay) in convergenceDelaysNanoseconds.enumerated() {
                    do { try await Task.sleep(nanoseconds: convergenceDelay) }
                    catch { return }
                    guard self.currentIntegrationActivityGenerations[sessionID] == generation else {
                        return
                    }
                    while self.currentIntegrationTasks[sessionID] != nil {
                        do { try await Task.sleep(nanoseconds: 50_000_000) }
                        catch { return }
                    }
                    self.lastCurrentIntegrationActivityRefreshAt[sessionID] = .now
                    self.requestCurrentIntegrationRefresh(
                        sessionID: sessionID,
                        reason: "\(reason)-converge-\(attempt + 1)"
                    )
                    while self.currentIntegrationTasks[sessionID] != nil {
                        do { try await Task.sleep(nanoseconds: 50_000_000) }
                        catch { return }
                    }
                    guard self.currentIntegrationActivityGenerations[sessionID] == generation else {
                        return
                    }
                    let state = self.currentIntegrationStates[sessionID]
                    if state?.kind != initialKind || state?.showsWarning == false {
                        DiagnosticLogStore.appendAgentCenter(
                            "current-refresh-converged sid=\(Self.diagnosticSessionID(sessionID)) reason=\(reason) attempt=\(attempt + 1) state=\(String(describing: state?.kind ?? .checking))"
                        )
                        return
                    }
                }
                DiagnosticLogStore.appendAgentCenter(
                    "current-refresh-converged sid=\(Self.diagnosticSessionID(sessionID)) reason=\(reason) result=bounded-timeout attempts=\(convergenceDelaysNanoseconds.count) state=\(String(describing: self.currentIntegrationStates[sessionID]?.kind ?? .checking))"
                )
                return
            }

            var wait = delayNanoseconds
            if !bypassThrottle, let lastRefresh {
                let elapsed = Date.now.timeIntervalSince(lastRefresh)
                let remaining = max(0, 0.75 - elapsed)
                wait = max(wait, UInt64(remaining * 1_000_000_000))
            }
            if wait > 0 {
                do { try await Task.sleep(nanoseconds: wait) }
                catch { return }
            }

            // A PID-bound hook event is newer than a periodic read and should
            // preempt it. User-confirmed repairs remain authoritative; normal
            // Return activity queues behind any in-flight read so it cannot
            // cancel an install/apply operation.
            if supersedeRead,
               self.currentIntegrationTasks[sessionID] != nil,
               self.currentIntegrationStates[sessionID]?.isRepairing != true {
                self.lastCurrentIntegrationActivityRefreshAt[sessionID] = .now
                self.requestCurrentIntegrationRefresh(
                    sessionID: sessionID,
                    supersedeCurrent: true,
                    reason: reason
                )
                return
            }
            while self.currentIntegrationTasks[sessionID] != nil {
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
            }
            self.lastCurrentIntegrationActivityRefreshAt[sessionID] = .now
            self.requestCurrentIntegrationRefresh(
                sessionID: sessionID,
                reason: reason
            )
        }
    }

    /// A shell-marker read is a separate remote boundary from host artifact
    /// status. Retry transient nil results on a short bounded schedule; false
    /// is an authoritative inactive result and must not be polled rapidly.
    private func handleCurrentShellProbeResult(
        _ active: Bool?,
        sessionID: UUID
    ) {
        guard active == nil else {
            currentIntegrationShellProbeFailures.removeValue(forKey: sessionID)
            return
        }
        let failureCount = (currentIntegrationShellProbeFailures[sessionID] ?? 0) + 1
        currentIntegrationShellProbeFailures[sessionID] = failureCount
        let delays: [UInt64] = [250_000_000, 1_000_000_000, 3_000_000_000]
        guard failureCount <= delays.count else { return }
        scheduleCurrentIntegrationRefreshAfterActivity(
            sessionID: sessionID,
            delayNanoseconds: delays[failureCount - 1],
            reason: "shell-probe-retry"
        )
    }

    func canInstallLifecycleIntegration(agentID: AgentInstanceID) -> Bool {
        #if DEBUG
        if harnessIntegrationStates[agentID] != nil { return true }
        #endif
        guard agentIDSupportedByLifecycleIntegration(agentID) else { return false }
        return sources[agentID.sessionID]?.installLifecycleIntegration != nil
    }

    func lifecycleIntegrationState(agentID: AgentInstanceID) -> AgentLifecycleIntegrationState {
        #if DEBUG
        if let state = harnessIntegrationStates[agentID] { return state }
        #endif
        if let event = lifecycleEvents[agentID], event.provesRunningAgentIntegration {
            return .active
        }
        guard let source = sources[agentID.sessionID],
              source.probeLifecycleIntegration != nil
        else { return .checking }
        if hostIntegrationProbeFailures.contains(source.lifecycleIntegrationCacheKey) {
            return .checkUnavailable
        }
        let cached = hostIntegrationInstallations[source.lifecycleIntegrationCacheKey]
        if let cached,
           !source.automaticallyProbeLifecycleIntegration,
           Date.now.timeIntervalSince(cached.checkedAt) >= Self.integrationProbeCacheLifetime {
            return .notChecked
        }
        switch cached?.installation {
        case .current?: return .installedInactive
        case .missing?: return .notInstalled
        case .outdated(let version)?: return .outdated(version: version)
        case nil:
            return source.automaticallyProbeLifecycleIntegration ? .checking : .notChecked
        }
    }

    func retryLifecycleIntegrationProbe(agentID: AgentInstanceID) {
        guard isEnabled else { return }
        guard let source = sources[agentID.sessionID] else { return }
        hostIntegrationProbeFailures.remove(source.lifecycleIntegrationCacheKey)
        hostIntegrationProbeFailedAt.removeValue(
            forKey: source.lifecycleIntegrationCacheKey
        )
        hostIntegrationAutomaticRetryCounts.removeValue(
            forKey: source.lifecycleIntegrationCacheKey
        )
        integrationProbeRetryTasks.removeValue(
            forKey: source.lifecycleIntegrationCacheKey
        )?.cancel()
        DiagnosticLogStore.appendAgentCenter(
            "host-probe sid=\(Self.diagnosticSessionID(agentID.sessionID)) reason=user-retry result=scheduled"
        )
        scheduleLifecycleIntegrationProbe(sessionID: agentID.sessionID)
        activityRevision &+= 1
    }

    func installLifecycleIntegration(agentID: AgentInstanceID) {
        guard isEnabled else { return }
        guard let source = sources[agentID.sessionID],
              source.installLifecycleIntegration != nil,
              agentIDSupportedByLifecycleIntegration(agentID),
              integrationTasks[source.lifecycleIntegrationCacheKey] == nil
        else { return }
        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].actionMessage = "installing precise status integration…"
            agents[index].actionIsError = false
        }
        let sessionID = agentID.sessionID
        let registrationID = source.registrationID
        let cacheKey = source.lifecycleIntegrationCacheKey
        let generation = (integrationGenerations[cacheKey] ?? 0) &+ 1
        DiagnosticLogStore.appendAgentCenter(
            "host-install sid=\(Self.diagnosticSessionID(sessionID)) result=started generation=\(generation) entry=agent-card"
        )
        integrationGenerations[cacheKey] = generation
        integrationProbeTasks.removeValue(forKey: cacheKey)?.cancel()
        integrationProbeGenerations[cacheKey] =
            (integrationProbeGenerations[cacheKey] ?? 0) &+ 1
        integrationTasks[cacheKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.integrationGenerations[cacheKey] == generation {
                    self.integrationTasks.removeValue(forKey: cacheKey)
                }
            }
            do {
                try await self.runSharedHostInstall(source: source)
                guard self.isEnabled,
                      !Task.isCancelled,
                      self.integrationGenerations[cacheKey] == generation,
                      self.sources[sessionID]?.registrationID == registrationID
                else { return }
                for index in self.agents.indices
                    where self.sources[self.agents[index].id.sessionID]?.lifecycleIntegrationCacheKey == cacheKey {
                    self.agents[index].actionMessage = "installed — enable Tessera integration in a shell; approve any provider hook review, then relaunch the agent"
                    self.agents[index].actionIsError = false
                }
                self.hostIntegrationInstallations[cacheKey] = CachedHostIntegrationInstallation(
                    installation: .current,
                    checkedAt: .now
                )
                self.hostIntegrationProbeFailures.remove(cacheKey)
                self.hostIntegrationProbeFailedAt.removeValue(forKey: cacheKey)
                self.hostIntegrationAutomaticRetryCounts.removeValue(forKey: cacheKey)
                self.integrationProbeRetryTasks.removeValue(forKey: cacheKey)?.cancel()
                DiagnosticLogStore.appendAgentCenter(
                    "host-install sid=\(Self.diagnosticSessionID(sessionID)) result=verified generation=\(generation) entry=agent-card"
                )
                let currentSessions = self.sources.values.compactMap { candidate -> UUID? in
                    guard candidate.lifecycleIntegrationCacheKey == cacheKey,
                          candidate.automaticallyInspectCurrentIntegration(),
                          self.currentIntegrationStates[candidate.sessionID] != nil
                    else { return nil }
                    return candidate.sessionID
                }
                for currentSessionID in currentSessions {
                    self.requestCurrentIntegrationRefresh(
                        sessionID: currentSessionID,
                        supersedeCurrent: true,
                        reason: "agent-card-install"
                    )
                }
            } catch {
                guard self.isEnabled,
                      !Task.isCancelled,
                      self.integrationGenerations[cacheKey] == generation,
                      self.sources[sessionID]?.registrationID == registrationID
                else { return }
                for index in self.agents.indices where self.agents[index].id.sessionID == sessionID {
                    self.agents[index].actionMessage = error.localizedDescription
                    self.agents[index].actionIsError = true
                }
                DiagnosticLogStore.appendAgentCenter(
                    "host-install sid=\(Self.diagnosticSessionID(sessionID)) result=failed generation=\(generation) entry=agent-card failureType=\(String(describing: type(of: error)))"
                )
            }
            self.activityRevision &+= 1
        }
    }

    private func scheduleLifecycleIntegrationProbe(
        sessionID: UUID,
        force: Bool = false
    ) {
        guard !Task.isCancelled,
              isEnabled,
              let source = sources[sessionID],
              let probe = source.probeLifecycleIntegration
        else { return }
        let cacheKey = source.lifecycleIntegrationCacheKey
        if !force,
           let failedAt = hostIntegrationProbeFailedAt[cacheKey],
           Date.now.timeIntervalSince(failedAt)
                < TimeInterval(integrationProbeFailureBackoffNanoseconds) / 1_000_000_000 {
            return
        }
        if !force,
           let cached = hostIntegrationInstallations[cacheKey],
           Date.now.timeIntervalSince(cached.checkedAt) < Self.integrationProbeCacheLifetime {
            return
        }
        guard sharedHostInstalls[cacheKey] == nil,
              integrationTasks[cacheKey] == nil
        else { return }
        guard integrationProbeTasks[cacheKey] == nil else { return }
        hostIntegrationProbeFailures.remove(cacheKey)
        let generation = (integrationProbeGenerations[cacheKey] ?? 0) &+ 1
        integrationProbeGenerations[cacheKey] = generation
        DiagnosticLogStore.appendAgentCenter(
            "host-probe sid=\(Self.diagnosticSessionID(sessionID)) result=started generation=\(generation) force=\(force)"
        )
        integrationProbeTasks[cacheKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.integrationProbeGenerations[cacheKey] == generation {
                    self.integrationProbeTasks.removeValue(forKey: cacheKey)
                }
            }
            var candidate = source
            var candidateProbe = probe
            var attemptedRegistrations = Set<UUID>()
            while true {
                attemptedRegistrations.insert(candidate.registrationID)
                do {
                    let installation = try await candidateProbe()
                    guard self.isEnabled,
                          !Task.isCancelled,
                          self.integrationProbeGenerations[cacheKey] == generation,
                          self.sharedHostInstalls[cacheKey] == nil,
                          self.integrationTasks[cacheKey] == nil
                    else { return }
                    self.hostIntegrationInstallations[cacheKey] = CachedHostIntegrationInstallation(
                        installation: installation,
                        checkedAt: .now
                    )
                    self.hostIntegrationProbeFailures.remove(cacheKey)
                    self.hostIntegrationProbeFailedAt.removeValue(forKey: cacheKey)
                    self.hostIntegrationAutomaticRetryCounts.removeValue(forKey: cacheKey)
                    self.integrationProbeRetryTasks.removeValue(forKey: cacheKey)?.cancel()
                    DiagnosticLogStore.appendAgentCenter(
                        "host-probe sid=\(Self.diagnosticSessionID(candidate.sessionID)) result=resolved generation=\(generation) installation=\(Self.diagnosticInstallation(installation)) carrierAttempts=\(attemptedRegistrations.count)"
                    )
                    self.activityRevision &+= 1
                    return
                } catch {
                    guard self.isEnabled,
                          !Task.isCancelled,
                          self.integrationProbeGenerations[cacheKey] == generation,
                          self.sharedHostInstalls[cacheKey] == nil,
                          self.integrationTasks[cacheKey] == nil
                    else { return }

                    // A route-level probe must not be poisoned by whichever
                    // session happened to start it closing mid-command. Try
                    // another live carrier for the same route while all
                    // waiters continue awaiting this one shared task.
                    if let fallback = self.sources.values.first(where: {
                        $0.lifecycleIntegrationCacheKey == cacheKey
                            && $0.probeLifecycleIntegration != nil
                            && !attemptedRegistrations.contains($0.registrationID)
                    }), let fallbackProbe = fallback.probeLifecycleIntegration {
                        candidate = fallback
                        candidateProbe = fallbackProbe
                        DiagnosticLogStore.appendAgentCenter(
                            "host-probe sid=\(Self.diagnosticSessionID(sessionID)) result=carrier-fallback generation=\(generation) attempt=\(attemptedRegistrations.count + 1)"
                        )
                        continue
                    }

                    let routeStillHasCarrier = self.sources.values.contains {
                        $0.lifecycleIntegrationCacheKey == cacheKey
                            && $0.probeLifecycleIntegration != nil
                    }
                    guard routeStillHasCarrier else { return }
                    // Never claim the hook is absent merely because every
                    // live carrier was unreachable. Expose a retryable read
                    // failure instead.
                    self.hostIntegrationProbeFailures.insert(cacheKey)
                    self.hostIntegrationProbeFailedAt[cacheKey] = .now
                    self.scheduleHostIntegrationProbeRetry(cacheKey: cacheKey)
                    DiagnosticLogStore.appendAgentCenter(
                        "host-probe sid=\(Self.diagnosticSessionID(sessionID)) result=failed generation=\(generation) carrierAttempts=\(attemptedRegistrations.count) failureType=\(String(describing: type(of: error)))"
                    )
                    self.activityRevision &+= 1
                    return
                }
            }
        }
    }

    /// A transient exec/control-channel read must not leave the UI on Retry
    /// until the 30-second recovery poll. Recheck the shared route once after
    /// a short bounded backoff; successful user retries and installs cancel it.
    private func scheduleHostIntegrationProbeRetry(cacheKey: String) {
        integrationProbeRetryTasks.removeValue(forKey: cacheKey)?.cancel()
        let retryCount = (hostIntegrationAutomaticRetryCounts[cacheKey] ?? 0) + 1
        guard retryCount <= 3 else {
            DiagnosticLogStore.appendAgentCenter(
                "host-probe-retry result=exhausted attempts=\(retryCount - 1) carriers=\(sources.values.count { $0.lifecycleIntegrationCacheKey == cacheKey })"
            )
            return
        }
        hostIntegrationAutomaticRetryCounts[cacheKey] = retryCount
        let delay = integrationProbeFailureBackoffNanoseconds
        DiagnosticLogStore.appendAgentCenter(
            "host-probe-retry result=scheduled attempt=\(retryCount) delayMs=\(delay / 1_000_000) carriers=\(sources.values.count { $0.lifecycleIntegrationCacheKey == cacheKey })"
        )
        integrationProbeRetryTasks[cacheKey] = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
            guard self.isEnabled,
                  self.hostIntegrationProbeFailures.contains(cacheKey),
                  let source = self.sources.values.first(where: {
                      $0.lifecycleIntegrationCacheKey == cacheKey
                          && $0.probeLifecycleIntegration != nil
                  })
            else {
                self.integrationProbeRetryTasks.removeValue(forKey: cacheKey)
                return
            }

            self.integrationProbeRetryTasks.removeValue(forKey: cacheKey)
            self.scheduleLifecycleIntegrationProbe(
                sessionID: source.sessionID,
                force: true
            )
            let currentSessionIDs: [UUID] = self.sources.values.compactMap { candidate -> UUID? in
                guard candidate.lifecycleIntegrationCacheKey == cacheKey,
                      candidate.automaticallyInspectCurrentIntegration(),
                      self.currentIntegrationStates[candidate.sessionID] != nil
                else { return nil }
                return candidate.sessionID
            }
            for sessionID in currentSessionIDs {
                self.requestCurrentIntegrationRefresh(
                    sessionID: sessionID,
                    forceHostProbe: true,
                    supersedeCurrent: true,
                    reason: "host-probe-retry"
                )
            }
        }
    }

    private func agentIDSupportedByLifecycleIntegration(_ agentID: AgentInstanceID) -> Bool {
        guard let profileID = agents.first(where: { $0.id == agentID })?.profileID else {
            return false
        }
        return lifecycleIntegrationSupports(profileID: profileID)
    }

    private func lifecycleIntegrationSupports(profileID: UUID) -> Bool {
        profileID == SwipePadProfile.builtInClaudeCodeID
            || profileID == SwipePadProfile.builtInCodexCLIID
    }

    #if DEBUG
    /// Deterministic, connection-free state injection for the dedicated visual
    /// harness. Production discovery still enters exclusively through sources.
    func installHarnessAgents(_ agents: [AgentInstance]) {
        self.agents = agents
        activityRevision &+= 1
    }

    func installHarnessAttention(
        _ kind: AgentAttentionKind,
        for agentID: AgentInstanceID
    ) {
        guard let agent = agent(agentID) else { return }
        attentionSequence &+= 1
        let attention = AgentAttention(
            agentID: agentID,
            kind: kind,
            occurredAt: agent.finishedAt ?? agent.statusChangedAt,
            sequence: attentionSequence
        )
        unreadAttentions.removeAll { $0.agentID == agentID }
        unreadAttentions.append(attention)
        activityRevision &+= 1
    }

    func installHarnessLifecycleIntegrationState(
        _ state: AgentLifecycleIntegrationState,
        for agentID: AgentInstanceID
    ) {
        harnessIntegrationStates[agentID] = state
        activityRevision &+= 1
    }

    func installHarnessCurrentIntegrationState(
        _ state: AgentIntegrationWarningState,
        for sessionID: UUID
    ) {
        currentIntegrationStates[sessionID] = state
    }
    #endif

    private func agent(_ id: AgentInstanceID) -> AgentInstance? {
        agents.first(where: { $0.id == id })
    }

    private func trackTerminalModes(
        agentID: AgentInstanceID,
        data: ArraySlice<UInt8>
    ) {
        let enabled = Array("\u{1B}[?2004h".utf8)
        let disabled = Array("\u{1B}[?2004l".utf8)
        var bytes = terminalModeTails[agentID, default: []]
        bytes.append(contentsOf: data)
        if let enabledAt = lastIndex(of: enabled, in: bytes),
           let disabledAt = lastIndex(of: disabled, in: bytes) {
            bracketedPasteModes[agentID] = enabledAt > disabledAt
        } else if lastIndex(of: enabled, in: bytes) != nil {
            bracketedPasteModes[agentID] = true
        } else if lastIndex(of: disabled, in: bytes) != nil {
            bracketedPasteModes[agentID] = false
        }
        if let modeEnabled = bracketedPasteModes[agentID],
           let index = agents.firstIndex(where: { $0.id == agentID }),
           agents[index].bracketedPasteEnabled != modeEnabled {
            agents[index].bracketedPasteEnabled = modeEnabled
        }
        terminalModeTails[agentID] = Array(bytes.suffix(max(enabled.count, disabled.count) - 1))
    }

    private func lastIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        for start in stride(from: bytes.count - needle.count, through: 0, by: -1) {
            if bytes[start..<(start + needle.count)].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }

    private func scheduleRefresh(sessionID: UUID, delayNanoseconds: UInt64) {
        guard isEnabled, sources[sessionID] != nil else { return }
        refreshTasks[sessionID]?.cancel()
        let generation = (refreshGenerations[sessionID] ?? 0) &+ 1
        refreshGenerations[sessionID] = generation
        refreshDueAt[sessionID] = Date.now.addingTimeInterval(
            TimeInterval(delayNanoseconds) / 1_000_000_000
        )
        refreshTasks[sessionID] = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.refreshDueAt.removeValue(forKey: sessionID)
            await self?.refresh(sessionID: sessionID, generation: generation)
        }
    }

    private func refresh(sessionID: UUID, generation: UInt64) async {
        guard isEnabled,
              refreshGenerations[sessionID] == generation,
              let source = sources[sessionID] else { return }
        let registrationID = source.registrationID
        let sid = Self.diagnosticSessionID(sessionID)
        let result = await source.discover()
        guard isEnabled,
              refreshGenerations[sessionID] == generation,
              sources[sessionID]?.registrationID == registrationID else { return }
        guard case .success(let probes) = result else {
            DiagnosticLogStore.appendAgentCenter(
                "discovery-refresh sid=\(sid) result=unavailable generation=\(generation) retry=\(surfaceDemand || observationBootstrapSessionIDs.contains(sessionID))"
            )
            refreshTasks.removeValue(forKey: sessionID)
            refreshDueAt.removeValue(forKey: sessionID)
            if surfaceDemand || observationBootstrapSessionIDs.contains(sessionID) {
                scheduleRefresh(sessionID: sessionID, delayNanoseconds: 2_000_000_000)
            }
            return
        }
        for id in Array(observationTasks.keys).filter({ $0.sessionID == sessionID }) {
            observationTasks.removeValue(forKey: id)?.cancel()
            observationDueAt.removeValue(forKey: id)
            observationGenerations[id] = (observationGenerations[id] ?? 0) &+ 1
        }
        lastDiscoveryAt[sessionID] = .now
        replaceAgents(for: sessionID, probes: probes, now: .now)
        let sessionAgents = agents.filter { $0.id.sessionID == sessionID }
        DiagnosticLogStore.appendAgentCenter(
            "discovery-refresh sid=\(sid) result=success generation=\(generation) probes=\(probes.count) cards=\(sessionAgents.count) waiting=\(sessionAgents.count { $0.status == .waitingForInput }) finished=\(sessionAgents.count { $0.status == .justFinished }) working=\(sessionAgents.count { $0.status == .working }) idle=\(sessionAgents.count { $0.status == .idle }) unavailable=\(sessionAgents.count { $0.status == .unavailable })"
        )
        if observationReadySessionIDs.remove(sessionID) != nil {
            observationBootstrapSessionIDs.remove(sessionID)
        }
        refreshTasks.removeValue(forKey: sessionID)
        refreshDueAt.removeValue(forKey: sessionID)
    }

    private func scheduleObservation(
        agentID: AgentInstanceID,
        delayNanoseconds: UInt64
    ) {
        // Leading-edge throttle: one pending capture represents every chunk
        // that arrives before it runs. Cancelling and recreating a task for
        // each byte burst made sustained terminal output itself expensive.
        // A semantic prompt boundary may move an already-scheduled surface
        // capture earlier, but ordinary output never postpones or churns it.
        guard isEnabled else { return }
        let dueAt = Date.now.addingTimeInterval(
            TimeInterval(delayNanoseconds) / 1_000_000_000
        )
        if let existingTask = observationTasks[agentID] {
            guard let existingDueAt = observationDueAt[agentID],
                  dueAt < existingDueAt else { return }
            existingTask.cancel()
            observationTasks.removeValue(forKey: agentID)
        }
        let generation = (observationGenerations[agentID] ?? 0) &+ 1
        observationGenerations[agentID] = generation
        observationDueAt[agentID] = dueAt
        observationTasks[agentID] = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.observe(agentID: agentID, generation: generation)
        }
    }

    private func observe(agentID: AgentInstanceID, generation: UInt64) async {
        guard isEnabled,
              observationGenerations[agentID] == generation,
              let source = sources[agentID.sessionID],
              let previous = agent(agentID) else {
            if observationGenerations[agentID] == generation {
                observationTasks.removeValue(forKey: agentID)
                observationDueAt.removeValue(forKey: agentID)
            }
            return
        }
        let registrationID = source.registrationID
        let observed = await source.observe(previous.location)
        guard isEnabled,
              observationGenerations[agentID] == generation,
              sources[agentID.sessionID]?.registrationID == registrationID else { return }
        guard let probe = observed else {
            observationTasks.removeValue(forKey: agentID)
            observationDueAt.removeValue(forKey: agentID)
            // Observation is a cheap capture, not an authoritative process
            // check. A transient capture failure must not erase the card;
            // full discovery below decides whether the process really exited.
            scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
            return
        }
        if let updated = makeInstance(
            from: probe,
            previous: previous,
            now: .now,
            preserveProfileWhenProcessUnavailable: true
        ),
           let index = agents.firstIndex(where: { $0.id == agentID }) {
            if cardMeaningfullyChanged(from: previous, to: updated) {
                agents[index] = updated
                if previous.status != updated.status {
                    DiagnosticLogStore.appendAgentCenter(
                        "status-transition sid=\(Self.diagnosticSessionID(agentID.sessionID)) pane=\(Self.diagnosticPaneID(agentID.paneID)) source=terminal-observation previous=\(String(describing: previous.status)) next=\(String(describing: updated.status)) promptParsed=\(updated.prompt != nil) lifecycleProof=\(lifecycleEvents[agentID] != nil)"
                    )
                }
                handleStatusTransition(
                    from: previous,
                    to: updated,
                    source: "terminal-observation"
                )
                activityRevision &+= 1
            }
        }
        observationTasks.removeValue(forKey: agentID)
        observationDueAt.removeValue(forKey: agentID)
    }

    private func cardMeaningfullyChanged(
        from old: AgentInstance,
        to new: AgentInstance
    ) -> Bool {
        old.providerSessionID != new.providerSessionID
            || old.location != new.location
            || old.status != new.status
            || old.taskSummary != new.taskSummary
            || old.outputTail != new.outputTail
            || old.prompt != new.prompt
            || old.finishedAt != new.finishedAt
            || old.lastLifecycleEventAt != new.lastLifecycleEventAt
            || old.bracketedPasteEnabled != new.bracketedPasteEnabled
            || old.sendInFlight != new.sendInFlight
            || old.actionMessage != new.actionMessage
            || old.actionIsError != new.actionIsError
    }

    private func replaceAgents(
        for sessionID: UUID,
        probes: [AgentProbeTarget],
        now: Date
    ) {
        let existing = Dictionary(
            uniqueKeysWithValues: agents
                .filter { $0.id.sessionID == sessionID }
                .map { ($0.id, $0) }
        )
        var replacements: [AgentInstance] = []
        var transitions: [(AgentInstance?, AgentInstance)] = []

        for probe in probes {
            let id = AgentInstanceID(
                sessionID: probe.location.sessionID,
                paneID: probe.location.paneID
            )
            let previous = existing[id]
            guard let instance = makeInstance(
                from: probe,
                previous: previous,
                now: now,
                preserveProfileWhenProcessUnavailable: false
            ) else {
                continue
            }
            replacements.append(instance)
            transitions.append((previous, instance))
        }

        let replacementIDs = Set(replacements.map(\.id))
        let removedIDs = Set(existing.keys).subtracting(replacementIDs)
        for id in removedIDs {
            if let event = lifecycleEvents[id] {
                let previous = discardedLifecycleEvents[id]
                if previous == nil
                    || event.timestampNanoseconds >= previous!.timestampNanoseconds {
                    discardedLifecycleEvents[id] = DiscardedLifecycleEvent(
                        timestampNanoseconds: event.timestampNanoseconds,
                        agentPID: event.agentPID
                    )
                }
            }
            lifecycleEvents.removeValue(forKey: id)
            processIDs.removeValue(forKey: id)
            inputStatusOverrides.removeValue(forKey: id)
            permissionPromptConfirmations.removeValue(forKey: id)
            permissionPromptPendingSince.removeValue(forKey: id)
            postStopPromptPendingSince.removeValue(forKey: id)
            blockingPromptEpochs.removeValue(forKey: id)
            latestNonBlockingLifecycleRevisions.removeValue(forKey: id)
            lifecycleScanners.removeValue(forKey: id)
            completionObservedAt.removeValue(forKey: id)
            cancelCompletionExpiry(agentID: id)
            cancelPendingAttention(agentID: id)
            markAttentionRead(agentID: id, reason: "agent-removed")
        }

        agents.removeAll { $0.id.sessionID == sessionID }
        agents.append(contentsOf: replacements)
        for (previous, replacement) in transitions {
            handleStatusTransition(
                from: previous,
                to: replacement,
                source: "discovery"
            )
        }
        activityRevision &+= 1
        if surfaceDemand,
           sources[sessionID]?.automaticallyProbeLifecycleIntegration == true,
           replacements.contains(where: {
               $0.status == .unavailable
                   && lifecycleIntegrationSupports(profileID: $0.profileID)
           }) {
            scheduleLifecycleIntegrationProbe(sessionID: sessionID)
        }
        if let pendingJump,
           pendingJump.sessionID == sessionID,
           agents.contains(where: { $0.id == pendingJump }) {
            jump(agentID: pendingJump)
        }
    }

    private func makeInstance(
        from probe: AgentProbeTarget,
        previous: AgentInstance?,
        now: Date,
        preserveProfileWhenProcessUnavailable: Bool
    ) -> AgentInstance? {
        let id = AgentInstanceID(
            sessionID: probe.location.sessionID,
            paneID: probe.location.paneID
        )
        let previousProcessIDs = processIDs[id] ?? []
        let candidateLifecycleEvent: AgentLifecycleEvent? = {
            let retained = probe.lifecycleEvent.flatMap { event in
                guard let discarded = discardedLifecycleEvents[id] else { return event }
                if event.timestampNanoseconds > discarded.timestampNanoseconds {
                    return event
                }
                let verifiedDifferentProcessAtSameTime = event.timestampNanoseconds
                    == discarded.timestampNanoseconds
                    && event.agentPID != nil
                    && discarded.agentPID != nil
                    && event.agentPID != discarded.agentPID
                    && probe.processIDs.contains(event.agentPID!)
                return verifiedDifferentProcessAtSameTime ? event : nil
            }
            let streamed = lifecycleEvents[id]
            switch (retained, streamed) {
            case (.some(let retained), .some(let streamed)):
                if retained.isStatusNeutral != streamed.isStatusNeutral {
                    return retained.isStatusNeutral ? streamed : retained
                }
                return retained.timestampNanoseconds >= streamed.timestampNanoseconds
                    ? retained : streamed
            case (.some(let retained), .none): return retained
            case (.none, .some(let streamed)): return streamed
            case (.none, .none): return nil
            }
        }()
        let profile: SwipePadProfile?
        if !probe.processNames.isEmpty {
            profile = matchingProfile(processNames: probe.processNames)
        } else if preserveProfileWhenProcessUnavailable, let previous {
            profile = profiles.first(where: { $0.id == previous.profileID })
        } else {
            profile = matchingProfile(processNames: probe.processNames)
        }
        guard let profile else { return nil }
        let lifecycleEvent: AgentLifecycleEvent? = candidateLifecycleEvent.flatMap { event in
            guard matchingProfile(processNames: [event.processName])?.id == profile.id else {
                return nil
            }
            if event.agentPID == nil, event.provesRunningAgentIntegration {
                return nil
            }
            if let agentPID = event.agentPID,
               !probe.processIDs.isEmpty,
               !probe.processIDs.contains(agentPID) {
                return nil
            }
            return event
        }
        let providerSessionChanged: Bool = {
            guard let oldSession = previous?.providerSessionID,
                  !oldSession.isEmpty,
                  let lifecycleEvent,
                  !lifecycleEvent.providerSessionID.isEmpty else { return false }
            return oldSession != lifecycleEvent.providerSessionID
        }()
        let processIncarnationChanged = !previousProcessIDs.isEmpty
            && !probe.processIDs.isEmpty
            && previousProcessIDs.isDisjoint(with: probe.processIDs)
        let retainedPrevious = providerSessionChanged || processIncarnationChanged
            ? nil
            : previous
        if retainedPrevious == nil, previous != nil {
            completionObservedAt.removeValue(forKey: id)
            cancelCompletionExpiry(agentID: id)
            cancelPendingAttention(agentID: id)
            markAttentionRead(agentID: id, reason: "agent-incarnation-changed")
        }
        processIDs[id] = probe.processIDs.isEmpty ? (processIDs[id] ?? []) : probe.processIDs
        if candidateLifecycleEvent != nil, lifecycleEvent == nil {
            lifecycleEvents.removeValue(forKey: id)
            inputStatusOverrides.removeValue(forKey: id)
            permissionPromptConfirmations.removeValue(forKey: id)
            permissionPromptPendingSince.removeValue(forKey: id)
            postStopPromptPendingSince.removeValue(forKey: id)
            blockingPromptEpochs.removeValue(forKey: id)
            latestNonBlockingLifecycleRevisions.removeValue(forKey: id)
        } else if let lifecycleEvent,
                  (lifecycleEvents[id]?.timestampNanoseconds ?? 0) < lifecycleEvent.timestampNanoseconds {
            discardedLifecycleEvents.removeValue(forKey: id)
            lifecycleEvents[id] = lifecycleEvent
        } else if lifecycleEvent != nil {
            discardedLifecycleEvents.removeValue(forKey: id)
        }
        let parsed = probe.visibleText.map {
            AgentPromptParser.parse(
                visibleText: $0,
                profile: profile,
                currentInputLine: probe.currentInputLine
            )
        }
        if parsed?.blockingPromptDetected == true,
           let signature = parsed?.prompt?.signature {
            if blockingPromptEpochs[id]?.signature != signature {
                blockingPromptEpochs[id] = BlockingPromptEpoch(
                    signature: signature,
                    firstSeenLifecycleRevision: lifecycleArrivalRevisions[id] ?? 0
                )
            }
        } else {
            blockingPromptEpochs.removeValue(forKey: id)
        }
        if let lifecycleEvent,
           Self.requiresVisiblePromptConfirmation(lifecycleEvent) {
            if parsed?.blockingPromptDetected == true,
               blockingPromptIsFreshForLatestSemanticBoundary(id) {
                if permissionPromptConfirmations[id] != lifecycleEvent.timestampNanoseconds {
                    DiagnosticLogStore.appendAgentCenter(
                        "permission-prompt sid=\(Self.diagnosticSessionID(id.sessionID)) pane=\(Self.diagnosticPaneID(id.paneID)) provider=\(Self.diagnosticProvider(lifecycleEvent.provider)) result=confirmed-visible options=\(parsed?.prompt?.options.count ?? 0)"
                    )
                }
                permissionPromptConfirmations[id] = lifecycleEvent.timestampNanoseconds
                permissionPromptPendingSince.removeValue(forKey: id)
                postStopPromptPendingSince.removeValue(forKey: id)
            } else if permissionPromptConfirmations[id] != lifecycleEvent.timestampNanoseconds {
                permissionPromptConfirmations.removeValue(forKey: id)
                permissionPromptPendingSince[id] = permissionPromptPendingSince[id] ?? .now
            }
        } else {
            permissionPromptConfirmations.removeValue(forKey: id)
            permissionPromptPendingSince.removeValue(forKey: id)
        }
        if lifecycleEvent?.provider == "codex",
           lifecycleEvent?.event == "Stop",
           parsed?.blockingPromptDetected == true,
           blockingPromptIsFreshForLatestSemanticBoundary(id) {
            postStopPromptPendingSince.removeValue(forKey: id)
        }
        if let lifecycleEvent {
            recordCompletionBoundary(
                lifecycleEvent,
                agentID: id,
                isStreamed: false,
                now: now
            )
        } else {
            completionObservedAt.removeValue(forKey: id)
            cancelCompletionExpiry(agentID: id)
        }
        let completedAt = lifecycleEvent.flatMap {
            completionDate(for: $0, agentID: id, now: now)
        }
        let activity = outputActivity[id]
        let status = status(
            parsed: parsed,
            lifecycleEvent: lifecycleEvent,
            inputOverride: inputStatusOverrides[id],
            previousStatus: retainedPrevious?.status,
            permissionPromptConfirmed: lifecycleEvent.map {
                permissionPromptConfirmations[id] == $0.timestampNanoseconds
            } ?? false,
            blockingPromptFresh: blockingPromptIsFreshForLatestSemanticBoundary(id),
            completionAt: completedAt,
            now: now
        )
        let freshExcerpt = parsed.map { AgentTerminalText.cardExcerpt($0.text) }
        let outputTail = freshExcerpt.flatMap { $0.isEmpty ? nil : $0 }
            ?? retainedPrevious?.outputTail
        let taskSummary = parsed.flatMap {
            AgentTerminalText.taskSummary(
                $0.text,
                excludingCurrentInputLine: probe.currentInputLine
            )
        }
            ?? retainedPrevious?.taskSummary
        let providerSessionID: String? = {
            if let lifecycleEvent, !lifecycleEvent.providerSessionID.isEmpty {
                return lifecycleEvent.providerSessionID
            }
            return retainedPrevious?.providerSessionID
        }()
        let lastLifecycleEventAt: Date? = {
            switch (retainedPrevious?.lastLifecycleEventAt, lifecycleEvent?.timestamp) {
            case (.some(let previous), .some(let current)): max(previous, current)
            case (.some(let previous), .none): previous
            case (.none, .some(let current)): current
            case (.none, .none): nil
            }
        }()
        return AgentInstance(
            id: id,
            profileID: profile.id,
            name: profile.name,
            providerSessionID: providerSessionID,
            location: probe.location,
            status: status,
            taskSummary: taskSummary,
            outputTail: outputTail,
            prompt: status == .waitingForInput ? parsed?.prompt : nil,
            detectedAt: retainedPrevious?.detectedAt ?? now,
            statusChangedAt: retainedPrevious?.status == status
                ? retainedPrevious!.statusChangedAt
                : (status == .justFinished ? (completedAt ?? now) : now),
            finishedAt: status == .justFinished ? completedAt : nil,
            lastLifecycleEventAt: lastLifecycleEventAt,
            lastOutputAt: activity?.0 ?? retainedPrevious?.lastOutputAt,
            outputSequence: activity?.1 ?? retainedPrevious?.outputSequence ?? 0,
            bracketedPasteEnabled: bracketedPasteModes[id] ?? probe.bracketedPasteEnabled,
            sendInFlight: retainedPrevious?.sendInFlight ?? false,
            actionMessage: retainedPrevious?.actionMessage,
            actionIsError: retainedPrevious?.actionIsError ?? false
        )
    }

    private func matchingProfile(processNames: [String]) -> SwipePadProfile? {
        let candidates = profiles.filter { !$0.matchProcess.isEmpty }
        for processName in processNames {
            if let profile = candidates.first(where: {
                SwipePadActiveProfileResolver.matches(
                    profile: $0,
                    processName: processName
                )
            }) {
                return profile
            }
        }
        return nil
    }

    private func blockingPromptIsFreshForLatestSemanticBoundary(
        _ id: AgentInstanceID
    ) -> Bool {
        guard let epoch = blockingPromptEpochs[id] else { return false }
        return epoch.firstSeenLifecycleRevision
            >= (latestNonBlockingLifecycleRevisions[id] ?? 0)
    }

    private func status(
        parsed: AgentPromptParser.Result?,
        lifecycleEvent: AgentLifecycleEvent?,
        inputOverride: AgentStatus?,
        previousStatus: AgentStatus?,
        permissionPromptConfirmed: Bool,
        blockingPromptFresh: Bool,
        completionAt: Date?,
        now: Date
    ) -> AgentStatus {
        if let inputOverride { return inputOverride }
        if let lifecycleEvent {
            if lifecycleEvent.isStatusNeutral {
                // Compatibility path for v2-v7 hook files that could retain a
                // late SubagentStop as the pane's last event. Prefer an actual
                // cursor-owned dialog/composer, then the card's prior root
                // state; without either, child completion still means the root
                // may be working, so remain conservative.
                if parsed?.blockingPromptDetected == true, blockingPromptFresh {
                    return .waitingForInput
                }
                if parsed?.isIdlePrompt == true { return .idle }
                return previousStatus ?? .working
            }
            if Self.requiresVisiblePromptConfirmation(lifecycleEvent),
               !permissionPromptConfirmed {
                return .working
            }
            // Codex completes its planning turn with Stop before presenting
            // the separate plan-approval menu; there is currently no native
            // hook for that dialog. A cursor-owned prompt first observed at
            // this latest semantic boundary is stronger than Stop's nominal
            // idle state. Never let an older menu override a newer boundary,
            // and never override a working lifecycle event.
            if lifecycleEvent.state == .idle,
               parsed?.blockingPromptDetected == true,
               blockingPromptFresh {
                return .waitingForInput
            }
            if Self.isRootCompletion(lifecycleEvent),
               completionIsFresh(completionAt, now: now) {
                return .justFinished
            }
            return lifecycleEvent.state
        }
        // Without a semantic event, a cursor-owned blocking dialog is still
        // enough to expose an actionable prompt. Once hooks exist, their newer
        // working/idle state wins over stale approval text in scrollback.
        if parsed?.blockingPromptDetected == true { return .waitingForInput }
        // Composer glyphs and recent output are deliberately non-authoritative:
        // both Claude and Codex retain prompt-looking rows while computing, and
        // agents may compute silently. Without hooks, only expose a parsed menu;
        // otherwise tell the truth that status is unavailable.
        return .unavailable
    }

    private func performSend(
        agentID: AgentInstanceID,
        stages: [[UInt8]],
        expectedPrompt: AgentPrompt?,
        echoNeedle: String?,
        requiresTailChange: Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard !stages.isEmpty,
              stages.allSatisfy({ !$0.isEmpty }),
              let index = agents.firstIndex(where: { $0.id == agentID }),
              !agents[index].sendInFlight,
              let source = sources[agentID.sessionID]
        else { return false }

        let baseline = agents[index]
        let sid = Self.diagnosticSessionID(agentID.sessionID)
        let pane = Self.diagnosticPaneID(agentID.paneID)
        let provider = Self.diagnosticProvider(profileID: baseline.profileID)
        let sendKind = expectedPrompt != nil
            ? "prompt-answer"
            : (echoNeedle != nil ? "message" : "interrupt")
        agents[index].sendInFlight = true
        agents[index].actionMessage = nil
        agents[index].actionIsError = false

        sendTasks[agentID]?.cancel()
        let generation = (sendGenerations[agentID] ?? 0) &+ 1
        sendGenerations[agentID] = generation
        DiagnosticLogStore.appendAgentCenter(
            "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=started generation=\(generation) stages=\(stages.count) byteCount=\(stages.reduce(0) { $0 + $1.count }) bracketed=\(baseline.bracketedPasteEnabled) lifecycleRevision=\(lifecycleArrivalRevisions[agentID] ?? 0)"
        )
        sendTasks[agentID] = Task { @MainActor [weak self] in
            guard let self else { return }
            // Every action, not only parsed answer buttons, gets a fresh
            // process/profile preflight. A stale card must never type into the
            // shell or a replacement program after its agent exits.
            guard let fresh = await source.inspect(baseline.location),
                  let profile = self.profiles.first(where: { $0.id == baseline.profileID }),
                  self.matchingProfile(processNames: fresh.processNames)?.id == baseline.profileID
            else {
                DiagnosticLogStore.appendAgentCenter(
                    "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=failed phase=preflight reason=process-or-profile-mismatch"
                )
                self.finishSend(
                    agentID,
                    generation: generation,
                    message: "status unavailable — open the pane",
                    isError: true,
                    completion: completion
                )
                self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
                return
            }
            guard self.sendIsCurrent(agentID, generation: generation) else { return }
            DiagnosticLogStore.appendAgentCenter(
                "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=ready phase=preflight processCount=\(fresh.processIDs.count) promptExpected=\(expectedPrompt != nil)"
            )
            if let expectedPrompt {
                let parsed = fresh.visibleText.map {
                    AgentPromptParser.parse(
                        visibleText: $0,
                        profile: profile,
                        currentInputLine: fresh.currentInputLine
                    )
                }
                guard parsed?.prompt?.signature == expectedPrompt.signature else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=failed phase=preflight reason=prompt-changed"
                    )
                    self.finishSend(
                        agentID,
                        generation: generation,
                        message: "prompt changed",
                        isError: true,
                        completion: completion
                    )
                    self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
                    return
                }
            }

            let preSendTail = fresh.visibleText.map {
                AgentTerminalText.tail(AgentTerminalText.normalized($0))
            } ?? baseline.outputTail.map {
                AgentTerminalText.tail(AgentTerminalText.normalized($0))
            }
            let preSendVisibleText = fresh.visibleText.map {
                AgentTerminalText.normalized($0)
            }
            let preSendInputLine = fresh.currentInputLine.map {
                AgentTerminalText.normalized($0)
            }
            let preSendContainedEchoNeedle: Bool = {
                guard let echoNeedle,
                      let visibleText = fresh.visibleText else { return false }
                return self.echoComparable(visibleText)
                    .contains(self.echoComparable(echoNeedle))
            }()
            let baselineLifecycleRevision = self.lifecycleArrivalRevisions[agentID] ?? 0
            let baselinePromptSubmitRevision = self.lifecyclePromptSubmitRevisions[agentID] ?? 0

            for (stageIndex, bytes) in stages.enumerated() {
                guard self.sendIsCurrent(agentID, generation: generation) else { return }
                let stageKind = bytes == [0x0D]
                    ? "return"
                    : (bytes == [0x1B] ? "escape" : "text")
                DiagnosticLogStore.appendAgentCenter(
                    "send-stage sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) stage=\(stageIndex + 1)-of-\(stages.count) stageKind=\(stageKind) byteCount=\(bytes.count) result=started"
                )
                let acknowledged: Bool
                if bytes == [0x0D], let sendKey = source.sendKey {
                    acknowledged = await sendKey(baseline.location, .enter)
                } else if bytes == [0x1B], let sendKey = source.sendKey {
                    acknowledged = await sendKey(baseline.location, .escape)
                } else {
                    acknowledged = await source.send(baseline.location, bytes)
                }
                guard acknowledged else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-stage sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) stage=\(stageIndex + 1)-of-\(stages.count) stageKind=\(stageKind) result=failed"
                    )
                    self.finishSend(
                        agentID,
                        generation: generation,
                        message: stageIndex > 0
                            ? "submission failed — text may still be in the composer"
                            : "didn't land — open the pane",
                        isError: true,
                        completion: completion
                    )
                    self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
                    return
                }
                DiagnosticLogStore.appendAgentCenter(
                    "send-stage sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) stage=\(stageIndex + 1)-of-\(stages.count) stageKind=\(stageKind) result=acknowledged"
                )

                if stageIndex + 1 < stages.count,
                   stages[stageIndex + 1] == [0x0D] {
                    // A carrier acknowledgement proves only that bytes entered
                    // SSH/mosh/tmux, not that the TUI consumed its paste/input
                    // transition. Observe the composer owning those bytes
                    // before sending exactly one semantic Enter. This is a
                    // state boundary, so it remains correct on latent hosts.
                    let settleState = await self.waitForSubmissionInsertion(
                        agentID: agentID,
                        generation: generation,
                        source: source,
                        location: baseline.location,
                        profile: profile,
                        stageBytes: bytes,
                        expectedPrompt: expectedPrompt,
                        echoNeedle: echoNeedle,
                        preSendTail: preSendTail,
                        preSendVisibleText: preSendVisibleText,
                        preSendInputLine: preSendInputLine,
                        sid: sid,
                        pane: pane,
                        provider: provider,
                        sendKind: sendKind
                    )
                    guard let settleState else {
                        self.finishSend(
                            agentID,
                            generation: generation,
                            message: "text landed but the composer did not become ready — open the pane",
                            isError: true,
                            completion: completion
                        )
                        self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
                        return
                    }
                    if case .alreadySubmitted = settleState {
                        DiagnosticLogStore.appendAgentCenter(
                            "send-stage sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) stage=\(stageIndex + 1)-of-\(stages.count) result=already-submitted remainingStages=\(stages.count - stageIndex - 1)"
                        )
                        break
                    }
                }
            }

            let totalDelay = max(1, self.sendVerificationDelayNanoseconds)
            let checkpoints = Set([
                min(totalDelay, 100_000_000),
                min(totalDelay, 400_000_000),
                min(totalDelay, 1_000_000_000),
                totalDelay,
            ]).sorted()
            var elapsed: UInt64 = 0
            var verified = false

            for checkpoint in checkpoints {
                let wait = checkpoint > elapsed ? checkpoint - elapsed : 0
                if wait > 0 {
                    do { try await Task.sleep(nanoseconds: wait) }
                    catch { return }
                }
                elapsed = checkpoint
                guard self.sendIsCurrent(agentID, generation: generation) else { return }

                let lifecycleVerified: Bool
                if echoNeedle != nil {
                    lifecycleVerified = (self.lifecyclePromptSubmitRevisions[agentID] ?? 0)
                        > baselinePromptSubmitRevision
                } else if expectedPrompt != nil {
                    let event = self.lifecycleEvents[agentID]
                    lifecycleVerified = (self.lifecycleArrivalRevisions[agentID] ?? 0)
                        > baselineLifecycleRevision
                        && event?.state != .waitingForInput
                        && event?.event != "SubagentStart"
                        && event?.event != "SubagentStop"
                } else {
                    let event = self.lifecycleEvents[agentID]
                    lifecycleVerified = (self.lifecycleArrivalRevisions[agentID] ?? 0)
                        > baselineLifecycleRevision
                        && (event.map {
                            ["Stop", "StopFailure", "SessionEnd", "WrapperExit"]
                                .contains($0.event)
                        } ?? false)
                }
                if lifecycleVerified {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-verify sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) checkpointMs=\(checkpoint / 1_000_000) method=lifecycle result=verified event=\(Self.diagnosticLifecycleEvent(self.lifecycleEvents[agentID]?.event ?? ""))"
                    )
                    verified = true
                    break
                }

                let postSend = await source.verifySend(baseline.location)
                guard self.sendIsCurrent(agentID, generation: generation) else { return }
                guard let postSend else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-verify sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) checkpointMs=\(checkpoint / 1_000_000) method=terminal result=unavailable"
                    )
                    continue
                }
                verified = self.terminalEvidenceVerifiesSend(
                    postSend,
                    profile: profile,
                    expectedPrompt: expectedPrompt,
                    echoNeedle: echoNeedle,
                    requiresTailChange: requiresTailChange,
                    preSendTail: preSendTail,
                    preSendVisibleText: preSendVisibleText,
                    preSendContainedEchoNeedle: preSendContainedEchoNeedle
                )
                DiagnosticLogStore.appendAgentCenter(
                    "send-verify sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) checkpointMs=\(checkpoint / 1_000_000) method=terminal result=\(verified ? "verified" : "not-yet")"
                )
                if verified { break }
            }

            if verified {
                DiagnosticLogStore.appendAgentCenter(
                    "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=verified generation=\(generation)"
                )
                self.finishSend(
                    agentID,
                    generation: generation,
                    message: nil,
                    isError: false,
                    completion: completion
                )
                self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
            } else {
                DiagnosticLogStore.appendAgentCenter(
                    "send sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) result=failed generation=\(generation) phase=verification"
                )
                self.finishSend(
                    agentID,
                    generation: generation,
                    message: echoNeedle == nil
                        ? "didn't land — open the pane"
                        : "submission not verified — open the pane",
                    isError: true,
                    completion: completion
                )
                self.scheduleRefresh(sessionID: agentID.sessionID, delayNanoseconds: 0)
            }
        }
        return true
    }

    private func finishSend(
        _ agentID: AgentInstanceID,
        generation: UInt64,
        message: String?,
        isError: Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard sendGenerations[agentID] == generation else { return }
        sendTasks.removeValue(forKey: agentID)
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else {
            completion?(false)
            return
        }
        agents[index].sendInFlight = false
        agents[index].actionMessage = message
        agents[index].actionIsError = isError
        completion?(!isError)
    }

    private func waitForSubmissionInsertion(
        agentID: AgentInstanceID,
        generation: UInt64,
        source: AgentSessionSource,
        location: AgentLocation,
        profile: SwipePadProfile,
        stageBytes: [UInt8],
        expectedPrompt: AgentPrompt?,
        echoNeedle: String?,
        preSendTail: String?,
        preSendVisibleText: String?,
        preSendInputLine: String?,
        sid: String,
        pane: String,
        provider: String,
        sendKind: String
    ) async -> SubmissionSettleState? {
        let maximumWait = min(
            1_600_000_000,
            max(5_000_000, sendVerificationDelayNanoseconds / 5 * 4)
        )
        let checkpoints: [UInt64] = [
            0,
            maximumWait / 16,
            maximumWait / 8,
            maximumWait / 4,
            maximumWait / 2,
            maximumWait,
        ]
        var elapsed: UInt64 = 0
        for checkpoint in checkpoints {
            let wait = checkpoint > elapsed ? checkpoint - elapsed : 0
            if wait > 0 {
                do { try await Task.sleep(nanoseconds: wait) }
                catch { return nil }
            }
            elapsed = checkpoint
            guard sendIsCurrent(agentID, generation: generation) else { return nil }
            guard let fresh = await source.verifySend(location) else {
                DiagnosticLogStore.appendAgentCenter(
                    "send-settle sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) checkpointMs=\(checkpoint / 1_000_000) result=unavailable"
                )
                continue
            }
            guard sendIsCurrent(agentID, generation: generation) else { return nil }
            let settleState = submissionSettleState(
                fresh,
                profile: profile,
                stageBytes: stageBytes,
                expectedPrompt: expectedPrompt,
                echoNeedle: echoNeedle,
                preSendTail: preSendTail,
                preSendVisibleText: preSendVisibleText,
                preSendInputLine: preSendInputLine
            )
            let result: String
            switch settleState {
            case .readyForReturn?: result = "composer-ready"
            case .alreadySubmitted?: result = "already-submitted"
            case nil: result = "not-yet"
            }
            DiagnosticLogStore.appendAgentCenter(
                "send-settle sid=\(sid) pane=\(pane) provider=\(provider) kind=\(sendKind) checkpointMs=\(checkpoint / 1_000_000) result=\(result)"
            )
            if let settleState { return settleState }
        }
        return nil
    }

    private func submissionSettleState(
        _ fresh: AgentProbeTarget,
        profile: SwipePadProfile,
        stageBytes: [UInt8],
        expectedPrompt: AgentPrompt?,
        echoNeedle: String?,
        preSendTail: String?,
        preSendVisibleText: String?,
        preSendInputLine: String?
    ) -> SubmissionSettleState? {
        let currentInput = fresh.currentInputLine.map {
            AgentTerminalText.normalized($0)
        }
        if let echoNeedle {
            guard let currentInput else { return nil }
            let comparableNeedle = echoComparable(echoNeedle)
            let comparableInput = echoComparable(currentInput)
            let suffix = String(comparableNeedle.suffix(min(24, comparableNeedle.count)))
            return comparableInput.contains(comparableNeedle)
                || (!suffix.isEmpty && comparableInput.contains(suffix))
                ? .readyForReturn
                : nil
        }

        guard let expectedPrompt,
              let visibleText = fresh.visibleText else { return nil }
        let normalizedVisibleText = AgentTerminalText.normalized(visibleText)
        guard !normalizedVisibleText.isEmpty else { return nil }
        let parsed = AgentPromptParser.parse(
            visibleText: visibleText,
            profile: profile,
            currentInputLine: fresh.currentInputLine
        )
        guard parsed.blockingPromptDetected,
              parsed.prompt?.signature == expectedPrompt.signature else {
            // Some numbered dialogs submit as soon as their accelerator is
            // pressed. A changed nonempty viewport after the exact prompt
            // preflight and acknowledged key means Return must be skipped; the
            // normal final verifier still has to prove the transition.
            return normalizedVisibleText != preSendVisibleText
                ? .alreadySubmitted
                : nil
        }

        let insertedText = AgentTerminalText.normalized(
            String(decoding: stageBytes, as: UTF8.self)
        )
        if !insertedText.isEmpty,
           let currentInput,
           currentInput != preSendInputLine,
           echoComparable(currentInput).contains(echoComparable(insertedText)) {
            return .readyForReturn
        }

        let targetOption = expectedPrompt.options.first { option in
            Self.stagedSubmission(MacroEncoder.encode(option.responseMacro)).first == stageBytes
        }
        let oldDefault = expectedPrompt.options.first(where: \.isDefault)?.id
        let newDefault = parsed.prompt?.options.first(where: \.isDefault)?.id
        if let targetOption,
           oldDefault == targetOption.id,
           newDefault == targetOption.id,
           stageBytes.count == 1,
           let accelerator = stageBytes.first,
           (0x20...0x7E).contains(accelerator) {
            // A one-key menu accelerator may leave an already-highlighted row
            // visually unchanged. The exact prompt preflight plus ordered
            // carrier acknowledgement is enough to press Enter once here;
            // final verification below still requires the menu to disappear
            // or semantically change, so this never claims delivery by itself.
            return .readyForReturn
        }
        if let targetOption,
           newDefault == targetOption.id,
           oldDefault != targetOption.id {
            return .readyForReturn
        }

        let freshTail = AgentTerminalText.tail(parsed.text)
        return freshTail != preSendTail && currentInput != preSendInputLine
            ? .readyForReturn
            : nil
    }

    private func terminalEvidenceVerifiesSend(
        _ fresh: AgentProbeTarget,
        profile: SwipePadProfile,
        expectedPrompt: AgentPrompt?,
        echoNeedle: String?,
        requiresTailChange: Bool,
        preSendTail: String?,
        preSendVisibleText: String?,
        preSendContainedEchoNeedle: Bool
    ) -> Bool {
        let freshTail = fresh.visibleText.map {
            AgentTerminalText.tail(AgentTerminalText.normalized($0))
        }
        let tailChanged = freshTail != nil && freshTail != preSendTail

        if let expectedPrompt {
            guard let visibleText = fresh.visibleText else { return false }
            let normalizedVisibleText = AgentTerminalText.normalized(visibleText)
            guard !normalizedVisibleText.isEmpty,
                  normalizedVisibleText != preSendVisibleText
            else { return false }
            let parsed = AgentPromptParser.parse(
                visibleText: visibleText,
                profile: profile,
                currentInputLine: fresh.currentInputLine
            )
            if parsed.blockingPromptDetected {
                guard let currentPrompt = parsed.prompt else { return false }
                return currentPrompt.signature != expectedPrompt.signature
            }
            return true
        }

        if let echoNeedle {
            guard let visibleText = fresh.visibleText,
                  let currentInputLine = fresh.currentInputLine
            else { return false }
            let normalizedVisibleText = AgentTerminalText.normalized(visibleText)
            guard !normalizedVisibleText.isEmpty,
                  normalizedVisibleText != preSendVisibleText
            else { return false }
            let comparableNeedle = echoComparable(echoNeedle)
            let visibleContainsMessage = echoComparable(normalizedVisibleText)
                .contains(comparableNeedle)
            let composer = echoComparable(currentInputLine)
            let suffix = String(comparableNeedle.suffix(min(24, comparableNeedle.count)))
            let composerStillOwnsMessage = composer.contains(comparableNeedle)
                || (!suffix.isEmpty && composer.contains(suffix))
            // Painted text proves insertion only. It is fallback submission
            // evidence solely after the cursor row has advanced away from it.
            return !preSendContainedEchoNeedle
                && visibleContainsMessage
                && !composerStillOwnsMessage
        }

        return requiresTailChange && tailChanged
    }

    private static func stagedSubmission(_ bytes: [UInt8]) -> [[UInt8]] {
        guard bytes.count > 1, bytes.last == 0x0D else { return [bytes] }
        return [Array(bytes.dropLast()), [0x0D]]
    }

    private func sendIsCurrent(
        _ agentID: AgentInstanceID,
        generation: UInt64
    ) -> Bool {
        sendGenerations[agentID] == generation
            && sources[agentID.sessionID] != nil
    }

    private func echoComparable(_ text: String) -> String {
        AgentTerminalText.normalized(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
