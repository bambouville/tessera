// Tessera/AgentCenterV2/Adapters/AgentRegexCache.swift
// Process-wide cache of compiled case-insensitive regular expressions.
import Foundation

/// Profile matchers and prompt-detection rules run on hot paths (every
/// resolver refresh, pane capture, and send-settle checkpoint) but draw from
/// a tiny, essentially static pattern set — built-in profiles plus a handful
/// of user-authored matchers. Compile each unique pattern once per process.
/// `NSRegularExpression` is immutable and thread-safe, so cached instances
/// can be shared across callers. Keyed by pattern string only, with options
/// fixed to case-insensitive (every current caller); key by (pattern,
/// options) if a second options set ever appears. Unbounded by design — the
/// population is bounded in practice by the profile set.
enum AgentRegexCache {
    private static let lock = NSLock()
    /// Invalid patterns cache `nil` too, so a malformed user matcher fails
    /// fast on every call instead of recompiling each time.
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression?] = [:]

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        let compiled = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
        cache[pattern] = compiled
        return compiled
    }
}

/// Processor-time allowance shared by every pattern one prompt parse
/// evaluates. Profile patterns run over remote terminal text on the main
/// actor, and a pattern that backtracks catastrophically on some screen
/// blocked it for minutes: iOS then killed the hung app whenever it was
/// backgrounded or relaunched. Past the allowance every evaluation reports no
/// match and `isExhausted` tells the caller the parse is inconclusive.
///
/// It counts the calling thread's CPU time, so a parse that is preempted or
/// suspended midway is not cut short. Use it only on the creating thread.
final class AgentRegexBudget {
    private static let ticksPerMillisecond: UInt64 = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
    }()
    /// Reading the thread's CPU clock is a system call, too slow to make at
    /// every progress callback; a tick count decides cheaply when one is due.
    private static let checkIntervalTicks = 2 * ticksPerMillisecond

    private let cpuDeadline: UInt64
    private var nextCheck: UInt64
    private(set) var isExhausted = false

    init(milliseconds: UInt64) {
        cpuDeadline = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) + milliseconds * 1_000_000
        nextCheck = mach_absolute_time() + Self.checkIntervalTicks
    }

    /// `.reportProgress` calls back periodically inside a long-running match,
    /// so the allowance also interrupts a single runaway evaluation.
    func matches(
        _ regex: NSRegularExpression,
        in text: String,
        limit: Int = .max
    ) -> [NSTextCheckingResult] {
        guard !isExhausted else { return [] }
        var results: [NSTextCheckingResult] = []
        regex.enumerateMatches(
            in: text,
            options: .reportProgress,
            range: NSRange(text.startIndex..., in: text)
        ) { match, _, stop in
            if let match {
                results.append(match)
                if results.count >= limit {
                    stop.pointee = true
                    return
                }
            }
            let now = mach_absolute_time()
            guard now >= nextCheck else { return }
            nextCheck = now + Self.checkIntervalTicks
            if clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) >= cpuDeadline {
                isExhausted = true
                stop.pointee = true
            }
        }
        return isExhausted ? [] : results
    }

    func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        matches(regex, in: text, limit: 1).first
    }
}
