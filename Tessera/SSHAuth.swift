import Foundation
import Security
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// SSH-level auth resolution and host-key validation primitives,
/// lifted out of `SSHSession` so a future `MoshBootstrap` can reuse
/// the same credential resolution without owning a full SSH session.
///
/// Today only `SSHSession` calls `resolveSSHAuthMethod`; when the mosh
/// transport lands, its bootstrap step (which opens an SSH exec
/// channel to run `mosh-server new`) will resolve credentials the
/// same way.

enum AuthResolutionError: LocalizedError {
    case storedKeyNotFound(UUID)
    case storedKeyMetadataNotFound(UUID)
    case legacyDevKeyUnavailable
    case appLocked
    case hostNoLongerAvailable(UUID)
    case policyChanged
    case ownerAuthenticationDisabledForProtectedKey
    case biometricCancelled
    case biometricFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .storedKeyNotFound(let id):
            // The "edit host" action on the connection-failed overlay now
            // points the user at the identity picker, so the old trailing
            // "Edit the identity…" sentence is redundant.
            return "SSH key \(id.uuidString.prefix(8))… not found in Keychain."
        case .storedKeyMetadataNotFound(let id):
            return "SSH key \(id.uuidString.prefix(8))… has no trusted metadata. Restore or replace the key before connecting."
        case .legacyDevKeyUnavailable:
            return "This legacy development-key identity is unavailable. Replace it with a Keychain-backed key before connecting."
        case .appLocked:
            return "Unlock Tessera before starting a connection."
        case .hostNoLongerAvailable:
            return "This saved host no longer exists."
        case .policyChanged:
            return "The host or authentication policy changed while connecting. Try again."
        case .ownerAuthenticationDisabledForProtectedKey:
            return "This key is still protected by iOS while authentication is off. Open Keys and choose ‘finish turning protection off’ before using it."
        case .biometricCancelled:
            return "Device authentication was cancelled - connection wasn't started."
        case .biometricFailed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Device authentication failed - connection wasn't started."
            }
            return "Device authentication failed - \(trimmed)"
        }
    }
}

struct SSHConnectionPolicyDraft: Sendable {
    let host: Host
    let requireBiometric: Bool
    let isSecureEnclave: Bool
    let keyAlgorithm: KeyAlgorithm?
    /// The durable owner-presence decision after both global and per-key user
    /// controls have agreed to authentication. Keychain boundary state is not
    /// permission to prompt and is deliberately excluded.
    let ownerPresencePreference: Bool

    init(
        host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        keyAlgorithm: KeyAlgorithm? = nil,
        ownerPresencePreference: Bool? = nil
    ) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.keyAlgorithm = keyAlgorithm
        self.ownerPresencePreference = ownerPresencePreference ?? requireBiometric
    }
}

struct SSHConnectionPolicySnapshot: Sendable {
    let host: Host
    let requireBiometric: Bool
    let isSecureEnclave: Bool
    let keyAlgorithm: KeyAlgorithm?
    let ownerPresencePreference: Bool
    let generation: UInt64

    fileprivate let signature: SSHConnectionPolicySignature
}

struct ResolvedSSHConnection: @unchecked Sendable {
    let policy: SSHConnectionPolicySnapshot
    let authenticationMethod: SSHAuthenticationMethod
    /// Passed through to KeyStore so protected software-key reads and Secure
    /// Enclave reconstruction can reuse the evaluated OS authorization.
    let biometricAuthorization: BiometricAuthorization?
}

private struct SSHConnectionPolicySignature: Hashable, Sendable {
    enum Credential: Hashable, Sendable {
        case key(UUID, KeyAlgorithm?)
        case legacyDevKey(String)
        case password(HostPasswordCredentialRevision)
        case none
    }

    let hostID: UUID
    let endpoint: String
    let username: String
    let credential: Credential
    /// Hashes only the user-authorized policy. A stale Keychain ACL never
    /// changes the signature or grants permission to authenticate.
    let ownerPresencePreference: Bool
    let isSecureEnclave: Bool

    init(_ draft: SSHConnectionPolicyDraft) {
        hostID = draft.host.id
        // The endpoint folds in the jump chain (outermost first) so that
        // editing a host's bastion routing invalidates any in-flight
        // policy snapshot the same way changing its address would.
        endpoint = draft.host.sshConnectionRouteIdentity
        username = draft.host.user
        if let keyID = draft.host.storedKeyID {
            credential = .key(keyID, draft.keyAlgorithm)
        } else if let filename = draft.host.privateKeyFilename {
            credential = .legacyDevKey(filename)
        } else if !draft.host.password.isEmpty,
                  let revision = draft.host.passwordCredentialRevision {
            credential = .password(revision)
        } else {
            credential = .none
        }
        ownerPresencePreference = draft.ownerPresencePreference
        isSecureEnclave = draft.isSecureEnclave
    }
}

/// Main-actor policy authority shared by terminal, Mosh side channels, Files,
/// and key/shell installers. ContentView installs one live SwiftData resolver;
/// callers provide a fallback solely for unmanaged quick-connect hosts.
@MainActor
final class SSHAuthenticationPolicyStore {
    static let shared = SSHAuthenticationPolicyStore()

    typealias CurrentPolicyProvider = @MainActor (
        _ hostID: UUID,
        _ fallback: Host
    ) -> SSHConnectionPolicyDraft?

    private struct PolicyEntry {
        let signature: SSHConnectionPolicySignature
        let generation: UInt64
        /// Password-free fallback used only to re-read the current SwiftData
        /// policy when a save/defaults mutation notification arrives.
        let refreshFallback: Host
    }

    private var provider: CurrentPolicyProvider?
    private var persistedHostIDs: Set<UUID> = []
    private var policies: [UUID: PolicyEntry] = [:]
    private var nextGeneration: UInt64 = 0
    private var pendingAttempts: [UUID: () -> Void] = [:]
    private var observedGlobalKeyRequirement: Bool?
    private var observedPasswordCredentialRevision: UInt64?
    private(set) var isAppLocked = false

    func configureCurrentPolicyProvider(_ provider: @escaping CurrentPolicyProvider) {
        self.provider = provider
    }

    /// True once the app has installed the SwiftData-backed resolver.
    /// Chain establishment registers bastion hop IDs only when this is
    /// live: registering without a provider would flip `resolve` from
    /// "use the fallback draft" to "fail closed", breaking DTO-only
    /// callers (tests, previews) that never install a provider.
    var hasCurrentPolicyProvider: Bool {
        provider != nil
    }

    func registerPersistedHosts<S: Sequence>(_ ids: S) where S.Element == UUID {
        persistedHostIDs.formUnion(ids)
    }

    func registerPersistedHost(_ id: UUID) {
        persistedHostIDs.insert(id)
    }

    func resolve(_ fallback: SSHConnectionPolicyDraft) throws -> SSHConnectionPolicySnapshot {
        guard !isAppLocked else { throw AuthResolutionError.appLocked }

        let draft: SSHConnectionPolicyDraft
        if persistedHostIDs.contains(fallback.host.id) {
            guard let provider,
                  let current = provider(fallback.host.id, fallback.host) else {
                invalidatePolicy(for: fallback.host.id)
                throw AuthResolutionError.hostNoLongerAvailable(fallback.host.id)
            }
            draft = current
        } else {
            draft = fallback
        }

        let signature = SSHConnectionPolicySignature(draft)
        let generation: UInt64
        if let existing = policies[draft.host.id], existing.signature == signature {
            generation = existing.generation
        } else if policies[draft.host.id] != nil {
            generation = allocateGeneration()
            policies[draft.host.id] = PolicyEntry(
                signature: signature,
                generation: generation,
                refreshFallback: draft.host.policyRefreshFallback
            )
            // A credential/endpoint/global-policy change also invalidates an
            // evaluation already showing the system authentication sheet.
            BiometricSessionCache.shared.revokeAll()
        } else {
            generation = allocateGeneration()
            policies[draft.host.id] = PolicyEntry(
                signature: signature,
                generation: generation,
                refreshFallback: draft.host.policyRefreshFallback
            )
        }

        return SSHConnectionPolicySnapshot(
            host: draft.host,
            requireBiometric: draft.requireBiometric,
            isSecureEnclave: draft.isSecureEnclave,
            keyAlgorithm: draft.keyAlgorithm,
            ownerPresencePreference: draft.ownerPresencePreference,
            generation: generation,
            signature: signature
        )
    }

    func revalidate(_ snapshot: SSHConnectionPolicySnapshot) throws {
        let fallback = SSHConnectionPolicyDraft(
            host: snapshot.host,
            requireBiometric: snapshot.requireBiometric,
            isSecureEnclave: snapshot.isSecureEnclave,
            keyAlgorithm: snapshot.keyAlgorithm,
            ownerPresencePreference: snapshot.ownerPresencePreference
        )
        let current = try resolve(fallback)
        guard current.generation == snapshot.generation,
              current.signature == snapshot.signature else {
            throw AuthResolutionError.policyChanged
        }
    }

    /// Re-evaluates every active saved-host signature after SwiftData or
    /// security-defaults mutation. Comparing before invalidating avoids
    /// disrupting connections for unrelated model/defaults writes, while a
    /// saved A→B→A sequence is observed at B and cannot reuse A's grant.
    func refreshCurrentPolicies() {
        guard let provider else { return }

        var invalidated = false
        for (hostID, entry) in Array(policies) where persistedHostIDs.contains(hostID) {
            guard let current = provider(hostID, entry.refreshFallback),
                  SSHConnectionPolicySignature(current) == entry.signature else {
                policies.removeValue(forKey: hostID)
                invalidated = true
                continue
            }
        }

        guard invalidated else { return }
        _ = allocateGeneration()
        BiometricSessionCache.shared.revokeAll()
        cancelAndRemovePendingAttempts()
    }

    /// Notification pipelines capture each preference value before hopping to
    /// MainActor, so even an A→B→A toggle delivered in one run-loop turn
    /// invalidates grants. Only key policies are affected; unrelated defaults
    /// writes preserve the same-policy burst.
    func observeGlobalKeyRequirement(_ value: Bool) {
        defer { observedGlobalKeyRequirement = value }
        guard let previous = observedGlobalKeyRequirement,
              previous != value else { return }

        let keyHostIDs = policies.compactMap { hostID, entry in
            if case .key = entry.signature.credential { return hostID }
            return nil
        }
        guard !keyHostIDs.isEmpty else { return }
        for hostID in keyHostIDs {
            policies.removeValue(forKey: hostID)
        }
        _ = allocateGeneration()
        BiometricSessionCache.shared.revokeAll()
        cancelAndRemovePendingAttempts()
    }

    /// KeychainHelper supplies a non-secret, process-lifetime mutation
    /// revision after each password set/delete. This proactively cancels
    /// password handshakes; revalidation also embeds the revision, so a
    /// delayed notification cannot permit stale authentication.
    func observePasswordCredentialRevision(_ revision: UInt64) {
        guard let previous = observedPasswordCredentialRevision else {
            observedPasswordCredentialRevision = revision
            return
        }
        guard revision > previous else { return }
        observedPasswordCredentialRevision = revision

        let passwordHostIDs = policies.compactMap { hostID, entry in
            if case .password = entry.signature.credential { return hostID }
            return nil
        }
        guard !passwordHostIDs.isEmpty else { return }
        for hostID in passwordHostIDs {
            policies.removeValue(forKey: hostID)
        }
        _ = allocateGeneration()
        cancelAndRemovePendingAttempts()
    }

    func lock() {
        isAppLocked = true
        revokeKeyUseAuthorizations()
    }

    /// Revokes cached/evaluating owner-presence grants and cancels fresh SSH
    /// handshakes without presenting or enabling the app lock screen. Scene
    /// backgrounding uses this even when the user explicitly disabled app lock.
    func revokeKeyUseAuthorizations() {
        _ = allocateGeneration()
        policies.removeAll()
        BiometricSessionCache.shared.revokeAll()
        cancelAndRemovePendingAttempts()
    }

    func unlock() {
        isAppLocked = false
        _ = allocateGeneration()
        policies.removeAll()
        BiometricSessionCache.shared.revokeAll()
    }

    func setInitialLockState(_ locked: Bool) {
        isAppLocked = locked
        if locked {
            policies.removeAll()
            BiometricSessionCache.shared.revokeAll()
        }
    }

    #if DEBUG
    func resetForTesting(isLocked: Bool = false) {
        cancelAndRemovePendingAttempts()
        provider = nil
        persistedHostIDs.removeAll()
        policies.removeAll()
        nextGeneration = 0
        observedGlobalKeyRequirement = nil
        observedPasswordCredentialRevision = nil
        isAppLocked = isLocked
        BiometricSessionCache.shared.revokeAll()
    }
    #endif

    fileprivate func registerPendingAttempt(id: UUID, cancel: @escaping () -> Void) throws {
        guard !isAppLocked else {
            cancel()
            throw AuthResolutionError.appLocked
        }
        pendingAttempts[id] = cancel
    }

    /// Atomically linearizes completion against app lock and policy-driven
    /// cancellation. A removed registration means cancellation already won.
    fileprivate func finishPendingAttempt(id: UUID) throws {
        guard !isAppLocked else {
            pendingAttempts.removeValue(forKey: id)
            throw AuthResolutionError.appLocked
        }
        guard pendingAttempts.removeValue(forKey: id) != nil else {
            throw CancellationError()
        }
    }

    fileprivate func abandonPendingAttempt(id: UUID) {
        pendingAttempts.removeValue(forKey: id)
    }

    private func invalidatePolicy(for hostID: UUID) {
        guard policies.removeValue(forKey: hostID) != nil else { return }
        _ = allocateGeneration()
        BiometricSessionCache.shared.revokeAll()
    }

    private func allocateGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    private func cancelAndRemovePendingAttempts() {
        let cancellations = Array(pendingAttempts.values)
        pendingAttempts.removeAll()
        for cancel in cancellations { cancel() }
    }
}

/// App lock owns cancellation for the whole pre-connection operation, not only
/// LocalAuthentication. This prevents a password or already-resolved key from
/// finishing a handshake behind the lock screen.
func withPendingSSHConnectionAttempt<T: Sendable>(
    onRejectedValue: @escaping @Sendable (T) async -> Void = { value in
        await cleanupRejectedSSHAttemptValue(value)
    },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let id = UUID()
    let startGate = SSHConnectionAttemptStartGate()
    let task = Task<T, Error> {
        await startGate.wait()
        try Task.checkCancellation()
        let value = try await operation()
        do {
            // Cooperative APIs are allowed to return after cancellation. Do
            // not let such a value cross the pending-attempt boundary.
            try Task.checkCancellation()
            return value
        } catch {
            await onRejectedValue(value)
            throw error
        }
    }

    return try await withTaskCancellationHandler {
        do {
            try await SSHAuthenticationPolicyStore.shared.registerPendingAttempt(
                id: id,
                cancel: { task.cancel() }
            )
            await startGate.open()
        } catch {
            task.cancel()
            await startGate.open()
            throw error
        }

        do {
            let value = try await task.value
            do {
                // Caller cancellation and app-lock cancellation are distinct:
                // the former marks this task, while the latter atomically
                // removes the registration in the MainActor authority.
                try Task.checkCancellation()
                try await SSHAuthenticationPolicyStore.shared.finishPendingAttempt(id: id)
                try Task.checkCancellation()
                return value
            } catch {
                await SSHAuthenticationPolicyStore.shared.abandonPendingAttempt(id: id)
                await onRejectedValue(value)
                throw error
            }
        } catch {
            await SSHAuthenticationPolicyStore.shared.abandonPendingAttempt(id: id)
            throw error
        }
    } onCancel: {
        task.cancel()
    }
}

/// Production pending attempts return an SSHClient, an EstablishedSSHChain,
/// or a `(chain, Host)` pair (SSHSession). Close every shape — including the
/// chain's bastion clients — when a value completed concurrently with
/// cancellation but was rejected at handoff.
private func cleanupRejectedSSHAttemptValue<T: Sendable>(_ value: T) async {
    if let client = value as? SSHClient {
        try? await client.close()
    } else if let result = value as? (SSHClient, Host) {
        try? await result.0.close()
    } else if let chain = value as? EstablishedSSHChain {
        await chain.closeAll()
    } else if let result = value as? (EstablishedSSHChain, Host) {
        await result.0.closeAll()
    }
}

private actor SSHConnectionAttemptStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

/// Auth resolution priority:
///   1. StoredKey (Keychain) — from identity's .key(UUID) mode
///   2. DEBUG-only legacy dev key — raw 32-byte Ed25519 seed from Documents/
///   3. Password — from Keychain or transient entry
///
/// Fails closed: if a stored key is configured but can't be loaded,
/// throws instead of silently falling back to password.
func resolveSSHAuthMethod(
    for host: Host,
    requireBiometric: Bool,
    isSecureEnclave: Bool = false
) async throws -> SSHAuthenticationMethod {
    let resolved = try await resolveSSHConnection(
        for: host,
        requireBiometric: requireBiometric,
        isSecureEnclave: isSecureEnclave
    )
    // Compatibility for MoshBootstrap while it is being remediated for
    // transcript disclosure in parallel. Its caller pre-resolves the Host; if
    // the endpoint changes in the intervening await, fail closed instead of
    // returning a current credential to a stale address.
    guard resolved.policy.host.address == host.address,
          resolved.policy.host.port == host.port,
          resolved.policy.host.user == host.user else {
        throw AuthResolutionError.policyChanged
    }
    return resolved.authenticationMethod
}

func resolveSSHConnection(
    for host: Host,
    requireBiometric: Bool,
    isSecureEnclave: Bool = false
) async throws -> ResolvedSSHConnection {
    let policy = try await resolveSSHConnectionPolicy(
        for: host,
        requireBiometric: requireBiometric,
        isSecureEnclave: isSecureEnclave
    )
    try Task.checkCancellation()

    // 1. Keychain-stored SSH key (Phase 2 key management).
    if let keyID = policy.host.storedKeyID {
        guard let algorithm = policy.keyAlgorithm else {
            throw AuthResolutionError.storedKeyMetadataNotFound(keyID)
        }
        let biometricAuthorization: BiometricAuthorization?
        if policy.requireBiometric {
            biometricAuthorization = try await evaluateBiometricForKeyUse(policy: policy, keyID: keyID)
        } else {
            biometricAuthorization = nil
        }

        try Task.checkCancellation()
        try await SSHAuthenticationPolicyStore.shared.revalidate(policy)

        let method: SSHAuthenticationMethod?
        do {
            method = try await KeyStore.authMethod(
                forKeyID: keyID,
                algorithm: algorithm,
                username: policy.host.user,
                authorization: biometricAuthorization,
                isSecureEnclave: policy.isSecureEnclave
            )
        } catch let error as KeychainOperationError
            where biometricAuthorization == nil
                && error.operation == .copy
                && (error.status == errSecInteractionNotAllowed
                    || error.status == errSecAuthFailed) {
            // OFF is an absolute no-prompt veto. The noninteractive Keychain
            // read proved that an older ACL still protects the bytes; surface
            // the mismatch instead of asking LocalAuthentication or allowing a
            // raw Security sheet to appear.
            throw AuthResolutionError.ownerAuthenticationDisabledForProtectedKey
        }

        if let method {
            try Task.checkCancellation()
            try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
            return ResolvedSSHConnection(
                policy: policy,
                authenticationMethod: method,
                biometricAuthorization: biometricAuthorization
            )
        }
        // Key was configured but couldn't be loaded — fail closed.
        throw AuthResolutionError.storedKeyNotFound(keyID)
    }

    // 2. Legacy dev key files are never an authentication source in release.
    if let filename = policy.host.privateKeyFilename {
        #if DEBUG
        guard let rawKey = loadRawDevKey(filename: filename + ".raw"),
              rawKey.count == 32,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
            throw AuthResolutionError.legacyDevKeyUnavailable
        }
        try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
        return ResolvedSSHConnection(
            policy: policy,
            authenticationMethod: .ed25519(username: policy.host.user, privateKey: privateKey),
            biometricAuthorization: nil
        )
        #else
        // Release builds never read raw keys from Documents, and a configured
        // legacy identity must not silently fall through to another credential.
        throw AuthResolutionError.legacyDevKeyUnavailable
        #endif
    }

    // 3. Password.
    try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
    return ResolvedSSHConnection(
        policy: policy,
        authenticationMethod: .passwordBased(
            username: policy.host.user,
            password: policy.host.password
        ),
        biometricAuthorization: nil
    )
}

func resolveSSHConnectionPolicy(
    for host: Host,
    requireBiometric: Bool,
    isSecureEnclave: Bool = false
) async throws -> SSHConnectionPolicySnapshot {
    let fallback = SSHConnectionPolicyDraft(
        host: host,
        requireBiometric: requireBiometric,
        isSecureEnclave: isSecureEnclave,
        keyAlgorithm: nil
    )
    return try await SSHAuthenticationPolicyStore.shared.resolve(fallback)
}

func describeSSHError(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }

    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        return "\(nsError.localizedDescription) (\(nsError.code))"
    }
    return String(describing: error)
}


private func evaluateBiometricForKeyUse(
    policy: SSHConnectionPolicySnapshot,
    keyID: UUID
) async throws -> BiometricAuthorization {
    let result = await BiometricSessionCache.shared.evaluate(
        key: BiometricGrantKey(
            hostID: policy.host.id,
            endpoint: "\(policy.host.address):\(policy.host.port)",
            keyID: keyID,
            policyGeneration: policy.generation
        ),
        reason: "unlock SSH key for \(policy.host.user)"
    )

    switch result {
    case .authenticated(let authorization):
        return authorization
    case .userCancelled:
        throw AuthResolutionError.biometricCancelled
    case .unavailable(let reason), .failed(let reason):
        throw AuthResolutionError.biometricFailed(reason: reason)
    }
}

#if DEBUG
private func loadRawDevKey(filename: String) -> Data? {
    guard let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    ).first else { return nil }
    let url = docs.appendingPathComponent(filename)
    return try? Data(contentsOf: url)
}
#endif

// MARK: - Host key TOFU validator

struct HostKeyVerificationChallenge: Sendable {
    let endpoint: String
    let fingerprint: String
    let keyType: String
    let isChanged: Bool
    let oldFingerprint: String?
    let peerFingerprint: String?
    let peerLabel: String?

    init(
        endpoint: String,
        fingerprint: String,
        keyType: String,
        isChanged: Bool,
        oldFingerprint: String?,
        peerFingerprint: String? = nil,
        peerLabel: String? = nil
    ) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.keyType = keyType
        self.isChanged = isChanged
        self.oldFingerprint = oldFingerprint
        self.peerFingerprint = peerFingerprint
        self.peerLabel = peerLabel
    }

    var peerFingerprintMatches: Bool? {
        peerFingerprint.map { $0 == fingerprint }
    }
}

typealias HostKeyVerificationPrompt = @MainActor @Sendable (HostKeyVerificationChallenge) async -> Bool

/// Bridges Citadel/NIO SSH's promise-based host key validation to
/// Tessera's async TOFU store + SwiftUI verification sheet.
///
/// Called on the NIO event loop during SSH handshake. Must complete
/// the promise exactly once. For unknown/changed keys, dispatches
/// to @MainActor to post a `HostKeyVerificationRequest` on the
/// session, then suspends via `CheckedContinuation` until the UI
/// responds.
///
final class TesseraHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let prompt: HostKeyVerificationPrompt?
    let peerFingerprint: String?
    let peerLabel: String?

    init(
        endpoint: String,
        prompt: HostKeyVerificationPrompt?,
        peerFingerprint: String? = nil,
        peerLabel: String? = nil
    ) {
        self.endpoint = endpoint
        self.prompt = prompt
        self.peerFingerprint = peerFingerprint
        self.peerLabel = peerLabel
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let endpoint = self.endpoint
        let prompt = self.prompt

        Task {
            let result = await KnownHostsStore.shared.check(hostKey, for: endpoint)
            let keyType = String(
                String(openSSHPublicKey: hostKey).prefix(while: { $0 != " " })
            )

            switch result {
            case .trusted:
                DiagnosticLogStore.appendSSH("hostkey validation result=trusted keyType=\(keyType)")
                await KnownHostsStore.shared.touch(for: endpoint)
                validationCompletePromise.succeed(())

            case .unknown(let fingerprint, _):
                DiagnosticLogStore.appendSSH("hostkey validation result=unknown keyType=\(keyType) promptAvailable=\(prompt != nil)")
                let challenge = HostKeyVerificationChallenge(
                    endpoint: endpoint,
                    fingerprint: fingerprint,
                    keyType: keyType,
                    isChanged: false,
                    oldFingerprint: nil,
                    peerFingerprint: peerFingerprint,
                    peerLabel: peerLabel
                )
                // Citadel starts a fixed ten-second login timer before asking
                // its host-key delegate. Human approval must not run inside
                // that timer. Abort this transport attempt immediately; the
                // shared chain layer awaits approval and retries from hop zero.
                validationCompletePromise.fail(HostKeyApprovalRequired(
                    hostKey: hostKey,
                    endpoint: endpoint,
                    prompt: prompt,
                    challenge: challenge
                ))

            case .changed(let oldFP, let newFP, _):
                DiagnosticLogStore.appendSSH("hostkey validation result=changed keyType=\(keyType) promptAvailable=\(prompt != nil)")
                let challenge = HostKeyVerificationChallenge(
                    endpoint: endpoint,
                    fingerprint: newFP,
                    keyType: keyType,
                    isChanged: true,
                    oldFingerprint: oldFP,
                    peerFingerprint: peerFingerprint,
                    peerLabel: peerLabel
                )
                validationCompletePromise.fail(HostKeyApprovalRequired(
                    hostKey: hostKey,
                    endpoint: endpoint,
                    prompt: prompt,
                    challenge: challenge
                ))
            }
        }
    }
}

/// Typed handoff from NIO's timed SSH handshake to Tessera's untimed human
/// approval flow. It contains immutable challenge data only; no unstructured
/// task survives the failed transport attempt.
final class HostKeyApprovalRequired: Error, @unchecked Sendable {
    let hostKey: NIOSSHPublicKey
    let endpoint: String
    let prompt: HostKeyVerificationPrompt?
    let challenge: HostKeyVerificationChallenge

    init(
        hostKey: NIOSSHPublicKey,
        endpoint: String,
        prompt: HostKeyVerificationPrompt?,
        challenge: HostKeyVerificationChallenge
    ) {
        self.hostKey = hostKey
        self.endpoint = endpoint
        self.prompt = prompt
        self.challenge = challenge
    }
}

actor HostKeyVerificationCoordinator {
    static let shared = HostKeyVerificationCoordinator()

    /// Cancellation handlers cannot synchronously hop back to this actor.
    /// Keep a lock-backed bit beside each waiter so `Task.cancel()` becomes
    /// visible to the trust path before the asynchronous actor cleanup runs.
    private final class WaiterCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    private struct PendingWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let cancellation: WaiterCancellation
    }

    private struct ChallengeKey: Hashable {
        let endpoint: String
        let fingerprint: String
        let keyType: String
        let isChanged: Bool
        let oldFingerprint: String?
        let peerFingerprint: String?
        let peerLabel: String?

        init(_ challenge: HostKeyVerificationChallenge) {
            endpoint = challenge.endpoint
            fingerprint = challenge.fingerprint
            keyType = challenge.keyType
            isChanged = challenge.isChanged
            oldFingerprint = challenge.oldFingerprint
            peerFingerprint = challenge.peerFingerprint
            peerLabel = challenge.peerLabel
        }
    }

    private struct PendingDecision {
        let hostKey: NIOSSHPublicKey
        let endpoint: String
        let challenge: HostKeyVerificationChallenge
        var prompt: HostKeyVerificationPrompt?
        var waiters: [UUID: PendingWaiter]
        var promptlessTimeout: Task<Void, Never>?
        var resolutionTask: Task<Void, Never>?
        var resolutionStarted: Bool
    }

    private let promptUpgradeGrace: @Sendable () async -> Void
    private var pendingDecisions: [ChallengeKey: PendingDecision] = [:]

    init(
        promptUpgradeGrace: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    ) {
        self.promptUpgradeGrace = promptUpgradeGrace
    }

    func resolve(
        hostKey: NIOSSHPublicKey,
        endpoint: String,
        prompt: HostKeyVerificationPrompt?,
        challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let key = ChallengeKey(challenge)
        let waiterID = UUID()
        let cancellation = WaiterCancellation()
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if var pending = pendingDecisions[key] {
                    DiagnosticLogStore.appendSSH(
                        "hostkey validation coalesced duplicate endpoint=\(endpoint) keyType=\(challenge.keyType)"
                    )
                    pending.waiters[waiterID] = PendingWaiter(
                        continuation: continuation,
                        cancellation: cancellation
                    )

                    // A promptless side channel can wait for, but never supply,
                    // an authorization decision. Upgrade the shared decision
                    // as soon as an equivalent user-facing request arrives.
                    if pending.prompt == nil, let prompt {
                        pending.prompt = prompt
                        pending.promptlessTimeout?.cancel()
                        pending.promptlessTimeout = nil
                        pending.resolutionStarted = true
                        pendingDecisions[key] = pending
                        startResolution(for: key, pending: pending, prompt: prompt)
                    } else {
                        pendingDecisions[key] = pending
                    }
                    return
                }

                var pending = PendingDecision(
                    hostKey: hostKey,
                    endpoint: endpoint,
                    challenge: challenge,
                    prompt: prompt,
                    waiters: [
                        waiterID: PendingWaiter(
                            continuation: continuation,
                            cancellation: cancellation
                        )
                    ],
                    promptlessTimeout: nil,
                    resolutionTask: nil,
                    resolutionStarted: prompt != nil
                )

                if let prompt {
                    pendingDecisions[key] = pending
                    startResolution(for: key, pending: pending, prompt: prompt)
                } else {
                    let timeout = Task { [promptUpgradeGrace] in
                        await promptUpgradeGrace()
                        guard !Task.isCancelled else { return }
                        await self.expirePromptlessDecision(for: key)
                    }
                    pending.promptlessTimeout = timeout
                    pendingDecisions[key] = pending
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                await self.cancelWaiter(waiterID, for: key)
            }
        }
    }

    private func startResolution(
        for key: ChallengeKey,
        pending: PendingDecision,
        prompt: @escaping HostKeyVerificationPrompt
    ) {
        let task = Task {
            let accepted = await resolveFirst(
                for: key,
                hostKey: pending.hostKey,
                endpoint: pending.endpoint,
                prompt: prompt,
                challenge: pending.challenge
            )
            finishDecision(for: key, accepted: accepted)
        }
        guard var current = pendingDecisions[key] else {
            task.cancel()
            return
        }
        current.resolutionTask = task
        pendingDecisions[key] = current
    }

    private func cancelWaiter(_ waiterID: UUID, for key: ChallengeKey) {
        guard var pending = pendingDecisions[key],
              let waiter = pending.waiters.removeValue(forKey: waiterID)
        else { return }
        waiter.continuation.resume(returning: false)
        guard pending.waiters.isEmpty else {
            pendingDecisions[key] = pending
            return
        }
        pending.promptlessTimeout?.cancel()
        pending.resolutionTask?.cancel()
        pendingDecisions.removeValue(forKey: key)
    }

    private func expirePromptlessDecision(for key: ChallengeKey) async {
        guard let pending = pendingDecisions[key],
              pending.prompt == nil,
              !pending.resolutionStarted else { return }

        // The validator may have observed this key as unknown before another
        // equivalent, prompted handshake trusted it. Re-check at the end of
        // the bounded grace instead of rejecting that stale observation.
        let isNowTrusted: Bool
        switch await KnownHostsStore.shared.check(pending.hostKey, for: pending.endpoint) {
        case .trusted:
            isNowTrusted = true
        case .unknown, .changed:
            isNowTrusted = false
        }

        // The store lookup is an actor hop. If a prompted duplicate arrived
        // while it was in flight, that explicit decision owns completion.
        guard let current = pendingDecisions[key],
              current.prompt == nil,
              !current.resolutionStarted else { return }

        if isNowTrusted {
            await KnownHostsStore.shared.touch(for: current.endpoint)
            guard let latest = pendingDecisions[key],
                  latest.prompt == nil,
                  !latest.resolutionStarted else { return }
            DiagnosticLogStore.appendSSH(
                "hostkey validation promptless staleChallengeNowTrusted endpoint=\(latest.endpoint) keyType=\(latest.challenge.keyType)"
            )
            finishDecision(for: key, accepted: true)
            return
        }

        DiagnosticLogStore.appendSSH(
            "hostkey validation promptless grace expired endpoint=\(current.endpoint) keyType=\(current.challenge.keyType)"
        )
        finishDecision(for: key, accepted: false)
    }

    private func finishDecision(for key: ChallengeKey, accepted: Bool) {
        guard let pending = pendingDecisions.removeValue(forKey: key) else { return }
        pending.promptlessTimeout?.cancel()
        for waiter in pending.waiters.values {
            waiter.continuation.resume(
                returning: accepted && !waiter.cancellation.isCancelled
            )
        }
    }

    #if DEBUG
    func pendingWaiterCount(for challenge: HostKeyVerificationChallenge) -> Int {
        pendingDecisions[ChallengeKey(challenge)]?.waiters.values.filter {
            !$0.cancellation.isCancelled
        }.count ?? 0
    }
    #endif

    private func resolveFirst(
        for key: ChallengeKey,
        hostKey: NIOSSHPublicKey,
        endpoint: String,
        prompt: HostKeyVerificationPrompt?,
        challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let refreshedChallenge: HostKeyVerificationChallenge
        switch await KnownHostsStore.shared.check(hostKey, for: endpoint) {
        case .trusted:
            DiagnosticLogStore.appendSSH(
                "hostkey validation coalesced alreadyTrusted keyType=\(challenge.keyType)"
            )
            await KnownHostsStore.shared.touch(for: endpoint)
            return true
        case .unknown(let fingerprint, _):
            refreshedChallenge = HostKeyVerificationChallenge(
                endpoint: endpoint,
                fingerprint: fingerprint,
                keyType: challenge.keyType,
                isChanged: false,
                oldFingerprint: nil,
                peerFingerprint: challenge.peerFingerprint,
                peerLabel: challenge.peerLabel
            )
        case .changed(let oldFingerprint, let newFingerprint, _):
            refreshedChallenge = HostKeyVerificationChallenge(
                endpoint: endpoint,
                fingerprint: newFingerprint,
                keyType: challenge.keyType,
                isChanged: true,
                oldFingerprint: oldFingerprint,
                peerFingerprint: challenge.peerFingerprint,
                peerLabel: challenge.peerLabel
            )
        }

        guard let prompt else { return false }
        let accepted = await prompt(refreshedChallenge)
        guard accepted,
              !Task.isCancelled,
              let pending = pendingDecisions[key],
              pending.waiters.values.contains(where: {
                  !$0.cancellation.isCancelled
              }) else { return false }
        if accepted {
            let matchedPeerLabel = refreshedChallenge.peerFingerprintMatches == true
                ? refreshedChallenge.peerLabel
                : nil
            await KnownHostsStore.shared.trust(
                hostKey,
                for: endpoint,
                matchedPeerLabel: matchedPeerLabel
            )
        }
        return accepted
    }
}

struct HostKeyRejectedError: LocalizedError {
    var errorDescription: String? {
        "Connection cancelled because the server's host key was not trusted."
    }
}
