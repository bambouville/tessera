import Foundation

/// Coalesces concurrent biometric prompts for the same host, and caches a
/// successful authorization for a short window so multi-leg connect flows
/// (mosh bootstrap + tmux control channel + post-disconnect monitor) fire
/// at most one Face ID prompt per host. Switching to a different host
/// re-prompts even if it uses the same key — the authorization is "permission
/// to connect to this host right now," not "permission to use this key."
///
/// Cleared on app lock by AppLockController.
actor BiometricSessionCache {
    static let shared = BiometricSessionCache()

    private struct Grant { let expiresAt: Date }

    private var grants: [UUID: Grant] = [:]
    private var inFlight: [UUID: Task<BiometricResult, Never>] = [:]
    private let ttl: TimeInterval = 30

    func evaluate(hostID: UUID, reason: String) async -> BiometricResult {
        if let grant = grants[hostID], grant.expiresAt > Date() {
            return .authenticated
        }
        grants.removeValue(forKey: hostID)

        if let task = inFlight[hostID] {
            return await task.value
        }

        let task = Task<BiometricResult, Never> {
            await BiometricGate.evaluate(reason: reason)
        }
        inFlight[hostID] = task
        let result = await task.value
        inFlight.removeValue(forKey: hostID)

        if case .authenticated = result {
            grants[hostID] = Grant(expiresAt: Date().addingTimeInterval(ttl))
        }
        return result
    }

    func revokeAll() {
        grants.removeAll()
    }
}
