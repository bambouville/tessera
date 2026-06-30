import SwiftUI

/// The two on-screen elements the guided walkthrough spotlights. They live in
/// different subtrees (the landing detail pane and the floating sidebar), so the
/// overlay can't reach them directly — it discovers their frames through the
/// standard SwiftUI anchor-preference channel, merged at the `ContentView`
/// ZStack that is the common ancestor of both.
///
/// Only the two *spotlight* steps need an anchor. The illustration steps (tmux,
/// swipe pad, shortcuts) render as centered cards and look up nothing.
enum OnboardingTarget: Hashable {
    case addHost
    case keysNav
}

/// Collects `Anchor<CGRect>` bounds keyed by target. `reduce` keeps the last
/// writer for a given target, so a re-rendered element overwrites its stale
/// bounds rather than accumulating.
struct OnboardingAnchorKey: PreferenceKey {
    static var defaultValue: [OnboardingTarget: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [OnboardingTarget: Anchor<CGRect>],
        nextValue: () -> [OnboardingTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tags this view as an onboarding spotlight target. The overlay resolves
    /// the published bounds against its own coordinate space to cut the dim
    /// hole and position the callout.
    func onboardingAnchor(_ target: OnboardingTarget) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) {
            [target: $0]
        }
    }

    /// Conditionally publishes the anchor. Used where two elements can serve as
    /// the same spotlight target depending on state (e.g. `.addHost` is the
    /// big empty-state CTA when there are no hosts, but the header "new host"
    /// button once the list is populated) — only one must publish at a time, or
    /// the `reduce` "keep last" rule picks a nondeterministic winner.
    @ViewBuilder
    func onboardingAnchor(_ target: OnboardingTarget, if condition: Bool) -> some View {
        if condition {
            onboardingAnchor(target)
        } else {
            self
        }
    }
}
