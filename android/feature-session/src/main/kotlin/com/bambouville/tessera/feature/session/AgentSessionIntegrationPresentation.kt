package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentSessionIntegrationAction
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationForeground
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationKind
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationStatus
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationCheckPolicy
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged

internal data class AgentSessionIntegrationPresentation(
    val title: String,
    val message: String,
    val actionLabel: String? = null,
    val action: AgentSessionIntegrationAction? = null,
    val secondaryActionLabel: String? = null,
    val secondaryAction: AgentSessionIntegrationAction? = null,
)

internal fun AgentSessionIntegrationStatus.presentation(): AgentSessionIntegrationPresentation = when (kind) {
    AgentSessionIntegrationKind.Checking -> AgentSessionIntegrationPresentation(
        title = "Checking agent integration",
        message = "Reading the integration state for this terminal.",
    )
    AgentSessionIntegrationKind.Ready -> AgentSessionIntegrationPresentation(
        title = "Agent integration ready",
        message = "Lifecycle status is available for this terminal.",
    )
    AgentSessionIntegrationKind.Missing -> AgentSessionIntegrationPresentation(
        title = "Agent integration not installed",
        message = when {
            foreground == AgentSessionIntegrationForeground.Agent && agentRequiresLifecycleHook != false ->
                "Installs Tessera's helpers now. If this agent has not loaded the lifecycle hooks, relaunch it to enable status reporting."
            foreground == AgentSessionIntegrationForeground.Agent ->
                "Installs Tessera's Agent Center helpers. OpenCode or Pi inventory refreshes automatically when installation completes."
            primaryAction == AgentSessionIntegrationAction.InstallAndApply ->
                "Installs Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
            else ->
                "Installs Tessera's local hook files. Return to a bash or zsh prompt afterward to enable this terminal."
        },
        actionLabel = if (primaryAction == AgentSessionIntegrationAction.InstallAndApply) "Install and enable" else "Install integration",
        action = primaryAction,
    )
    AgentSessionIntegrationKind.Outdated -> AgentSessionIntegrationPresentation(
        title = "Agent integration needs an update",
        message = when {
            foreground == AgentSessionIntegrationForeground.Agent && agentRequiresLifecycleHook != false ->
                "Updates Tessera's helpers immediately without interrupting this agent. Existing hooks use the new scripts on their next event. If lifecycle status remains unavailable, relaunch the agent to load its hooks."
            foreground == AgentSessionIntegrationForeground.Agent ->
                "Updates Tessera's Agent Center helpers. OpenCode or Pi inventory refreshes automatically when installation completes."
            primaryAction == AgentSessionIntegrationAction.InstallAndApply ->
                "Updates Tessera's local hook files and PATH shims, then loads them here so future agents report accurate status."
            else ->
                "Updates Tessera's local hook files. Return to a bash or zsh prompt afterward to enable this terminal."
        },
        actionLabel = if (primaryAction == AgentSessionIntegrationAction.InstallAndApply) "Update and enable" else "Update integration",
        action = primaryAction,
    )
    AgentSessionIntegrationKind.InactiveShell -> AgentSessionIntegrationPresentation(
        title = "Agent integration inactive here",
        message = "Loads Tessera's shell marker here. Enable automatically also saves the guarded activation line in this shell's startup file for future windows.",
        actionLabel = "Enable in this shell",
        action = primaryAction,
        secondaryActionLabel = "Enable automatically",
        secondaryAction = this.secondaryAction,
    )
    AgentSessionIntegrationKind.InsideAgent -> AgentSessionIntegrationPresentation(
        title = "Agent lifecycle not yet confirmed",
        message = "The helpers are installed, but no trusted lifecycle event has arrived from this agent yet. Tessera rechecks as you use it. If status remains unavailable, relaunch the agent to load its hooks.",
    )
    AgentSessionIntegrationKind.AwayFromShell -> AgentSessionIntegrationPresentation(
        title = "Return to this terminal to enable integration",
        message = "Tessera will recheck this exact session when its shell is visible again.",
    )
    AgentSessionIntegrationKind.UnsupportedShell -> AgentSessionIntegrationPresentation(
        title = "Open bash or zsh to enable integration",
        message = "Tessera preserves other shell configurations and only sources its provider shims into bash or zsh.",
    )
    AgentSessionIntegrationKind.BusyProgram -> AgentSessionIntegrationPresentation(
        title = "Integration check paused",
        message = "Tessera will recheck when the foreground program returns to its shell.",
    )
    AgentSessionIntegrationKind.ManualCheckRequired -> AgentSessionIntegrationPresentation(
        title = "Check agent integration",
        message = "This transport needs a secondary read-only check before Tessera can verify the shell integration.",
        actionLabel = "Check now",
        action = primaryAction,
    )
    AgentSessionIntegrationKind.Repairing -> AgentSessionIntegrationPresentation(
        title = "Fixing agent integration",
        message = "This keeps future agent status accurate in Agent Center.",
    )
    AgentSessionIntegrationKind.Unavailable -> AgentSessionIntegrationPresentation(
        title = "Could not verify agent integration",
        message = detail ?: "The terminal-specific check failed. Tessera will retry after the next command.",
        actionLabel = "Retry",
        action = primaryAction,
    )
    // Deliberately action-free: installing would downgrade another device's
    // newer integration, and only an app update can make this host usable.
    AgentSessionIntegrationKind.AppUpdateRequired -> AgentSessionIntegrationPresentation(
        title = "Update Tessera for this host",
        message = "This host's Agent Center integration comes from a newer Tessera. " +
            "Update this app to keep agent status accurate.",
    )
}

internal fun AgentSessionIntegrationAction.confirmationTitle(): String = when (this) {
    AgentSessionIntegrationAction.InstallAndApply -> "Install or update and enable integration?"
    AgentSessionIntegrationAction.InstallOnly -> "Install or update integration?"
    AgentSessionIntegrationAction.Apply -> "Enable integration here?"
    AgentSessionIntegrationAction.PersistAndApply -> "Enable integration automatically?"
    AgentSessionIntegrationAction.Check -> "Check agent integration?"
    AgentSessionIntegrationAction.Retry -> "Retry integration check?"
}

internal fun AgentSessionIntegrationAction.confirmationMessage(): String = when (this) {
    AgentSessionIntegrationAction.InstallAndApply ->
        "Writes Tessera hook files and provider shims, then loads them when this exact terminal is at an empty bash or zsh prompt. It never types into a running agent or another program."
    AgentSessionIntegrationAction.InstallOnly ->
        "Writes Tessera hook files and provider shims without typing into the running foreground program. Helper updates take effect immediately. Relaunch is only needed if the agent has not loaded its lifecycle hooks."
    AgentSessionIntegrationAction.Apply ->
        "Types one guarded source command so agents launched here report precise status. Continue only at an empty bash or zsh prompt."
    AgentSessionIntegrationAction.PersistAndApply ->
        "Adds one guarded activation line to this exact shell's startup file, then loads it here. Continue only at an empty bash or zsh prompt."
    AgentSessionIntegrationAction.Check,
    AgentSessionIntegrationAction.Retry ->
        "Runs a read-only host check to verify the integration state for this terminal."
}

internal fun AgentSessionIntegrationAction.confirmationLabel(): String = when (this) {
    AgentSessionIntegrationAction.InstallAndApply -> "Install and enable"
    AgentSessionIntegrationAction.InstallOnly -> "Install integration"
    AgentSessionIntegrationAction.Apply -> "Enable here"
    AgentSessionIntegrationAction.PersistAndApply -> "Enable automatically"
    AgentSessionIntegrationAction.Check -> "Check"
    AgentSessionIntegrationAction.Retry -> "Retry"
}

/** Mirrors Core's `warningPresentationDelayMilliseconds` for previews and
 * tests where the shared policy ABI is not loaded. */
internal const val FALLBACK_INTEGRATION_WARNING_DELAY_MILLIS = 5_000L

/** Core owns how long a warning must hold before any chrome surfaces it. */
internal fun integrationWarningPresentationDelayMillis(): Long = runCatching {
    SharedAgentIntegrationCheckPolicy.warningPresentationDelayMillis
}.getOrDefault(FALLBACK_INTEGRATION_WARNING_DELAY_MILLIS)

/**
 * Presents a warning, identified by whose warning it is (a session key), only
 * after the upstream has named it continuously for [holdMillis]. Probes,
 * reconnects and foreground changes pass through warning states on the way to
 * ready; surfacing each one would flash chrome. `null` (no warning) is
 * forwarded at once and cancels any pending onset. Any change of value hides
 * the old one and starts a fresh hold, so another session's warning never
 * inherits this one's.
 */
internal fun <T : Any> Flow<T?>.presentedAfterContinuousHold(holdMillis: Long): Flow<T?> {
    require(holdMillis >= 0)
    val upstream = distinctUntilChanged()
    return channelFlow {
        upstream.collectLatest { raw ->
            if (raw != null && holdMillis > 0) {
                send(null)
                delay(holdMillis)
            }
            send(raw)
        }
    }.distinctUntilChanged()
}
