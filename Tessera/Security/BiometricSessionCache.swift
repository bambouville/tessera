import Foundation

/// A biometric grant is scoped to the complete credential context. In
/// particular, changing an endpoint or rotating a key can never reuse a grant
/// merely because the PersistedHost UUID stayed the same.
struct BiometricGrantKey: Hashable, Sendable {
    let hostID: UUID
    let endpoint: String
    let keyID: UUID
    let policyGeneration: UInt64
}

/// Coalesces concurrent owner-presence prompts and caches the evaluated
/// LAContext for a short connection burst. Main-actor isolation is deliberate:
/// AppLockController can synchronously revoke grants and cancel every in-flight
/// evaluation before lock() returns.
@MainActor
final class BiometricSessionCache {
    static let shared = BiometricSessionCache()

    typealias Evaluator = @Sendable (String) async -> BiometricAuthorizationResult
    typealias Now = @Sendable () -> Date

    private struct Grant {
        let authorization: BiometricAuthorization
        let expiresAt: Date
    }

    private struct InFlight {
        let token: UUID
        let revocationGeneration: UInt64
        let task: Task<BiometricAuthorizationResult, Never>
        let waiters: BiometricEvaluationWaiters
    }

    private var grants: [BiometricGrantKey: Grant] = [:]
    private var inFlight: [BiometricGrantKey: InFlight] = [:]
    private var revocationGeneration: UInt64 = 0
    private let ttl: TimeInterval
    private let now: Now
    private let evaluator: Evaluator

    init(
        ttl: TimeInterval = 30,
        now: @escaping Now = { Date() },
        evaluator: @escaping Evaluator = { reason in
            await BiometricGate.evaluateForKeyUse(reason: reason)
        }
    ) {
        self.ttl = ttl
        self.now = now
        self.evaluator = evaluator
    }

    func evaluate(key: BiometricGrantKey, reason: String) async -> BiometricAuthorizationResult {
        guard !Task.isCancelled else { return .userCancelled }
        if let grant = grants[key], grant.expiresAt > now() {
            return .authenticated(grant.authorization)
        }
        grants.removeValue(forKey: key)

        let waiterID = UUID()
        let current: InFlight
        if let existing = inFlight[key] {
            existing.waiters.add(waiterID)
            current = existing
        } else {
            let token = UUID()
            let evaluationGeneration = revocationGeneration
            let evaluator = self.evaluator
            let task = Task<BiometricAuthorizationResult, Never> {
                await evaluator(reason)
            }
            let waiters = BiometricEvaluationWaiters(firstWaiter: waiterID)
            current = InFlight(
                token: token,
                revocationGeneration: evaluationGeneration,
                task: task,
                waiters: waiters
            )
            waiters.attach(task)
            inFlight[key] = current
        }

        let result = await withTaskCancellationHandler {
            await current.task.value
        } onCancel: { [weak self] in
            // Synchronous and lock-backed: a sole cancelled waiter invalidates
            // BiometricGate's LAContext immediately, without waiting for a
            // MainActor hop. Shared evaluations remain alive for other waiters.
            current.waiters.cancel(waiterID)
            Task { @MainActor in
                self?.removeEmptyInFlight(for: key, token: current.token)
            }
        }
        return finish(
            result,
            for: key,
            waiterID: waiterID,
            token: current.token,
            evaluationGeneration: current.revocationGeneration,
            taskWasCancelled: current.task.isCancelled,
            callerWasCancelled: Task.isCancelled
        )
    }

    /// Cancels LocalAuthentication evaluations as well as clearing completed
    /// grants. Any evaluator that ignores cancellation is still harmless: its
    /// completion carries the old generation and is rejected by finish().
    func revokeAll() {
        revocationGeneration &+= 1
        grants.removeAll()
        let waiters = inFlight.values.map(\.waiters)
        inFlight.removeAll()
        for waiterGroup in waiters {
            waiterGroup.cancelAll()
        }
    }

    private func finish(
        _ result: BiometricAuthorizationResult,
        for key: BiometricGrantKey,
        waiterID: UUID,
        token: UUID,
        evaluationGeneration: UInt64,
        taskWasCancelled: Bool,
        callerWasCancelled: Bool
    ) -> BiometricAuthorizationResult {
        guard let current = inFlight[key], current.token == token else {
            return .userCancelled
        }

        let waiterWasActive = callerWasCancelled
            ? current.waiters.cancel(waiterID)
            : current.waiters.finish(waiterID)
        guard waiterWasActive else { return .userCancelled }

        if current.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
        }

        guard evaluationGeneration == revocationGeneration,
              !taskWasCancelled,
              !callerWasCancelled else {
            return .userCancelled
        }

        if case .authenticated(let authorization) = result {
            grants[key] = Grant(
                authorization: authorization,
                expiresAt: now().addingTimeInterval(ttl)
            )
        }
        return result
    }

    /// Removes only the cancelled waiter. Concurrent attempts sharing the same
    /// exact policy may continue; when the last waiter leaves, invalidate the
    /// LAContext-backed evaluator immediately and reject any late success.
    private func removeEmptyInFlight(for key: BiometricGrantKey, token: UUID) {
        guard let current = inFlight[key], current.token == token else { return }
        if current.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
        }
    }
}

/// Thread-safe waiter accounting used from task-cancellation handlers, which
/// cannot synchronously call the MainActor cache. It owns no authorization and
/// retains the evaluator only while at least one connection attempt is waiting.
private final class BiometricEvaluationWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<UUID>
    private var task: Task<BiometricAuthorizationResult, Never>?

    init(firstWaiter: UUID) {
        active = [firstWaiter]
    }

    func attach(_ task: Task<BiometricAuthorizationResult, Never>) {
        lock.withLock {
            self.task = task
            if active.isEmpty { task.cancel() }
        }
    }

    func add(_ waiter: UUID) {
        lock.withLock { _ = active.insert(waiter) }
    }

    @discardableResult
    func cancel(_ waiter: UUID) -> Bool {
        lock.withLock {
            guard active.remove(waiter) != nil else { return false }
            if active.isEmpty { task?.cancel() }
            return true
        }
    }

    @discardableResult
    func finish(_ waiter: UUID) -> Bool {
        lock.withLock { active.remove(waiter) != nil }
    }

    func cancelAll() {
        lock.withLock {
            active.removeAll()
            task?.cancel()
        }
    }

    var isEmpty: Bool {
        lock.withLock { active.isEmpty }
    }
}
