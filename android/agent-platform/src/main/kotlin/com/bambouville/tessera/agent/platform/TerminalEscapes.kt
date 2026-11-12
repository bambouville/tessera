package com.bambouville.tessera.agent.platform

/**
 * Mirrors AgentPromptGrammar.withoutEscapes(_:keepingBackgrounds:) in shared
 * Core. `keepingBackgrounds` keeps one style, each cell's background and
 * reverse video, as `ESC[0;…m` where it changes and `ESC[0m` before a row
 * ends in one: every row then reads alone, as bounding keeps only the bottom ones.
 */
fun withoutTerminalEscapes(value: String, keepingBackgrounds: Boolean = false): String {
    if ('\u001b' !in value) return value
    val result = StringBuilder(value.length)
    var color: String? = null
    var reverse = false
    var background: String? = null
    var written: String? = null
    fun append(char: Char) {
        if (keepingBackgrounds) {
            val next = if (char == '\n') null else background
            if (next != written) {
                result.append("\u001b[0").append(next?.let { ";$it" } ?: "").append('m')
                written = next
            }
        }
        result.append(char)
    }
    var index = 0
    while (index < value.length) {
        val char = value[index++]
        if (char != '\u001b') { append(char); continue }
        if (index >= value.length) break
        val kind = value[index++]
        when (kind) {
            '[' -> {
                val start = index
                while (index < value.length && value[index].code in 0x20..0x3f) index++
                if (index < value.length && value[index].code in 0x40..0x7e) {
                    if (keepingBackgrounds && value[index] == 'm') {
                        val style = selectGraphicRendition(value.substring(start, index), color, reverse)
                        color = style.first
                        reverse = style.second
                        background = if (reverse) listOfNotNull("7", color).joinToString(";") else color
                    }
                    index++
                }
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
    if (keepingBackgrounds && written != null) result.append("\u001b[0m")
    return result.toString()
}

/**
 * The background and reverse video an SGR sequence leaves; every other style
 * is skipped, extended colours with their arguments.
 */
private fun selectGraphicRendition(parameters: String, color: String?, reverse: Boolean): Pair<String?, Boolean> {
    if (!parameters.all { it in '0'..'9' || it == ';' || it == ':' }) return color to reverse
    fun extended(values: List<String>): String? {
        val numbers = values.mapNotNull { it.toIntOrNull() }
        return when (values.firstOrNull()) {
            "5" -> if (values.size >= 2 && numbers.size >= 2 && numbers[1] in 0..255) "48;5;${numbers[1]}" else null
            "2" -> {
                val rgb = values.takeLast(3).mapNotNull { it.toIntOrNull() }
                if (values.size >= 4 && rgb.size == 3 && rgb.all { it in 0..255 }) "48;2;" + rgb.joinToString(";") else null
            }
            else -> null
        }
    }
    var background = color
    var reversed = reverse
    val parts = parameters.split(';')
    var index = 0
    while (index < parts.size) {
        val part = parts[index++]
        if (':' in part) {
            // `48:5:n`, `48:2::r:g:b`: one parameter with its arguments.
            val values = part.split(':')
            if (values.first() == "48") extended(values.drop(1))?.let { background = it }
            continue
        }
        val code = if (part.isEmpty()) 0 else part.toIntOrNull() ?: continue
        when (code) {
            0 -> { background = null; reversed = false }
            7 -> reversed = true
            27 -> reversed = false
            in 40..47, in 100..107 -> background = "$code"
            49 -> background = null
            38, 48, 58 -> {
                val count = when (parts.getOrNull(index)) { "5" -> 2; "2" -> 4; else -> 0 }
                val values = parts.subList(index, minOf(parts.size, index + count))
                if (code == 48) extended(values)?.let { background = it }
                index += values.size
            }
        }
    }
    return background to reversed
}
