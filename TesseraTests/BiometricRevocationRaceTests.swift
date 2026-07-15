import Foundation
import LocalAuthentication
import SwiftUI
import Testing
@testable import Tessera

@Suite("Biometric revocation races", .serialized)
struct BiometricRevocationRaceTests {
    @Test("app-lock off never locks when backgrounded")
    @MainActor
    func appLockOffRespectsPreferenceOnBackground() {
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        let controller = AppLockController(
            requiresOwnerAuthentication: { false },
            locksWhenBackgrounded: { true },
            autoLockMinutes: { 5 }
        )

        controller.notifyUserActivity()
        controller.handleScenePhaseChange(.background)

        #expect(!controller.isLocked)
        #expect(!store.isAppLocked)
    }

    @Test("foreground activation preserves an in-flight policy when app lock is already off")
    @MainActor
    func foregroundActivationPreservesPolicyWhenAlreadyUnlocked() throws {
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        let controller = AppLockController(
            requiresOwnerAuthentication: { false },
            locksWhenBackgrounded: { true },
            autoLockMinutes: { 5 }
        )
        let draft = SSHConnectionPolicyDraft(
            host: Host(address: "startup-restore.example", user: "alice"),
            requireBiometric: false,
            isSecureEnclave: false
        )
        let resolvedPolicy = try store.resolve(draft)

        controller.handleScenePhaseChange(.active)

        try store.revalidate(resolvedPolicy)
    }

    @Test("backgrounding still invalidates an in-flight policy when app lock is off")
    @MainActor
    func backgroundInvalidatesPolicyWhenAlreadyUnlocked() throws {
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        let controller = AppLockController(
            requiresOwnerAuthentication: { false },
            locksWhenBackgrounded: { true },
            autoLockMinutes: { 5 }
        )
        let draft = SSHConnectionPolicyDraft(
            host: Host(address: "startup-restore.example", user: "alice"),
            requireBiometric: false,
            isSecureEnclave: false
        )
        let resolvedPolicy = try store.resolve(draft)

        controller.handleScenePhaseChange(.background)

        #expect(!controller.isLocked)
        #expect(!store.isAppLocked)
        do {
            try store.revalidate(resolvedPolicy)
            Issue.record("backgrounding preserved an in-flight policy")
        } catch AuthResolutionError.policyChanged {
            // Expected: background revocation advances the policy generation.
        } catch {
            Issue.record("unexpected background revalidation error: \(error)")
        }
    }

    @Test("app-lock off backgrounding cancels a pending connection attempt")
    func appLockOffBackgroundCancelsPendingAttempt() async {
        let controller = await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
            return AppLockController(
                requiresOwnerAuthentication: { false },
                locksWhenBackgrounded: { true },
                autoLockMinutes: { 5 }
            )
        }
        let started = BackgroundAttemptLatch()
        let attempt = Task {
            try await withPendingSSHConnectionAttempt {
                await started.signal()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()

        await MainActor.run {
            controller.handleScenePhaseChange(.background)
        }

        await #expect(throws: CancellationError.self) {
            try await attempt.value
        }
        await MainActor.run {
            SSHAuthenticationPolicyStore.shared.resetForTesting()
        }
    }

    @Test("turning app-lock off reconciles an existing lock without authentication")
    @MainActor
    func disablingAppLockDismissesExistingLock() throws {
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        var required = true
        let controller = AppLockController(
            requiresOwnerAuthentication: { required },
            locksWhenBackgrounded: { true },
            autoLockMinutes: { 5 }
        )
        #expect(controller.isLocked)

        required = false
        controller.reconcileRequirement()

        #expect(!controller.isLocked)
        #expect(!store.isAppLocked)
        _ = try store.resolve(SSHConnectionPolicyDraft(
            host: Host(address: "unlocked.example", user: "alice"),
            requireBiometric: false,
            isSecureEnclave: false
        ))
    }

    @Test("app-lock off reconciliation still clears stale local lock state")
    @MainActor
    func appLockOffReconciliationClearsStaleLocalState() {
        let store = SSHAuthenticationPolicyStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        var required = true
        let controller = AppLockController(
            requiresOwnerAuthentication: { required },
            locksWhenBackgrounded: { false },
            autoLockMinutes: { 5 }
        )
        controller.isLocked = false
        store.unlock()
        controller.notifyUserActivity()
        controller.lastAuthError = .failed(reason: "stale")
        #expect(controller.isIdleTimerArmedForTesting)

        required = false
        controller.reconcileRequirement()

        #expect(!controller.isIdleTimerArmedForTesting)
        #expect(controller.lastAuthError == nil)
        #expect(!store.isAppLocked)
    }

    @Test("turning app-lock on applies the requirement immediately")
    @MainActor
    func enablingAppLockLocksImmediately() {
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        var required = false
        let controller = AppLockController(
            requiresOwnerAuthentication: { required },
            locksWhenBackgrounded: { false },
            autoLockMinutes: { 0 }
        )
        #expect(!controller.isLocked)

        required = true
        controller.reconcileRequirement(enforceNewlyEnabled: true)

        #expect(controller.isLocked)
        #expect(SSHAuthenticationPolicyStore.shared.isAppLocked)
        SSHAuthenticationPolicyStore.shared.resetForTesting()
    }

    @Test("foreground activation arms idle lock outside terminal views")
    @MainActor
    func foregroundArmsIdleLock() {
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        let controller = AppLockController(
            requiresOwnerAuthentication: { true },
            locksWhenBackgrounded: { false },
            autoLockMinutes: { 5 }
        )
        controller.isLocked = false
        SSHAuthenticationPolicyStore.shared.unlock()

        controller.handleScenePhaseChange(.active)

        #expect(controller.isIdleTimerArmedForTesting)
        SSHAuthenticationPolicyStore.shared.resetForTesting()
    }

    @Test("lock-time revocation rejects a late successful evaluation")
    @MainActor
    func lateSuccessCannotRepopulateGrant() async {
        let evaluator = PausedBiometricEvaluator()
        let cache = BiometricSessionCache(
            evaluator: { reason in await evaluator.evaluate(reason: reason) }
        )
        let key = BiometricGrantKey(
            hostID: UUID(),
            endpoint: "first.example:22",
            keyID: UUID(),
            policyGeneration: 7
        )

        let first = Task { @MainActor in
            await cache.evaluate(key: key, reason: "test")
        }
        await evaluator.waitUntilEvaluationStarted(count: 1)

        cache.revokeAll()
        await evaluator.completeNextSuccessfully()

        guard case .userCancelled = await first.value else {
            Issue.record("a completion from before revocation was accepted")
            return
        }

        let second = Task { @MainActor in
            await cache.evaluate(key: key, reason: "test again")
        }
        await evaluator.waitUntilEvaluationStarted(count: 2)
        await evaluator.completeNextSuccessfully()
        guard case .authenticated = await second.value else {
            Issue.record("the post-revocation evaluation did not run afresh")
            return
        }
        let evaluationCount = await evaluator.evaluationCount
        #expect(evaluationCount == 2)
    }

    @Test("caller cancellation invalidates a sole evaluator and rejects late success")
    @MainActor
    func callerCancellationCannotPopulateGrant() async {
        let evaluator = PausedBiometricEvaluator()
        let cache = BiometricSessionCache(
            evaluator: { reason in await evaluator.evaluate(reason: reason) }
        )
        let key = makeGrantKey()

        let cancelled = Task { @MainActor in
            await cache.evaluate(key: key, reason: "cancel me")
        }
        await evaluator.waitUntilEvaluationStarted(count: 1)
        cancelled.cancel()
        await evaluator.completeNextSuccessfully()

        guard case .userCancelled = await cancelled.value else {
            Issue.record("a cancelled waiter accepted a late successful evaluation")
            return
        }

        let next = Task { @MainActor in
            await cache.evaluate(key: key, reason: "must evaluate again")
        }
        await evaluator.waitUntilEvaluationStarted(count: 2)
        await evaluator.completeNextSuccessfully()
        guard case .authenticated = await next.value else {
            Issue.record("the post-cancellation request did not evaluate afresh")
            return
        }
        #expect(await evaluator.evaluationCount == 2)
    }

    @Test("cancelling one shared waiter preserves the other waiter")
    @MainActor
    func sharedEvaluationKeepsLiveWaiter() async {
        let evaluator = PausedBiometricEvaluator()
        let cache = BiometricSessionCache(
            evaluator: { reason in await evaluator.evaluate(reason: reason) }
        )
        let key = makeGrantKey()

        let first = Task { @MainActor in
            await cache.evaluate(key: key, reason: "shared")
        }
        await evaluator.waitUntilEvaluationStarted(count: 1)
        let second = Task { @MainActor in
            await cache.evaluate(key: key, reason: "shared")
        }
        await Task.yield()

        first.cancel()
        await evaluator.completeNextSuccessfully()

        guard case .userCancelled = await first.value else {
            Issue.record("the cancelled shared waiter accepted success")
            return
        }
        guard case .authenticated = await second.value else {
            Issue.record("cancelling a sibling incorrectly revoked the live waiter")
            return
        }

        guard case .authenticated = await cache.evaluate(key: key, reason: "cached") else {
            Issue.record("the live waiter did not establish the shared grant")
            return
        }
        #expect(await evaluator.evaluationCount == 1)
    }

    private func makeGrantKey() -> BiometricGrantKey {
        BiometricGrantKey(
            hostID: UUID(),
            endpoint: "example.test:22",
            keyID: UUID(),
            policyGeneration: 1
        )
    }
}

private actor BackgroundAttemptLatch {
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

private actor PausedBiometricEvaluator {
    private var evaluations = 0
    private var completions: [CheckedContinuation<BiometricAuthorizationResult, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var evaluationCount: Int { evaluations }

    func evaluate(reason: String) async -> BiometricAuthorizationResult {
        _ = reason
        evaluations += 1
        let ready = startWaiters.filter { evaluations >= $0.0 }
        startWaiters.removeAll { evaluations >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }

        // Deliberately ignore Task cancellation. This models the adversarial
        // late LAContext completion the generation check must reject.
        return await withCheckedContinuation { completion in
            completions.append(completion)
        }
    }

    func waitUntilEvaluationStarted(count: Int) async {
        guard evaluations < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func completeNextSuccessfully() {
        let completion = completions.removeFirst()
        completion.resume(returning: .authenticated(
            BiometricAuthorization(context: LAContext())
        ))
    }
}
