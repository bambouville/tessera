import SwiftUI

/// Drives the passive first-launch walkthrough. Modeled on `AppLockController`:
/// `@MainActor @Observable`, constructed in `TesseraApp.init`, injected into the
/// environment in `RootView`, and holding a reference to `AppearancePreferences`
/// so `finish`/`skip` can flip the persisted `hasSeenWelcome` flag.
///
/// Phases:
/// - `.inactive`  — nothing shown; the overlay passes touches through.
/// - `.welcome`   — the opening card (`take the tour` / `skip`).
/// - `.whatsNew`  — this release's navigation changes (`show me` / `done`).
/// - `.touring(n) — coach-mark step `n`.
@MainActor
@Observable
final class OnboardingController {
    var phase: OnboardingPhase = .inactive

    /// The ordered step list. Pure data — see `OnboardingStep.firstRun`.
    var steps: [OnboardingStep] {
        let all = OnboardingStep.firstRun(
            appearance.modifierNotation,
            agentCenterEnabled: appearance.agentCenterEnabled
        )
        switch tourScope {
        case .firstRun: return all
        case .whatsNew(let isPhone): return WhatsNewPolicy.walkthroughSteps(all, isPhone: isPhone)
        }
    }

    private let appearance: AppearancePreferences
    private let currentVersion: String
    private var tourScope: TourScope = .firstRun

    private enum TourScope {
        case firstRun
        case whatsNew(isPhone: Bool)
    }

    init(
        appearance: AppearancePreferences,
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    ) {
        self.appearance = appearance
        self.currentVersion = currentVersion
    }

    enum BootstrapPresentationAction: Equatable {
        case none, hideOnboarding, completeWelcome, resumeOnboarding
    }

    /// Shared decision for the bootstrap sheet's presentation-change handler.
    /// Cancel resumes the ordinary welcome flow without marking it complete.
    static func bootstrapPresentationAction(
        wasPresented: Bool,
        isPresented: Bool,
        hasCompletedFirstOpen: Bool
    ) -> BootstrapPresentationAction {
        if isPresented { return .hideOnboarding }
        guard wasPresented else { return .none }
        return hasCompletedFirstOpen ? .completeWelcome : .resumeOnboarding
    }

    /// Auto-runs the welcome card exactly once, and only on a genuine first
    /// launch: the user hasn't seen it (`hasSeen == false`) and there are no
    /// hosts yet (`hasHosts == false`). Idempotent — guarded on `.inactive`, so
    /// a re-entrant `onAppear` after the tour has started is a no-op.
    func beginIfFirstLaunch(hasHosts: Bool, hasSeen: Bool) {
        guard phase == .inactive, !hasSeen, !hasHosts else { return }
        tourScope = .firstRun
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .welcome
        }
    }

    /// Call after the lock/setup presentation gates, independently of the
    /// empty-landing welcome gate: an updater may have restored live sessions.
    func beginWhatsNewIfNeeded(hostCount: Int, isLocked: Bool, isSetupPresented: Bool) {
        guard phase == .inactive, !isLocked, !isSetupPresented,
              WhatsNewPolicy.shouldShowWhatsNew(
                currentVersion: currentVersion,
                lastSeen: appearance.lastSeenWhatsNewVersion,
                hasSeenWelcome: appearance.hasSeenWelcome,
                hostCount: hostCount
              ) else { return }
        showWhatsNew()
    }

    /// Settings → About may reopen this card even after it was acknowledged.
    func showWhatsNew() {
        tourScope = .firstRun
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .whatsNew
        }
    }

    func startWhatsNewTour(isPhone: Bool) {
        markWhatsNewSeen()
        tourScope = .whatsNew(isPhone: isPhone)
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .touring(0)
        }
    }

    func dismissWhatsNew() {
        markWhatsNewSeen()
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .inactive
        }
    }

    /// Also used when the nearby setup sheet completes the welcome flow.
    /// Cancel must never call this; it resumes the ordinary welcome instead.
    func completeWelcome() {
        appearance.hasSeenWelcome = true
        markWhatsNewSeen()
    }

    private func markWhatsNewSeen() {
        if appearance.lastSeenWhatsNewVersion.compare(WhatsNewPolicy.version, options: .numeric) == .orderedAscending {
            appearance.lastSeenWhatsNewVersion = WhatsNewPolicy.version
        }
    }

    /// Jumps straight into the tour at step 0. Backs both the welcome card's
    /// "take the tour" button and the Settings → About replay row, so the tour
    /// is never lost once dismissed.
    func startTour() {
        tourScope = .firstRun
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .touring(0)
        }
    }

    /// Advances to the next step; advancing past the last step finishes.
    func next() {
        guard case .touring(let index) = phase else { return }
        if index + 1 >= steps.count {
            finish()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                phase = .touring(index + 1)
            }
        }
    }

    /// Steps back one; clamped at the first step.
    func back() {
        guard case .touring(let index) = phase, index > 0 else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            phase = .touring(index - 1)
        }
    }

    /// Dismisses the tour and records that the user has seen the welcome flow so
    /// it never auto-runs again.
    func finish() {
        completeWelcome()
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .inactive
        }
    }

    /// Skipping a walkthrough completes welcome; dismissing the release card
    /// alone acknowledges only that card.
    func skip() {
        if phase == .whatsNew {
            dismissWhatsNew()
        } else {
            finish()
        }
    }
}

enum OnboardingPhase: Equatable {
    case inactive
    case welcome
    case whatsNew
    case touring(Int)
}
