package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.core.bridge.SharedSetupFlow
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.foundation.Image
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.design.DisplayText
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.design.text
import com.bambouville.tessera.security.canConfirmDeviceOwner
import com.bambouville.tessera.security.confirmDeviceOwner
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Compact-phone pairing UI. QR text has a strict manual/clipboard fallback. */
@Composable
fun PairingScreen(
    hosts: List<SavedHost>,
    coordinator: CrossDevicePairingCoordinator,
    onExternalUiActiveChanged: (Boolean) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    autoStartContinuationHost: SavedHost? = null,
    onAutoStartConsumed: () -> Unit = {},
    onReceivedSetupFinished: () -> Unit = {},
) {
    val context = LocalContext.current
    val state by coordinator.state.collectAsState()
    var qrText by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    var manualEntry by remember { mutableStateOf(false) }
    var reviewStep by remember { mutableIntStateOf(0) }
    var manualCodeError by remember { mutableStateOf<DisplayText?>(null) }
    var ownerAuthorizationError by remember { mutableStateOf<DisplayText?>(null) }
    val scope = rememberCoroutineScope()
    var ownerPrompt by remember { mutableStateOf<Job?>(null) }
    var sourcePassword by remember { mutableStateOf("") }
    var localNetworkError by remember { mutableStateOf<DisplayText?>(null) }
    var pendingLocalNetworkAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    // Resolved in composition: the owner prompt opens from a callback, which is not composable.
    val ownerPromptTitle = stringResource(R.string.pairing_owner_prompt_title)
    val ownerPromptDetail = stringResource(R.string.pairing_owner_prompt_detail)
    val localNetworkPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        onExternalUiActiveChanged(false)
        val action = pendingLocalNetworkAction
        pendingLocalNetworkAction = null
        if (granted) {
            localNetworkError = null
            action?.invoke()
        } else {
            localNetworkError = DisplayText.Resource(R.string.pairing_local_network_denied)
        }
    }
    fun withLocalNetworkAccess(action: () -> Unit) {
        if (Build.VERSION.SDK_INT < 37 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
        ) {
            localNetworkError = null
            action()
        } else {
            pendingLocalNetworkAction = action
            onExternalUiActiveChanged(true)
            localNetworkPermission.launch(Manifest.permission.ACCESS_LOCAL_NETWORK)
        }
    }
    LaunchedEffect(autoStartContinuationHost?.id) {
        autoStartContinuationHost?.let { host ->
            onAutoStartConsumed()
            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.Continue, host) }
        }
    }
    var selectedHost by remember(hosts) { mutableStateOf(hosts.firstOrNull()) }
    val tokens = LocalTesseraTokens.current
    LaunchedEffect(state::class) {
        if (state is PairingUiState.AwaitingOwnerApproval) reviewStep = 0
    }
    Surface(modifier, color = tokens.bg) {
        Column(Modifier.fillMaxSize().imePadding().navigationBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            TesseraSubPageHeader(
                title = stringResource(R.string.pairing_title),
                onBack = {
                    coordinator.cancel()
                    onBack()
                },
                backContentDescription = stringResource(R.string.pairing_back),
            )
            TesseraHairline()
            Column(
                Modifier.weight(1f).widthIn(max = 600.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                val presentation = remember(state, coordinator.presentationPurpose) { coordinator.presentation(state) }
                PairingSteps(presentation)
                AnimatedContent(
                    targetState = state,
                    contentKey = { it::class },
                    transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(90)) },
                    label = "pairing phase",
                ) { current ->
                Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                when (current) {
                is PairingUiState.RecoveryPending -> {
                    TesseraKicker(stringResource(R.string.pairing_recovery_kicker))
                    Text(
                        stringResource(
                            R.string.pairing_recovery_summary,
                            pluralStringResource(R.plurals.pairing_recovery_attempts, current.attempts, current.attempts),
                            pluralStringResource(R.plurals.pairing_recovery_pending_hosts, current.hosts, current.hosts),
                        ),
                        style = TesseraType.body,
                        color = tokens.fg,
                    )
                    Text(
                        stringResource(R.string.pairing_recovery_detail),
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                    TesseraButton(
                        stringResource(R.string.pairing_recovery_restart),
                        coordinator::restartAfterInterruption,
                        style = TesseraButtonStyle.Primary,
                    )
                }
                PairingUiState.Idle -> {
                    PairingHeading(stringResource(R.string.pairing_idle_title), stringResource(R.string.pairing_idle_detail))
                    localNetworkError?.let { Text(it.text(), style = TesseraType.body, color = tokens.red) }
                    if (selectedHost == null) TesseraEmptyState(
                        stringResource(R.string.pairing_no_host_title),
                        stringResource(R.string.pairing_no_host_body),
                    )
                    else {
                        TesseraKicker(stringResource(R.string.pairing_show_qr_kicker))
                        hosts.forEach { host ->
                            TesseraButton(host.displayName, { selectedHost = host }, style = if (host == selectedHost) TesseraButtonStyle.Primary else TesseraButtonStyle.Default)
                        }
                        TesseraButton(stringResource(R.string.pairing_continue_host, selectedHost!!.displayName), {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.Continue, host) }
                        }, style = TesseraButtonStyle.Primary)
                        TesseraButton(stringResource(R.string.pairing_setup_and_continue_host, selectedHost!!.displayName), {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.SetupAndContinue, host) }
                        }, style = TesseraButtonStyle.Default)
                        TesseraButton(stringResource(R.string.pairing_send_setup), {
                            withLocalNetworkAccess { coordinator.createBootstrapOrigin() }
                        }, style = TesseraButtonStyle.Default)
                        TesseraButton(stringResource(R.string.pairing_enroll_host, selectedHost!!.displayName), {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.Enroll, host) }
                        }, style = TesseraButtonStyle.Default)
                    }
                    TesseraKicker(stringResource(R.string.pairing_scan_kicker))
                    TesseraButton(stringResource(R.string.pairing_scan_code), { manualCodeError = null; scanning = true }, style = TesseraButtonStyle.Primary)
                    if (scanning) Dialog(
                        onDismissRequest = { scanning = false },
                        properties = DialogProperties(usePlatformDefaultWidth = false),
                    ) {
                        Surface(
                            modifier = Modifier.padding(20.dp).widthIn(max = 600.dp).fillMaxWidth().fillMaxHeight(0.85f),
                            shape = RoundedCornerShape(28.dp), color = tokens.bg,
                        ) {
                        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        PairingHeading(stringResource(R.string.pairing_scan_title), stringResource(R.string.pairing_scan_detail))
                        PairingQrScanner(
                        onScanned = { scanned ->
                            qrText = scanned
                            scanning = false
                            withLocalNetworkAccess {
                                manualCodeError = runCatching { coordinator.createRecipient(scanned, selectedHost); null }.getOrElse {
                                    pairingFailureText(it, R.string.pairing_code_invalid_or_expired)
                                }
                            }
                        },
                        onFailure = { message -> manualCodeError = message; scanning = false; manualEntry = true },
                        modifier = Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(20.dp)),
                    )
                        TesseraButton(stringResource(R.string.pairing_cancel_scan), { scanning = false }, style = TesseraButtonStyle.Default)
                        }
                        }
                    }
                    TesseraButton(stringResource(R.string.pairing_enter_code_instead), { manualEntry = !manualEntry }, style = TesseraButtonStyle.Default)
                    if (manualEntry) {
                    TesseraTextField(
                        value = qrText,
                        onValueChange = { qrText = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = stringResource(R.string.pairing_qr_text_label),
                        placeholder = "tessera://pair/v1?offer=…",
                        keyboardOptions = KeyboardOptions(),
                        supporting = manualCodeError?.text(),
                        isError = manualCodeError != null,
                    )
                    TesseraButton(stringResource(R.string.pairing_use_code), {
                        withLocalNetworkAccess {
                            manualCodeError = runCatching { coordinator.createRecipient(qrText, selectedHost); null }.getOrElse {
                                pairingFailureText(it, R.string.pairing_code_unusable)
                            }
                        }
                    }, style = TesseraButtonStyle.Primary, enabled = qrText.isNotBlank())
                    }
                    if (!manualEntry) manualCodeError?.let { Text(it.text(), color = tokens.red) }
                }
                is PairingUiState.Offer -> {
                    PairingHeading(stringResource(R.string.pairing_offer_title), stringResource(R.string.pairing_offer_detail))
                    val qr = remember(current.text) { PairingQrRenderer.render(current.text).asImageBitmap() }
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Image(qr, contentDescription = stringResource(R.string.pairing_qr_content_description),
                            modifier = Modifier.widthIn(max = 300.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Color.White).padding(20.dp))
                    }
                    Text(stringResource(R.string.pairing_offer_compare_hint), style = TesseraType.body, color = tokens.fgMuted)
                    TesseraButton(stringResource(R.string.pairing_cancel), coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                is PairingUiState.Sas -> PairingVerification(current.digits, false,
                    { coordinator.decideSas(true) }, { coordinator.decideSas(false) }, coordinator::cancel)
                is PairingUiState.AwaitingPeerSas -> PairingVerification(current.digits, true,
                    { coordinator.decideSas(true) }, { coordinator.decideSas(false) }, coordinator::cancel)
                is PairingUiState.AwaitingOwnerApproval -> {
                    PairingSelectionReview(current, presentation, reviewStep, { reviewStep = it },
                        coordinator::setHostSelected, coordinator::setTrustedHostKeysSelected,
                        coordinator::setOptionalTransferSelected, ownerAuthorizationError,
                        onApprove = approve@{
                        // A second tap before the prompt is up would supersede the first token.
                        if (ownerPrompt?.isActive == true) return@approve
                        if (!canConfirmDeviceOwner(context)) {
                            ownerAuthorizationError = DisplayText.Resource(R.string.pairing_owner_auth_unavailable)
                            return@approve
                        }
                        val token = coordinator.beginOwnerAuthorization() ?: return@approve
                        ownerAuthorizationError = null
                        ownerPrompt = scope.launch {
                            val approved = confirmDeviceOwner(context, ownerPromptTitle, ownerPromptDetail)
                            coordinator.finishOwnerAuthorization(token, approved)
                            if (!approved) ownerAuthorizationError = DisplayText.Resource(R.string.pairing_owner_auth_canceled)
                        }
                        }, onCancel = coordinator::cancel)
                }
                is PairingUiState.AwaitingRecipientImport -> {
                    TesseraKicker(stringResource(R.string.pairing_import_kicker))
                    Text(
                        pluralStringResource(R.plurals.pairing_import_summary, current.hosts.size, current.hosts.size),
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                    current.hosts.forEach { host ->
                        Text(host.name, style = TesseraType.rowTitle, color = tokens.fg)
                        Text(host.endpoint, style = TesseraType.code, color = tokens.fgMuted)
                    }
                    TesseraButton(stringResource(R.string.pairing_import_setup), coordinator::approveBootstrapImport, style = TesseraButtonStyle.Primary)
                    TesseraButton(stringResource(R.string.pairing_cancel), coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                is PairingUiState.AwaitingSourcePassword -> {
                    Text(stringResource(R.string.pairing_source_password_prompt, current.username, current.hostName), style = TesseraType.body, color = tokens.fg)
                    TesseraTextField(
                        value = sourcePassword,
                        onValueChange = { sourcePassword = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = stringResource(R.string.pairing_source_password_label),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        visualTransformation = PasswordVisualTransformation(),
                    )
                    TesseraButton(stringResource(R.string.pairing_continue), {
                        coordinator.submitSourcePassword(sourcePassword)
                        sourcePassword = ""
                    }, style = TesseraButtonStyle.Primary)
                    TesseraButton(stringResource(R.string.pairing_cancel), coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                PairingUiState.AwaitingSetupChoice -> {
                    PairingHeading(stringResource(R.string.pairing_choose_on_sender_title), stringResource(R.string.pairing_choose_on_sender_detail))
                    CircularProgressIndicator(color = tokens.fg, modifier = Modifier.size(28.dp), strokeWidth = 2.dp)
                }
                is PairingUiState.Working -> {
                    PairingProgress(stringResource(R.string.pairing_keep_open_title), current.message.text())
                }
                is PairingUiState.AwaitingConnection -> {
                    PairingProgress(stringResource(R.string.pairing_picking_up_title), stringResource(R.string.pairing_opening_session, current.transport))
                }
                is PairingUiState.Completed -> {
                    PairingHeading(stringResource(R.string.pairing_ready_title), stringResource(R.string.pairing_ready_detail))
                    Text(current.message.text(), style = TesseraType.body, color = tokens.fg)
                    PairingAccessReceipt(current.hosts)
                    TesseraButton(stringResource(R.string.pairing_done), {
                        val receivedSetup = coordinator.didReceiveBootstrap
                        coordinator.cancel()
                        if (receivedSetup) onReceivedSetupFinished()
                    }, style = TesseraButtonStyle.Primary)
                }
                is PairingUiState.Failed -> {
                    PairingHeading(
                        current.title?.text() ?: stringResource(R.string.pairing_stopped_title),
                        current.message.text(),
                    )
                    PairingAccessReceipt(current.hosts)
                    TesseraButton(stringResource(R.string.pairing_start_again), coordinator::cancel, style = TesseraButtonStyle.Primary)
                    TesseraButton(stringResource(R.string.pairing_done), { coordinator.cancel(); onBack() }, style = TesseraButtonStyle.Default)
                }
                }
                }
                }
            }
        }
    }
}
