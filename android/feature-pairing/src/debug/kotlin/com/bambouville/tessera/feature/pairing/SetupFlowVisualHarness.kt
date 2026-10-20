package com.bambouville.tessera.feature.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedSetupFlow
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraSubPageHeader

/** Exact shipping native components, typed fixture facts, no keys/network/DB. */
@Composable
fun SetupFlowVisualHarness(scene: String) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val first = "11111111-1111-1111-1111-111111111111"
    val second = "22222222-2222-2222-2222-222222222222"
    var phase by remember { mutableStateOf(when (scene) {
        "setup-receipt" -> SharedSetupFlow.Phase.completed
        "setup-progress" -> SharedSetupFlow.Phase.waitingForGrant
        else -> SharedSetupFlow.Phase.compareCode
    }) }
    var step by remember { mutableStateOf(0) }
    var selected by remember { mutableStateOf(setOf(first, second)) }
    var optional by remember { mutableStateOf(emptySet<String>()) }
    val presentation = SharedSetupFlow.project("setUpAndContinue", phase,
        actions = listOf(SharedSetupFlow.Action.approve), selection = SharedSetupFlow.Selection(
            setOf(first, second), selected, setOf(first)))
    Column(Modifier.fillMaxSize().background(tokens.panelBg).statusBarsPadding().navigationBarsPadding()) {
        TesseraSubPageHeader("pair another device", {}, backContentDescription = "Back")
        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                PairingSteps(presentation)
                when (phase) {
                    SharedSetupFlow.Phase.compareCode -> PairingVerification("123456", false,
                        { phase = SharedSetupFlow.Phase.choosing }, { phase = SharedSetupFlow.Phase.failed }, {})
                    SharedSetupFlow.Phase.choosing -> PairingSelectionReview(
                        PairingUiState.AwaitingOwnerApproval("Only reviewed setup is copied.",
                            listOf(PairingHostSummary(first, "Build server", "builder@build.example:22"),
                                PairingHostSummary(second, "Password server", "user@password.example:22")),
                            selected, optional, "SHA256:fixture-public-key-only", true),
                        presentation, step, { step = it },
                        { id, value -> selected = if (value) selected + id else selected - id },
                        { value -> optional = if (value) optional + "trustedHostKeys" else optional - "trustedHostKeys" },
                        { id, value -> optional = if (value) optional + id else optional - id },
                        null, { phase = SharedSetupFlow.Phase.completed }, {})
                    SharedSetupFlow.Phase.waitingForGrant -> PairingProgress("Keep both devices open",
                        "Setup copied. Waiting for the sender to authorize and verify this device’s key…")
                    SharedSetupFlow.Phase.completed -> {
                        PairingHeading("Setup copied", "Review access before connecting.")
                        PairingAccessReceipt(listOf(PairingReceiptHost(first, "Build server", SharedSetupFlow.Outcome.authorized),
                            PairingReceiptHost(second, "Password server", SharedSetupFlow.Outcome.passwordNeeded)))
                        TesseraButton("done", {})
                    }
                    else -> {
                        PairingHeading("Pairing stopped", pairingFailureMessage(context, SharedSetupFlow.FailureReason.codeMismatch))
                        TesseraButton("start again", { phase = SharedSetupFlow.Phase.compareCode })
                    }
                }
            }
        }
    }
}
