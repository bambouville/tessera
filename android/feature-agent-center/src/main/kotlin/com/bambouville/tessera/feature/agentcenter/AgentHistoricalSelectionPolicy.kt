package com.bambouville.tessera.feature.agentcenter

/**
 * Core lists only live routes. A bound owner can still safely project a
 * historical thread, so list replacement must not discard its local detail.
 */
internal data class AgentHistoricalSelection(
    val selectedThreadKey: String?,
    val retainedDetailKeys: Set<String>,
)

internal fun resolveAgentHistoricalSelection(
    previousSelection: String?,
    cachedDetailKeys: Set<String>,
    visibleRowKeys: List<String>,
    ownedThreadKeys: Set<String>,
): AgentHistoricalSelection {
    val visible = visibleRowKeys.toSet()
    val valid = visible + ownedThreadKeys
    return AgentHistoricalSelection(
        selectedThreadKey = previousSelection?.takeIf(valid::contains) ?: visibleRowKeys.firstOrNull(),
        retainedDetailKeys = cachedDetailKeys.intersect(valid),
    )
}
