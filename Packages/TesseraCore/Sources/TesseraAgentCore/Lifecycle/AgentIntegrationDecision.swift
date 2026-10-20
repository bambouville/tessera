import Foundation

/// Platform-neutral observations used to decide how a live terminal's Agent
/// integration should be presented and repaired. Platform adapters gather
/// these facts over their already-authenticated session; they do not reduce
/// them independently.
public enum AgentIntegrationInstallationKind: String, Codable, CaseIterable, Sendable {
    case missing
    case current
    case outdated
    /// A newer Tessera's installation that this app is too old to operate.
    case requiresAppUpdate
}

public enum AgentIntegrationForegroundKind: String, Codable, CaseIterable, Sendable {
    case shell
    case unsupportedShell
    case agent
    case other
}

public struct AgentIntegrationForegroundClassification: Equatable, Sendable {
    public let foreground: AgentIntegrationForegroundKind
    public let providerIDs: Set<AgentProviderID>
    public let requiresLifecycleHook: Bool

    public init(
        foreground: AgentIntegrationForegroundKind,
        providerIDs: Set<AgentProviderID>,
        requiresLifecycleHook: Bool
    ) {
        self.foreground = foreground
        self.providerIDs = providerIDs
        self.requiresLifecycleHook = requiresLifecycleHook
    }
}

/// One compiled foreground classifier imported directly by Apple and exposed
/// through the C ABI to Android. Platforms provide executable observations;
/// shell/provider policy stays here.
public enum AgentIntegrationForegroundClassifier {
    private static let supportedShells: Set<String> = ["bash", "zsh"]
    private static let unsupportedShells: Set<String> = [
        "ash", "csh", "dash", "fish", "ksh", "mksh", "nu", "pwsh", "sh", "tcsh",
    ]
    private static let lifecycleHookProviders: Set<AgentProviderID> = [.claude, .codex, .kimi]

    public static func isSupportedShell(_ executable: String) -> Bool {
        supportedShells.contains(normalizedExecutableName(executable))
    }

    public static func isUnsupportedShell(_ executable: String) -> Bool {
        unsupportedShells.contains(normalizedExecutableName(executable))
    }

    public static func classify(executables: [String]) -> AgentIntegrationForegroundClassification {
        let names = executables.map(normalizedExecutableName)
        let descriptors = executables.compactMap { AgentProcessDescriptor(executableName: $0) }
        let providerIDs = Set(AgentProviderRegistry.builtIn.providers(matching: descriptors))
        // A provider anywhere in the foreground set wins. Tessera's own shims
        // run the provider as a child of `/bin/sh` without job control, so the
        // pane's foreground process group is {sh, codex}; ranking the shell
        // first turned every shimmed Codex pane into "open bash or zsh".
        let foreground: AgentIntegrationForegroundKind
        if !providerIDs.isEmpty { foreground = .agent }
        else if names.contains(where: supportedShells.contains) { foreground = .shell }
        else if names.contains(where: unsupportedShells.contains) { foreground = .unsupportedShell }
        else { foreground = .other }
        return .init(
            foreground: foreground,
            providerIDs: providerIDs,
            requiresLifecycleHook: !providerIDs.isDisjoint(with: lifecycleHookProviders)
        )
    }

    private static func normalizedExecutableName(_ executable: String) -> String {
        URL(fileURLWithPath: executable).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }
}

/// The only host process-tree roots that may be interpolated into Core's
/// fixed discovery program. Route markers bind raw SSH to its carrier; a PID
/// root is supplied only by transports that have already proved ownership.
public enum AgentIntegrationProcessDiscoveryScope: Codable, Equatable, Sendable {
    case routeMarker(String)
    case rootProcess(Int)

    private enum CodingKeys: String, CodingKey { case kind, marker, processID }
    private enum Kind: String, Codable { case routeMarker, rootProcess }

    public init?(routeMarker: String) {
        guard routeMarker.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else { return nil }
        self = .routeMarker(routeMarker)
    }

    public init?(rootProcessID: Int) {
        guard rootProcessID > 1 else { return nil }
        self = .rootProcess(rootProcessID)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .routeMarker:
            guard let value = AgentIntegrationProcessDiscoveryScope(routeMarker: try values.decode(String.self, forKey: .marker)) else {
                throw DecodingError.dataCorruptedError(forKey: .marker, in: values, debugDescription: "invalid route marker")
            }
            self = value
        case .rootProcess:
            guard let value = AgentIntegrationProcessDiscoveryScope(rootProcessID: try values.decode(Int.self, forKey: .processID)) else {
                throw DecodingError.dataCorruptedError(forKey: .processID, in: values, debugDescription: "invalid root process")
            }
            self = value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .routeMarker(marker):
            try values.encode(Kind.routeMarker, forKey: .kind)
            try values.encode(marker, forKey: .marker)
        case let .rootProcess(processID):
            try values.encode(Kind.rootProcess, forKey: .kind)
            try values.encode(processID, forKey: .processID)
        }
    }
}

/// Content-free process facts emitted by the fixed discovery script. The
/// Core parser accepts only this bounded schema before reducing foreground
/// classification; adapters never infer shell/provider policy from strings.
public struct AgentIntegrationDiscoveredProcess: Codable, Equatable, Sendable {
    public let processID: Int
    public let parentProcessID: Int?
    public let executable: String
    public let foreground: Bool

    enum CodingKeys: String, CodingKey { case processID = "pid", parentProcessID = "ppid", executable, foreground }

    public init?(processID: Int, parentProcessID: Int?, executable: String, foreground: Bool) {
        guard processID > 1,
              parentProcessID == nil || parentProcessID! >= 1,
              executable.utf8.count <= 256,
              executable.range(of: #"^[A-Za-z0-9._+/@:-]+$"#, options: .regularExpression) != nil
        else { return nil }
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.executable = executable
        self.foreground = foreground
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = AgentIntegrationDiscoveredProcess(
            processID: try values.decode(Int.self, forKey: .processID),
            parentProcessID: try values.decodeIfPresent(Int.self, forKey: .parentProcessID),
            executable: try values.decode(String.self, forKey: .executable),
            foreground: try values.decodeIfPresent(Bool.self, forKey: .foreground) ?? false
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .executable, in: values, debugDescription: "invalid process descriptor")
        }
        self = value
    }
}

public struct AgentIntegrationProcessDiscoveryResult: Codable, Equatable, Sendable {
    public let processes: [AgentIntegrationDiscoveredProcess]
    public let foreground: AgentIntegrationForegroundKind
    public let foregroundShellProcessIDs: [Int]
    public let foregroundProviderProcessIDs: [Int]
    /// Only these provider processes can make lifecycle-hook activity
    /// meaningful. Inventory/RPC-only providers (for example OpenCode/Pi)
    /// remain visible as agents but never produce a hook-inactive repair.
    public let foregroundLifecycleProviderProcessIDs: [Int]
    public let foregroundRequiresLifecycleHook: Bool

    public init(processes: [AgentIntegrationDiscoveredProcess], foreground: AgentIntegrationForegroundKind, foregroundShellProcessIDs: [Int], foregroundProviderProcessIDs: [Int], foregroundLifecycleProviderProcessIDs: [Int], foregroundRequiresLifecycleHook: Bool) {
        self.processes = processes
        self.foreground = foreground
        self.foregroundShellProcessIDs = foregroundShellProcessIDs
        self.foregroundProviderProcessIDs = foregroundProviderProcessIDs
        self.foregroundLifecycleProviderProcessIDs = foregroundLifecycleProviderProcessIDs
        self.foregroundRequiresLifecycleHook = foregroundRequiresLifecycleHook
    }
}

public struct AgentIntegrationObservation: Codable, Equatable, Sendable {
    public let installation: AgentIntegrationInstallationKind
    public let foreground: AgentIntegrationForegroundKind
    public let shellIntegrationActive: Bool?
    public let agentIntegrationActive: Bool
    public let agentRequiresLifecycleHook: Bool?

    public init(
        installation: AgentIntegrationInstallationKind,
        foreground: AgentIntegrationForegroundKind,
        shellIntegrationActive: Bool?,
        agentIntegrationActive: Bool,
        agentRequiresLifecycleHook: Bool? = nil
    ) {
        self.installation = installation
        self.foreground = foreground
        self.shellIntegrationActive = shellIntegrationActive
        self.agentIntegrationActive = agentIntegrationActive
        self.agentRequiresLifecycleHook = agentRequiresLifecycleHook
    }
}

public enum AgentIntegrationDecisionKind: String, Codable, CaseIterable, Sendable {
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
    /// The host runs a newer integration than this app understands. There is
    /// deliberately no action: installing would downgrade another device.
    case appUpdateRequired
}

public enum AgentIntegrationDecisionAction: String, Codable, CaseIterable, Sendable {
    case installAndApply
    case installOnly
    case apply
    case persistAndApply
    case check
    case retry
}

public struct AgentIntegrationDecision: Codable, Equatable, Sendable {
    public let kind: AgentIntegrationDecisionKind
    public let primaryAction: AgentIntegrationDecisionAction?
    public let secondaryAction: AgentIntegrationDecisionAction?

    public init(
        kind: AgentIntegrationDecisionKind,
        primaryAction: AgentIntegrationDecisionAction? = nil,
        secondaryAction: AgentIntegrationDecisionAction? = nil
    ) {
        self.kind = kind
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    public var showsWarning: Bool {
        kind != .checking && kind != .ready && kind != .busyProgram
    }

    /// Reconciles an action captured from an earlier presentation with fresh
    /// terminal observations. Installing files may gain shell activation only
    /// when the fresh target proves it is safe, while an agent launch narrows
    /// install-and-apply to files-only.
    public func effectiveAction(
        for requested: AgentIntegrationDecisionAction?
    ) -> AgentIntegrationDecisionAction? {
        guard let requested else { return nil }
        if requested == primaryAction || requested == secondaryAction { return requested }

        switch (requested, primaryAction) {
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

    public func supports(_ action: AgentIntegrationDecisionAction?) -> Bool {
        effectiveAction(for: action) != nil
    }
}

public enum AgentIntegrationDecisionReducer {
    public static func resolve(_ observation: AgentIntegrationObservation) -> AgentIntegrationDecision {
        if observation.foreground == .agent {
            if observation.agentRequiresLifecycleHook == false {
                switch observation.installation {
                case .missing:
                    return .init(kind: .notInstalled, primaryAction: .installOnly)
                case .outdated:
                    return .init(kind: .outdated, primaryAction: .installOnly)
                case .current:
                    return .init(kind: .ready)
                case .requiresAppUpdate:
                    return .init(kind: .appUpdateRequired)
                }
            }
            switch observation.installation {
            case .missing:
                return .init(kind: .notInstalled, primaryAction: .installOnly)
            case .outdated:
                return .init(kind: .outdated, primaryAction: .installOnly)
            case .current:
                return observation.agentIntegrationActive
                    ? .init(kind: .ready)
                    : .init(kind: .insideAgent)
            case .requiresAppUpdate:
                return .init(kind: .appUpdateRequired)
            }
        }

        switch observation.installation {
        // Whatever runs in the foreground, nothing this app writes can help.
        case .requiresAppUpdate:
            return .init(kind: .appUpdateRequired)
        case .missing:
            return .init(
                kind: .notInstalled,
                primaryAction: observation.foreground == .shell ? .installAndApply : .installOnly
            )
        case .outdated:
            return .init(
                kind: .outdated,
                primaryAction: observation.foreground == .shell ? .installAndApply : .installOnly
            )
        case .current:
            if observation.shellIntegrationActive == true {
                return .init(kind: .ready)
            }
            switch observation.foreground {
            case .shell:
                guard observation.shellIntegrationActive != nil else {
                    return .init(kind: .unavailable, primaryAction: .retry)
                }
                return .init(
                    kind: .inactiveShell,
                    primaryAction: .apply,
                    secondaryAction: .persistAndApply
                )
            case .unsupportedShell:
                return .init(kind: .unsupportedShell)
            case .agent:
                // Handled above, but retained as an exhaustive conservative
                // fallback if the decision inputs grow in a future ABI.
                return .init(kind: .insideAgent)
            case .other:
                return .init(kind: .busyProgram)
            }
        }
    }
}
