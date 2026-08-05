import Foundation
import CryptoKit
import PortForwarding
import SwiftData

struct BootstrapImportReceipt: Equatable, Sendable {
    let insertedHosts: Int
    let skippedExistingHosts: Int
    let insertedIdentities: Int
    let insertedJumpLinks: Int
    let insertedKnownHosts: Int
    let skippedKnownHosts: Int
    let conflictingKnownHosts: Int
    /// Exact allowlist for applying later grant receipts. Counts are display
    /// data; only these IDs were accepted as new local records by this import.
    let insertedHostIDs: Set<UUID>
    /// Host IDs this exact manifest may safely grant on this attempt. This also
    /// includes unchanged hosts durably imported by an interrupted prior
    /// attempt, while `insertedHostIDs` remains the truthful count source.
    let acceptedHostIDs: Set<UUID>

    init(
        insertedHosts: Int,
        skippedExistingHosts: Int,
        insertedIdentities: Int,
        insertedJumpLinks: Int,
        insertedKnownHosts: Int = 0,
        skippedKnownHosts: Int = 0,
        conflictingKnownHosts: Int = 0,
        insertedHostIDs: Set<UUID> = [],
        acceptedHostIDs: Set<UUID>? = nil
    ) {
        self.insertedHosts = insertedHosts
        self.skippedExistingHosts = skippedExistingHosts
        self.insertedIdentities = insertedIdentities
        self.insertedJumpLinks = insertedJumpLinks
        self.insertedKnownHosts = insertedKnownHosts
        self.skippedKnownHosts = skippedKnownHosts
        self.conflictingKnownHosts = conflictingKnownHosts
        self.insertedHostIDs = insertedHostIDs
        self.acceptedHostIDs = acceptedHostIDs ?? insertedHostIDs
    }
}

/// The persisted-host cost of a nearby-setup import, computed before any
/// mutation. The saved-host admission boundary uses this plan to accept the
/// whole batch, choose whole routes, or decline the import entirely.
struct BootstrapImportPlan {
    struct Route: Identifiable, Equatable {
        let id: UUID                    // root/destination host id
        let name: String
        let address: String
        let closureHostIDs: Set<UUID>   // root + its NEW jump-host ancestors that this import would insert
    }
    let newHostIDs: Set<UUID>           // every PersistedHost row this apply would newly insert (post skip/unavailable filtering; same semantics as insertedHostIDs)
    let routes: [Route]                 // one per newly-insertable destination host whose full route is importable
}

enum BootstrapAdmissionResponse { case proceedFull, restrictTo(Set<UUID>), cancel }
typealias BootstrapAdmissionHandler = (BootstrapImportPlan) async -> BootstrapAdmissionResponse
typealias BootstrapFinalAdmissionValidator = @MainActor @Sendable (Int) -> Bool

enum BootstrapImportAdmissionError: Error, Equatable {
    case stateChanged
}

/// A restricted import selection that is not a union of whole jump closures.
/// Thrown before any mutation; a partial route must never reach SwiftData.
enum BootstrapImportRestrictionError: Error, Equatable, LocalizedError {
    case incompleteRoute(hostID: UUID, missingAncestorID: UUID)

    var errorDescription: String? {
        switch self {
        case .incompleteRoute(let hostID, let missingAncestorID):
            return "A restricted import of \(hostID) also requires jump host \(missingAncestorID)."
        }
    }
}

/// Device-local, secret-free idempotency provenance for an imported manifest.
/// The record is written only after SwiftData commits. It lets a retry
/// acknowledge unchanged imported hosts instead of either reinstalling blindly
/// or permanently stranding a prior partial transfer.
struct BootstrapImportProvenanceStore {
    private static let key = "tessera.bootstrapImportProvenance.v1"
    private static let maximumRecords = 32
    private let defaults: UserDefaults

    private struct Record: Codable {
        let localStateByHostID: [String: String]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasInterruptedImport: Bool {
        records().values.contains { !$0.localStateByHostID.isEmpty }
    }

    func localStates(for manifest: BootstrapManifest) throws -> [UUID: String] {
        let key = try manifestKey(manifest)
        guard let values = records()[key]?.localStateByHostID else { return [:] }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func record(
        localStates: [UUID: String],
        for manifest: BootstrapManifest
    ) throws {
        guard !localStates.isEmpty else { return }
        let key = try manifestKey(manifest)
        var values = records()
        values[key] = Record(
            localStateByHostID: Dictionary(uniqueKeysWithValues: localStates.map {
                ($0.key.uuidString, $0.value)
            })
        )
        if values.count > Self.maximumRecords {
            for stale in values.keys.sorted().prefix(values.count - Self.maximumRecords) {
                values.removeValue(forKey: stale)
            }
        }
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func markComplete(_ manifest: BootstrapManifest) throws {
        let key = try manifestKey(manifest)
        var values = records()
        values.removeValue(forKey: key)
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func clearAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func records() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return decoded
    }

    private func manifestKey(_ manifest: BootstrapManifest) throws -> String {
        SHA256.hash(data: try manifest.encoded()).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// Public TOFU comparison material retained for continuation comparison UI.
/// Nearby bootstrap now also imports the exact owner-authorized pin into
/// `KnownHostsStore`; this sidecar remains useful for peer-attribution text.
struct BootstrapTrustHint: Codable, Equatable, Sendable {
    let fingerprint: String
    let peerDeviceName: String
}

struct BootstrapTrustHintStore {
    private static let key = "tessera.bootstrapTrustHints.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hint(for hostID: UUID) -> BootstrapTrustHint? {
        all()[hostID]
    }

    func record(_ hint: BootstrapTrustHint, for hostID: UUID) {
        var hints = all()
        hints[hostID] = hint
        save(hints)
    }

    private func all() -> [UUID: BootstrapTrustHint] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(
                [String: BootstrapTrustHint].self,
                from: data
              )
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save(_ hints: [UUID: BootstrapTrustHint]) {
        let encoded = Dictionary(uniqueKeysWithValues: hints.map {
            ($0.key.uuidString, $0.value)
        })
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor
enum BootstrapManifestAdapter {
    private static func localProvenanceState(_ host: PersistedHost) -> String {
        let identityID = host.identity?.id.uuidString ?? "nil"
        let credential: String
        switch host.identity?.credentialMode {
        case .some(.password): credential = "password"
        case .some(.key(let keyID)): credential = "key:\(keyID.uuidString)"
        case .some(.legacyDevKey): credential = "legacy"
        case .some(.none): credential = "none"
        case nil: credential = "nil"
        }
        return "\(identityID)|\(credential)"
    }

    /// Called only after authenticated grant results have been durably applied.
    /// It advances retry provenance from the credential-less import state to
    /// the protocol-promoted device-key state before the final acknowledgement.
    static func refreshImportProvenance(
        for manifest: BootstrapManifest,
        in modelContext: ModelContext,
        provenance: BootstrapImportProvenanceStore = BootstrapImportProvenanceStore()
    ) throws {
        let acceptedIDs = Set(try provenance.localStates(for: manifest).keys)
        let hosts = try modelContext.fetch(FetchDescriptor<PersistedHost>())
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let localStates = Dictionary(uniqueKeysWithValues: acceptedIDs.compactMap { hostID in
            hostsByID[hostID].map { (hostID, localProvenanceState($0)) }
        })
        try provenance.record(localStates: localStates, for: manifest)
    }

    static func export(
        from modelContext: ModelContext,
        appearance: AppearancePreferences,
        knownHosts: KnownHostsStore = .shared
    ) async throws -> BootstrapManifest {
        let persistedHosts = try modelContext.fetch(FetchDescriptor<PersistedHost>())
        let identities = try modelContext.fetch(FetchDescriptor<Identity>())
        let links = try modelContext.fetch(FetchDescriptor<HostJumpLink>())
        let storedKeys = try modelContext.fetch(FetchDescriptor<StoredKey>())
        let storedKeysByID = Dictionary(uniqueKeysWithValues: storedKeys.map { ($0.id, $0) })

        var observedKnownHosts: [UUID: KnownHostsStore.TrustedRecordSnapshot] = [:]
        var conflictingKnownHostIDs = Set<UUID>()
        for persisted in persistedHosts {
            let host = Host(from: persisted)
            let route = host.jumpChain + [host]
            var routeEndpoints: [String] = []
            for routeHost in route {
                routeEndpoints.append("\(routeHost.address):\(routeHost.port)")
                if let snapshot = await knownHosts.trustedRecord(
                    for: sshHostKeyEndpoint(routeEndpoints: routeEndpoints)
                ) {
                    if let existing = observedKnownHosts[routeHost.id],
                       existing != snapshot {
                        conflictingKnownHostIDs.insert(routeHost.id)
                        observedKnownHosts.removeValue(forKey: routeHost.id)
                    } else if !conflictingKnownHostIDs.contains(routeHost.id) {
                        observedKnownHosts[routeHost.id] = snapshot
                    }
                }
            }
        }
        // A host reached through multiple routes should present one key. If
        // local records disagree, omit the peer hint instead of selecting an
        // arbitrary fingerprint and giving a compromised route extra weight.
        let fingerprints = observedKnownHosts.mapValues(\.fingerprint)

        var validIdentitiesByID: [UUID: BootstrapIdentityDescriptor] = [:]
        for identity in identities {
            let descriptor = BootstrapIdentityDescriptor(
                id: identity.id,
                name: identity.name,
                user: identity.user
            )
            do {
                try BootstrapManifest.validateIdentityDescriptor(descriptor)
                validIdentitiesByID[descriptor.id] = descriptor
            } catch {
                DiagnosticLogStore.appendApp(
                    "bootstrap export skipped identity=\(identity.id) error='\(error.localizedDescription)'"
                )
            }
        }

        var candidateHostsByID: [UUID: BootstrapHostDescriptor] = [:]
        for host in persistedHosts {
            guard (1...65_535).contains(host.port) else {
                DiagnosticLogStore.appendApp(
                    "bootstrap export skipped host=\(host.id) error='invalid port'"
                )
                continue
            }
            let credentialHint: BootstrapAuthenticationHint
            switch host.identity?.credentialMode {
            case .some(.password): credentialHint = .password
            case .some(.key), .some(.legacyDevKey):
                let route = HostJumpChainResolver.resolve(for: host, in: modelContext)
                let canAuthenticate = !route.isBroken
                    && (route.hops + [host]).allSatisfy { routeHost in
                        SessionRestoreEligibility.isRestorable(
                            host: routeHost,
                            storedKey: { storedKeysByID[$0] }
                        )
                    }
                credentialHint = canAuthenticate ? .publicKey : .none
            case .some(.none), nil: credentialHint = .none
            }
            let forwards = RuleCodec.decode(host.portForwardRulesData).map {
                BootstrapPortForwardRule(
                    id: $0.id,
                    enabled: $0.enabled,
                    autoStart: $0.autoStart,
                    localPort: $0.localPort,
                    remoteHost: $0.remoteHost,
                    remotePort: $0.remotePort,
                    label: $0.label
                )
            }
            let portableIdentityID: UUID?
            if let identityID = host.identity?.id,
               validIdentitiesByID[identityID] != nil {
                portableIdentityID = identityID
            } else {
                portableIdentityID = nil
            }
            let descriptor = BootstrapHostDescriptor(
                id: host.id,
                name: host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? host.address : host.name,
                address: host.address,
                port: UInt16(host.port),
                user: host.effectiveUser,
                transport: host.transport == .mosh ? .mosh : .ssh,
                launchMode: bootstrapLaunchMode(host.launchMode),
                tmuxSessionName: host.launchMode == .pinnedTmux
                    ? host.tmuxSessionName : nil,
                tags: host.tags,
                osHint: host.osHint,
                sortOrder: host.sortOrder,
                authenticationHint: portableIdentityID == nil ? .none : credentialHint,
                identityID: portableIdentityID,
                hostKeyFingerprint: fingerprints[host.id],
                launchCommand: host.launchCommand,
                notes: host.notes,
                envVars: host.envVars,
                startupSnippet: host.startupSnippet,
                portForwards: forwards
            )
            do {
                try BootstrapManifest.validateHostDescriptor(descriptor)
                candidateHostsByID[descriptor.id] = descriptor
            } catch {
                DiagnosticLogStore.appendApp(
                    "bootstrap export skipped host=\(host.id) error='\(error.localizedDescription)'"
                )
            }
        }

        var parentByHostID: [UUID: UUID] = [:]
        var hostsWithDuplicateLinks = Set<UUID>()
        for link in links {
            if parentByHostID.updateValue(link.jumpHostID, forKey: link.hostID) != nil {
                hostsWithDuplicateLinks.insert(link.hostID)
            }
        }
        func hasValidRoute(_ hostID: UUID) -> Bool {
            var current = hostID
            var seen = Set<UUID>()
            var depth = 0
            while let parent = parentByHostID[current] {
                guard !hostsWithDuplicateLinks.contains(current),
                      seen.insert(current).inserted,
                      candidateHostsByID[parent] != nil else { return false }
                depth += 1
                guard depth <= 8 else { return false }
                current = parent
            }
            return true
        }

        let acceptedHostIDs = Set(candidateHostsByID.keys.filter(hasValidRoute))
        for hostID in candidateHostsByID.keys where !acceptedHostIDs.contains(hostID) {
            DiagnosticLogStore.appendApp(
                "bootstrap export skipped host=\(hostID) error='invalid or incomplete jump route'"
            )
        }
        let hostDescriptors = acceptedHostIDs.compactMap { candidateHostsByID[$0] }.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sortOrder < $1.sortOrder
        }
        let jumpDescriptors = links.compactMap { link -> BootstrapJumpLink? in
            guard acceptedHostIDs.contains(link.hostID),
                  acceptedHostIDs.contains(link.jumpHostID),
                  !hostsWithDuplicateLinks.contains(link.hostID) else { return nil }
            return BootstrapJumpLink(hostID: link.hostID, jumpHostID: link.jumpHostID)
        }.sorted {
            if $0.hostID == $1.hostID {
                return $0.jumpHostID.uuidString < $1.jumpHostID.uuidString
            }
            return $0.hostID.uuidString < $1.hostID.uuidString
        }
        let referencedIdentityIDs = Set(hostDescriptors.compactMap(\.identityID))
        let identityDescriptors = referencedIdentityIDs.compactMap {
            validIdentitiesByID[$0]
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let knownHostDescriptors = acceptedHostIDs.compactMap { hostID in
            observedKnownHosts[hostID].map {
                BootstrapKnownHostDescriptor(
                    hostID: hostID,
                    fingerprint: $0.fingerprint,
                    keyString: $0.keyString,
                    firstSeen: $0.firstSeen,
                    lastSeen: $0.lastSeen
                )
            }
        }.sorted { $0.hostID.uuidString < $1.hostID.uuidString }

        let manifest = BootstrapManifest(
            identities: identityDescriptors,
            hosts: hostDescriptors,
            jumpChains: jumpDescriptors,
            knownHosts: knownHostDescriptors,
            appearance: BootstrapAppearanceSettings(
                colorScheme: appearance.mode.rawValue,
                accent: appearance.accent.rawValue,
                customAccentRGB: appearance.customAccentRGB,
                monospacedFontName: appearance.monoFontName,
                terminalFontSize: appearance.fontSize,
                chromeMaterial: appearance.chromeMaterial.rawValue,
                cursorStyle: appearance.cursorStyle.rawValue,
                cursorBlink: appearance.cursorBlink,
                terminalThemeID: appearance.terminalThemeID
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: appearance.scrollbackLines,
                modifierBehavior: appearance.modifierBehavior,
                bellSoundEnabled: appearance.bellSoundEnabled,
                bellVisualEnabled: appearance.bellVisualEnabled,
                bellNotificationEnabled: appearance.bellNotificationEnabled,
                accessoryBarKeys: appearance.accessoryBarKeys,
                filesReaperDays: appearance.filesReaperDays,
                filesDefaultDestination: appearance.filesDefaultDestination
            )
        )
        try manifest.validate()
        return manifest
    }

    /// Read-only preview of the batch `apply` would persist from this manifest
    /// right now. Shares the eligibility computation with `apply` — ID
    /// collisions, route eligibility, and durable retry provenance included —
    /// so the admission boundary can price the import before any SwiftData or
    /// UserDefaults mutation begins.
    @MainActor
    static func plannedInsertions(
        _ manifest: BootstrapManifest,
        to modelContext: ModelContext,
        provenance: BootstrapImportProvenanceStore = BootstrapImportProvenanceStore()
    ) throws -> BootstrapImportPlan {
        let eligibility = try importEligibility(
            for: manifest,
            in: modelContext,
            provenance: provenance
        )
        let routes = eligibility.acceptedDescriptors.map { descriptor in
            var closureHostIDs: Set<UUID> = [descriptor.id]
            var cursor = descriptor.id
            var visited = Set<UUID>()
            while let parent = eligibility.parentByHostID[cursor],
                  visited.insert(cursor).inserted,
                  eligibility.newlyAcceptedHostIDs.contains(parent) {
                closureHostIDs.insert(parent)
                cursor = parent
            }
            return BootstrapImportPlan.Route(
                id: descriptor.id,
                name: descriptor.name,
                address: descriptor.address,
                closureHostIDs: closureHostIDs
            )
        }
        return BootstrapImportPlan(
            newHostIDs: eligibility.newlyAcceptedHostIDs,
            routes: routes
        )
    }

    /// `restrictTo:` narrows the batch to an admission-approved union of whole
    /// jump closures (see `BootstrapImportPlan.Route.closureHostIDs`). Rows
    /// outside the set are set aside and reported as skipped; every other
    /// semantic — validation, provenance, trust hints, failure cleanup — is
    /// identical to a full import.
    @MainActor
    static func apply(
        _ manifest: BootstrapManifest,
        fromPeer peerDeviceName: String,
        to modelContext: ModelContext,
        appearance: AppearancePreferences,
        trustHints: BootstrapTrustHintStore = BootstrapTrustHintStore(),
        provenance: BootstrapImportProvenanceStore = BootstrapImportProvenanceStore(),
        knownHosts: KnownHostsStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() },
        restrictTo hostIDs: Set<UUID>? = nil,
        finalAdmissionValidator: BootstrapFinalAdmissionValidator? = nil
    ) async throws -> BootstrapImportReceipt {
        let eligibility = try importEligibility(
            for: manifest,
            in: modelContext,
            provenance: provenance
        )
        var acceptedDescriptors = eligibility.acceptedDescriptors
        if let hostIDs {
            // Admission must never strand a route: the selection is valid only
            // as whole jump closures. Verify defensively before any mutation
            // so a caller bug fails loudly instead of partially inserting.
            for descriptor in acceptedDescriptors where hostIDs.contains(descriptor.id) {
                var cursor = descriptor.id
                var visited = Set<UUID>()
                while let parent = eligibility.parentByHostID[cursor],
                      visited.insert(cursor).inserted {
                    guard hostIDs.contains(parent) else {
                        throw BootstrapImportRestrictionError.incompleteRoute(
                            hostID: descriptor.id,
                            missingAncestorID: parent
                        )
                    }
                    cursor = parent
                }
            }
            acceptedDescriptors = acceptedDescriptors.filter { hostIDs.contains($0.id) }
        }
        // Planning and the user-paced admission sheet necessarily suspend.
        // Revalidate the exact number this recomputed apply will insert on the
        // MainActor immediately before mutation; no manual/Handoff insertion
        // can interleave between this check and the save below.
        if let finalAdmissionValidator,
           !finalAdmissionValidator(acceptedDescriptors.count) {
            throw BootstrapImportAdmissionError.stateChanged
        }
        let newlyAcceptedHostIDs = Set(acceptedDescriptors.map(\.id))
        let requiredIdentityIDs = Set(acceptedDescriptors.compactMap(\.identityID))
        let existingIdentityIDs = eligibility.existingIdentityIDs
        var importedIdentityByDescriptorID: [UUID: Identity] = [:]
        var insertedIdentityCount = 0
        var insertedHostCount = 0
        let skippedHostCount = manifest.hosts.count - acceptedDescriptors.count
        var insertedLinkCount = 0
        var insertedIdentities: [Identity] = []
        var insertedHosts: [PersistedHost] = []
        var insertedLinks: [HostJumpLink] = []
        var pendingTrustHints: [(UUID, BootstrapTrustHint)] = []

        for descriptor in manifest.identities where requiredIdentityIDs.contains(descriptor.id) {
            // A peer identity UUID is portable grouping metadata, not authority
            // to bind imported endpoint data to an existing local credential.
            // Preserve the UUID only when it is unused locally; otherwise clone
            // a fresh credential-less identity for this import.
            let localID = existingIdentityIDs.contains(descriptor.id)
                ? UUID() : descriptor.id
            let identity = Identity(
                id: localID,
                name: descriptor.name,
                user: descriptor.user,
                credentialMode: .none
            )
            modelContext.insert(identity)
            insertedIdentities.append(identity)
            importedIdentityByDescriptorID[descriptor.id] = identity
            insertedIdentityCount += 1
        }

        for descriptor in acceptedDescriptors {
            let launchMode = hostLaunchMode(descriptor.launchMode)
            let host = PersistedHost(
                id: descriptor.id,
                name: descriptor.name,
                address: descriptor.address,
                port: Int(descriptor.port),
                autoTmux: launchMode != .customCommand,
                transport: descriptor.transport == .mosh ? .mosh : .ssh,
                launchMode: launchMode,
                tmuxSessionName: descriptor.tmuxSessionName,
                launchCommand: descriptor.launchCommand,
                sortOrder: descriptor.sortOrder,
                identity: descriptor.identityID.flatMap {
                    importedIdentityByDescriptorID[$0]
                }
            )
            host.user = descriptor.user
            host.tags = descriptor.tags
            host.osHint = descriptor.osHint
            host.notes = descriptor.notes ?? ""
            host.envVars = descriptor.envVars ?? ""
            host.startupSnippet = descriptor.startupSnippet ?? ""
            host.setPortForwardRules(descriptor.portForwards.map {
                PortForwardRule(
                    id: $0.id,
                    enabled: $0.enabled,
                    autoStart: $0.autoStart,
                    localPort: $0.localPort,
                    remoteHost: $0.remoteHost,
                    remotePort: $0.remotePort,
                    label: $0.label
                )
            })
            modelContext.insert(host)
            insertedHosts.append(host)
            insertedHostCount += 1
            if let fingerprint = descriptor.hostKeyFingerprint {
                pendingTrustHints.append((
                    host.id,
                    BootstrapTrustHint(
                        fingerprint: fingerprint,
                        peerDeviceName: peerDeviceName
                    )
                ))
            }
        }

        for link in manifest.jumpChains
        where newlyAcceptedHostIDs.contains(link.hostID)
            && newlyAcceptedHostIDs.contains(link.jumpHostID) {
            let inserted = HostJumpLink(
                hostID: link.hostID,
                jumpHostID: link.jumpHostID
            )
            modelContext.insert(inserted)
            insertedLinks.append(inserted)
            insertedLinkCount += 1
        }

        do {
            try save(modelContext)
        } catch {
            // Delete only records owned by this import attempt. A context-wide
            // rollback would also discard unrelated unsaved user work.
            for link in insertedLinks.reversed() { modelContext.delete(link) }
            for host in insertedHosts.reversed() { modelContext.delete(host) }
            for identity in insertedIdentities.reversed() { modelContext.delete(identity) }
            throw error
        }

        for (hostID, hint) in pendingTrustHints {
            trustHints.record(hint, for: hostID)
        }
        let acceptedHostIDs = newlyAcceptedHostIDs.union(eligibility.reusableAcceptedHostIDs)
        var insertedKnownHosts = 0
        var skippedKnownHosts = 0
        var conflictingKnownHosts = 0
        for descriptor in manifest.knownHosts ?? []
        where acceptedHostIDs.contains(descriptor.hostID) {
            let endpoint = try knownHostEndpoint(
                for: descriptor.hostID,
                in: manifest
            )
            let result = try await knownHosts.importTrustedRecord(
                KnownHostsStore.TrustedRecordSnapshot(
                    fingerprint: descriptor.fingerprint,
                    keyString: descriptor.keyString,
                    firstSeen: descriptor.firstSeen,
                    lastSeen: descriptor.lastSeen
                ),
                for: endpoint,
                fromPeer: peerDeviceName
            )
            switch result {
            case .inserted:
                insertedKnownHosts += 1
            case .unchanged:
                skippedKnownHosts += 1
            case .conflict:
                conflictingKnownHosts += 1
            }
        }
        apply(manifest.appearance, manifest.settings, to: appearance)
        let savedHostsByID = eligibility.existingHostsByID.merging(
            Dictionary(uniqueKeysWithValues: insertedHosts.map { ($0.id, $0) })
        ) { _, inserted in inserted }
        let acceptedLocalStates = Dictionary(uniqueKeysWithValues: acceptedHostIDs.compactMap {
            hostID in
            savedHostsByID[hostID].map { (hostID, localProvenanceState($0)) }
        })
        try provenance.record(localStates: acceptedLocalStates, for: manifest)
        return BootstrapImportReceipt(
            insertedHosts: insertedHostCount,
            skippedExistingHosts: skippedHostCount,
            insertedIdentities: insertedIdentityCount,
            insertedJumpLinks: insertedLinkCount,
            insertedKnownHosts: insertedKnownHosts,
            skippedKnownHosts: skippedKnownHosts,
            conflictingKnownHosts: conflictingKnownHosts,
            insertedHostIDs: newlyAcceptedHostIDs,
            acceptedHostIDs: acceptedHostIDs
        )
    }

    /// How this manifest meets the current local store: which host descriptors
    /// are newly insertable, and which prior-attempt rows an interrupted import
    /// may reuse without reinsertion. Pure reads only; shared by
    /// `plannedInsertions` and `apply` so the admission preview can never
    /// drift from the import itself.
    private struct ImportEligibility {
        let existingHostsByID: [UUID: PersistedHost]
        let existingIdentityIDs: Set<UUID>
        let parentByHostID: [UUID: UUID]
        let reusableAcceptedHostIDs: Set<UUID>
        let acceptedDescriptors: [BootstrapHostDescriptor]
        let newlyAcceptedHostIDs: Set<UUID>
    }

    private static func importEligibility(
        for manifest: BootstrapManifest,
        in modelContext: ModelContext,
        provenance: BootstrapImportProvenanceStore
    ) throws -> ImportEligibility {
        // Preflight both structure and the transport byte budget before any
        // SwiftData or UserDefaults mutation begins.
        _ = try manifest.encoded()
        let existingHosts = try modelContext.fetch(FetchDescriptor<PersistedHost>())
        let existingIdentities = try modelContext.fetch(FetchDescriptor<Identity>())
        let existingLinks = try modelContext.fetch(FetchDescriptor<HostJumpLink>())
        let existingHostIDs = Set(existingHosts.map(\.id))
        let existingHostsByID = Dictionary(uniqueKeysWithValues: existingHosts.map { ($0.id, $0) })
        let existingParentByHostID = Dictionary(
            uniqueKeysWithValues: existingLinks.map { ($0.hostID, $0.jumpHostID) }
        )
        let locallyReferencedHostIDs = Set(existingLinks.flatMap { [$0.hostID, $0.jumpHostID] })
        let unavailableHostIDs = existingHostIDs.union(locallyReferencedHostIDs)
        let candidateHostIDs = Set(
            manifest.hosts.map(\.id).filter { !unavailableHostIDs.contains($0) }
        )
        let parentByHostID = Dictionary(
            uniqueKeysWithValues: manifest.jumpChains.map { ($0.hostID, $0.jumpHostID) }
        )
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) }
        )

        let priorLocalStates = try provenance.localStates(for: manifest)
        let previouslyAccepted = Set(priorLocalStates.keys)
        func matchesImportedConfiguration(_ hostID: UUID) -> Bool {
            guard let local = existingHostsByID[hostID],
                  let descriptor = descriptorsByID[hostID],
                  priorLocalStates[hostID] == localProvenanceState(local),
                  local.address == descriptor.address,
                  local.port == Int(descriptor.port),
                  local.effectiveUser == descriptor.user,
                  local.transport == (descriptor.transport == .mosh ? .mosh : .ssh),
                  local.launchMode == hostLaunchMode(descriptor.launchMode),
                  local.tmuxSessionName == descriptor.tmuxSessionName,
                  existingParentByHostID[hostID] == parentByHostID[hostID]
            else { return false }
            return true
        }

        func priorRouteIsIntact(_ hostID: UUID) -> Bool {
            var cursor = hostID
            var visited = Set<UUID>()
            while true {
                guard visited.insert(cursor).inserted,
                      previouslyAccepted.contains(cursor),
                      matchesImportedConfiguration(cursor) else { return false }
                guard let parent = parentByHostID[cursor] else { return true }
                cursor = parent
            }
        }
        let reusableAcceptedHostIDs = Set(
            previouslyAccepted.filter(priorRouteIsIntact)
        )

        func routeIsEntirelyImportable(_ hostID: UUID) -> Bool {
            var cursor = hostID
            var visited = Set<UUID>()
            while let parent = parentByHostID[cursor] {
                guard visited.insert(cursor).inserted,
                      candidateHostIDs.contains(parent) else { return false }
                cursor = parent
            }
            return true
        }

        let acceptedDescriptors = manifest.hosts.filter {
            candidateHostIDs.contains($0.id) && routeIsEntirelyImportable($0.id)
        }
        return ImportEligibility(
            existingHostsByID: existingHostsByID,
            existingIdentityIDs: Set(existingIdentities.map(\.id)),
            parentByHostID: parentByHostID,
            reusableAcceptedHostIDs: reusableAcceptedHostIDs,
            acceptedDescriptors: acceptedDescriptors,
            newlyAcceptedHostIDs: Set(acceptedDescriptors.map(\.id))
        )
    }

    private static func knownHostEndpoint(
        for hostID: UUID,
        in manifest: BootstrapManifest
    ) throws -> String {
        let hostsByID = Dictionary(uniqueKeysWithValues: manifest.hosts.map {
            ($0.id, $0)
        })
        let parentByHostID = Dictionary(uniqueKeysWithValues: manifest.jumpChains.map {
            ($0.hostID, $0.jumpHostID)
        })
        var routeIDs = [hostID]
        var cursor = hostID
        while let parent = parentByHostID[cursor] {
            routeIDs.append(parent)
            cursor = parent
        }
        routeIDs.reverse()
        let endpoints = try routeIDs.map { routeID -> String in
            guard let host = hostsByID[routeID] else {
                throw BootstrapManifestError.invalidKnownHost(
                    hostID,
                    field: "hostID"
                )
            }
            return "\(host.address):\(host.port)"
        }
        return sshHostKeyEndpoint(routeEndpoints: endpoints)
    }

    private static func bootstrapLaunchMode(_ mode: HostLaunchMode) -> BootstrapHostLaunchMode {
        switch mode {
        case .autoTmux: return .autoTmux
        case .pinnedTmux: return .pinnedTmux
        case .customCommand: return .customCommand
        }
    }

    private static func hostLaunchMode(_ mode: BootstrapHostLaunchMode) -> HostLaunchMode {
        switch mode {
        case .autoTmux: return .autoTmux
        case .pinnedTmux: return .pinnedTmux
        case .customCommand: return .customCommand
        }
    }

    private static func apply(
        _ portableAppearance: BootstrapAppearanceSettings,
        _ settings: BootstrapGeneralSettings,
        to appearance: AppearancePreferences
    ) {
        if let mode = AppearanceModeOption(rawValue: portableAppearance.colorScheme) {
            appearance.mode = mode
        }
        if let accent = AccentName(rawValue: portableAppearance.accent) {
            appearance.accent = accent
        }
        appearance.customAccentRGB = portableAppearance.customAccentRGB
        appearance.monoFontName = portableAppearance.monospacedFontName
        appearance.fontSize = portableAppearance.terminalFontSize
        if let material = ChromeMaterial(rawValue: portableAppearance.chromeMaterial),
           material.isAvailable {
            appearance.chromeMaterial = material
        }
        if let cursor = CursorStyleOption(rawValue: portableAppearance.cursorStyle) {
            appearance.cursorStyle = cursor
        }
        appearance.cursorBlink = portableAppearance.cursorBlink
        appearance.terminalThemeID = portableAppearance.terminalThemeID
        appearance.scrollbackLines = settings.scrollbackLines
        appearance.modifierBehavior = settings.modifierBehavior
        appearance.bellSoundEnabled = settings.bellSoundEnabled
        appearance.bellVisualEnabled = settings.bellVisualEnabled
        appearance.bellNotificationEnabled = settings.bellNotificationEnabled
        appearance.accessoryBarKeys = settings.accessoryBarKeys
        appearance.filesReaperDays = settings.filesReaperDays
        appearance.filesDefaultDestination = settings.filesDefaultDestination
    }
}
