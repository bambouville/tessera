import SwiftUI

@MainActor
@Observable
final class AppLockController {
    var isLocked: Bool
    var lastAuthError: BiometricResult?

    private var idleTask: Task<Void, Never>?
    private var pendingAutoPrompt: Bool
    private var lockGeneration: UInt64 = 0
    private let requiresOwnerAuthentication: () -> Bool
    private let locksWhenBackgrounded: () -> Bool
    private let configuredAutoLockMinutes: () -> Int

    init(appearance: AppearancePreferences) {
        self.requiresOwnerAuthentication = { appearance.requireFaceIDToUnlock }
        self.locksWhenBackgrounded = { appearance.lockWhenBackgrounded }
        self.configuredAutoLockMinutes = { appearance.autoLockMinutes }
        self.isLocked = appearance.requireFaceIDToUnlock
        self.pendingAutoPrompt = false
        SSHAuthenticationPolicyStore.shared.setInitialLockState(self.isLocked)
    }

    init(
        requiresOwnerAuthentication: @escaping () -> Bool,
        locksWhenBackgrounded: @escaping () -> Bool,
        autoLockMinutes: @escaping () -> Int
    ) {
        self.requiresOwnerAuthentication = requiresOwnerAuthentication
        self.locksWhenBackgrounded = locksWhenBackgrounded
        self.configuredAutoLockMinutes = autoLockMinutes
        self.isLocked = requiresOwnerAuthentication()
        self.pendingAutoPrompt = false
        SSHAuthenticationPolicyStore.shared.setInitialLockState(self.isLocked)
    }

    func lock() {
        idleTask?.cancel()
        idleTask = nil
        lastAuthError = nil

        guard requiresOwnerAuthentication() else {
            pendingAutoPrompt = false
            SSHAuthenticationPolicyStore.shared.revokeKeyUseAuthorizations()
            return
        }

        lockGeneration &+= 1

        // Synchronous MainActor revocation is security-sensitive: when lock()
        // returns there are no cached/in-flight key-use grants, and every SSH
        // handshake still pending has received cancellation.
        SSHAuthenticationPolicyStore.shared.lock()

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
        let attemptedGeneration = lockGeneration

        let result = await BiometricGate.evaluate(reason: String(localized: "Unlock Tessera"))

        // A background/idle lock that happened while the system sheet was up
        // supersedes this completion, even if LocalAuthentication reports
        // success afterward.
        guard attemptedGeneration == lockGeneration, isLocked else { return }

        switch result {
        case .authenticated:
            lastAuthError = nil
            SSHAuthenticationPolicyStore.shared.unlock()
            withAnimation(.easeInOut(duration: 0.18)) {
                isLocked = false
            }
            // Unlock is user activity too. Pages outside the terminal do not
            // emit SessionView activity events, so arm the configured idle
            // deadline here rather than leaving them unlocked indefinitely.
            notifyUserActivity()
        case .userCancelled:
            lastAuthError = nil
        case .unavailable, .failed:
            lastAuthError = result
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if requiresOwnerAuthentication() && locksWhenBackgrounded() {
                lock()
            } else {
                // Backgrounding always invalidates short key-use grants and
                // pending SSH legs, but app-lock OFF must never create a lock
                // screen that can only be dismissed through biometrics.
                SSHAuthenticationPolicyStore.shared.revokeKeyUseAuthorizations()
            }
        case .active:
            reconcileRequirement()
            if isLocked && pendingAutoPrompt {
                pendingAutoPrompt = false
                Task { await unlock() }
            } else if !isLocked {
                notifyUserActivity()
            }
        default:
            break
        }
    }

    func notifyUserActivity() {
        idleTask?.cancel()
        idleTask = nil

        guard requiresOwnerAuthentication(), !isLocked else { return }
        let minutes = configuredAutoLockMinutes()
        guard minutes > 0 else { return }

        let nanoseconds = UInt64(minutes) * 60 * 1_000_000_000
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.lockIfIdleTimerStillCurrent(expectedMinutes: minutes)
        }
    }

    private func lockIfIdleTimerStillCurrent(expectedMinutes: Int) {
        guard requiresOwnerAuthentication(),
              !isLocked,
              configuredAutoLockMinutes() == expectedMinutes else { return }
        lock()
    }

    #if DEBUG
    var isIdleTimerArmedForTesting: Bool { idleTask != nil }
    #endif

    /// Applies a changed app-lock preference immediately. Enabling locks now;
    /// disabling dismisses an existing lock without another owner-auth prompt
    /// because the user's explicit OFF choice is authoritative here.
    func reconcileRequirement(enforceNewlyEnabled: Bool = false) {
        if requiresOwnerAuthentication() {
            guard enforceNewlyEnabled, !isLocked else { return }
            lock()
            return
        }

        idleTask?.cancel()
        idleTask = nil
        pendingAutoPrompt = false
        lastAuthError = nil
        lockGeneration &+= 1
        guard isLocked else { return }
        SSHAuthenticationPolicyStore.shared.unlock()
        withAnimation(.easeInOut(duration: 0.18)) {
            isLocked = false
        }
    }
}

/// Installs `AppSwitcherPrivacyCover` only while the effective policy hides
/// content (Settings → security → hide content in app switcher, or app lock;
/// see `AppSwitcherPrivacyPolicy`). Reading the preference in this body keeps
/// the toggle live: turning it off removes the anchor, whose window detach
/// drops its observers and any cover it owns.
struct AppSwitcherPrivacyGate: View {
    let appearance: AppearancePreferences

    var body: some View {
        if appearance.effectiveHideContentInAppSwitcher {
            AppSwitcherPrivacyCover()
        }
    }
}

/// Covers a scene synchronously before UIKit captures its switcher snapshot.
/// Driven by `AppSwitcherPrivacyGate`, not by the lock state: the lock screen
/// is not guaranteed to be in the snapshot.
struct AppSwitcherPrivacyCover: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {}

    final class Anchor: UIView {
        private var observers: [NSObjectProtocol] = []
        private var cover: UIWindow?
        private weak var observedScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window?.windowScene !== observedScene else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            cover?.isHidden = true; cover = nil
            observedScene = window?.windowScene
            guard let scene = observedScene else { return }
            for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.setCovered(note.name == UIScene.willDeactivateNotification) }
                })
            }
            setCovered(scene.activationState != .foregroundActive)
        }

        private func setCovered(_ hiddenContent: Bool) {
            guard let scene = observedScene else { return }
            if hiddenContent {
                guard cover == nil else { return }
                let shield = UIWindow(windowScene: scene)
                shield.windowLevel = .alert + 1
                let controller = UIViewController()
                controller.view.backgroundColor = .black
                controller.view.accessibilityIdentifier = "app-switcher-privacy-cover"
                let label = UILabel()
                label.text = "Tessera"
                label.textColor = .white
                label.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
                label.translatesAutoresizingMaskIntoConstraints = false
                controller.view.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
                shield.rootViewController = controller
                cover = shield
                shield.isHidden = false
                shield.layoutIfNeeded()
            } else {
                cover?.isHidden = true
                cover = nil
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
