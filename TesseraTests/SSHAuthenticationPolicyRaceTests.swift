import Foundation
import Security
import Testing
@testable import Tessera

@Suite("Fresh SSH authentication policy", .serialized)
struct SSHAuthenticationPolicyRaceTests {
    @Test("endpoint and key rotation invalidates an in-progress snapshot")
    @MainActor
    func staleSnapshotIsRejected() throws {
        let hostID = UUID()
        let keyA = UUID()
        let keyB = UUID()
        let fallback = Host(
            id: hostID,
            address: "old.example",
            user: "alice",
            storedKeyID: keyA
        )
        let box = CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
            host: fallback,
            requireBiometric: true,
            isSecureEnclave: false
        ))
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.registerPersistedHost(hostID)
        store.configureCurrentPolicyProvider { _, _ in box.draft }

        let first = try store.resolve(box.draft)

        var rotatedHost = fallback
        rotatedHost.address = "new.example"
        rotatedHost.storedKeyID = keyB
        box.draft = SSHConnectionPolicyDraft(
            host: rotatedHost,
            requireBiometric: true,
            isSecureEnclave: false
        )

        #expect(throws: AuthResolutionError.self) {
            try store.revalidate(first)
        }
        let second = try store.resolve(box.draft)
        #expect(second.host.address == "new.example")
        #expect(second.host.storedKeyID == keyB)
        #expect(second.generation > first.generation)
        store.resetForTesting()
    }

    @Test("same-endpoint jump-host swap invalidates an in-progress snapshot")
    @MainActor
    func sameEndpointJumpIdentityChangeIsRejected() throws {
        let hostID = UUID()
        let firstBastion = Host(
            address: "bastion.example",
            user: "jump"
        )
        let secondBastion = Host(
            address: "bastion.example",
            user: "jump"
        )
        var destination = Host(
            id: hostID,
            address: "10.0.0.5",
            user: "alice"
        )
        destination.jumpChain = [firstBastion]
        let box = CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
            host: destination,
            requireBiometric: false,
            isSecureEnclave: false
        ))
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.registerPersistedHost(hostID)
        store.configureCurrentPolicyProvider { _, _ in box.draft }

        let original = try store.resolve(box.draft)
        destination.jumpChain = [secondBastion]
        box.draft = SSHConnectionPolicyDraft(
            host: destination,
            requireBiometric: false,
            isSecureEnclave: false
        )

        #expect(throws: AuthResolutionError.self) {
            try store.revalidate(original)
        }
        store.resetForTesting()
    }

    @Test("app lock cancels and rejects a pending connection attempt")
    func appLockCancelsPendingAttempt() async {
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
        let started = AsyncLatch()
        let attempt = Task {
            try await withPendingSSHConnectionAttempt {
                await started.signal()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.lock()
        }

        await #expect(throws: CancellationError.self) {
            try await attempt.value
        }
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("an operation that returns after app-lock cancellation cannot hand off its value")
    func appLockRejectsCancellationIgnoringCompletion() async {
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
        let rejected = RejectedValueRecorder<Int>()

        do {
            _ = try await withPendingSSHConnectionAttempt(
                onRejectedValue: { value in await rejected.record(value) }
            ) {
                await MainActor.run {
                    SSHAuthenticationPolicyStore.shared.lock()
                }
                // Deliberately return despite the cancellation issued by lock.
                return 41
            }
            Issue.record("a value escaped after app lock cancelled the attempt")
        } catch is CancellationError {
            // Expected: the child post-operation gate observed cancellation.
        } catch is AuthResolutionError {
            // Also acceptable if the atomic MainActor handoff observes lock.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await rejected.values == [41])
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("caller cancellation rejects and cleans a late successful value")
    func callerCancellationRejectsLateValue() async {
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
        let gate = IgnoringCancellationValueGate<Int>()
        let rejected = RejectedValueRecorder<Int>()
        let attempt = Task {
            try await withPendingSSHConnectionAttempt(
                onRejectedValue: { value in await rejected.record(value) }
            ) {
                await gate.waitForValue()
            }
        }
        await gate.waitUntilStarted()
        attempt.cancel()
        await gate.complete(with: 73)

        do {
            _ = try await attempt.value
            Issue.record("a caller-cancelled attempt returned its late value")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await rejected.values == [73])
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("an observed A-B-A mutation cannot reuse A's generation")
    @MainActor
    func observedABAMutationGetsFreshGeneration() throws {
        let hostID = UUID()
        let keyA = UUID()
        let keyB = UUID()
        let hostA = Host(
            id: hostID,
            address: "a.example",
            user: "alice",
            storedKeyID: keyA
        )
        let box = CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
            host: hostA,
            requireBiometric: true,
            isSecureEnclave: false,
            keyAlgorithm: .ed25519
        ))
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.registerPersistedHost(hostID)
        store.configureCurrentPolicyProvider { _, _ in box.draft }

        let original = try store.resolve(box.draft)
        var hostB = hostA
        hostB.storedKeyID = keyB
        box.draft = SSHConnectionPolicyDraft(
            host: hostB,
            requireBiometric: true,
            isSecureEnclave: false,
            keyAlgorithm: .ed25519
        )
        store.refreshCurrentPolicies()

        box.draft = SSHConnectionPolicyDraft(
            host: hostA,
            requireBiometric: true,
            isSecureEnclave: false,
            keyAlgorithm: .ed25519
        )
        store.refreshCurrentPolicies()
        let returned = try store.resolve(box.draft)

        #expect(returned.generation > original.generation)
        store.resetForTesting()
    }

    @Test("global owner-auth A-B-A invalidates a key grant generation")
    @MainActor
    func globalRequirementABAGetsFreshGeneration() throws {
        let host = Host(
            address: "global.example",
            user: "alice",
            storedKeyID: UUID()
        )
        let draft = SSHConnectionPolicyDraft(
            host: host,
            requireBiometric: false,
            isSecureEnclave: false,
            keyAlgorithm: .ed25519
        )
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.observeGlobalKeyRequirement(false)
        let original = try store.resolve(draft)

        store.observeGlobalKeyRequirement(true)
        store.observeGlobalKeyRequirement(false)
        let returned = try store.resolve(draft)

        #expect(returned.generation > original.generation)
        store.resetForTesting()
    }

    @Test("an observed policy mutation cancels a pending attempt")
    func policyMutationCancelsPendingAttempt() async throws {
        let hostID = UUID()
        let keyA = UUID()
        let keyB = UUID()
        let hostA = Host(
            id: hostID,
            address: "mutation.example",
            user: "alice",
            storedKeyID: keyA
        )
        let box = await MainActor.run {
            CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
                host: hostA,
                requireBiometric: true,
                isSecureEnclave: false,
                keyAlgorithm: .ed25519
            ))
        }
        try await MainActor.run {
            let store = SSHAuthenticationPolicyStore.shared
            store.resetForTesting()
            store.registerPersistedHost(hostID)
            store.configureCurrentPolicyProvider { _, _ in box.draft }
            _ = try store.resolve(box.draft)
        }

        let started = AsyncLatch()
        let attempt = Task {
            try await withPendingSSHConnectionAttempt {
                await started.signal()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()

        await MainActor.run {
            var hostB = hostA
            hostB.storedKeyID = keyB
            box.draft = SSHConnectionPolicyDraft(
                host: hostB,
                requireBiometric: true,
                isSecureEnclave: false,
                keyAlgorithm: .ed25519
            )
            SSHAuthenticationPolicyStore.shared.refreshCurrentPolicies()
        }

        await #expect(throws: CancellationError.self) {
            try await attempt.value
        }
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("password revision invalidates an in-flight snapshot without retaining a verifier")
    @MainActor
    func passwordRotationChangesSignature() throws {
        let hostID = UUID()
        var oldHost = Host(
            id: hostID,
            address: "password.example",
            user: "alice",
            password: "same-storage-shape"
        )
        let identityID = UUID()
        oldHost.passwordCredentialRevision = .keychain(
            identityID: identityID,
            revision: 10
        )
        let box = CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
            host: oldHost,
            requireBiometric: false,
            isSecureEnclave: false
        ))
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.registerPersistedHost(hostID)
        store.configureCurrentPolicyProvider { _, _ in box.draft }
        let snapshot = try store.resolve(box.draft)

        var rotated = oldHost
        rotated.passwordCredentialRevision = .keychain(
            identityID: identityID,
            revision: 11
        )
        box.draft = SSHConnectionPolicyDraft(
            host: rotated,
            requireBiometric: false,
            isSecureEnclave: false
        )
        #expect(throws: AuthResolutionError.self) {
            try store.revalidate(snapshot)
        }
        store.resetForTesting()
    }

    @Test("switching password identities changes policy without a password hash")
    @MainActor
    func passwordIdentityChangeChangesSignature() throws {
        let hostID = UUID()
        var first = Host(
            id: hostID,
            address: "identity.example",
            user: "alice",
            password: "not-in-signature"
        )
        first.passwordCredentialRevision = .keychain(
            identityID: UUID(),
            revision: 22
        )
        let box = CurrentPolicyBox(draft: SSHConnectionPolicyDraft(
            host: first,
            requireBiometric: false,
            isSecureEnclave: false
        ))
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        store.registerPersistedHost(hostID)
        store.configureCurrentPolicyProvider { _, _ in box.draft }
        let snapshot = try store.resolve(box.draft)

        var second = first
        second.passwordCredentialRevision = .keychain(
            identityID: UUID(),
            revision: 22
        )
        box.draft = SSHConnectionPolicyDraft(
            host: second,
            requireBiometric: false,
            isSecureEnclave: false
        )

        #expect(throws: AuthResolutionError.self) {
            try store.revalidate(snapshot)
        }
        store.resetForTesting()
    }

    @Test("a configured key without algorithm metadata fails closed")
    func configuredKeyWithoutMetadataIsRejected() async {
        let keyID = UUID()
        let host = Host(
            address: "metadata.example",
            user: "alice",
            storedKeyID: keyID
        )
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }

        do {
            _ = try await resolveSSHConnection(
                for: host,
                requireBiometric: false,
                isSecureEnclave: false
            )
            Issue.record("configured key authenticated without StoredKey algorithm metadata")
        } catch AuthResolutionError.storedKeyMetadataNotFound(let rejectedID) {
            #expect(rejectedID == keyID)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("transient password is cleared when the saved identity is removed")
    func identityNoneDoesNotReuseTransientPassword() {
        let identity = Identity(user: "alice", credentialMode: .none)
        let persisted = PersistedHost(address: "none.example", identity: identity)
        let host = Host(
            from: persisted,
            transientPassword: "stale password",
            transientPasswordCredentialRevision: .ephemeral(
                identityID: identity.id,
                token: UUID()
            ),
            keychain: passwordKeychain(status: errSecItemNotFound)
        )

        #expect(host.password.isEmpty)
        #expect(host.passwordCredentialRevision == nil)
    }

    @Test("transient password is bound to its original saved identity")
    func identitySwitchDoesNotReuseTransientPassword() {
        let originalIdentity = Identity(user: "alice", credentialMode: .password)
        let replacementIdentity = Identity(user: "alice", credentialMode: .password)
        let persisted = PersistedHost(
            address: "identity-switch.example",
            identity: replacementIdentity
        )
        let host = Host(
            from: persisted,
            transientPassword: "belongs to original",
            transientPasswordCredentialRevision: .ephemeral(
                identityID: originalIdentity.id,
                token: UUID()
            ),
            keychain: passwordKeychain(status: errSecItemNotFound)
        )

        #expect(host.password.isEmpty)
        #expect(host.passwordCredentialRevision == nil)
    }

    @Test("Keychain read failure does not resurrect an ephemeral fallback")
    func keychainFailureDoesNotReuseTransientPassword() {
        let identity = Identity(user: "alice", credentialMode: .password)
        let persisted = PersistedHost(address: "failure.example", identity: identity)
        let host = Host(
            from: persisted,
            transientPassword: "stale password",
            transientPasswordCredentialRevision: .ephemeral(
                identityID: identity.id,
                token: UUID()
            ),
            keychain: passwordKeychain(status: errSecInteractionNotAllowed)
        )

        #expect(host.password.isEmpty)
        #expect(host.passwordCredentialRevision == nil)
    }

    @Test("deleted Keychain password does not reuse the saved-host snapshot")
    func deletedKeychainPasswordDoesNotUseFallback() {
        let identity = Identity(user: "alice", credentialMode: .password)
        let persisted = PersistedHost(address: "deleted.example", identity: identity)
        let host = Host(
            from: persisted,
            transientPassword: "formerly saved",
            transientPasswordCredentialRevision: .keychain(
                identityID: identity.id,
                revision: 9
            ),
            keychain: passwordKeychain(status: errSecItemNotFound)
        )

        #expect(host.password.isEmpty)
        #expect(host.passwordCredentialRevision == nil)
    }

    @Test("a genuinely ephemeral password survives only a missing Keychain item")
    func missingKeychainItemUsesExplicitEphemeralPassword() {
        let identity = Identity(user: "alice", credentialMode: .password)
        let token = HostPasswordCredentialRevision.ephemeral(
            identityID: identity.id,
            token: UUID()
        )
        let persisted = PersistedHost(address: "ephemeral.example", identity: identity)
        let host = Host(
            from: persisted,
            transientPassword: "one session only",
            transientPasswordCredentialRevision: token,
            keychain: passwordKeychain(status: errSecItemNotFound)
        )

        #expect(host.password == "one session only")
        #expect(host.passwordCredentialRevision == token)
    }

    @Test("a newly entered transient password receives session provenance")
    func newTransientPasswordGetsEphemeralRevision() {
        let identity = Identity(user: "alice", credentialMode: .password)
        let persisted = PersistedHost(address: "new-ephemeral.example", identity: identity)
        let host = Host(
            from: persisted,
            transientPassword: "entered now",
            keychain: passwordKeychain(status: errSecItemNotFound)
        )

        #expect(host.password == "entered now")
        guard case .ephemeral = host.passwordCredentialRevision else {
            Issue.record("new transient password did not receive ephemeral provenance")
            return
        }
    }

    private func passwordKeychain(status: OSStatus) -> KeychainClient {
        KeychainClient(
            add: { _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            copyMatching: { _ in (status, nil) },
            delete: { _ in errSecSuccess }
        )
    }
}

@MainActor
private final class CurrentPolicyBox {
    var draft: SSHConnectionPolicyDraft

    init(draft: SSHConnectionPolicyDraft) {
        self.draft = draft
    }
}

private actor AsyncLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RejectedValueRecorder<Value: Sendable & Equatable> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }
}

private actor IgnoringCancellationValueGate<Value: Sendable> {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var valueWaiter: CheckedContinuation<Value, Never>?

    func waitForValue() async -> Value {
        started = true
        let current = startWaiters
        startWaiters.removeAll()
        for waiter in current { waiter.resume() }
        return await withCheckedContinuation { valueWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete(with value: Value) {
        valueWaiter?.resume(returning: value)
        valueWaiter = nil
    }
}
