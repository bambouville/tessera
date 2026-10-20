import Foundation

/// Stable compact counts on both platforms: exact below 1k, whole k rounded
/// half up, then tenths of M rounded half up. Promote 999.5k to 1M and omit .0.
public enum AgentCompactTokenCount {
    public static func format(_ count: Int, locale: Locale = .current) -> String {
        let count = max(0, count)
        if count < 1_000 { return String(count) }
        if count < 999_500 { return "\((count + 500) / 1_000)k" }
        // Quotient/remainder arithmetic avoids overflowing at Int.max.
        let tenths = count / 100_000 + (count % 100_000 >= 50_000 ? 1 : 0)
        let fraction = tenths % 10
        return fraction == 0 ? "\(tenths / 10)M" : "\(tenths / 10)\(locale.decimalSeparator ?? ".")\(fraction)M"
    }
}

extension AgentContextSummary {
    /// A percentage wins when known; zero/absent usage leaves the line fallback.
    public var compactTokenCount: String? {
        guard percentUsed == nil, let usedTokens, usedTokens > 0 else { return nil }
        return AgentCompactTokenCount.format(usedTokens)
    }
}
