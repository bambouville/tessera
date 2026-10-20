package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentTmuxControlAck

/** Preserve physical rows: a cursor in a tall pane must index the same capture.
 * Oversized replies fail closed instead of looking like complete partial captures. */
internal fun agentTmuxControlReply(success: Boolean, lines: List<String>): AgentTmuxControlAck {
    var remaining = 65_536
    for (line in lines) {
        if (line.length >= remaining) return AgentTmuxControlAck(false, emptyList())
        remaining -= line.encodeToByteArray().size + 1
        if (remaining < 0) return AgentTmuxControlAck(false, emptyList())
    }
    return AgentTmuxControlAck(success, lines)
}
