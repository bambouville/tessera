package com.bambouville.tessera.forwarding

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraCard
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraSegmented
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType

/**
 * Compact-safe host editor panel. Persistence and the live manager remain
 * caller-owned so the same view works before a connection and in-session.
 */
@Composable
fun PortForwardingPanel(
    rules: List<PortForwardRule>,
    states: Map<java.util.UUID, PortForwardingState>,
    onRulesChanged: (List<PortForwardRule>) -> Unit,
    modifier: Modifier = Modifier,
    onStartRule: (java.util.UUID) -> Unit = {},
    onStopRule: (java.util.UUID) -> Unit = {},
    /**
     * Asks for every probeable rule to be checked now. Called once when the
     * panel appears: the user opened it to read these answers.
     */
    onProbeServices: () -> Unit = {},
) {
    val tokens = LocalTesseraTokens.current
    var editing by remember { mutableStateOf<PortForwardRule?>(null) }
    var creating by remember { mutableStateOf(false) }
    var browsing by remember { mutableStateOf<BrowsingTunnel?>(null) }
    val currentProbeServices by rememberUpdatedState(onProbeServices)
    LaunchedEffect(Unit) { currentProbeServices() }

    Column(modifier = modifier) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                TesseraKicker("port forwarding")
                Text(
                    "Local and dynamic listeners stay on this device. Remote binds are server-side.",
                    modifier = Modifier.padding(top = 4.dp),
                    style = TesseraType.rowMeta,
                    color = tokens.fgMuted,
                )
            }
            TesseraButton(text = "add", onClick = { creating = true }, compact = true)
        }
        TesseraHairline()

        if (rules.isEmpty()) {
            Text(
                "No forwarding rules.",
                modifier = Modifier.padding(18.dp),
                style = TesseraType.body,
                color = tokens.fgMuted,
            )
        } else {
            LazyColumn {
                items(rules, key = PortForwardRule::id) { rule ->
                    ForwardRuleRow(
                        rule = rule,
                        state = states[rule.id],
                        onEnabledChanged = { enabled ->
                            onRulesChanged(rules.map { if (it.id == rule.id) it.copy(enabled = enabled) else it })
                        },
                        onEdit = { editing = rule },
                        onDelete = { onRulesChanged(rules.filterNot { it.id == rule.id }) },
                        onStart = { onStartRule(rule.id) },
                        onStop = { onStopRule(rule.id) },
                        onOpenInBrowser = { target ->
                            browsing = BrowsingTunnel(target, rule.label)
                        },
                    )
                    TesseraHairline(Modifier.padding(start = 18.dp))
                }
            }
        }
    }

    if (creating) {
        ForwardRuleEditor(
            initial = defaultRule(),
            existing = rules,
            onDismiss = { creating = false },
            onSave = { rule ->
                onRulesChanged(rules + rule)
                creating = false
            },
        )
    }
    browsing?.let { tunnel ->
        TunnelWebBrowser(
            target = tunnel.target,
            ruleLabel = tunnel.label,
            onDismiss = { browsing = null },
        )
    }
    editing?.let { rule ->
        ForwardRuleEditor(
            initial = rule,
            existing = rules,
            onDismiss = { editing = null },
            onSave = { next ->
                onRulesChanged(rules.map { if (it.id == next.id) next else it })
                editing = null
            },
        )
    }
}

/** The tunnel the in-app browser is showing, with the label its chrome names. */
private data class BrowsingTunnel(val target: SharedForwardedWebTarget, val label: String)

@Composable
private fun ForwardRuleRow(
    rule: PortForwardRule,
    state: PortForwardingState?,
    onEnabledChanged: (Boolean) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onOpenInBrowser: (SharedForwardedWebTarget) -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val status = state?.status ?: PortForwardingStatus.Idle
    // Remembered per rule: both answers cross the JNI bridge, and this row
    // recomposes every time its byte counters tick.
    val probed = remember(rule) { ForwardingRulePolicy.Shared.watchesService(rule) }
    TesseraCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp)) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        rule.label.ifBlank { directionLabel(rule.direction).lowercase() },
                        style = TesseraType.rowTitle,
                        color = tokens.fg,
                    )
                    Text(ruleSummary(rule), style = TesseraType.code, color = tokens.fgMuted)
                }
                TesseraToggleRow(
                    title = "enabled",
                    checked = rule.enabled,
                    onCheckedChange = onEnabledChanged,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 10.dp),
                    modifier = Modifier.weight(0.75f),
                )
            }
            Text(
                forwardRuleStatusText(rule, state, probed),
                style = TesseraType.rowMeta,
                color = statusColor(
                    status = status,
                    service = state?.service ?: ForwardedServiceState.Unknown,
                ),
                modifier = Modifier.testTag("tunnel-status-${rule.bind.port}"),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // A tunnel is only browsable while something is listening on
                // it: the shared policy answers the address, the status
                // answers the liveness it deliberately does not hold. Still
                // offered when nothing is serving yet: the page may be up by
                // the time the user taps, and the browser says so if not.
                // Remembered per rule: the answer crosses the JNI bridge, and
                // this row recomposes every time its byte counters tick.
                val addressable = remember(rule) { rule.browsableWebTarget() }
                val webTarget = addressable.takeIf { status.isCarrying() }
                if (webTarget != null) {
                    TesseraButton(
                        text = "\u2197 open",
                        onClick = { onOpenInBrowser(webTarget) },
                        style = TesseraButtonStyle.Primary,
                        compact = true,
                        modifier = Modifier.testTag("tunnel-open-${rule.bind.port}"),
                    )
                }
                TesseraButton(text = "edit", onClick = onEdit, compact = true)
                TesseraButton(
                    text = "delete",
                    onClick = onDelete,
                    style = TesseraButtonStyle.Danger,
                    compact = true,
                )
                if (status is PortForwardingStatus.Listening || status is PortForwardingStatus.Active ||
                    status is PortForwardingStatus.Starting
                ) {
                    TesseraButton(text = "stop", onClick = onStop, compact = true)
                } else if (rule.enabled) {
                    TesseraButton(
                        text = "start",
                        onClick = onStart,
                        style = TesseraButtonStyle.Primary,
                        compact = true,
                    )
                }
            }
        }
    }
}

@Composable
private fun ForwardRuleEditor(
    initial: PortForwardRule,
    existing: List<PortForwardRule>,
    onDismiss: () -> Unit,
    onSave: (PortForwardRule) -> Unit,
) {
    var direction by remember(initial.id) { mutableStateOf(initial.direction) }
    var label by remember(initial.id) { mutableStateOf(initial.label) }
    var bindHost by remember(initial.id) { mutableStateOf(initial.bind.host) }
    var bindPort by remember(initial.id) { mutableStateOf(initial.bind.port.toString()) }
    var targetHost by remember(initial.id) { mutableStateOf(initial.target?.host.orEmpty()) }
    var targetPort by remember(initial.id) { mutableStateOf(initial.target?.port?.toString().orEmpty()) }
    var validation by remember(initial.id) { mutableStateOf<String?>(null) }

    fun save() {
        val rule = ruleFromForm(
            initial = initial,
            direction = direction,
            label = label,
            bindHost = bindHost,
            bindPort = bindPort,
            targetHost = targetHost,
            targetPort = targetPort,
        )
        if (rule == null) {
            validation = "Ports must be whole numbers."
        } else {
            val error = PortForwardRuleValidator.validate(rule, existing)
            if (error == null) onSave(rule) else validation = validationText(error)
        }
    }

    TesseraDialog(
        title = if (initial.label.isBlank()) "forwarding rule" else "edit ${initial.label}",
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = "cancel", onClick = onDismiss, compact = true)
            TesseraButton(
                text = "save",
                onClick = ::save,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            DirectionPicker(direction = direction, onSelected = { direction = it })
            TesseraTextField(
                value = label,
                onValueChange = { label = it },
                label = "label",
                placeholder = "optional",
            )
            TesseraTextField(
                value = bindHost,
                onValueChange = { bindHost = it },
                label = "bind address",
                supporting = if (direction != PortForwardDirection.REMOTE) "loopback only" else null,
            )
            TesseraTextField(
                value = bindPort,
                onValueChange = { bindPort = it.filter(Char::isDigit) },
                label = if (direction == PortForwardDirection.REMOTE) "bind port · 0 allowed" else "bind port",
            )
            if (direction != PortForwardDirection.DYNAMIC) {
                TesseraTextField(
                    value = targetHost,
                    onValueChange = { targetHost = it },
                    label = if (direction == PortForwardDirection.LOCAL) "remote host" else "device host",
                )
                TesseraTextField(
                    value = targetPort,
                    onValueChange = { targetPort = it.filter(Char::isDigit) },
                    label = "target port",
                )
            }
            validation?.let { TesseraBanner(it) }
        }
    }
}

@Composable
private fun DirectionPicker(direction: PortForwardDirection, onSelected: (PortForwardDirection) -> Unit) {
    val choices = PortForwardDirection.entries
    TesseraSegmented(
        options = choices.map(::directionLabel),
        selectedIndex = choices.indexOf(direction),
        onSelect = { onSelected(choices[it]) },
    )
}

private fun ruleFromForm(
    initial: PortForwardRule,
    direction: PortForwardDirection,
    label: String,
    bindHost: String,
    bindPort: String,
    targetHost: String,
    targetPort: String,
): PortForwardRule? {
    val parsedBindPort = bindPort.toIntOrNull() ?: return null
    val target = if (direction == PortForwardDirection.DYNAMIC) null else {
        PortForwardEndpoint(targetHost, targetPort.toIntOrNull() ?: return null)
    }
    return initial.copy(
        direction = direction,
        bind = PortForwardEndpoint(bindHost, parsedBindPort),
        target = target,
        label = label.trim(),
    )
}

private fun defaultRule() = PortForwardRule(
    bind = PortForwardEndpoint("127.0.0.1", 8080),
    target = PortForwardEndpoint("localhost", 80),
)

private fun directionLabel(direction: PortForwardDirection): String = when (direction) {
    PortForwardDirection.LOCAL -> "Local"
    PortForwardDirection.REMOTE -> "Remote"
    PortForwardDirection.DYNAMIC -> "Dynamic"
}

private fun ruleSummary(rule: PortForwardRule): String = when (rule.direction) {
    PortForwardDirection.LOCAL -> "${rule.bind.host}:${rule.bind.port} → ${rule.target?.host}:${rule.target?.port}"
    PortForwardDirection.REMOTE -> "${rule.bind.host}:${rule.bind.port} → device ${rule.target?.host}:${rule.target?.port}"
    PortForwardDirection.DYNAMIC -> "SOCKS5 ${rule.bind.host}:${rule.bind.port}"
}

/**
 * A rule row's status line. A listening rule also says whether anything
 * answers at the far end; those lines match iOS `listeningStatusText` word
 * for word.
 *
 * "checking…" is promised only for a rule the manager actively probes
 * ([probed]) and whose server has not refused forwarding outright: any other
 * unknown rule would never resolve, so it says only that it is listening.
 * The row already shows the bound address.
 */
internal fun forwardRuleStatusText(
    rule: PortForwardRule,
    state: PortForwardingState?,
    probed: Boolean,
): String = when (val status = state?.status ?: PortForwardingStatus.Idle) {
    PortForwardingStatus.Idle -> "Stopped"
    PortForwardingStatus.Starting -> "Starting"
    is PortForwardingStatus.Listening -> when {
        state?.service == ForwardedServiceState.Serving -> "serving \u00b7 0 active"
        state?.service == ForwardedServiceState.NotServing ->
            "listening \u00b7 nothing serving on remote port ${rule.target?.port}"
        probed && state?.forwardingProhibited != true -> "listening \u00b7 checking\u2026"
        else -> "listening \u00b7 0 active"
    }
    is PortForwardingStatus.Active -> "${status.connectionCount} active connection${if (status.connectionCount == 1) "" else "s"}"
    is PortForwardingStatus.Failed -> when (val failure = status.failure) {
        is PortForwardingFailure.Transport -> failure.reason
        is PortForwardingFailure.Unsupported -> failure.reason
        is PortForwardingFailure.Validation -> validationText(failure.error)
    }
}

@Composable
private fun statusColor(
    status: PortForwardingStatus,
    service: ForwardedServiceState,
) = with(LocalTesseraTokens.current) {
    when (status) {
        is PortForwardingStatus.Failed -> red
        PortForwardingStatus.Starting -> amber
        // Green is reserved for a far end that answered, as on iOS: a
        // listener that is up but unconfirmed — being checked, never
        // checked (https, postgres, SOCKS), or refused forwarding by the
        // server — is the softened accent, and one refused by its target
        // is muted.
        is PortForwardingStatus.Listening -> when (service) {
            ForwardedServiceState.Serving -> green
            ForwardedServiceState.NotServing -> fgMuted
            ForwardedServiceState.Unknown -> accent.copy(alpha = 0.7f)
        }
        is PortForwardingStatus.Active -> green
        PortForwardingStatus.Idle -> fgMuted
    }
}

private fun validationText(error: PortForwardRuleError): String = when (error) {
    is PortForwardRuleError.InvalidBindAddress -> "A bind address is required."
    is PortForwardRuleError.InvalidBindPort -> "Bind port must be valid."
    is PortForwardRuleError.NonLoopbackLocalBind -> "Local and dynamic forwarding must bind to loopback."
    PortForwardRuleError.MissingTarget -> "A target is required."
    is PortForwardRuleError.InvalidTargetAddress -> "A target host is required."
    is PortForwardRuleError.InvalidTargetPort -> "Target port must be valid."
    PortForwardRuleError.DynamicForwardCannotHaveTarget -> "Dynamic forwarding chooses a target per SOCKS request."
    is PortForwardRuleError.BindCollision -> "Another local listener uses this port."
}
