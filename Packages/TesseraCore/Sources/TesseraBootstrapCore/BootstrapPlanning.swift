import Foundation
import TesseraProtocolCore

public enum BootstrapImportDisposition: String, Codable, CaseIterable, Sendable {
    case inserted
    case unchanged
    case conflict
    case mappedSetting
    case ignoredPlatformHint
    case requiresLocalCredential
}

public enum BootstrapImportRecordKind: String, Codable, CaseIterable, Sendable {
    case host
    case identity
    case jumpLink
    case trustedHost
    case appearanceSetting
    case generalSetting
    case platformHint
    case credentialRequirement
}

public struct BootstrapImportResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let recordKind: BootstrapImportRecordKind
    public let sourceID: UUID?
    public let disposition: BootstrapImportDisposition
    public let code: String

    public init(
        id: UUID = UUID(),
        recordKind: BootstrapImportRecordKind,
        sourceID: UUID? = nil,
        disposition: BootstrapImportDisposition,
        code: String
    ) {
        self.id = id
        self.recordKind = recordKind
        self.sourceID = sourceID
        self.disposition = disposition
        self.code = code
    }
}

public struct BootstrapImportPlan: Equatable, Sendable {
    public let manifest: BootstrapManifestV2
    public let selectedHostIDs: [UUID]
    public let insertedHostIDs: Set<UUID>
    public let reusedHostIDs: Set<UUID>
    public let requiresLocalCredentialHostIDs: Set<UUID>

    public init(
        manifest: BootstrapManifestV2,
        selectedHostIDs: [UUID],
        insertedHostIDs: Set<UUID>,
        reusedHostIDs: Set<UUID>,
        requiresLocalCredentialHostIDs: Set<UUID>
    ) {
        self.manifest = manifest
        self.selectedHostIDs = selectedHostIDs
        self.insertedHostIDs = insertedHostIDs
        self.reusedHostIDs = reusedHostIDs
        self.requiresLocalCredentialHostIDs = requiresLocalCredentialHostIDs
    }
}

public enum BootstrapAdmissionLimit: Equatable, Sendable {
    case checking
    case limited(maximumSavedHosts: Int)
    case unlimited
}

public enum BootstrapAdmissionDecision: Equatable, Sendable {
    case allow(BootstrapImportPlan)
    case checkingEntitlement(BootstrapImportPlan)
    case requiresUpgrade(BootstrapImportPlan)
}

public enum BootstrapPlanningError: Error, Equatable, Sendable {
    case emptySelection
    case duplicateSelection(UUID)
    case unknownHost(UUID)
    case selectedRouteDependencyMissing(hostID: UUID, jumpHostID: UUID)
}

/// Computes one atomic import set before a platform writes persistence. A jump
/// dependency is never silently omitted and a password hint never implies that
/// password material arrived.
public enum BootstrapAdmissionPlanner {
    public static func plan(
        manifest: BootstrapManifestV2,
        selectedHostIDs: [UUID],
        savedHostIDs: Set<UUID>,
        existingSavedHostCount: Int,
        limit: BootstrapAdmissionLimit
    ) throws -> BootstrapAdmissionDecision {
        try manifest.validate()
        guard !selectedHostIDs.isEmpty else { throw BootstrapPlanningError.emptySelection }
        let selected = Set(selectedHostIDs)
        guard selected.count == selectedHostIDs.count else {
            let duplicate = Dictionary(grouping: selectedHostIDs, by: { $0 })
                .first(where: { $0.value.count > 1 })!.key
            throw BootstrapPlanningError.duplicateSelection(duplicate)
        }
        let manifestHostIDs = Set(manifest.hosts.map(\.id))
        if let unknown = selected.first(where: { !manifestHostIDs.contains($0) }) {
            throw BootstrapPlanningError.unknownHost(unknown)
        }
        for link in manifest.jumpChains where selected.contains(link.hostID) {
            guard selected.contains(link.jumpHostID) || savedHostIDs.contains(link.jumpHostID) else {
                throw BootstrapPlanningError.selectedRouteDependencyMissing(
                    hostID: link.hostID,
                    jumpHostID: link.jumpHostID
                )
            }
        }
        let inserted = selected.subtracting(savedHostIDs)
        let reused = selected.intersection(savedHostIDs)
        let credentialRequired = Set(manifest.hosts.compactMap { host in
            selected.contains(host.id) && host.authenticationHint != .none ? host.id : nil
        })
        let plan = BootstrapImportPlan(
            manifest: manifest,
            selectedHostIDs: selectedHostIDs,
            insertedHostIDs: inserted,
            reusedHostIDs: reused,
            requiresLocalCredentialHostIDs: credentialRequired
        )
        switch limit {
        case .unlimited:
            return .allow(plan)
        case .checking:
            return inserted.isEmpty ? .allow(plan) : .checkingEntitlement(plan)
        case .limited(let maximumSavedHosts):
            return existingSavedHostCount + inserted.count <= max(0, maximumSavedHosts)
                ? .allow(plan)
                : .requiresUpgrade(plan)
        }
    }
}

public protocol BootstrapManifestExporter: Sendable {
    func exportManifest(
        selectedHostIDs: [UUID],
        optionalTransfers: Set<BootstrapOptionalTransfer>
    ) async throws -> BootstrapManifestV2
}

/// Implementations must apply the plan atomically and durably before returning.
public protocol BootstrapManifestImporter: Sendable {
    func apply(_ plan: BootstrapImportPlan) async throws -> [BootstrapImportResult]
}

public protocol BootstrapSettingsMapper: Sendable {
    func mapAppearance(_ settings: BootstrapAppearanceSettings) -> [BootstrapImportResult]
    func mapGeneral(_ settings: BootstrapGeneralSettings) -> [BootstrapImportResult]
}
