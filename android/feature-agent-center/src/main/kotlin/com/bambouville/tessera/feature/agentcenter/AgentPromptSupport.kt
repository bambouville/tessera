package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.withoutTerminalEscapes
import java.lang.Long.toUnsignedString

/** Mirrors AgentPromptGrammar.actionToken(for:) in shared Core. */
internal fun livePromptActionToken(signature: String): String {
    var hash = 14695981039346656037UL
    for (byte in signature.encodeToByteArray()) {
        hash = (hash xor byte.toUByte().toULong()) * 1099511628211UL
    }
    return "live-prompt-${toUnsignedString(hash.toLong(), 16)}"
}

/**
 * Keep complete terminal rows at the bottom, bounded by UTF-8 bytes. A tmux
 * capture keeps its SGR (`capture-pane -e`); the grammar reads the cells, so
 * escapes go before the rows are bounded (AgentPromptGrammar.promptText).
 */
internal fun bottomPromptRows(tail: String, maximumBytes: Int = 16_384): String {
    val rows = withoutTerminalEscapes(tail).split('\n')
    var used = 0
    var first = rows.size
    for (index in rows.indices.reversed()) {
        val bytes = rows[index].encodeToByteArray().size + if (first == rows.size) 0 else 1
        if (used + bytes > maximumBytes) break
        used += bytes
        first = index
    }
    return if (first == rows.size) "" else rows.subList(first, rows.size).joinToString("\n")
}

internal fun boundedPromptCursor(line: String?): String? = line?.takeIf { it.isNotBlank() }
    ?.let { value ->
        val result = StringBuilder()
        var bytes = 0
        for (point in value.codePoints().toArray()) {
            val scalar = String(Character.toChars(point))
            val size = scalar.encodeToByteArray().size
            if (bytes + size > 2_048) break
            result.append(scalar)
            bytes += size
        }
        result.toString().takeIf(String::isNotBlank)
    }

internal fun promptPlanRefusalCode(refusal: String?): String = when (refusal) {
    "stalePrompt", "unsupported" -> "stalePrompt"
    "occupied" -> "terminalDraft"
    else -> "verification_failed"
}
