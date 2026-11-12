package com.bambouville.tessera.forwarding

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.LocalArtifactOpener
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
import com.bambouville.tessera.design.text
import kotlinx.coroutines.flow.StateFlow

/**
 * A connected session's tunnels, for a page outside that session that lists
 * the same host's rules: what each is doing now, and the controls that act on
 * it. The page shows idle rules without one, and offers no start.
 */
class LiveForwarding(
    val states: StateFlow<Map<java.util.UUID, PortForwardingState>>,
    val start: (java.util.UUID) -> Unit,
    val stop: (java.util.UUID) -> Unit,
    val probeServices: () -> Unit,
)

/**
 * Compact-safe host editor panel. Persistence and the live manager remain
 * caller-owned so the same view works before a connection and in-session.
 * A null [onStartRule] means nothing can start a rule from here.
 */
@Composable
fun PortForwardingPanel(
    rules: List<PortForwardRule>,
    states: Map<java.util.UUID, PortForwardingState>,
    onRulesChanged: (List<PortForwardRule>) -> Unit,
    modifier: Modifier = Modifier,
    onStartRule: ((java.util.UUID) -> Unit)? = {},
    onStopRule: (java.util.UUID) -> Unit = {},
    /**
     * Asks for every probeable rule to be checked now. Called once when the
     * panel appears: the user opened it to read these answers.
     */
    onProbeServices: () -> Unit = {},
    hostId: String? = null,
    sessionHint: String? = null,
) {
    val tokens = LocalTesseraTokens.current
    val artifactOpener = LocalArtifactOpener.current
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
                TesseraKicker(stringResource(R.string.forwarding_title))
                Text(
                    stringResource(R.string.forwarding_intro),
                    modifier = Modifier.padding(top = 4.dp),
                    style = TesseraType.rowMeta,
                    color = tokens.fgMuted,
                )
            }
            TesseraButton(text = stringResource(R.string.forwarding_add), onClick = { creating = true }, compact = true)
        }
        TesseraHairline()

        if (rules.isEmpty()) {
            Text(
                stringResource(R.string.forwarding_no_rules),
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
                        onStart = onStartRule?.let { start -> { start(rule.id) } },
                        onStop = { onStopRule(rule.id) },
                        onOpenInBrowser = { target ->
                            val page = forwardingArtifactPage(rule, hostId, target.scheme, sessionHint)
                            if (artifactOpener != null && page != null) artifactOpener.open(page)
                            else browsing = BrowsingTunnel(target, rule.label)
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

/** A page tab is remote loopback; a rule targeting another machine keeps its browser. */
internal fun forwardingArtifactPage(
    rule: PortForwardRule,
    hostId: String?,
    scheme: String,
    sessionHint: String? = null,
): ArtifactOpenRequest.Page? {
    val target = rule.target ?: return null
    if (hostId.isNullOrBlank() || rule.direction != PortForwardDirection.LOCAL ||
        target.port !in 1..65_535 || !isArtifactLoopbackHost(target.host)) return null
    return ArtifactOpenRequest.Page(hostId, scheme, target.port, "/", ArtifactOpenOrigin.Forwarding, sessionHint)
}

/** Numeric parsing only: classifying a rule must never resolve a hostname. */
internal fun isArtifactLoopbackHost(host: String): Boolean {
    val value = host.trim()
    if (value.equals("localhost", ignoreCase = true) ||
        value in setOf("::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]")) return true
    val octets = value.split('.')
    return octets.size == 4 && octets.first() == "127" && octets.all { octet ->
        octet.isNotEmpty() && octet.length <= 3 && octet.all { it in '0'..'9' } &&
            octet.toInt() in 0..255
    }
}

@Composable
private fun ForwardRuleRow(
    rule: PortForwardRule,
    state: PortForwardingState?,
    onEnabledChanged: (Boolean) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onStart: (() -> Unit)?,
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
                    val directionTitle = stringResource(directionLabel(rule.direction)).lowercase()
                    Text(
                        rule.label.ifBlank { directionTitle },
                        style = TesseraType.rowTitle,
                        color = tokens.fg,
                    )
                    Text(ruleSummary(rule), style = TesseraType.code, color = tokens.fgMuted)
                }
                TesseraToggleRow(
                    title = stringResource(R.string.forwarding_enabled),
                    checked = rule.enabled,
                    onCheckedChange = onEnabledChanged,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 10.dp),
                    modifier = Modifier.weight(0.75f),
                )
            }
            Text(
                forwardRuleStatusText(forwardRuleStatus(rule, state, probed)),
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
                        text = stringResource(R.string.forwarding_open),
                        onClick = { onOpenInBrowser(webTarget) },
                        style = TesseraButtonStyle.Primary,
                        compact = true,
                        modifier = Modifier.heightIn(min = 48.dp).testTag("tunnel-open-${rule.bind.port}"),
                    )
                }
                TesseraButton(text = stringResource(R.string.forwarding_edit), onClick = onEdit, compact = true)
                TesseraButton(
                    text = stringResource(R.string.forwarding_delete),
                    onClick = onDelete,
                    style = TesseraButtonStyle.Danger,
                    compact = true,
                )
                if (status is PortForwardingStatus.Listening || status is PortForwardingStatus.Active ||
                    status is PortForwardingStatus.Starting
                ) {
                    TesseraButton(text = stringResource(R.string.forwarding_stop), onClick = onStop, compact = true)
                } else if (rule.enabled && onStart != null) {
                    TesseraButton(
                        text = stringResource(R.string.forwarding_start),
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
    var validation by remember(initial.id) { mutableStateOf<Int?>(null) }

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
            validation = R.string.forwarding_ports_whole_numbers
        } else {
            val error = PortForwardRuleValidator.validate(rule, existing)
            if (error == null) onSave(rule) else validation = validationText(error)
        }
    }

    TesseraDialog(
        title = if (initial.label.isBlank()) {
            stringResource(R.string.forwarding_rule_title)
        } else {
            stringResource(R.string.forwarding_edit_title, initial.label)
        },
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = stringResource(R.string.forwarding_cancel), onClick = onDismiss, compact = true)
            TesseraButton(
                text = stringResource(R.string.forwarding_save),
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
                label = stringResource(R.string.forwarding_label),
                placeholder = stringResource(R.string.forwarding_optional),
            )
            TesseraTextField(
                value = bindHost,
                onValueChange = { bindHost = it },
                label = stringResource(R.string.forwarding_bind_address),
                supporting = if (direction != PortForwardDirection.REMOTE) {
                    stringResource(R.string.forwarding_loopback_only)
                } else {
                    null
                },
            )
            TesseraTextField(
                value = bindPort,
                onValueChange = { bindPort = it.filter(Char::isDigit) },
                label = stringResource(
                    if (direction == PortForwardDirection.REMOTE) R.string.forwarding_bind_port_zero_allowed
                    else R.string.forwarding_bind_port,
                ),
            )
            if (direction != PortForwardDirection.DYNAMIC) {
                TesseraTextField(
                    value = targetHost,
                    onValueChange = { targetHost = it },
                    label = stringResource(
                        if (direction == PortForwardDirection.LOCAL) R.string.forwarding_remote_host
                        else R.string.forwarding_device_host,
                    ),
                )
                TesseraTextField(
                    value = targetPort,
                    onValueChange = { targetPort = it.filter(Char::isDigit) },
                    label = stringResource(R.string.forwarding_target_port),
                )
            }
            validation?.let { TesseraBanner(stringResource(it)) }
        }
    }
}

@Composable
private fun DirectionPicker(direction: PortForwardDirection, onSelected: (PortForwardDirection) -> Unit) {
    val choices = PortForwardDirection.entries
    TesseraSegmented(
        options = choices.map { stringResource(directionLabel(it)) },
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

@StringRes
private fun directionLabel(direction: PortForwardDirection): Int = when (direction) {
    PortForwardDirection.LOCAL -> R.string.forwarding_direction_local
    PortForwardDirection.REMOTE -> R.string.forwarding_direction_remote
    PortForwardDirection.DYNAMIC -> R.string.forwarding_direction_dynamic
}

@Composable
private fun ruleSummary(rule: PortForwardRule): String = when (rule.direction) {
    PortForwardDirection.LOCAL -> "${rule.bind.host}:${rule.bind.port} → ${rule.target?.host}:${rule.target?.port}"
    PortForwardDirection.REMOTE -> stringResource(
        R.string.forwarding_summary_remote,
        "${rule.bind.host}:${rule.bind.port}",
        "${rule.target?.host}:${rule.target?.port}",
    )
    PortForwardDirection.DYNAMIC -> "SOCKS5 ${rule.bind.host}:${rule.bind.port}"
}

/**
 * What a rule row's status line says. A listening rule also says whether
 * anything answers at the far end; those lines match iOS
 * `listeningStatusText` word for word.
 *
 * "checking…" is promised only for a rule the manager actively probes
 * ([probed]) and whose server has not refused forwarding outright: any other
 * unknown rule would never resolve, so it says only that it is listening.
 * The row already shows the bound address.
 */
internal sealed interface ForwardRuleStatusLine {
    data object Stopped : ForwardRuleStatusLine
    data object Starting : ForwardRuleStatusLine
    data object Serving : ForwardRuleStatusLine
    data class NothingServing(val remotePort: Int?) : ForwardRuleStatusLine
    data object Checking : ForwardRuleStatusLine
    data object Listening : ForwardRuleStatusLine
    data class Active(val connections: Int) : ForwardRuleStatusLine
    data class Failed(val failure: PortForwardingFailure) : ForwardRuleStatusLine
}

internal fun forwardRuleStatus(
    rule: PortForwardRule,
    state: PortForwardingState?,
    probed: Boolean,
): ForwardRuleStatusLine = when (val status = state?.status ?: PortForwardingStatus.Idle) {
    PortForwardingStatus.Idle -> ForwardRuleStatusLine.Stopped
    PortForwardingStatus.Starting -> ForwardRuleStatusLine.Starting
    is PortForwardingStatus.Listening -> when {
        state?.service == ForwardedServiceState.Serving -> ForwardRuleStatusLine.Serving
        state?.service == ForwardedServiceState.NotServing -> ForwardRuleStatusLine.NothingServing(rule.target?.port)
        probed && state?.forwardingProhibited != true -> ForwardRuleStatusLine.Checking
        else -> ForwardRuleStatusLine.Listening
    }
    is PortForwardingStatus.Active -> ForwardRuleStatusLine.Active(status.connectionCount)
    is PortForwardingStatus.Failed -> ForwardRuleStatusLine.Failed(status.failure)
}

/** The row's status line in the user's language. */
@Composable
internal fun forwardRuleStatusText(line: ForwardRuleStatusLine): String = when (line) {
    ForwardRuleStatusLine.Stopped -> stringResource(R.string.forwarding_status_stopped)
    ForwardRuleStatusLine.Starting -> stringResource(R.string.forwarding_status_starting)
    ForwardRuleStatusLine.Serving -> stringResource(R.string.forwarding_status_serving)
    is ForwardRuleStatusLine.NothingServing ->
        stringResource(R.string.forwarding_status_nothing_serving, line.remotePort.toString())
    ForwardRuleStatusLine.Checking -> stringResource(R.string.forwarding_status_checking)
    ForwardRuleStatusLine.Listening -> stringResource(R.string.forwarding_status_listening)
    is ForwardRuleStatusLine.Active ->
        pluralStringResource(R.plurals.forwarding_status_active_connections, line.connections, line.connections)
    is ForwardRuleStatusLine.Failed -> when (val failure = line.failure) {
        is PortForwardingFailure.Transport -> failure.display.text()
        is PortForwardingFailure.Unsupported -> failure.display.text()
        is PortForwardingFailure.Validation -> stringResource(validationText(failure.error))
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

@StringRes
private fun validationText(error: PortForwardRuleError): Int = when (error) {
    is PortForwardRuleError.InvalidBindAddress -> R.string.forwarding_invalid_bind_address
    is PortForwardRuleError.InvalidBindPort -> R.string.forwarding_invalid_bind_port
    is PortForwardRuleError.NonLoopbackLocalBind -> R.string.forwarding_non_loopback_local_bind
    PortForwardRuleError.MissingTarget -> R.string.forwarding_missing_target
    is PortForwardRuleError.InvalidTargetAddress -> R.string.forwarding_invalid_target_address
    is PortForwardRuleError.InvalidTargetPort -> R.string.forwarding_invalid_target_port
    PortForwardRuleError.DynamicForwardCannotHaveTarget -> R.string.forwarding_dynamic_cannot_have_target
    is PortForwardRuleError.BindCollision -> R.string.forwarding_bind_collision
}
