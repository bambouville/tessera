package com.bambouville.tessera.feature.agentcenter

import java.text.DecimalFormatSymbols
import java.util.Locale

/** Same integer rounding as Core: exact below 1k, whole k, tenths of M,
 * half up; promote 999.5k to 1M and omit .0. No floating-point count loss. */
internal fun compactAgentTokenCount(count: Long, locale: Locale = Locale.getDefault()): String {
    val value = count.coerceAtLeast(0)
    if (value < 1_000) return value.toString()
    if (value < 999_500) return "${(value + 500) / 1_000}k"
    val tenths = value / 100_000 + if (value % 100_000 >= 50_000) 1 else 0
    val separator = DecimalFormatSymbols.getInstance(locale).decimalSeparator
    return if (tenths % 10 == 0L) "${tenths / 10}M" else "${tenths / 10}$separator${tenths % 10}M"
}

internal fun AgentThreadRow.compactContextTokens(): String? {
    if (contextPercent != null) return null
    val count = contextUsedTokens?.toLongOrNull()?.takeIf { it > 0 } ?: return null
    return compactAgentTokenCount(count)
}

/** Context wins over line changes even for finished/idle threads. Cost stays
 * supplementary, as before. tokenText is localized by the Compose caller. */
internal fun AgentThreadRow.summaryMeter(tokenText: String?): String? {
    val context = contextPercent?.let { "${it.wholePercent()}% context" } ?: tokenText
    val changes = listOfNotNull(linesAdded?.let { "+$it" }, linesRemoved?.let { "−$it" })
        .joinToString(" ").takeIf(String::isNotBlank)
    return listOfNotNull(
        context ?: changes?.let { "$it changes" },
        totalCost?.let { "$$it" },
    ).joinToString(" · ").takeIf(String::isNotBlank)
}
