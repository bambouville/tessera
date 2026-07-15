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

    init(endpoint: String, prompt: HostKeyVerificationPrompt?) {
        self.endpoint = endpoint
        self.prompt = prompt
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
                    oldFingerprint: nil
                )
                let userAccepted = await HostKeyVerificationCoordinator.shared.resolve(
                    hostKey: hostKey,
                    endpoint: endpoint,
                    prompt: prompt,
                    challenge: challenge
                )
                if userAccepted {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=accepted status=unknown keyType=\(keyType)")
                    validationCompletePromise.succeed(())
                } else {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=rejected status=unknown keyType=\(keyType)")
                    validationCompletePromise.fail(HostKeyRejectedError())
                }

            case .changed(let oldFP, let newFP, _):
                DiagnosticLogStore.appendSSH("hostkey validation result=changed keyType=\(keyType) promptAvailable=\(prompt != nil)")
                let challenge = HostKeyVerificationChallenge(
                    endpoint: endpoint,
                    fingerprint: newFP,
                    keyType: keyType,
                    isChanged: true,
                    oldFingerprint: oldFP
                )
                let userAccepted = await HostKeyVerificationCoordinator.shared.resolve(
                    hostKey: hostKey,
                    endpoint: endpoint,
                    prompt: prompt,
                    challenge: challenge
                )
                if userAccepted {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=accepted status=changed keyType=\(keyType)")
                    validationCompletePromise.succeed(())
                } else {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=rejected status=changed keyType=\(keyType)")
                    validationCompletePromise.fail(HostKeyRejectedError())
                }
            }
        }
    }
}

actor HostKeyVerificationCoordinator {
    static let shared = HostKeyVerificationCoordinator()

    private struct ChallengeKey: Hashable {
        let endpoint: String
        let fingerprint: String
        let keyType: String
        let isChanged: Bool
        let oldFingerprint: String?

        init(_ challenge: HostKeyVerificationChallenge) {
            endpoint = challenge.endpoint
            fingerprint = challenge.fingerprint
            keyType = challenge.keyType
            isChanged = challenge.isChanged
            oldFingerprint = challenge.oldFingerprint
        }
    }

    private var waiters: [ChallengeKey: [CheckedContinuation<Bool, Never>]] = [:]

    func resolve(
        hostKey: NIOSSHPublicKey,
        endpoint: String,
        prompt: HostKeyVerificationPrompt?,
        challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let key = ChallengeKey(challenge)
        if waiters[key] != nil {
            DiagnosticLogStore.appendSSH(
                "hostkey validation coalesced duplicate endpoint=\(endpoint) keyType=\(challenge.keyType)"
            )
            return await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }

        waiters[key] = []
        let accepted = await resolveFirst(
            hostKey: hostKey,
            endpoint: endpoint,
            prompt: prompt,
            challenge: challenge
        )
        let pendingWaiters = waiters.removeValue(forKey: key) ?? []
        for continuation in pendingWaiters {
            continuation.resume(returning: accepted)
        }
        return accepted
    }

    private func resolveFirst(
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
                oldFingerprint: nil
            )
        case .changed(let oldFingerprint, let newFingerprint, _):
            refreshedChallenge = HostKeyVerificationChallenge(
                endpoint: endpoint,
                fingerprint: newFingerprint,
                keyType: challenge.keyType,
                isChanged: true,
                oldFingerprint: oldFingerprint
            )
        }

        guard let prompt else { return false }
        let accepted = await prompt(refreshedChallenge)
        if accepted {
            await KnownHostsStore.shared.trust(hostKey, for: endpoint)
        }
        return accepted
    }
}

struct HostKeyRejectedError: Error {}
