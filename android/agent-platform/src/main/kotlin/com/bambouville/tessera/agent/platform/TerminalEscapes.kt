package com.bambouville.tessera.agent.platform

/** Mirrors AgentPromptGrammar.withoutEscapes(_:) in shared Core. */
fun withoutTerminalEscapes(value: String): String {
    if ('\u001b' !in value) return value
    val result = StringBuilder(value.length)
    var index = 0
    while (index < value.length) {
        val char = value[index++]
        if (char != '\u001b') { result.append(char); continue }
        if (index >= value.length) break
        val kind = value[index++]
        when (kind) {
            '[' -> {
                while (index < value.length && value[index].code in 0x20..0x3f) index++
                if (index < value.length && value[index].code in 0x40..0x7e) index++
            }
            ']', 'P', 'X', '^', '_' -> {
                // Ends at BEL or ST (`ESC \`); another ESC starts a new sequence.
                while (index < value.length && value[index] != '\n') {
                    if (value[index] == '\u0007') { index++; break }
                    if (value[index] == '\u001b') {
                        if (index + 1 < value.length && value[index + 1] == '\\') index += 2
                        break
                    }
                    index++
                }
            }
            else -> when (kind.code) {
                // `ESC ( B` designates a character set; `ESC 7` and `ESC =` stand alone.
                in 0x20..0x2f -> {
                    while (index < value.length && value[index].code in 0x20..0x2f) index++
                    if (index < value.length && value[index].code in 0x30..0x7e) index++
                }
                in 0x30..0x7e -> Unit
                // Not an escape: keep the newline, glyph or ESC that follows.
                else -> index--
            }
        }
    }
    return result.toString()
}
