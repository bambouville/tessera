package com.bambouville.tessera

import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.feature.agentcenter.AgentCenterUiState
import com.bambouville.tessera.feature.agentcenter.targetsLiveSession
import com.bambouville.tessera.feature.session.ProgramStatusAgentInput
import com.bambouville.tessera.feature.session.ProgramStatusAgentPane
import com.bambouville.tessera.feature.session.ProgramStatusPaneRef

/** Shared Core's attention verdicts, with bindings only to the app's existing live carriers. */
internal fun programStatusAgentInput(
    state: AgentCenterUiState,
    liveSessionIds: Map<String, String>,
): ProgramStatusAgentInput {
    val panes = mutableMapOf<ProgramStatusPaneRef, ProgramStatusAgentPane>()
    state.threads.forEach { row ->
        // Summary rows have no binding; projection details need no detail-screen visit.
        val detail = state.projectedDetails[row.key]?.takeIf { it.binding != null }
            ?: state.detail?.takeIf { it.row.key == row.key && it.binding != null }
            ?: return@forEach
        if (detail.row.key != row.key) return@forEach
        val hostId = liveSessionIds.keys.firstOrNull { detail.targetsLiveSession(it, liveSessionIds[it]) }
            ?: return@forEach
        val binding = detail.binding ?: return@forEach
        val transport = (binding.fields["transport"] as? SharedAgentValue.StringValue)?.value
        val raw = transport == "ssh" || transport == "mosh"
        if (!raw && transport != "sshTmux" && transport != "moshTmux") return@forEach
        val paneId = if (raw) null else {
            binding.terminalNumber("paneID", '%') ?: return@forEach
        }
        val windowId = if (raw) null else binding.terminalNumber("windowID", '@')
        val ref = ProgramStatusPaneRef(hostId, paneId)
        val previous = panes[ref]
        panes[ref] = ProgramStatusAgentPane(
            windowId = windowId ?: previous?.windowId,
            needsInput = row.attention == "needsYou" || previous?.needsInput == true,
            unreadCompletion = row.attention == "unreadCompletion" || previous?.unreadCompletion == true,
        )
    }
    // These are the same reduced attention fields Agent Center uses for its needs-you/finished groups.
    return ProgramStatusAgentInput(
        waiting = state.threads.count { it.attention == "needsYou" },
        finished = state.threads.count { it.attention == "unreadCompletion" },
        panes = panes,
    )
}

private fun SharedAgentValue.ObjectValue.terminalNumber(name: String, prefix: Char): Int? =
    (fields[name] as? SharedAgentValue.StringValue)?.value
        ?.removePrefix(prefix.toString())?.takeIf { it.isNotEmpty() && it.all(Char::isDigit) }
        ?.toIntOrNull()
