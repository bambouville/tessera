import Foundation

/// Device-local release education. The card describes 0.4.1 specifically;
/// later releases need their own copy and an explicit policy update.
enum WhatsNewPolicy {
    static let version = "0.4.1"

    static func shouldShowWhatsNew(
        currentVersion: String,
        lastSeen: String,
        hasSeenWelcome: Bool,
        hostCount: Int
    ) -> Bool {
        currentVersion == version
            && (lastSeen.isEmpty || lastSeen.compare(version, options: .numeric) == .orderedAscending)
            && (hasSeenWelcome || hostCount > 0)
    }

    /// One-based first-run step numbers, retained in walkthrough order.
    static func walkthroughStepNumbers(isPhone: Bool) -> [Int] {
        isPhone ? [2, 4, 6, 7, 8, 11] : [2, 6, 7, 8, 11]
    }

    static func walkthroughSteps(_ steps: [OnboardingStep], isPhone: Bool) -> [OnboardingStep] {
        let included = Set(walkthroughStepNumbers(isPhone: isPhone))
        return steps.enumerated().compactMap { index, step in
            included.contains(index + 1) ? step : nil
        }
    }
}
