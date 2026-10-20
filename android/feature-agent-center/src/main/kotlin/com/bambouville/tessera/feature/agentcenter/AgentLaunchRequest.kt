package com.bambouville.tessera.feature.agentcenter

/**
 * UI-owned launch intent.  It deliberately contains only user selections and
 * the currently displayed target identity; the session endpoint remains the
 * authority which revalidates all of it before it starts a remote process.
 */
data class AgentLaunchRequest(
    val kind: AgentLaunchKind,
    val task: String,
    val name: String?,
    val providerID: String,
    val target: AgentLaunchTarget,
    val directory: String,
    val placement: AgentLaunchPlacement,
    val isolation: AgentLaunchIsolation,
)

enum class AgentLaunchKind { Spawn, Fork }

data class AgentLaunchTarget(
    val liveSessionID: String,
    val carrierGeneration: Long,
    val hostID: String,
    val transport: String,
    val hostLabel: String,
    val tmuxSession: String?,
    val windowID: String?,
    val paneID: String?,
    val provenDirectories: List<String>,
)

enum class AgentLaunchPlacement { NewWindow, SplitRight, SplitDown }

sealed interface AgentLaunchIsolation {
    data object CurrentWorktree : AgentLaunchIsolation
    data class NewWorktree(val branch: String) : AgentLaunchIsolation
}

/** Mutable sheet state kept separate from the shared reducer. */
internal data class AgentLaunchDraft(
    val task: String = "",
    val name: String = "",
    val directory: String = "",
    val placement: AgentLaunchPlacement = AgentLaunchPlacement.NewWindow,
    val newWorktree: Boolean = false,
    val branch: String = "",
)

/**
 * This is intentionally conservative.  In particular a split cannot be
 * fabricated from a generic SSH binding: it needs the exact window and pane
 * that the later endpoint implementation will lease and compare.
 */
internal fun AgentLaunchDraft.toRequestOrNull(
    kind: AgentLaunchKind,
    providerID: String,
    target: AgentLaunchTarget?,
): AgentLaunchRequest? {
    val trimmedTask = task.trim().takeIf { it.isNotEmpty() && it.length <= 32_768 } ?: return null
    val trimmedDirectory = directory.trim().takeIf { it.isNotEmpty() && it.length <= 4_096 } ?: return null
    val validTarget = target?.takeIf { it.liveSessionID.isNotBlank() && providerID.isNotBlank() && it.provenDirectories.isNotEmpty() } ?: return null
    if (trimmedDirectory !in validTarget.provenDirectories) return null
    if (placement != AgentLaunchPlacement.NewWindow &&
        (validTarget.windowID.isNullOrBlank() || validTarget.paneID.isNullOrBlank())
    ) return null
    val isolation = if (newWorktree) {
        val trimmedBranch = branch.trim().takeIf { it.isNotEmpty() && it.length <= 255 } ?: return null
        AgentLaunchIsolation.NewWorktree(trimmedBranch)
    } else {
        AgentLaunchIsolation.CurrentWorktree
    }
    return AgentLaunchRequest(
        kind = kind,
        task = trimmedTask,
        name = name.trim().takeIf { it.isNotEmpty() }?.take(255),
        providerID = providerID,
        target = validTarget,
        directory = trimmedDirectory,
        placement = placement,
        isolation = isolation,
    )
}

internal fun AgentThreadDetail.launchTargetOrNull(): AgentLaunchTarget? {
    val binding = binding ?: return null
    return AgentLaunchTarget(
        liveSessionID = binding.string("liveSessionID") ?: return null,
        carrierGeneration = binding.number("carrierGeneration")?.toLongOrNull() ?: return null,
        // hostID is deliberately a ThreadID field in the shared ABI rather
        // than a duplicated field in the endpoint binding.
        hostID = row.hostID.takeIf(String::isNotBlank) ?: return null,
        transport = binding.string("transport") ?: return null,
        hostLabel = row.hostID.ifBlank { "connected host" },
        tmuxSession = binding.string("tmuxSession"),
        windowID = binding.string("windowID"),
        paneID = binding.string("paneID"),
        provenDirectories = provenDirectories.filter(::validProvenDirectory),
    )
}

internal fun validProvenDirectory(value: String): Boolean = value.isNotEmpty() && value.encodeToByteArray().size <= 2_048 &&
    (value.startsWith('/') || value.startsWith("~/")) && value.none { it == '\u0000' || it.code < 0x20 || it.code == 0x7f } &&
    value.split('/').none { it == ".." }
