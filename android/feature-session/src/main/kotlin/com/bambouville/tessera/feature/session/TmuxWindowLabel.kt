package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxWindow

/**
 * Mirrors Swift TmuxWindowSnapshot.agentDisplayName beside displayName in
 * Packages/TmuxControl/Sources/TmuxControlCore/Snapshot.swift.
 * A chosen window name survives provider discovery; auto-named shells use the verified provider.
 */
internal fun SharedTmuxWindow.agentDisplayName(
    agentProvider: (paneId: Int) -> String? = { null },
): String {
    val activePane = panes.firstOrNull { it.id == activePaneId } ?: panes.firstOrNull { it.active }
    val name = name?.trim()?.takeIf { it.isNotEmpty() }
    val command = activePane?.currentCommand?.trim()?.takeIf { it.isNotEmpty() }
    val provider = (activePaneId ?: activePane?.id)?.let(agentProvider)?.trim()?.takeIf { it.isNotEmpty() }
    return activePaneTitle?.trim()?.takeIf { !activePaneTitleIsDefault && it.isNotEmpty() }
        ?: name?.takeIf { it != command }
        ?: provider
        ?: name
        ?: "@$id"
}
