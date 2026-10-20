import Foundation
import TesseraPairingCore
import TesseraProtocolCore

/// Stateless presentation only. Existing protocol/coordinator state remains
/// authoritative, and every action must be revalidated when it is performed.
public enum SetupFlowPresentationV1 {
    public enum Entry: String, Codable, Sendable { case qr, nearby }
    public enum Stage: String, Codable, Sendable { case scan, discover, verify, choose, transfer, connect }
    public enum Phase: String, Codable, Sendable {
        case entry, connecting, compareCode, waitingForPeerCode, preparingKey
        case choosing, waitingForSelection, reviewingImport, authorizing
        case transferring, importing, waitingForGrant, granting, recordingAccess
        case awaitingConnection, completed, failed, rejecting
    }
    public enum Action: String, Codable, Sendable {
        case cancel, confirmCode, rejectCode, approve, importSetup, retry, done, configureLater
    }
    public enum UnavailableReason: String, Codable, Sendable { case notSupported, wrongPhase, emptySelection }
    public enum SelectionMode: String, Codable, Sendable { case copy, grants }
    public enum Access: String, Codable, Sendable {
        case unknown, installed, alreadyInstalled, failed, skipped, notSelected, excluded, uncertain
    }
    public enum Outcome: String, Codable, Sendable {
        case configurationCopied, authorized, alreadyAuthorized, passwordNeeded
        case failed, skipped, notSelected, notImported, excluded, uncertain
    }
    public enum FailureReason: String, Codable, Sendable {
        case expired, codeMismatch, disconnected, locked, policyChanged, protocolError, other
    }

    public struct Selection: Codable, Equatable, Sendable {
        public var mode: SelectionMode
        public var allHostIDs: [UUID]
        public var selectedHostIDs: [UUID]
        public var grantEligibleHostIDs: [UUID]
        public var jumpLinks: [BootstrapJumpLink]
        public init(mode: SelectionMode, allHostIDs: [UUID], selectedHostIDs: [UUID],
                    grantEligibleHostIDs: [UUID], jumpLinks: [BootstrapJumpLink] = []) {
            self.mode = mode; self.allHostIDs = allHostIDs; self.selectedHostIDs = selectedHostIDs
            self.grantEligibleHostIDs = grantEligibleHostIDs; self.jumpLinks = jumpLinks
        }
    }
    public struct HostFact: Codable, Equatable, Sendable {
        public var id: UUID
        public var access: Access
        public var wasAccepted: Bool?
        public var passwordNeeded: Bool
        public init(id: UUID, access: Access, wasAccepted: Bool? = nil, passwordNeeded: Bool = false) {
            self.id = id; self.access = access; self.wasAccepted = wasAccepted; self.passwordNeeded = passwordNeeded
        }
    }
    public struct Input: Codable, Equatable, Sendable {
        public var purpose: PairingPurpose
        public var entry: Entry
        public var phase: Phase
        /// Adapter remembers where an operation stopped; failure is not completion.
        public var stoppedAt: Stage?
        public var failureCode: String?
        public var supportedActions: [Action]
        public var selection: Selection?
        public var hosts: [HostFact]
        public init(purpose: PairingPurpose = .bootstrap, entry: Entry = .qr, phase: Phase,
                    supportedActions: [Action] = [], selection: Selection? = nil, hosts: [HostFact] = [], stoppedAt: Stage? = nil,
                    failureCode: String? = nil) {
            self.purpose = purpose; self.entry = entry; self.phase = phase
            self.supportedActions = supportedActions; self.selection = selection; self.hosts = hosts
            self.stoppedAt = stoppedAt
            self.failureCode = failureCode
        }
    }
    public struct ActionAvailability: Codable, Equatable, Sendable {
        public let action: Action
        public let unavailableReason: UnavailableReason?
        public var isAvailable: Bool { unavailableReason == nil }
    }
    public struct HostOutcome: Codable, Equatable, Sendable {
        public let id: UUID
        public let outcome: Outcome
    }
    public struct Output: Codable, Equatable, Sendable {
        public let stages: [Stage]
        public let currentStage: Stage
        /// A semantic status, never a localized sentence used as a discriminator.
        public let status: Phase
        public let copiedHostIDs: [UUID]
        public let grantedHostIDs: [UUID]
        public let requiredRouteHostIDs: [UUID]
        public let actions: [ActionAvailability]
        public let hosts: [HostOutcome]
        public let failureReason: FailureReason?
        public var currentStageIndex: Int { stages.firstIndex(of: currentStage) ?? 0 }
        public func allows(_ action: Action) -> Bool {
            actions.contains { $0.action == action && $0.isAvailable }
        }
    }

    public static func project(_ input: Input) -> Output {
        let first: Stage = input.entry == .qr ? .scan : .discover
        let hasSetup = input.purpose == .bootstrap || input.purpose == .setUpAndContinue
        var stages: [Stage] = [first, .verify]
        if hasSetup || input.purpose == .enroll { stages.append(.choose) }
        if input.purpose != .continueSession { stages.append(.transfer) }
        if input.purpose == .continueSession || input.purpose == .setUpAndContinue { stages.append(.connect) }
        let stage: Stage
        switch input.phase {
        case .entry, .connecting: stage = first
        case .compareCode, .waitingForPeerCode, .preparingKey, .rejecting: stage = .verify
        case .choosing, .waitingForSelection, .reviewingImport, .authorizing:
            stage = hasSetup || input.purpose == .enroll ? .choose : .connect
        case .transferring, .importing, .waitingForGrant, .granting, .recordingAccess:
            stage = input.purpose == .continueSession ? .connect : .transfer
        case .awaitingConnection: stage = stages.contains(.connect) ? .connect : .transfer
        case .completed: stage = stages.last ?? first
        case .failed: stage = input.stoppedAt.flatMap { stages.contains($0) ? $0 : nil } ?? first
        }
        let all = Set(input.selection?.allHostIDs ?? [])
        let selected = Set(input.selection?.selectedHostIDs ?? []).intersection(all)
        // Use the protocol's route closure, not a second platform implementation.
        let closure = BootstrapManifestV2.hostSelectionClosure(
            selected, jumpChains: input.selection?.jumpLinks ?? []
        ).intersection(all)
        let copied = input.selection?.mode == .grants ? all : closure
        let granted = (input.selection?.mode == .grants ? selected : copied)
            .intersection(Set(input.selection?.grantEligibleHostIDs ?? []))
        func sorted(_ ids: Set<UUID>) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
        let actions = input.supportedActions.map { action -> ActionAvailability in
            let valid: Bool
            switch action {
            case .confirmCode, .rejectCode: valid = input.phase == .compareCode
            case .approve: valid = input.phase == .choosing
            case .importSetup: valid = input.phase == .reviewingImport
            case .retry: valid = input.phase == .failed
            case .done, .configureLater: valid = input.phase == .completed || input.phase == .failed
            case .cancel: valid = true
            }
            let empty = action == .approve && hasSetup && input.selection?.mode == .copy && copied.isEmpty
            return ActionAvailability(action: action, unavailableReason: !valid ? .wrongPhase : empty ? .emptySelection : nil)
        }
        return Output(stages: stages, currentStage: stage, status: input.phase,
                      copiedHostIDs: sorted(copied), grantedHostIDs: sorted(granted),
                      requiredRouteHostIDs: sorted(closure.subtracting(selected)), actions: actions,
                      hosts: input.hosts.map { HostOutcome(id: $0.id, outcome: outcome($0)) },
                      failureReason: input.failureCode.map(failureReason))
    }

    public static func failureReason(_ code: String) -> FailureReason {
        switch code {
        case "expired": .expired
        case "sasRejected": .codeMismatch
        case "peerAborted", "peerDisconnected": .disconnected
        case "applicationLocked": .locked
        case "policyChanged": .policyChanged
        case "invalidOrder", "malformedOrReplay": .protocolError
        default: .other
        }
    }

    public static func outcome(_ host: HostFact) -> Outcome {
        if host.wasAccepted == false { return .notImported }
        switch host.access {
        case .installed: return .authorized
        case .alreadyInstalled: return .alreadyAuthorized
        case .failed: return .failed
        case .uncertain: return .uncertain
        case .notSelected: return .notSelected
        case .excluded: return host.passwordNeeded ? .passwordNeeded : .excluded
        case .skipped: return host.passwordNeeded ? .passwordNeeded : .skipped
        case .unknown: return host.passwordNeeded ? .passwordNeeded : .configurationCopied
        }
    }
}
