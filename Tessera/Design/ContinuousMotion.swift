import Foundation

/// Process-wide switch for the app's continuous (`repeatForever`) animations:
/// status-dot pulses, the launch overlay's breathing halo and blinking mark,
/// the sidebar attention pulse, the continuation "breathing" badge, and the
/// swipe pad's rings.
///
/// XCUITest waits for the target app to become idle before every public-API
/// interaction. A forever animation never lets that happen, so each tap or
/// launch sits out the full 60-second "App animations complete notification
/// not received" timeout. Reduce Motion is the user-facing off switch for
/// most of these; DEBUG automation opts in per launch with
/// `launchEnvironment["TESSERA_STATIC_RINGS"] = "1"` instead of mutating the
/// simulator's accessibility settings. Every gated element stays visible —
/// it just holds its resting frame.
enum ContinuousMotion {
    #if DEBUG
    static let isSuppressed =
        ProcessInfo.processInfo.environment["TESSERA_STATIC_RINGS"] == "1"
    #else
    static let isSuppressed = false
    #endif
}
