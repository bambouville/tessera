// Tessera/AgentCenter/AgentRegexCache.swift
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
