import Foundation
import SwiftData

/// Metadata for a stored SSH key. The actual private key bytes
/// live in iOS Keychain — this model stores only the public
/// information needed for UI display and `authorized_keys` export.
@Model
final class StoredKey {
    @Attribute(.unique) var id: UUID
    var name: String
    var algorithm: KeyAlgorithm
    /// The full `authorized_keys` line: "ssh-ed25519 AAAA... name"
    var authorizedKeysLine: String
    var createdAt: Date
    /// The user's requested per-key owner-presence policy. Tessera applies it
    /// before key use; the actual Keychain/Secure Enclave ACL is recorded
    /// separately and can still make key material unavailable.
    /// Literal default is load-bearing for SwiftData migration.
    var requiresBiometric: Bool = false
    /// True when the P-256 private key is backed by this device's
    /// Secure Enclave. Literal default required for SwiftData migration.
    var isSecureEnclave: Bool = false
    /// Retained only to preserve the shipped SwiftData schema. Agent
    /// forwarding is not implemented and no UI exposes this inert value.
    var agentForwarding: Bool = false

    init(
        id: UUID = UUID(),
        name: String = "",
        algorithm: KeyAlgorithm = .ed25519,
        authorizedKeysLine: String = "",
        createdAt: Date = Date(),
        requiresBiometric: Bool = false,
        agentForwarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.authorizedKeysLine = authorizedKeysLine
        self.createdAt = createdAt
        self.requiresBiometric = requiresBiometric
        self.agentForwarding = agentForwarding
    }
}

enum KeyAlgorithm: String, Codable, CaseIterable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case rsa = "ssh-rsa"

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .rsa: return "RSA"
        }
    }
}

enum KeyMaterialIntegrity: String, Codable, Equatable {
    /// The private bytes were read without UI and derive the expected public key.
    case valid
    /// No item exists for the metadata UUID.
    case missing
    /// The item is a valid key, but derives a different public fingerprint.
    case mismatched
    /// Keychain ACLs prevented a non-interactive read. This is expected for
    /// owner-presence protected keys and is not treated as corruption.
    case authenticationRequired
    /// Bytes exist but cannot be parsed as the declared algorithm.
    case invalid
    /// The legacy algorithm is deliberately ineligible for authentication.
    case unsupportedAlgorithm
    /// Keychain could not complete a non-interactive integrity check.
    case unavailable

    var permitsAuthenticationAttempt: Bool {
        self == .valid || self == .authenticationRequired
    }

    /// Session restore is allowed to hand a transient Keychain failure to the
    /// normal authentication path. That path performs the authoritative read
    /// (and owner-presence prompt) and still fails closed if the material is
    /// unavailable. Definite absence, corruption, or unsupported material must
    /// never produce a restore attempt.
    var permitsSessionRestoreAttempt: Bool {
        switch self {
        case .valid, .authenticationRequired, .unavailable:
            return true
        case .missing, .mismatched, .invalid, .unsupportedAlgorithm:
            return false
        }
    }
}

extension StoredKey {
    /// The one canonical OpenSSH SHA-256 representation used by recovery,
    /// integrity checks, session restore, and UI. OpenSSH omits Base64 padding.
    var canonicalFingerprint: String {
        KeyStore.canonicalFingerprint(forAuthorizedKeysLine: authorizedKeysLine)
    }
}

// MARK: - Non-secret lifecycle metadata

/// Recovery and remote-placement metadata deliberately lives outside SwiftData.
/// Adding a column to the current model graph triggers an iOS 26 lightweight-
/// migration failure because `PersistedHost` contains a `[String]` attribute.
/// The private material remains exclusively in Keychain; this record contains
/// only dates, public fingerprints, acknowledgements, and host labels.
struct KeySecurityRecord: Codable, Equatable {
    enum RemoteAccessDirection: String, Codable, Equatable {
        /// A pre-continuity or same-device install.
        case localInstallation
        /// This device held the authenticated session and granted a peer key.
        case grantedToPeer
        /// This device owns the key which a peer installed remotely.
        case receivedFromPeer
    }

    enum RemoteAccessFlow: String, Codable, Equatable {
        case manual
        case enrollment
        case bootstrap
    }

    /// `.uncertain` is written durably immediately before a remote
    /// authorized_keys mutation. Only command-level verification promotes an
    /// install to `.verified`; a crash, cancellation, or verification failure
    /// therefore cannot leave the ledger claiming access was proven.
    enum RemoteInstallationVerificationState: String, Codable, Equatable {
        case uncertain
        case verified
    }

    struct RemoteInstallation: Codable, Equatable, Identifiable {
        let hostID: UUID
        var hostLabel: String
        var endpoint: String
        /// Exact, secret-free route that was used when access was installed.
        /// Revocation must match this value before dialing: a host UUID can be
        /// repointed to a different server or jump chain after the grant.
        var routeIdentity: String?
        var installedAt: Date
        var peerDeviceName: String?
        var direction: RemoteAccessDirection
        var flow: RemoteAccessFlow
        var verificationState: RemoteInstallationVerificationState
        /// Public material retained so the granting side can revoke a peer key
        /// even though it never possesses that peer's private key.
        var publicKeyFingerprint: String?
        var authorizedKeysLine: String?

        var id: UUID { hostID }

        init(
            hostID: UUID,
            hostLabel: String,
            endpoint: String,
            routeIdentity: String? = nil,
            installedAt: Date,
            peerDeviceName: String? = nil,
            direction: RemoteAccessDirection = .localInstallation,
            flow: RemoteAccessFlow = .manual,
            verificationState: RemoteInstallationVerificationState = .verified,
            publicKeyFingerprint: String? = nil,
            authorizedKeysLine: String? = nil
        ) {
            self.hostID = hostID
            self.hostLabel = hostLabel
            self.endpoint = endpoint
            self.routeIdentity = routeIdentity
            self.installedAt = installedAt
            self.peerDeviceName = peerDeviceName
            self.direction = direction
            self.flow = flow
            self.verificationState = verificationState
            self.publicKeyFingerprint = publicKeyFingerprint
            self.authorizedKeysLine = authorizedKeysLine
        }

        private enum CodingKeys: String, CodingKey {
            case hostID, hostLabel, endpoint, routeIdentity, installedAt
            case peerDeviceName, direction, flow
            case verificationState
            case publicKeyFingerprint, authorizedKeysLine
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            hostID = try values.decode(UUID.self, forKey: .hostID)
            hostLabel = try values.decode(String.self, forKey: .hostLabel)
            endpoint = try values.decode(String.self, forKey: .endpoint)
            routeIdentity = try values.decodeIfPresent(
                String.self,
                forKey: .routeIdentity
            )
            installedAt = try values.decode(Date.self, forKey: .installedAt)
            peerDeviceName = try values.decodeIfPresent(String.self, forKey: .peerDeviceName)
            direction = try values.decodeIfPresent(
                RemoteAccessDirection.self,
                forKey: .direction
            ) ?? .localInstallation
            flow = try values.decodeIfPresent(RemoteAccessFlow.self, forKey: .flow)
                ?? .manual
            // Historical entries were created only after the remote verifier
            // returned its success marker, so their safe compatible meaning is
            // verified rather than uncertain.
            verificationState = try values.decodeIfPresent(
                RemoteInstallationVerificationState.self,
                forKey: .verificationState
            ) ?? .verified
            publicKeyFingerprint = try values.decodeIfPresent(
                String.self,
                forKey: .publicKeyFingerprint
            )
            authorizedKeysLine = try values.decodeIfPresent(
                String.self,
                forKey: .authorizedKeysLine
            )
        }
    }

    var backupExportedAt: Date?
    var backupFingerprint: String?
    var unrecoverableAcknowledgedAt: Date?
    var remoteInstallations: [RemoteInstallation]
    /// Records the protection established at the actual Keychain/Secure
    /// Enclave boundary. Optional so pre-remediation records decode safely and
    /// are treated as unknown rather than trusting a stale model toggle.
    var boundaryProtection: KeyBoundaryProtection?
    /// Last non-interactive integrity fact. Optional for records written by
    /// pre-remediation builds.
    var materialIntegrity: KeyMaterialIntegrity?
    /// Records that at least one tracked remote authorization was successfully
    /// removed, so a later local-only cleanup does not claim nothing was revoked.
    var lastRemoteRevocationAt: Date?

    static let empty = KeySecurityRecord(
        backupExportedAt: nil,
        backupFingerprint: nil,
        unrecoverableAcknowledgedAt: nil,
        remoteInstallations: [],
        boundaryProtection: nil,
        materialIntegrity: nil,
        lastRemoteRevocationAt: nil
    )
}

/// Stable, secret-free identity for the complete route that an SSH mutation
/// will traverse. Length-prefixing every field makes the representation
/// unambiguous even when a username/address contains punctuation. Credentials,
/// key handles, display names, and launch commands are intentionally absent.
enum RemoteAccessRouteIdentity {
    static func value(for host: Host) -> String {
        guard host.jumpChainBrokenReason == nil else {
            return encode(["v1", "broken", host.id.uuidString])
        }
        let route = host.jumpChain + [host]
        var fields = ["v1", "route", String(route.count)]
        for endpoint in route {
            fields.append(endpoint.id.uuidString)
            fields.append(endpoint.transport.rawValue)
            fields.append(endpoint.user)
            fields.append(endpoint.address)
            fields.append(String(endpoint.port))
        }
        return encode(fields)
    }

    private static func encode(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

enum KeyRecoveryState: Equatable {
    case notBackedUp
    case backupExported(date: Date, fingerprint: String)
    case deviceBoundUnrecoverable(acknowledged: Bool)
    case missingPrivateMaterial
    case mismatchedPrivateMaterial
    case invalidPrivateMaterial
    case privateMaterialUnavailable
    case legacyAlgorithmDisabled
}

struct KeySecurityMetadataStore {
    struct TrackedRemoteInstallation: Identifiable, Equatable {
        let keyID: UUID
        let installation: KeySecurityRecord.RemoteInstallation

        var id: String { "\(keyID.uuidString):\(installation.hostID.uuidString)" }
    }

    static let defaultKey = "tessera.keySecurityMetadata.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = Self.defaultKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func record(for keyID: UUID) -> KeySecurityRecord {
        records()[keyID] ?? .empty
    }

    func recoveryState(
        for key: StoredKey,
        integrity: KeyMaterialIntegrity
    ) -> KeyRecoveryState {
        switch integrity {
        case .missing:
            return .missingPrivateMaterial
        case .mismatched:
            return .mismatchedPrivateMaterial
        case .invalid:
            return .invalidPrivateMaterial
        case .unsupportedAlgorithm:
            return .legacyAlgorithmDisabled
        case .unavailable:
            return .privateMaterialUnavailable
        case .valid, .authenticationRequired:
            break
        }

        let record = record(for: key.id)
        if key.isSecureEnclave {
            return .deviceBoundUnrecoverable(
                acknowledged: record.unrecoverableAcknowledgedAt != nil
            )
        }
        if let date = record.backupExportedAt,
           let fingerprint = record.backupFingerprint {
            return .backupExported(date: date, fingerprint: fingerprint)
        }
        return .notBackedUp
    }

    func markBackupExported(
        for keyID: UUID,
        fingerprint: String,
        at date: Date = Date()
    ) {
        update(keyID) { record in
            record.backupExportedAt = date
            record.backupFingerprint = fingerprint
        }
    }

    func acknowledgeDeviceBoundRisk(for keyID: UUID, at date: Date = Date()) {
        update(keyID) { $0.unrecoverableAcknowledgedAt = date }
    }

    func markBoundaryProtection(
        _ protection: KeyBoundaryProtection,
        for keyID: UUID
    ) {
        update(keyID) { $0.boundaryProtection = protection }
    }

    func markMaterialIntegrity(
        _ integrity: KeyMaterialIntegrity,
        for keyID: UUID
    ) {
        update(keyID) { record in
            record.materialIntegrity = integrity
            // A record that says a recovery file was verified against private
            // material must not survive discovery that the live bytes are for
            // another/invalid/disabled key. Missing and temporarily locked
            // material keep the recovery fact because that file is the repair.
            if integrity == .mismatched
                || integrity == .invalid
                || integrity == .unsupportedAlgorithm {
                record.backupExportedAt = nil
                record.backupFingerprint = nil
            }
        }
    }

    func recordRemoteInstallation(
        keyID: UUID,
        hostID: UUID,
        hostLabel: String,
        endpoint: String,
        routeIdentity: String? = nil,
        peerDeviceName: String? = nil,
        direction: KeySecurityRecord.RemoteAccessDirection = .localInstallation,
        flow: KeySecurityRecord.RemoteAccessFlow = .manual,
        verificationState: KeySecurityRecord.RemoteInstallationVerificationState = .verified,
        publicKeyFingerprint: String? = nil,
        authorizedKeysLine: String? = nil,
        at date: Date = Date()
    ) {
        update(keyID) { record in
            record.remoteInstallations.removeAll { $0.hostID == hostID }
            record.remoteInstallations.append(.init(
                hostID: hostID,
                hostLabel: hostLabel,
                endpoint: endpoint,
                routeIdentity: routeIdentity,
                installedAt: date,
                peerDeviceName: peerDeviceName,
                direction: direction,
                flow: flow,
                verificationState: verificationState,
                publicKeyFingerprint: publicKeyFingerprint,
                authorizedKeysLine: authorizedKeysLine
            ))
            record.remoteInstallations.sort { $0.hostLabel < $1.hostLabel }
        }
    }

    /// Downgrades an existing placement without destroying its peer/public-key
    /// audit fields. If no placement exists yet, creates a public-only generic
    /// entry so an interrupted first mutation is still recoverable in the UI.
    func markRemoteInstallationUncertain(
        keyID: UUID,
        hostID: UUID,
        hostLabel: String,
        endpoint: String,
        routeIdentity: String? = nil,
        publicKeyFingerprint: String? = nil,
        authorizedKeysLine: String? = nil,
        at date: Date = Date()
    ) {
        markRemoteInstallationVerificationState(
            .uncertain,
            keyID: keyID,
            hostID: hostID,
            hostLabel: hostLabel,
            endpoint: endpoint,
            routeIdentity: routeIdentity,
            publicKeyFingerprint: publicKeyFingerprint,
            authorizedKeysLine: authorizedKeysLine,
            at: date
        )
    }

    func markRemoteInstallationVerificationState(
        _ state: KeySecurityRecord.RemoteInstallationVerificationState,
        keyID: UUID,
        hostID: UUID,
        hostLabel: String,
        endpoint: String,
        routeIdentity: String? = nil,
        publicKeyFingerprint: String? = nil,
        authorizedKeysLine: String? = nil,
        at date: Date = Date()
    ) {
        update(keyID) { record in
            if let index = record.remoteInstallations.firstIndex(where: {
                $0.hostID == hostID
            }) {
                record.remoteInstallations[index].verificationState = state
                if let routeIdentity {
                    record.remoteInstallations[index].routeIdentity = routeIdentity
                }
                return
            }
            record.remoteInstallations.append(.init(
                hostID: hostID,
                hostLabel: hostLabel,
                endpoint: endpoint,
                routeIdentity: routeIdentity,
                installedAt: date,
                verificationState: state,
                publicKeyFingerprint: publicKeyFingerprint,
                authorizedKeysLine: authorizedKeysLine
            ))
            record.remoteInstallations.sort { $0.hostLabel < $1.hostLabel }
        }
    }

    func allRemoteInstallations() -> [TrackedRemoteInstallation] {
        records().flatMap { keyID, record in
            record.remoteInstallations.map {
                TrackedRemoteInstallation(keyID: keyID, installation: $0)
            }
        }
        .sorted {
            if $0.installation.installedAt == $1.installation.installedAt {
                return $0.installation.hostLabel < $1.installation.hostLabel
            }
            return $0.installation.installedAt > $1.installation.installedAt
        }
    }

    /// A host UUID is editable and therefore is not enough to identify a
    /// remote authorization. Callers must refuse to replace an existing row
    /// whose route, public key, or direction describes a different placement.
    func hasConflictingRemoteInstallation(
        keyID: UUID,
        hostID: UUID,
        routeIdentity: String?,
        publicKeyFingerprint: String?,
        authorizedKeysLine: String,
        direction: KeySecurityRecord.RemoteAccessDirection
    ) -> Bool {
        record(for: keyID).remoteInstallations.contains {
            $0.hostID == hostID
                && ($0.routeIdentity != routeIdentity
                    || $0.publicKeyFingerprint != publicKeyFingerprint
                    || $0.authorizedKeysLine != authorizedKeysLine
                    || $0.direction != direction)
        }
    }

    func removeRemoteInstallation(
        keyID: UUID,
        hostID: UUID,
        at date: Date = Date()
    ) {
        update(keyID) { record in
            if record.remoteInstallations.contains(where: { $0.hostID == hostID }) {
                record.lastRemoteRevocationAt = date
            }
            record.remoteInstallations.removeAll { $0.hostID == hostID }
        }
    }

    /// Drops a pre-mutation uncertain intent after the protocol reports that
    /// no grant was installed. This is cleanup, not a remote revocation, so it
    /// deliberately leaves `lastRemoteRevocationAt` untouched.
    /// Removes only the still-uncertain row created for an exact protocol
    /// attempt. A delayed rejection must never erase a verified or replacement
    /// record written by a newer operation sharing the same host UUID.
    func discardRemoteInstallationIntent(
        keyID: UUID,
        hostID: UUID,
        routeIdentity: String,
        publicKeyFingerprint: String,
        authorizedKeysLine: String,
        direction: KeySecurityRecord.RemoteAccessDirection,
        flow: KeySecurityRecord.RemoteAccessFlow
    ) {
        update(keyID) { record in
            record.remoteInstallations.removeAll {
                $0.hostID == hostID
                    && $0.routeIdentity == routeIdentity
                    && $0.publicKeyFingerprint == publicKeyFingerprint
                    && $0.authorizedKeysLine == authorizedKeysLine
                    && $0.direction == direction
                    && $0.flow == flow
                    && $0.verificationState == .uncertain
            }
        }
    }

    func removeRecord(for keyID: UUID) {
        var all = records()
        all.removeValue(forKey: keyID)
        save(all)
    }

    private func update(_ keyID: UUID, mutate: (inout KeySecurityRecord) -> Void) {
        var all = records()
        var record = all[keyID] ?? .empty
        mutate(&record)
        all[keyID] = record
        save(all)
    }

    private func records() -> [UUID: KeySecurityRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                  [String: KeySecurityRecord].self,
                  from: data
              ) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save(_ records: [UUID: KeySecurityRecord]) {
        let encoded = Dictionary(uniqueKeysWithValues: records.map {
            ($0.key.uuidString, $0.value)
        })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum KeyBoundaryProtection: String, Codable, Equatable {
    case deviceUnlocked
    case userPresence
}

/// Keeps the user's requested setting separate from the protection that iOS is
/// currently enforcing at the Keychain boundary. They can temporarily differ
/// after installing an older build or restoring app metadata. An OFF preference
/// is an absolute no-prompt veto; a stale stronger ACL makes the key unavailable
/// until the user explicitly confirms the ACL rewrite from the Keys page.
enum KeyOwnerPresencePolicy {
    /// New keys inherit the user's explicit global key-use choice. The modal
    /// still exposes a per-key override before any material is created.
    static func initialKeyPreference(globalPreference: Bool) -> Bool {
        globalPreference
    }

    /// Enabling can require the same authorization during rollback: after the
    /// forward rewrite, the item itself is already presence-protected.
    static func requiresAuthorizationForProtectionChange(
        currentBoundary: KeyStore.KeyMaterialProtection?,
        enabling: Bool
    ) -> Bool {
        enabling || currentBoundary == .userPresence
    }

    static func isRequired(
        globalPreference: Bool,
        keyPreference: Bool,
        boundaryProtection: KeyBoundaryProtection?
    ) -> Bool {
        // Both user controls must permit owner authentication. Boundary truth
        // describes whether Security can release the bytes; it never grants
        // Tessera permission to present authentication when either control is
        // OFF.
        _ = boundaryProtection
        return globalPreference && keyPreference
    }

    /// Reads the real Keychain boundary first so stale non-secret metadata
    /// cannot manufacture an owner-auth prompt after protection was removed.
    /// If Security cannot answer, retain the recorded fail-safe boundary.
    static func currentBoundaryProtection(
        for key: StoredKey,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        keychain: KeychainClient = .live
    ) -> KeyBoundaryProtection? {
        do {
            switch try KeyStore.materialProtection(
                forKeyID: key.id,
                keychain: keychain
            ) {
            case .missing:
                return nil
            case .deviceUnlocked:
                return .deviceUnlocked
            case .userPresence:
                return .userPresence
            }
        } catch {
            return metadata.record(for: key.id).boundaryProtection
        }
    }

    static func isRequired(
        globalPreference: Bool,
        key: StoredKey?,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        keychain: KeychainClient = .live
    ) -> Bool {
        // Prompt permission is fully determined by user intent. Do not even
        // inspect Security here: this resolver runs for restore, Files, mosh,
        // tmux, and jump-host legs, and boundary state must never trigger UI.
        _ = metadata
        _ = keychain
        return isRequired(
            globalPreference: globalPreference,
            keyPreference: key?.requiresBiometric ?? false,
            boundaryProtection: nil
        )
    }

    static func reconciledKeyPreference(
        currentPreference: Bool,
        isSecureEnclave: Bool,
        boundaryProtection: KeyBoundaryProtection
    ) -> Bool {
        // Boundary truth never rewrites durable user intent. A device-unlocked
        // Secure Enclave key honors an ON preference through Tessera's app gate,
        // allowing the preference to change without rotating the SSH key.
        _ = isSecureEnclave
        _ = boundaryProtection
        return currentPreference
    }
}

// MARK: - Checked persistence boundaries and deletion journal

enum KeyLifecycleSaveBoundary: String, Equatable {
    case generation
    case keyImport
    case protection
    case deletion
    case deletionRecovery
    case integrityReconciliation
}

@MainActor
struct KeyLifecyclePersistence {
    let insertKey: (StoredKey) -> Void
    let deleteKey: (StoredKey) -> Void
    let fetchKeys: () throws -> [StoredKey]
    let fetchIdentities: () throws -> [Identity]
    let save: (KeyLifecycleSaveBoundary) throws -> Void
    let rollback: () -> Void

    static func live(_ context: ModelContext) -> Self {
        Self(
            insertKey: { context.insert($0) },
            deleteKey: { context.delete($0) },
            fetchKeys: { try context.fetch(FetchDescriptor<StoredKey>()) },
            fetchIdentities: { try context.fetch(FetchDescriptor<Identity>()) },
            save: { _ in try context.save() },
            rollback: { context.rollback() }
        )
    }
}

struct KeyDeletionIntent: Codable, Equatable {
    let keyID: UUID
    let createdAt: Date
}

struct KeyDeletionIntentStore {
    static let defaultKey = "tessera.keyDeletionIntents.v1"

    enum StoreError: LocalizedError {
        case encodingFailed
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Could not encode the non-secret key deletion journal."
            case .persistenceFailed:
                return "Could not persist the non-secret key deletion journal."
            }
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = Self.defaultKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func intents() -> [KeyDeletionIntent] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([KeyDeletionIntent].self, from: data)
        else { return [] }
        return decoded
    }

    func begin(keyID: UUID, at date: Date = Date()) throws {
        var values = intents().filter { $0.keyID != keyID }
        values.append(KeyDeletionIntent(keyID: keyID, createdAt: date))
        try save(values)
    }

    func clear(keyID: UUID) throws {
        try save(intents().filter { $0.keyID != keyID })
    }

    private func save(_ values: [KeyDeletionIntent]) throws {
        guard let data = try? JSONEncoder().encode(values) else {
            throw StoreError.encodingFailed
        }
        defaults.set(data, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == data, defaults.synchronize() else {
            throw StoreError.persistenceFailed
        }
    }
}

enum KeyLifecycleError: LocalizedError {
    case creationPersistenceFailed(primary: Error, cleanup: Error?)
    case protectionPersistenceFailed(primary: Error)
    case protectionRollbackFailed(
        primary: Error,
        compensation: Error,
        actual: KeyStore.KeyMaterialProtection?
    )
    case deletionPending(primary: Error)

    var errorDescription: String? {
        switch self {
        case .creationPersistenceFailed(let primary, nil):
            return "The key metadata could not be saved. Secure key material was removed. \(primary.localizedDescription)"
        case .creationPersistenceFailed(let primary, let cleanup?):
            return "The key metadata could not be saved (\(primary.localizedDescription)), and secure cleanup also failed (\(cleanup.localizedDescription)). No success was reported."
        case .protectionPersistenceFailed(let primary):
            return "The key metadata could not be saved, so the Keychain protection change was reversed. \(primary.localizedDescription)"
        case .protectionRollbackFailed(let primary, let compensation, let actual):
            let boundary: String
            switch actual {
            case .userPresence?:
                boundary = "The actual Keychain boundary currently requires biometrics (Face ID/Touch ID) or passcode."
            case .deviceUnlocked?:
                boundary = "The actual Keychain boundary currently uses device-unlocked protection."
            case .missing?:
                boundary = "The private material is now missing from Keychain."
            case nil:
                boundary = "The actual Keychain boundary could not be determined."
            }
            return "The metadata save failed (\(primary.localizedDescription)) and protection rollback failed (\(compensation.localizedDescription)). \(boundary)"
        case .deletionPending(let primary):
            return "Key metadata was removed, but secure private-material cleanup is pending and will retry at next launch. \(primary.localizedDescription)"
        }
    }
}

@MainActor
enum StoredKeyLifecycle {
    static func persistCreatedKey(
        _ key: StoredKey,
        boundary: KeyLifecycleSaveBoundary,
        persistence: KeyLifecyclePersistence,
        compensate: (UUID) throws -> Void = {
            _ = try KeyStore.compensateFailedCreation(forKeyID: $0)
        }
    ) throws {
        precondition(boundary == .generation || boundary == .keyImport)
        persistence.insertKey(key)
        do {
            try persistence.save(boundary)
        } catch {
            let primary = error
            persistence.rollback()
            do {
                try compensate(key.id)
                throw KeyLifecycleError.creationPersistenceFailed(
                    primary: primary,
                    cleanup: nil
                )
            } catch let lifecycleError as KeyLifecycleError {
                throw lifecycleError
            } catch {
                throw KeyLifecycleError.creationPersistenceFailed(
                    primary: primary,
                    cleanup: error
                )
            }
        }
    }

    static func updateProtection(
        for key: StoredKey,
        enabled: Bool,
        persistence: KeyLifecyclePersistence,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        applyBoundary: (KeyStore.KeyProtection) throws -> Void,
        inspectBoundary: () throws -> KeyStore.KeyMaterialProtection
    ) throws {
        let oldEnabled = key.requiresBiometric
        let requested: KeyStore.KeyProtection = enabled ? .userPresence : .deviceUnlocked
        let previous: KeyStore.KeyProtection
        switch try inspectBoundary() {
        case .userPresence:
            previous = .userPresence
        case .deviceUnlocked:
            previous = .deviceUnlocked
        case .missing:
            // `applyBoundary` will surface the missing material before any
            // metadata save. This fallback is therefore never used for
            // compensation, but keeps the transaction's requested state clear.
            previous = oldEnabled ? .userPresence : .deviceUnlocked
        }

        try applyBoundary(requested)
        // Publish the boundary established above before the SwiftData save can
        // notify the live SSH policy resolver. This keeps Files and secondary
        // transport legs from observing the new preference with the old ACL.
        metadata.markBoundaryProtection(
            enabled ? .userPresence : .deviceUnlocked,
            for: key.id
        )
        key.requiresBiometric = enabled
        do {
            try persistence.save(.protection)
        } catch {
            let primary = error
            persistence.rollback()
            key.requiresBiometric = oldEnabled
            do {
                try applyBoundary(previous)
                metadata.markBoundaryProtection(
                    previous == .userPresence ? .userPresence : .deviceUnlocked,
                    for: key.id
                )
            } catch {
                let compensation = error
                // `key.requiresBiometric` keeps the user's requested policy
                // (already restored above); only the metadata records which
                // ACL actually survived. OFF remains authoritative: callers
                // fail noninteractively rather than allowing the stale stronger
                // ACL to manufacture an authentication prompt.
                let actual = try? inspectBoundary()
                switch actual {
                case .userPresence?:
                    metadata.markBoundaryProtection(.userPresence, for: key.id)
                case .deviceUnlocked?:
                    metadata.markBoundaryProtection(.deviceUnlocked, for: key.id)
                case .missing?, nil:
                    break
                }
                throw KeyLifecycleError.protectionRollbackFailed(
                    primary: primary,
                    compensation: compensation,
                    actual: actual
                )
            }
            throw KeyLifecycleError.protectionPersistenceFailed(primary: primary)
        }
    }

    /// Updates only Tessera's key-use authorization policy. This is used for
    /// device-unlocked Secure Enclave keys whose hardware ACL cannot be edited
    /// after creation. The key remains non-exportable and hardware-bound.
    static func updateOwnerAuthenticationPreference(
        for key: StoredKey,
        enabled: Bool,
        persistence: KeyLifecyclePersistence
    ) throws {
        let oldEnabled = key.requiresBiometric
        key.requiresBiometric = enabled
        do {
            try persistence.save(.protection)
        } catch {
            let primary = error
            persistence.rollback()
            key.requiresBiometric = oldEnabled
            throw KeyLifecycleError.protectionPersistenceFailed(primary: primary)
        }
    }

    /// Forward-only deletion: the SwiftData row and every reference are removed
    /// in one atomic save before Keychain deletion. A durable, non-secret intent
    /// makes a crash or transient Keychain error resumable without guessing.
    static func delete(
        _ key: StoredKey,
        persistence: KeyLifecyclePersistence,
        journal: KeyDeletionIntentStore = KeyDeletionIntentStore(),
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        deleteMaterial: (UUID) throws -> Void = {
            _ = try KeyStore.deleteKey(forKeyID: $0)
        }
    ) throws {
        try journal.begin(keyID: key.id)
        do {
            let identities = try persistence.fetchIdentities()
            for identity in identities {
                if case .key(let keyID) = identity.credentialMode, keyID == key.id {
                    identity.credentialMode = .none
                }
            }
            persistence.deleteKey(key)
            try persistence.save(.deletion)
        } catch {
            let primary = error
            persistence.rollback()
            do {
                try journal.clear(keyID: key.id)
            } catch {
                throw KeyLifecycleError.deletionPending(primary: error)
            }
            throw primary
        }

        do {
            try deleteMaterial(key.id)
            metadata.removeRecord(for: key.id)
            try journal.clear(keyID: key.id)
        } catch {
            throw KeyLifecycleError.deletionPending(primary: error)
        }
    }

    struct ReconciliationReport: Equatable {
        var completed = 0
        var failed = 0
    }

    static func reconcilePendingDeletions(
        persistence: KeyLifecyclePersistence,
        journal: KeyDeletionIntentStore = KeyDeletionIntentStore(),
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        deleteMaterial: (UUID) throws -> Void = {
            _ = try KeyStore.deleteKey(forKeyID: $0)
        }
    ) -> ReconciliationReport {
        var report = ReconciliationReport()
        for intent in journal.intents() {
            do {
                if let key = try persistence.fetchKeys().first(where: {
                    $0.id == intent.keyID
                }) {
                    for identity in try persistence.fetchIdentities() {
                        if case .key(let keyID) = identity.credentialMode,
                           keyID == intent.keyID {
                            identity.credentialMode = .none
                        }
                    }
                    persistence.deleteKey(key)
                    try persistence.save(.deletionRecovery)
                }
                try deleteMaterial(intent.keyID)
                metadata.removeRecord(for: intent.keyID)
                try journal.clear(keyID: intent.keyID)
                report.completed += 1
            } catch {
                persistence.rollback()
                report.failed += 1
            }
        }
        return report
    }
}
