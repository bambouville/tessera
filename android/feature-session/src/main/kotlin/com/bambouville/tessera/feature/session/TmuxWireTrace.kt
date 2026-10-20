package com.bambouville.tessera.feature.session

/**
 * Bounded, secret-safe evidence of what actually crossed the tmux control
 * wire at attach.
 *
 * Every earlier "attaching pane" diagnosis was reasoned from the ledger's own
 * summary of a reply it could not parse. The summary cannot say whether the
 * host replaced the tab separators, dropped them, or answered a different
 * command altogether, and the diagnostics sink strips control characters, so
 * the raw line has to be escaped before it is recorded. The trace is a fixed
 * number of lines per attachment, and pane content never enters it: `%output`
 * payloads and capture bodies are reduced to their length.
 */
internal const val TMUX_WIRE_TRACE_LINES = 200
internal const val TMUX_WIRE_TRACE_SENDS = 48

private const val ESCAPE = '\u001b'
private const val DELETE = '\u007f'

/** `text` with separators and control bytes escaped, cut at [limit] with an ellipsis. */
internal fun tmuxWireSnippet(text: String, limit: Int): String {
    val out = StringBuilder()
    var count = 0
    for (ch in text) {
        if (count >= limit) {
            out.append('…')
            break
        }
        count += 1
        when {
            ch == '\t' -> out.append("\\t")
            ch == '\r' -> out.append("\\r")
            ch == '\n' -> out.append("\\n")
            ch == ESCAPE -> out.append("\\e")
            ch == '\\' -> out.append("\\\\")
            ch < ' ' || ch == DELETE -> out.append("\\x").append(ch.code.toString(16).padStart(2, '0'))
            else -> out.append(ch)
        }
    }
    return out.toString()
}

private val ECHOED_COMMAND_VERBS = listOf(
    "display-message", "list-windows", "list-panes", "list-clients", "refresh-client",
    "show-options", "set-option", "select-window", "select-pane", "capture-pane",
    "resize-window", "rename-window", "new-window", "kill-window", "split-window", "send-keys",
)

/**
 * The recordable form of one received line, or null when the line carries
 * nothing a diagnosis needs.
 *
 * Kept: notifications and frame guards (`%begin`/`%end`/`%error`/`%layout-…`),
 * the tagged hydration rows (`__tessera_…`), rendered-pane metadata rows
 * (`%3\t…`, or their mangled twins), bare ids (`@3`, `$0`), the control-mode
 * DCS, and command text a cooked pty echoed back before tmux took the tty.
 * Withheld: `%output` payloads and every other body line, which is screen
 * content — only their length is recorded.
 */
internal fun tmuxWireTraceLine(line: String): String? {
    if (line.isEmpty()) return null
    if (line.startsWith("%output ") || line.startsWith("%extended-output ")) {
        val header = line.split(' ', limit = 3)
        return "${header[0]} ${header.getOrElse(1) { "" }} len=${header.getOrElse(2) { "" }.length}"
    }
    if (line.startsWith("%") || line.startsWith("@") || line.startsWith("$") ||
        line.startsWith("__tessera_") || line.startsWith(ESCAPE)
    ) return tmuxWireSnippet(line, 240)
    val verb = ECHOED_COMMAND_VERBS.firstOrNull { line.startsWith(it) }
    if (verb != null) return tmuxWireSnippet(tmuxWireTraceCommand(line), 240)
    return "body len=${line.length}"
}

/** A command as it may be recorded: a `send-keys` payload is user input and stays out. */
internal fun tmuxWireTraceCommand(command: String): String =
    if (command.startsWith("send-keys")) "send-keys …" else command
