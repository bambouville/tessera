package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentSessionDirectory
import com.bambouville.tessera.agent.platform.AgentSessionKey
import org.json.JSONObject

/**
 * Match iOS's verified thread-route projection, rather than process discovery or
 * list rows: the snapshot must still hold the owner's exact Core binding and
 * the endpoint registration that proved it must still own that pane route.
 */
internal fun derivePaneAgentProviders(
    enabled: Boolean,
    details: Map<String, AgentThreadDetail>,
    owners: Map<String, AgentCenterPresenter.ThreadOwner>,
    directory: AgentSessionDirectory,
): Map<AgentSessionKey, Map<Int, String>> {
    if (!enabled) return emptyMap()
    val providers = linkedMapOf<Pair<AgentSessionKey, Int>, String>()
    val ambiguous = mutableSetOf<Pair<AgentSessionKey, Int>>()
    for ((threadKey, owner) in owners) {
        val detail = details[threadKey] ?: continue
        val binding = owner.endpointBinding ?: continue
        val paneId = binding.paneID?.removePrefix("%")?.toIntOrNull() ?: continue
        val endpoint = owner.endpoint ?: continue
        if (binding.key != owner.endpointKey || directory.resolve(owner.endpointKey) !== endpoint ||
            !endpoint.isCurrentRoute(binding) ||
            !JSONObject(owner.coreBindingJSON).sameCoreBinding(detail.binding?.toJson())) continue
        val provider = JSONObject(owner.threadID).optJSONObject("providerID")?.optString("rawValue")
            ?.takeIf { it.isNotBlank() && it == detail.row.providerID } ?: continue
        val key = binding.key to paneId
        if (providers[key]?.let { it != provider } == true) ambiguous.add(key)
        providers[key] = provider
    }
    return providers.entries.filterNot { it.key in ambiguous }
        .groupBy({ it.key.first }, { it.key.second to it.value })
        .mapValues { (_, panes) -> panes.toMap() }
}
