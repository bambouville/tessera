package com.bambouville.tessera.feature.pairing

import android.content.Context
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
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType

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
    ownerAuthorizationError: String?, onApprove: () -> Unit, onCancel: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {

                    if (current.hosts.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("Hosts", "Include", "Review").forEachIndexed { index, title ->
                            FilterChip(selected = reviewStep == index, onClick = { onStep(index) }, label = { Text(title) })
                        }
                    }
                    if (current.hosts.isEmpty() || reviewStep == 2) {
                    PairingHeading("Ready to copy", "Review this transfer. Passwords and private keys never leave this device.")
                    Text(current.summary, style = TesseraType.body, color = tokens.fg)
                    current.hosts.filter { it.id in presentation.copiedHostIds }.forEach { Text(it.name, style = MaterialTheme.typography.bodyLarge, color = tokens.fg) }
                    if (current.hosts.isNotEmpty()) {
                        Text(pluralStringResource(R.plurals.setup_grants_selected, presentation.grantedHostIds.size, presentation.grantedHostIds.size), color = tokens.fgMuted)
                        Text(pluralStringResource(R.plurals.setup_categories_selected, current.selectedOptionalTransfers.size, current.selectedOptionalTransfers.size), color = tokens.fgMuted)
                    }
                    if ("trustedHostKeys" in current.selectedOptionalTransfers) Text("Includes trusted server keys", color = tokens.fgMuted)
                    current.selectedOptionalTransfers.filter { it != "trustedHostKeys" }.forEach {
                        Text("Includes " + when (it) { "launchCommands" -> "launch commands"; "environmentVariables" -> "environment variables"; "startupSnippets" -> "startup snippets"; else -> it }, color = tokens.fgMuted)
                    }
                    current.recipientFingerprint?.let { fingerprint ->
                        TesseraKicker("recipient public key")
                        Text(fingerprint, style = TesseraType.code, color = tokens.fgMuted)
                        if (current.recipientUsesSoftwareKey) Text(
                            "Software-backed key. It is not hardware protected; grant access only to hosts you intend this device to use.",
                            style = TesseraType.body,
                            color = tokens.amber,
                        )
                    }
                    }
                    if (current.hosts.isNotEmpty() && reviewStep == 0) {
                        PairingHeading("Choose your hosts", "Choose which hosts to copy. Required jump hosts are included with their routes.")
                        TesseraKicker("hosts to copy")
                        Text(
                            "An unselected host is not copied at all. Deselecting a host also drops any host that routes through it, so what is checked is exactly what is copied.",
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
                    TesseraButton("next: choose data", { onStep(1) }, style = TesseraButtonStyle.Primary, enabled = presentation.allows(SharedSetupFlow.Action.approve))
                    }
                    if (current.hosts.isNotEmpty() && reviewStep == 1) {
                        PairingHeading("Make it feel familiar", "Host addresses, jump routes, local port forwards, terminal font, scrollback, and bell settings are included.")
                        TesseraToggleRow(
                            title = "trusted server keys",
                            subtitle = "Trust the same servers on the receiving device. Existing conflicting keys are preserved for review. Off by default.",
                            checked = "trustedHostKeys" in current.selectedOptionalTransfers,
                            onCheckedChange = onTrusted,
                        )
                        listOf("launchCommands" to "launch commands", "notes" to "notes", "environmentVariables" to "environment variables", "startupSnippets" to "startup snippets").forEach { (category, label) ->
                            TesseraToggleRow(title = label,
                                subtitle = "May contain sensitive data or executable shell text. Off by default.",
                                checked = category in current.selectedOptionalTransfers,
                                onCheckedChange = { onOptional(category, it) })
                        }
                        TesseraButton("next: review transfer", { onStep(2) }, style = TesseraButtonStyle.Primary)
                    }
                    if (current.hosts.isEmpty() || reviewStep == 2) {
                    ownerAuthorizationError?.let { Text(it, style = TesseraType.body, color = tokens.red) }
                    if (current.hosts.isNotEmpty() && current.selectedHostIds.isEmpty()) Text(
                        "Select at least one host to copy.",
                        style = TesseraType.body,
                        color = tokens.amber,
                    )
                    TesseraButton("approve source access", {
                        onApprove()
                    }, style = TesseraButtonStyle.Primary,
                        enabled = presentation.allows(SharedSetupFlow.Action.approve))
                    }
                    TesseraButton("cancel", onCancel, style = TesseraButtonStyle.Default)
    }
}

@Composable
internal fun PairingVerification(digits: String, waiting: Boolean, confirm: () -> Unit, reject: () -> Unit, cancel: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        PairingHeading(if (waiting) "Confirm on your other device" else "Do the codes match?",
            if (waiting) "This device confirmed the code. Confirm the same code on the other screen to continue."
            else "Compare all six digits on both screens before continuing. No setup has been sent yet.")
        PairingSecurityCode(digits)
        if (waiting) {
            PairingProgress("Waiting for the other device", "Either device can confirm first.")
            TesseraButton("cancel", cancel, style = TesseraButtonStyle.Default)
        } else {
            TesseraButton("codes match", confirm, style = TesseraButtonStyle.Primary)
            TesseraButton("they differ", reject, style = TesseraButtonStyle.Danger)
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

internal fun pairingFailureMessage(context: Context, reason: SharedSetupFlow.FailureReason?): String = context.getString(when (reason) {
    SharedSetupFlow.FailureReason.expired -> R.string.setup_failure_expired
    SharedSetupFlow.FailureReason.codeMismatch -> R.string.setup_failure_mismatch
    SharedSetupFlow.FailureReason.disconnected -> R.string.setup_failure_disconnected
    SharedSetupFlow.FailureReason.locked -> R.string.setup_failure_locked
    SharedSetupFlow.FailureReason.policyChanged -> R.string.setup_failure_policy
    SharedSetupFlow.FailureReason.protocolError -> R.string.setup_failure_protocol
    else -> R.string.setup_failure_other
})
