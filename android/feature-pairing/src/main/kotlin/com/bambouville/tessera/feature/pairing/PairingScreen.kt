package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.core.bridge.SharedSetupFlow
import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.bambouville.tessera.data.SavedHost
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
    var reviewStep by remember { mutableStateOf(0) }
    var manualCodeError by remember { mutableStateOf<String?>(null) }
    var ownerToken by remember { mutableStateOf<PairingOwnerAuthorizationToken?>(null) }
    var ownerAuthorizationError by remember { mutableStateOf<String?>(null) }
    var sourcePassword by remember { mutableStateOf("") }
    var localNetworkError by remember { mutableStateOf<String?>(null) }
    var pendingLocalNetworkAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    val ownerAuthorization = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        onExternalUiActiveChanged(false)
        ownerToken?.let { coordinator.finishOwnerAuthorization(it, result.resultCode == Activity.RESULT_OK) }
        if (result.resultCode != Activity.RESULT_OK) ownerAuthorizationError = "Device authentication was canceled; no source access was changed."
        ownerToken = null
    }
    val localNetworkPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        onExternalUiActiveChanged(false)
        val action = pendingLocalNetworkAction
        pendingLocalNetworkAction = null
        if (granted) {
            localNetworkError = null
            action?.invoke()
        } else {
            localNetworkError = "Local-network access was denied. Tessera cannot open the short-lived device-to-device pairing connection."
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
                title = "pair another device",
                onBack = {
                    coordinator.cancel()
                    onBack()
                },
                backContentDescription = "Back",
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
                    TesseraKicker("interrupted setup detected")
                    Text(
                        "${current.attempts} interrupted pairing attempt(s) left ${current.hosts} host access record(s) pending. No host is linked from those records without a newly verified grant.",
                        style = TesseraType.body,
                        color = tokens.fg,
                    )
                    Text(
                        "Pairing secrets are intentionally not persisted, so recovery starts a fresh QR and SAS transaction. A successful grant clears older markers for that host.",
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                    TesseraButton(
                        "start a fresh verified pairing",
                        coordinator::restartAfterInterruption,
                        style = TesseraButtonStyle.Primary,
                    )
                }
                PairingUiState.Idle -> {
                    PairingHeading("Bring your setup with you", "Copy your hosts or pick up a session on another device. Keep Tessera open on both devices on the same network.")
                    localNetworkError?.let { Text(it, style = TesseraType.body, color = tokens.red) }
                    if (selectedHost == null) TesseraEmptyState(
                        "no saved host",
                        "Scan or paste a setup QR below to import hosts. Add a host only when this device is sending setup or starting continuation.",
                    )
                    else {
                        TesseraKicker("show QR on this Android device")
                        hosts.forEach { host ->
                            TesseraButton(host.displayName, { selectedHost = host }, style = if (host == selectedHost) TesseraButtonStyle.Primary else TesseraButtonStyle.Default)
                        }
                        TesseraButton("continue ${selectedHost!!.displayName}", {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.Continue, host) }
                        }, style = TesseraButtonStyle.Primary)
                        TesseraButton("set up & continue ${selectedHost!!.displayName}", {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.SetupAndContinue, host) }
                        }, style = TesseraButtonStyle.Default)
                        TesseraButton("send setup to another device", {
                            withLocalNetworkAccess { coordinator.createBootstrapOrigin() }
                        }, style = TesseraButtonStyle.Default)
                        TesseraButton("enroll a device for ${selectedHost!!.displayName}", {
                            val host = selectedHost ?: return@TesseraButton
                            withLocalNetworkAccess { coordinator.createOrigin(PairingPurpose.Enroll, host) }
                        }, style = TesseraButtonStyle.Default)
                    }
                    TesseraKicker("scan or paste QR from another device")
                    TesseraButton("scan pairing code", { manualCodeError = null; scanning = true }, style = TesseraButtonStyle.Primary)
                    if (scanning) Dialog(
                        onDismissRequest = { scanning = false },
                        properties = DialogProperties(usePlatformDefaultWidth = false),
                    ) {
                        Surface(
                            modifier = Modifier.padding(20.dp).widthIn(max = 600.dp).fillMaxWidth().fillMaxHeight(0.85f),
                            shape = RoundedCornerShape(28.dp), color = tokens.bg,
                        ) {
                        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        PairingHeading("Scan pairing code", "Keep the whole QR code in view. Your devices will show a six-digit code to compare next.")
                        PairingQrScanner(
                        onScanned = { scanned ->
                            qrText = scanned
                            scanning = false
                            withLocalNetworkAccess {
                                manualCodeError = runCatching { coordinator.createRecipient(scanned, selectedHost); null }.getOrElse {
                                    it.message ?: "Invalid or expired pairing code."
                                }
                            }
                        },
                        onFailure = { message -> manualCodeError = message; scanning = false; manualEntry = true },
                        modifier = Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(20.dp)),
                    )
                        TesseraButton("cancel scan", { scanning = false }, style = TesseraButtonStyle.Default)
                        }
                        }
                    }
                    TesseraButton("enter code instead", { manualEntry = !manualEntry }, style = TesseraButtonStyle.Default)
                    if (manualEntry) {
                    TesseraTextField(
                        value = qrText,
                        onValueChange = { qrText = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = "pairing QR text",
                        placeholder = "tessera://pair/v1?offer=…",
                        keyboardOptions = KeyboardOptions(),
                        supporting = manualCodeError,
                        isError = manualCodeError != null,
                    )
                    TesseraButton("use pairing code", {
                        withLocalNetworkAccess {
                            manualCodeError = runCatching { coordinator.createRecipient(qrText, selectedHost); null }.getOrElse {
                                it.message ?: "Invalid, expired, or unsupported Tessera pairing code."
                            }
                        }
                    }, style = TesseraButtonStyle.Primary, enabled = qrText.isNotBlank())
                    }
                    if (!manualEntry) manualCodeError?.let { Text(it, color = tokens.red) }
                }
                is PairingUiState.Offer -> {
                    PairingHeading("Scan with your other device", "Open Tessera → Settings → sync & continuity on the other device. On Apple, tap “scan pairing code.” On Android, tap “pair another device,” then “scan pairing code.” Keep both devices on the same network.")
                    val qr = remember(current.text) { PairingQrRenderer.render(current.text).asImageBitmap() }
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Image(qr, contentDescription = "Tessera pairing QR",
                            modifier = Modifier.widthIn(max = 300.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Color.White).padding(20.dp))
                    }
                    Text("Compare the six-digit security code before continuing.", style = TesseraType.body, color = tokens.fgMuted)
                    TesseraButton("cancel", coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                is PairingUiState.Sas -> PairingVerification(current.digits, false,
                    { coordinator.decideSas(true) }, { coordinator.decideSas(false) }, coordinator::cancel)
                is PairingUiState.AwaitingPeerSas -> PairingVerification(current.digits, true,
                    { coordinator.decideSas(true) }, { coordinator.decideSas(false) }, coordinator::cancel)
                is PairingUiState.AwaitingOwnerApproval -> {
                    PairingSelectionReview(current, presentation, reviewStep, { reviewStep = it },
                        coordinator::setHostSelected, coordinator::setTrustedHostKeysSelected,
                        coordinator::setOptionalTransferSelected, ownerAuthorizationError,
                        onApprove = {
                        val keyguard = context.getSystemService(KeyguardManager::class.java)
                        val intent = keyguard?.createConfirmDeviceCredentialIntent("Approve source access", "Install only this recipient public key on the selected hosts.")
                        val token = coordinator.beginOwnerAuthorization()
                        if (intent != null && token != null) {
                            ownerAuthorizationError = null
                            ownerToken = token
                            onExternalUiActiveChanged(true)
                            ownerAuthorization.launch(intent)
                        } else {
                            ownerAuthorizationError = "Set a device PIN, pattern, password, or strong biometric before approving source access."
                        }
                        }, onCancel = coordinator::cancel)
                }
                is PairingUiState.AwaitingRecipientImport -> {
                    TesseraKicker("review setup from paired device")
                    Text(
                        "Import ${current.hosts.size} host${if (current.hosts.size == 1) "" else "s"}. Passwords and private keys are not imported. Existing host text is kept; selected data fills empty fields.",
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                    current.hosts.forEach { host ->
                        Text(host.name, style = TesseraType.rowTitle, color = tokens.fg)
                        Text(host.endpoint, style = TesseraType.code, color = tokens.fgMuted)
                    }
                    TesseraButton("import setup", coordinator::approveBootstrapImport, style = TesseraButtonStyle.Primary)
                    TesseraButton("cancel", coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                is PairingUiState.AwaitingSourcePassword -> {
                    Text("Enter the password for ${current.username}@${current.hostName}. It stays in memory on this Android device and is wiped after SSH authentication.", style = TesseraType.body, color = tokens.fg)
                    TesseraTextField(
                        value = sourcePassword,
                        onValueChange = { sourcePassword = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = "source-host password",
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        visualTransformation = PasswordVisualTransformation(),
                    )
                    TesseraButton("continue", {
                        coordinator.submitSourcePassword(sourcePassword)
                        sourcePassword = ""
                    }, style = TesseraButtonStyle.Primary)
                    TesseraButton("cancel", coordinator::cancel, style = TesseraButtonStyle.Default)
                }
                PairingUiState.AwaitingSetupChoice -> {
                    PairingHeading("Choose on the sending device", "Your devices are verified. Choose the hosts and data to copy on the device sending setup; the receiving device will review them next.")
                    CircularProgressIndicator(color = tokens.fg, modifier = Modifier.size(28.dp), strokeWidth = 2.dp)
                }
                is PairingUiState.Working -> {
                    PairingProgress("Keep both devices open", current.message)
                }
                is PairingUiState.AwaitingConnection -> {
                    PairingProgress("Picking up your session", "Opening the verified ${current.transport} session…")
                }
                is PairingUiState.Completed -> {
                    PairingHeading("You’re ready", "Your devices have finished this transfer.")
                    Text(current.message, style = TesseraType.body, color = tokens.fg)
                    PairingAccessReceipt(current.hosts)
                    TesseraButton("done", {
                        val receivedSetup = coordinator.didReceiveBootstrap
                        coordinator.cancel()
                        if (receivedSetup) onReceivedSetupFinished()
                    }, style = TesseraButtonStyle.Primary)
                }
                is PairingUiState.Failed -> {
                    PairingHeading(current.title, current.message)
                    PairingAccessReceipt(current.hosts)
                    TesseraButton("start again", coordinator::cancel, style = TesseraButtonStyle.Primary)
                    TesseraButton("done", { coordinator.cancel(); onBack() }, style = TesseraButtonStyle.Default)
                }
                }
                }
                }
            }
        }
    }
}
