import Foundation

/// R3's expiry for a pending show or tap intent: about `windowMillis` after
/// the user's last step (the show or tap itself, an answered prompt, Retry).
///
/// A host-key, password, OTP or biometric prompt pauses the clock: the user
/// is busy answering it, not waiting on the network. A pause freezes the
/// clock, and ending it is the user's next step, so the full window restarts
/// from there rather than continuing the old one.
///
/// All times are milliseconds on one clock that keeps running while the
/// device sleeps (iOS `CLOCK_MONOTONIC_RAW`, Android `elapsedRealtime`), so
/// an intent whose window ran out during sleep is overdue on wake even though
/// no timer fired.
public struct TmuxAuthorityIntentClock: Equatable, Sendable {
    /// §6.9 R3: about 20 s from the user's last step.
    public static let defaultWindowMillis: Int64 = 20_000

    public let windowMillis: Int64
    /// The pending intent being timed, if any.
    public private(set) var token: UInt64?
    /// The user's last step for `token`.
    public private(set) var stepAt: Int64 = 0
    /// Since when a prompt pauses the clock; nil while running.
    public private(set) var pausedSince: Int64?

    public init(windowMillis: Int64 = Self.defaultWindowMillis) {
        self.windowMillis = max(0, windowMillis)
    }

    public var paused: Bool { pausedSince != nil }

    /// Follows the reducer's pending intent. A new token starts its window
    /// at `stepAt` (the gesture's own time, which can precede delivery: a
    /// show carried from a replaced session object, or buffered before its
    /// session registered); nil stops tracking. The same token keeps its
    /// step.
    public mutating func track(_ intentToken: UInt64?, stepAt: Int64) {
        guard intentToken != token else { return }
        token = intentToken
        if intentToken != nil { self.stepAt = stepAt }
    }

    /// The user answered a prompt or pressed Retry: a fresh window from now.
    public mutating func userStep(now: Int64) {
        guard token != nil else { return }
        stepAt = now
    }

    /// A prompt went up or came down. Ending a pause is a fresh step.
    public mutating func setPaused(_ paused: Bool, now: Int64) {
        switch (paused, pausedSince) {
        case (true, nil):
            pausedSince = now
        case (false, .some):
            pausedSince = nil
            if token != nil { stepAt = now }
        default:
            break
        }
    }

    /// When the pending intent expires, or nil while paused or idle.
    public var deadline: Int64? {
        guard token != nil, pausedSince == nil else { return nil }
        return stepAt.clampedAdding(windowMillis)
    }

    /// The token to expire now, if its window has run out and no prompt is up.
    public func expiredToken(now: Int64) -> UInt64? {
        guard let deadline, now >= deadline else { return nil }
        return token
    }

    /// Milliseconds until `expiredToken` can fire, or nil when paused or idle.
    public func remaining(now: Int64) -> Int64? {
        deadline.map { max(0, $0.clampedSubtracting(now)) }
    }

    /// Time the user's step has already used of its window, for a show
    /// carried to a successor session object; zero while paused (answering
    /// the prompt restarts the full window).
    public func elapsed(now: Int64) -> Int64? {
        guard token != nil else { return nil }
        guard pausedSince == nil else { return 0 }
        return max(0, now.clampedSubtracting(stepAt))
    }
}
