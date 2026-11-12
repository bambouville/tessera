package com.bambouville.tessera.feature.pairing

import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.animation.animateColorAsState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.DisplayText
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.design.text

import com.bambouville.tessera.core.bridge.SharedSetupFlow

@Composable
internal fun PairingHeading(title: String, detail: String) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.headlineSmall.copy(fontFamily = FontFamily.SansSerif), color = tokens.fg)
        Text(detail, style = MaterialTheme.typography.bodyLarge, color = tokens.fgMuted)
    }
}

@Composable
internal fun PairingSecurityCode(digits: String) {
    val tokens = LocalTesseraTokens.current
    Surface(shape = RoundedCornerShape(20.dp), color = tokens.panelBg, modifier = Modifier.fillMaxWidth()) {
        BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            val size = minOf(42f, (maxWidth.value - 32f) / 4.5f / LocalDensity.current.fontScale)
            Text(digits, fontSize = size.sp, letterSpacing = (size / 7).sp, fontFamily = FontFamily.Monospace,
                maxLines = 1, textAlign = TextAlign.Center, color = tokens.fg, modifier = Modifier.padding(vertical = 28.dp))
        }
    }
}

@Composable
internal fun PairingSteps(presentation: SharedSetupFlow.Output) {
    val tokens = LocalTesseraTokens.current
    val step = presentation.stages.indexOf(presentation.currentStage)
    val titles = presentation.stages.map { stage ->
        stringResource(when (stage) {
                SharedSetupFlow.Stage.scan -> R.string.setup_stage_scan; SharedSetupFlow.Stage.discover -> R.string.setup_stage_discover
                SharedSetupFlow.Stage.verify -> R.string.setup_stage_verify; SharedSetupFlow.Stage.choose -> R.string.setup_stage_choose
                SharedSetupFlow.Stage.transfer -> R.string.setup_stage_transfer; SharedSetupFlow.Stage.connect -> R.string.setup_stage_connect
        })
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Keep text at the user's chosen size: narrow/large-text layouts show
        // the current stage once, rather than breaking every label mid-word.
        val compact = maxWidth.value / LocalDensity.current.fontScale < presentation.stages.size * 76f
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                titles.forEachIndexed { index, title ->
                    val color by animateColorAsState(if (index <= step) tokens.fg else tokens.border)
                    Column(Modifier.weight(1f).semantics(mergeDescendants = true) {
                        contentDescription = title
                        selected = index == step
                    }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(color))
                        if (!compact) Text(title, style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.SansSerif), color = if (index == step) tokens.fg else tokens.fgMuted)
                    }
                }
            }
            if (compact && step in titles.indices) Text(
                stringResource(R.string.setup_current_stage, titles[step], step + 1, titles.size),
                style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.SansSerif), color = tokens.fg,
            )
        }
    }
}

@Composable
internal fun PairingSelectionReview(
    current: PairingUiState.AwaitingOwnerApproval,
    presentation: SharedSetupFlow.Output,
    reviewStep: Int, onStep: (Int) -> Unit,
    onHost: (String, Boolean) -> Unit, onTrusted: (Boolean) -> Unit,
    onOptional: (String, Boolean) -> Unit,
    ownerAuthorizationError: DisplayText?, onApprove: () -> Unit, onCancel: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {

                    if (current.hosts.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(
                            stringResource(R.string.pairing_review_tab_hosts),
                            stringResource(R.string.pairing_review_tab_include),
                            stringResource(R.string.pairing_review_tab_review),
                        ).forEachIndexed { index, title ->
                            FilterChip(selected = reviewStep == index, onClick = { onStep(index) }, label = { Text(title) })
                        }
                    }
                    if (current.hosts.isEmpty() || reviewStep == 2) {
                    PairingHeading(stringResource(R.string.pairing_ready_to_copy_title), stringResource(R.string.pairing_ready_to_copy_detail))
                    Text(current.summary.text(), style = TesseraType.body, color = tokens.fg)
                    current.hosts.filter { it.id in presentation.copiedHostIds }.forEach { Text(it.name, style = MaterialTheme.typography.bodyLarge, color = tokens.fg) }
                    if (current.hosts.isNotEmpty()) {
                        Text(pluralStringResource(R.plurals.setup_grants_selected, presentation.grantedHostIds.size, presentation.grantedHostIds.size), color = tokens.fgMuted)
                        Text(pluralStringResource(R.plurals.setup_categories_selected, current.selectedOptionalTransfers.size, current.selectedOptionalTransfers.size), color = tokens.fgMuted)
                    }
                    if ("trustedHostKeys" in current.selectedOptionalTransfers) Text(stringResource(R.string.pairing_includes_trusted_server_keys), color = tokens.fgMuted)
                    current.selectedOptionalTransfers.filter { it != "trustedHostKeys" }.forEach {
                        Text(when (it) {
                            "launchCommands" -> stringResource(R.string.pairing_includes_launch_commands)
                            "environmentVariables" -> stringResource(R.string.pairing_includes_environment_variables)
                            "startupSnippets" -> stringResource(R.string.pairing_includes_startup_snippets)
                            "notes" -> stringResource(R.string.pairing_includes_notes)
                            else -> stringResource(R.string.pairing_includes_other, it)
                        }, color = tokens.fgMuted)
                    }
                    current.recipientFingerprint?.let { fingerprint ->
                        TesseraKicker(stringResource(R.string.pairing_recipient_key_kicker))
                        Text(fingerprint, style = TesseraType.code, color = tokens.fgMuted)
                        if (current.recipientUsesSoftwareKey) Text(
                            stringResource(R.string.pairing_software_key_warning),
                            style = TesseraType.body,
                            color = tokens.amber,
                        )
                    }
                    }
                    if (current.hosts.isNotEmpty() && reviewStep == 0) {
                        PairingHeading(stringResource(R.string.pairing_choose_hosts_title), stringResource(R.string.pairing_choose_hosts_detail))
                        TesseraKicker(stringResource(R.string.pairing_hosts_to_copy_kicker))
                        Text(
                            stringResource(R.string.pairing_hosts_to_copy_detail),
                            style = TesseraType.body,
                            color = tokens.fgMuted,
                        )
                    current.hosts.forEach { host ->
                        TesseraToggleRow(
                            title = host.name,
                            subtitle = host.endpoint,
                            checked = host.id in current.selectedHostIds,
                            onCheckedChange = { onHost(host.id, it) },
                            contentPadding = PaddingValues(vertical = 8.dp),
                        )
                    }
                    TesseraButton(stringResource(R.string.pairing_next_choose_data), { onStep(1) }, style = TesseraButtonStyle.Primary, enabled = presentation.allows(SharedSetupFlow.Action.approve))
                    }
                    if (current.hosts.isNotEmpty() && reviewStep == 1) {
                        PairingHeading(stringResource(R.string.pairing_familiar_title), stringResource(R.string.pairing_familiar_detail))
                        TesseraToggleRow(
                            title = stringResource(R.string.pairing_trusted_server_keys),
                            subtitle = stringResource(R.string.pairing_trusted_server_keys_detail),
                            checked = "trustedHostKeys" in current.selectedOptionalTransfers,
                            onCheckedChange = onTrusted,
                        )
                        listOf(
                            "launchCommands" to stringResource(R.string.pairing_launch_commands),
                            "notes" to stringResource(R.string.pairing_notes),
                            "environmentVariables" to stringResource(R.string.pairing_environment_variables),
                            "startupSnippets" to stringResource(R.string.pairing_startup_snippets),
                        ).forEach { (category, label) ->
                            TesseraToggleRow(title = label,
                                subtitle = stringResource(R.string.pairing_optional_data_detail),
                                checked = category in current.selectedOptionalTransfers,
                                onCheckedChange = { onOptional(category, it) })
                        }
                        TesseraButton(stringResource(R.string.pairing_next_review_transfer), { onStep(2) }, style = TesseraButtonStyle.Primary)
                    }
                    if (current.hosts.isEmpty() || reviewStep == 2) {
                    ownerAuthorizationError?.let { Text(it.text(), style = TesseraType.body, color = tokens.red) }
                    if (current.hosts.isNotEmpty() && current.selectedHostIds.isEmpty()) Text(
                        stringResource(R.string.pairing_select_one_host),
                        style = TesseraType.body,
                        color = tokens.amber,
                    )
                    TesseraButton(stringResource(R.string.pairing_approve_source_access), {
                        onApprove()
                    }, style = TesseraButtonStyle.Primary,
                        enabled = presentation.allows(SharedSetupFlow.Action.approve))
                    }
                    TesseraButton(stringResource(R.string.pairing_cancel), onCancel, style = TesseraButtonStyle.Default)
    }
}

@Composable
internal fun PairingVerification(digits: String, waiting: Boolean, confirm: () -> Unit, reject: () -> Unit, cancel: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        PairingHeading(stringResource(if (waiting) R.string.pairing_confirm_other_title else R.string.pairing_codes_match_title),
            stringResource(if (waiting) R.string.pairing_confirm_other_detail else R.string.pairing_codes_match_detail))
        PairingSecurityCode(digits)
        if (waiting) {
            PairingProgress(stringResource(R.string.pairing_waiting_other_title), stringResource(R.string.pairing_waiting_other_detail))
            TesseraButton(stringResource(R.string.pairing_cancel), cancel, style = TesseraButtonStyle.Default)
        } else {
            TesseraButton(stringResource(R.string.pairing_codes_match), confirm, style = TesseraButtonStyle.Primary)
            TesseraButton(stringResource(R.string.pairing_codes_differ), reject, style = TesseraButtonStyle.Danger)
        }
    }
}

@Composable
internal fun PairingProgress(title: String, detail: String) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        PairingHeading(title, detail)
        CircularProgressIndicator(color = tokens.fg, modifier = Modifier.size(28.dp), strokeWidth = 2.dp)
    }
}

@Composable
internal fun PairingAccessReceipt(hosts: List<PairingReceiptHost>) {
    val tokens = LocalTesseraTokens.current
    hosts.forEach { host ->
        val label = when (host.outcome) {
            SharedSetupFlow.Outcome.authorized -> R.string.setup_access_authorized
            SharedSetupFlow.Outcome.alreadyAuthorized -> R.string.setup_access_already_authorized
            SharedSetupFlow.Outcome.configurationCopied -> R.string.setup_access_copied
            SharedSetupFlow.Outcome.passwordNeeded -> R.string.setup_access_password
            SharedSetupFlow.Outcome.failed -> R.string.setup_access_failed
            SharedSetupFlow.Outcome.skipped -> R.string.setup_access_skipped
            SharedSetupFlow.Outcome.notSelected -> R.string.setup_access_not_selected
            SharedSetupFlow.Outcome.notImported -> R.string.setup_access_not_imported
            SharedSetupFlow.Outcome.excluded -> R.string.setup_access_excluded
            SharedSetupFlow.Outcome.uncertain -> R.string.setup_access_uncertain
        }
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(host.name, style = MaterialTheme.typography.bodyLarge, color = tokens.fg)
            Text(stringResource(label), style = MaterialTheme.typography.labelMedium,
                color = when (host.outcome) {
                    SharedSetupFlow.Outcome.failed -> tokens.red
                    SharedSetupFlow.Outcome.uncertain -> tokens.amber
                    else -> tokens.fgMuted
                })
        }
    }
}

internal fun pairingFailureMessage(reason: SharedSetupFlow.FailureReason?): DisplayText = DisplayText.Resource(when (reason) {
    SharedSetupFlow.FailureReason.expired -> R.string.setup_failure_expired
    SharedSetupFlow.FailureReason.codeMismatch -> R.string.setup_failure_mismatch
    SharedSetupFlow.FailureReason.disconnected -> R.string.setup_failure_disconnected
    SharedSetupFlow.FailureReason.locked -> R.string.setup_failure_locked
    SharedSetupFlow.FailureReason.policyChanged -> R.string.setup_failure_policy
    SharedSetupFlow.FailureReason.protocolError -> R.string.setup_failure_protocol
    else -> R.string.setup_failure_other
})
