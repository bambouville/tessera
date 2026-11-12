package com.bambouville.tessera.feature.session

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.bambouville.tessera.agent.platform.AgentEndpointUnavailableReason
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

/**
 * The string resource ids behind an [AgentSessionIntegrationPresentation].
 * [detail] is the reason for an unavailable check; when present it is shown in
 * place of [message], translated when the coordinator or the endpoint named
 * its reason and verbatim when it is a host's own words.
 */
internal data class AgentSessionIntegrationCopy(
    val title: Int,
    val message: Int,
    val detail: String? = null,
    val actionLabel: Int? = null,
    val action: AgentSessionIntegrationAction? = null,
    val secondaryActionLabel: Int? = null,
    val secondaryAction: AgentSessionIntegrationAction? = null,
)

@Composable
internal fun AgentSessionIntegrationStatus.presentation(): AgentSessionIntegrationPresentation {
    val copy = integrationCopy()
    return AgentSessionIntegrationPresentation(
        title = stringResource(copy.title),
        message = copy.detail?.let { detailText() ?: endpointReasonText(it) } ?: stringResource(copy.message),
        actionLabel = copy.actionLabel?.let { stringResource(it) },
        action = copy.action,
        secondaryActionLabel = copy.secondaryActionLabel?.let { stringResource(it) },
        secondaryAction = copy.secondaryAction,
    )
}

/** [AgentSessionIntegrationStatus.detail] in the reader's language when the coordinator gave its reason; null for a host's own words. */
@Composable
private fun AgentSessionIntegrationStatus.detailText(): String? {
    val reason = detailReason ?: return null
    val argument = detailArgument?.let { endpointReasonText(it) }
    return if (argument == null) stringResource(reason.text) else stringResource(reason.text, argument)
}

/** An endpoint's [AgentEndpointUnavailableReason] in the reader's language; a code or a host's words as they came. */
@Composable
private fun endpointReasonText(reason: String): String =
    AgentEndpointUnavailableReason.textFor(reason)?.let { stringResource(it) } ?: reason

internal fun AgentSessionIntegrationStatus.integrationCopy(): AgentSessionIntegrationCopy = when (kind) {
    AgentSessionIntegrationKind.Checking -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_checking_title,
        message = R.string.session_integration_checking_message,
    )
    AgentSessionIntegrationKind.Ready -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_ready_title,
        message = R.string.session_integration_ready_message,
    )
    AgentSessionIntegrationKind.Missing -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_missing_title,
        message = when {
            !agentLifecycleDeliverable ->
                R.string.session_integration_install_message_plain_mosh
            foreground == AgentSessionIntegrationForeground.Agent && agentRequiresLifecycleHook != false ->
                R.string.session_integration_install_message_agent_relaunch
            foreground == AgentSessionIntegrationForeground.Agent ->
                R.string.session_integration_install_message_agent_center
            primaryAction == AgentSessionIntegrationAction.InstallAndApply ->
                R.string.session_integration_install_message_apply
            else ->
                R.string.session_integration_install_message_return_to_shell
        },
        actionLabel = if (primaryAction == AgentSessionIntegrationAction.InstallAndApply) {
            R.string.session_integration_install_and_enable
        } else {
            R.string.session_integration_install
        },
        action = primaryAction,
    )
    AgentSessionIntegrationKind.Outdated -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_outdated_title,
        message = when {
            !agentLifecycleDeliverable ->
                R.string.session_integration_update_message_plain_mosh
            foreground == AgentSessionIntegrationForeground.Agent && agentRequiresLifecycleHook != false ->
                R.string.session_integration_update_message_agent_relaunch
            foreground == AgentSessionIntegrationForeground.Agent ->
                R.string.session_integration_update_message_agent_center
            primaryAction == AgentSessionIntegrationAction.InstallAndApply ->
                R.string.session_integration_update_message_apply
            else ->
                R.string.session_integration_update_message_return_to_shell
        },
        actionLabel = if (primaryAction == AgentSessionIntegrationAction.InstallAndApply) {
            R.string.session_integration_update_and_enable
        } else {
            R.string.session_integration_update
        },
        action = primaryAction,
    )
    AgentSessionIntegrationKind.InactiveShell -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_inactive_title,
        message = R.string.session_integration_inactive_message,
        actionLabel = R.string.session_integration_enable_in_shell,
        action = primaryAction,
        secondaryActionLabel = R.string.session_integration_enable_automatically,
        secondaryAction = this.secondaryAction,
    )
    AgentSessionIntegrationKind.InsideAgent -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_inside_agent_title,
        message = R.string.session_integration_inside_agent_message,
    )
    AgentSessionIntegrationKind.AwayFromShell -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_away_title,
        message = R.string.session_integration_away_message,
    )
    AgentSessionIntegrationKind.UnsupportedShell -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_unsupported_shell_title,
        message = R.string.session_integration_unsupported_shell_message,
    )
    AgentSessionIntegrationKind.BusyProgram -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_busy_title,
        message = R.string.session_integration_busy_message,
    )
    AgentSessionIntegrationKind.ManualCheckRequired -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_manual_check_title,
        message = R.string.session_integration_manual_check_message,
        actionLabel = R.string.session_integration_check_now,
        action = primaryAction,
    )
    AgentSessionIntegrationKind.Repairing -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_repairing_title,
        message = R.string.session_integration_repairing_message,
    )
    AgentSessionIntegrationKind.Unavailable -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_unavailable_title,
        message = R.string.session_integration_unavailable_message,
        detail = detail,
        actionLabel = R.string.session_integration_retry,
        action = primaryAction,
    )
    // Deliberately action-free: installing would downgrade another device's
    // newer integration, and only an app update can make this host usable.
    AgentSessionIntegrationKind.AppUpdateRequired -> AgentSessionIntegrationCopy(
        title = R.string.session_integration_app_update_title,
        message = R.string.session_integration_app_update_message,
    )
}

internal val AgentSessionIntegrationAction.confirmationTitleRes: Int
    get() = when (this) {
        AgentSessionIntegrationAction.InstallAndApply -> R.string.session_integration_confirm_install_and_apply_title
        AgentSessionIntegrationAction.InstallOnly -> R.string.session_integration_confirm_install_only_title
        AgentSessionIntegrationAction.Apply -> R.string.session_integration_confirm_apply_title
        AgentSessionIntegrationAction.PersistAndApply -> R.string.session_integration_confirm_persist_title
        AgentSessionIntegrationAction.Check -> R.string.session_integration_confirm_check_title
        AgentSessionIntegrationAction.Retry -> R.string.session_integration_confirm_retry_title
    }

internal val AgentSessionIntegrationAction.confirmationMessageRes: Int
    get() = when (this) {
        AgentSessionIntegrationAction.InstallAndApply -> R.string.session_integration_confirm_install_and_apply_message
        AgentSessionIntegrationAction.InstallOnly -> R.string.session_integration_confirm_install_only_message
        AgentSessionIntegrationAction.Apply -> R.string.session_integration_confirm_apply_message
        AgentSessionIntegrationAction.PersistAndApply -> R.string.session_integration_confirm_persist_message
        AgentSessionIntegrationAction.Check,
        AgentSessionIntegrationAction.Retry,
        -> R.string.session_integration_confirm_check_message
    }

internal val AgentSessionIntegrationAction.confirmationLabelRes: Int
    get() = when (this) {
        AgentSessionIntegrationAction.InstallAndApply -> R.string.session_integration_install_and_enable
        AgentSessionIntegrationAction.InstallOnly -> R.string.session_integration_install
        AgentSessionIntegrationAction.Apply -> R.string.session_integration_enable_here
        AgentSessionIntegrationAction.PersistAndApply -> R.string.session_integration_enable_automatically
        AgentSessionIntegrationAction.Check -> R.string.session_integration_check
        AgentSessionIntegrationAction.Retry -> R.string.session_integration_retry
    }

@Composable
internal fun AgentSessionIntegrationAction.confirmationTitle(): String = stringResource(confirmationTitleRes)

@Composable
internal fun AgentSessionIntegrationAction.confirmationMessage(): String = stringResource(confirmationMessageRes)

@Composable
internal fun AgentSessionIntegrationAction.confirmationLabel(): String = stringResource(confirmationLabelRes)

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
