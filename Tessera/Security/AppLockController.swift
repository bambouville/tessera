import SwiftUI

@MainActor
@Observable
final class AppLockController {
    var isLocked: Bool
    var lastAuthError: BiometricResult?

    private var idleTask: Task<Void, Never>?
    private var pendingAutoPrompt: Bool
    private let appearance: AppearancePreferences

    init(appearance: AppearancePreferences) {
        self.appearance = appearance
        self.isLocked = appearance.requireFaceIDToUnlock
        self.pendingAutoPrompt = false
    }

    func lock() {
        idleTask?.cancel()
        idleTask = nil
        lastAuthError = nil

        Task { await BiometricSessionCache.shared.revokeAll() }

        pendingAutoPrompt = true

        guard !isLocked else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isLocked = true
        }
    }

    func unlock() async {
        // Manual unlock attempt clears the pending auto-prompt so a
        // subsequent .active transition (e.g. user briefly switched apps)
        // doesn't re-fire on top of the user's own retry.
        pendingAutoPrompt = false

        let result = await BiometricGate.evaluate(reason: "Unlock Tessera")

        switch result {
        case .authenticated:
            lastAuthError = nil
            withAnimation(.easeInOut(duration: 0.18)) {
                isLocked = false
            }
        case .userCancelled:
            lastAuthError = nil
        case .unavailable, .failed:
            lastAuthError = result
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if appearance.lockWhenBackgrounded { lock() }
        case .active:
            if isLocked && pendingAutoPrompt {
                pendingAutoPrompt = false
                Task { await unlock() }
            }
        default:
            break
        }
    }

    func notifyUserActivity() {
        idleTask?.cancel()
        idleTask = nil

        guard !isLocked else { return }
        let minutes = appearance.autoLockMinutes
        guard minutes > 0 else { return }

        let nanoseconds = UInt64(minutes) * 60 * 1_000_000_000
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.lockIfIdleTimerStillCurrent(expectedMinutes: minutes)
        }
    }

    private func lockIfIdleTimerStillCurrent(expectedMinutes: Int) {
        guard !isLocked, appearance.autoLockMinutes == expectedMinutes else { return }
        lock()
    }
}
