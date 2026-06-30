import SwiftUI

/// Drives the passive first-launch walkthrough. Modeled on `AppLockController`:
/// `@MainActor @Observable`, constructed in `TesseraApp.init`, injected into the
/// environment in `RootView`, and holding a reference to `AppearancePreferences`
/// so `finish`/`skip` can flip the persisted `hasSeenWelcome` flag.
///
/// Phases:
/// - `.inactive`  — nothing shown; the overlay passes touches through.
/// - `.welcome`   — the opening card (`take the tour` / `skip`).
/// - `.touring(n) — coach-mark step `n`.
@MainActor
@Observable
final class OnboardingController {
    var phase: OnboardingPhase = .inactive

    /// The ordered step list. Pure data — see `OnboardingStep.firstRun`.
    let steps: [OnboardingStep] = OnboardingStep.firstRun

    private let appearance: AppearancePreferences

    init(appearance: AppearancePreferences) {
        self.appearance = appearance
    }

    /// Auto-runs the welcome card exactly once, and only on a genuine first
    /// launch: the user hasn't seen it (`hasSeen == false`) and there are no
    /// hosts yet (`hasHosts == false`). Idempotent — guarded on `.inactive`, so
    /// a re-entrant `onAppear` after the tour has started is a no-op.
    func beginIfFirstLaunch(hasHosts: Bool, hasSeen: Bool) {
        guard phase == .inactive, !hasSeen, !hasHosts else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .welcome
        }
    }

    /// Jumps straight into the tour at step 0. Backs both the welcome card's
    /// "take the tour" button and the Settings → About replay row, so the tour
    /// is never lost once dismissed.
    func startTour() {
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
        appearance.hasSeenWelcome = true
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .inactive
        }
    }

    /// `skip` is `finish` — the flag is set either way, per the locked design.
    func skip() {
        finish()
    }
}

enum OnboardingPhase: Equatable {
    case inactive
    case welcome
    case touring(Int)
}
