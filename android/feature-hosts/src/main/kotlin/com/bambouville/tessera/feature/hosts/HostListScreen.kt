package com.bambouville.tessera.feature.hosts

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.produceState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraActionStack
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraCard
import com.bambouville.tessera.design.TesseraConfirmDialog
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraFormDialog
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraLogoMark
import com.bambouville.tessera.design.TesseraOptionPicker
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraRowGlyph
import com.bambouville.tessera.design.TesseraSearchField
import com.bambouville.tessera.design.TesseraSegmented
import com.bambouville.tessera.design.TesseraSelectField
import com.bambouville.tessera.design.TesseraTag
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.forwarding.AndroidPortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingPanel
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.CredentialKinds
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.SavedIdentity
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import java.util.UUID
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch

@Composable
fun HostListScreen(
    repository: HostRepository,
    identities: IdentityRepository,
    modifier: Modifier = Modifier,
    connectedHostIds: Set<String> = emptySet(),
    onOpenHost: (SavedHost) -> Unit,
) {
    val context = LocalContext.current
    val tokens = LocalTesseraTokens.current
    val hostExportTitle = stringResource(R.string.host_export_title)
    val scope = rememberCoroutineScope()
    val forwardingStore = remember(context.applicationContext) {
        AndroidPortForwardRuleStore(context.applicationContext)
    }
    // `null` until the database answers. Collecting the cold flow with an
    // empty initial value rendered the "no hosts" empty state for one frame on
    // *every* tab switch, because the tab's content is rebuilt each time.
    val loadedHosts by repository.loadedHosts.collectAsState()
    val hosts = loadedHosts.orEmpty()
    val savedIdentities = identities.loadedIdentities.collectAsState().value.orEmpty()
    var editing by remember { mutableStateOf<SavedHost?>(null) }
    var deleting by remember { mutableStateOf<SavedHost?>(null) }
    var forwardingHost by remember { mutableStateOf<SavedHost?>(null) }
    var creating by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var importError by remember { mutableStateOf<String?>(null) }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                val contents = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                        ?: error("The selected host file is unavailable")
                }
                val payload = HostImportCodec.decode(contents)
                val saved = repository.save(payload.host)
                forwardingStore.replace(saved.id, payload.forwardingRules)
            } catch (failure: Throwable) {
                importError = failure.message ?: "The host could not be imported"
            }
        }
    }
    val visibleHosts = remember(hosts, query) {
        val needle = query.trim()
        if (needle.isEmpty()) hosts else hosts.filter { host ->
            host.displayName.contains(needle, ignoreCase = true) ||
                host.hostname.contains(needle, ignoreCase = true) ||
                host.username.contains(needle, ignoreCase = true)
        }
    }

    Column(modifier.background(tokens.bg)) {
        TesseraPageHeader(title = stringResource(R.string.hosts_title).lowercase(), hero = true) {
            TesseraIconButton(
                icon = TesseraIcons.Download,
                contentDescription = stringResource(R.string.host_import_action),
                onClick = { importLauncher.launch(arrayOf("application/json", "text/json", "text/plain")) },
            )
            TesseraIconButton(
                icon = TesseraIcons.Plus,
                contentDescription = stringResource(R.string.host_add),
                onClick = { creating = true },
                prominent = true,
            )
        }
        TesseraHairline()
        if (hosts.isNotEmpty()) {
            TesseraSearchField(
                value = query,
                onValueChange = { query = it },
                placeholder = stringResource(R.string.host_search),
                clearContentDescription = stringResource(R.string.host_search_clear),
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 10.dp),
            )
        }
        if (loadedHosts == null) {
            // Nothing to say yet: an unanswered database is not an empty one.
            Spacer(Modifier.fillMaxSize().weight(1f))
        } else if (visibleHosts.isEmpty()) {
            EmptyHosts(
                modifier = Modifier.fillMaxSize().weight(1f),
                filtered = hosts.isNotEmpty(),
                onAdd = { creating = true },
            )
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize().weight(1f)) {
                items(visibleHosts, key = SavedHost::id) { host ->
                    CompactHostRow(
                        host = host,
                        onOpen = { onOpenHost(host) },
                        onEdit = { editing = host },
                        onDelete = { deleting = host },
                        onForwarding = { forwardingHost = host },
                        onExport = {
                            scope.launch {
                                val rules = forwardingStore.observe(host.id).first()
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND).apply {
                                            type = "application/json"
                                            putExtra(Intent.EXTRA_TEXT, HostImportCodec.encode(host, rules))
                                        },
                                        hostExportTitle,
                                    ),
                                )
                            }
                        },
                        connected = host.id in connectedHostIds,
                    )
                }
            }
        }
    }

    if (creating) {
        HostEditorForm(
            host = null,
            repository = repository,
            availableHosts = hosts,
            identities = savedIdentities,
            onDismiss = { creating = false },
        )
    }
    editing?.let { host ->
        HostEditorForm(
            host = host,
            repository = repository,
            availableHosts = hosts,
            identities = savedIdentities,
            onDismiss = { editing = null },
        )
    }
    forwardingHost?.let { host ->
        HostForwardingEditor(
            host = host,
            store = forwardingStore,
            onDismiss = { forwardingHost = null },
        )
    }
    deleting?.let { host ->
        val deleteScope = rememberCoroutineScope()
        val usedAsJump = hosts.any { it.jumpHostId == host.id }
        TesseraConfirmDialog(
            title = stringResource(R.string.host_delete_title, host.displayName),
            body = if (usedAsJump) stringResource(R.string.host_delete_used_as_jump)
            else stringResource(R.string.host_delete_body),
            confirmLabel = stringResource(R.string.host_delete),
            cancelLabel = stringResource(R.string.host_cancel),
            destructive = true,
            confirmEnabled = !usedAsJump,
            onConfirm = {
                deleteScope.launch {
                    forwardingStore.delete(host.id)
                    repository.delete(host.id)
                    deleting = null
                }
            },
            onDismiss = { deleting = null },
        )
    }
    importError?.let { message ->
        TesseraDialog(
            title = stringResource(R.string.host_import_failed),
            onDismissRequest = { importError = null },
            actions = {
                TesseraButton(
                    text = stringResource(R.string.host_close),
                    onClick = { importError = null },
                    style = TesseraButtonStyle.Primary,
                    compact = true,
                )
            },
        ) {
            TesseraBanner(text = message)
        }
    }
}

@Composable
private fun HostForwardingEditor(
    host: SavedHost,
    store: PortForwardRuleStore,
    onDismiss: () -> Unit,
) {
    val rules by store.observe(host.id).collectAsState(initial = emptyList())
    val scope = rememberCoroutineScope()
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxSize().background(tokens.bg)) {
        TesseraSubPageHeader(
            title = "${host.displayName} · forwarding",
            onBack = onDismiss,
            backContentDescription = "Back to hosts",
        )
        TesseraHairline()
        PortForwardingPanel(
            rules = rules,
            states = emptyMap(),
            onRulesChanged = { updated -> scope.launch { store.replace(host.id, updated) } },
            modifier = Modifier.fillMaxSize().weight(1f),
        )
    }
}

@Composable
private fun EmptyHosts(modifier: Modifier, filtered: Boolean, onAdd: () -> Unit) {
    if (filtered) {
        TesseraEmptyState(
            title = stringResource(R.string.hosts_no_results).lowercase(),
            body = stringResource(R.string.hosts_no_results_body),
            icon = TesseraIcons.Search,
            modifier = modifier,
        )
    } else {
        TesseraEmptyState(
            title = stringResource(R.string.hosts_empty_title).lowercase(),
            body = stringResource(R.string.hosts_empty_body),
            mark = { TesseraLogoMark(size = 56.dp) },
            modifier = modifier,
            action = {
                TesseraButton(
                    text = stringResource(R.string.host_add),
                    onClick = onAdd,
                    style = TesseraButtonStyle.Primary,
                )
            },
        )
    }
}

@Composable
private fun CompactHostRow(
    host: SavedHost,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onForwarding: () -> Unit,
    onExport: () -> Unit,
    connected: Boolean,
) {
    val tokens = LocalTesseraTokens.current
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 70.dp)
            .testTag("host-row")
            .clickable(onClick = onOpen)
            .padding(start = 18.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Green is a claim about *now*: this host has a session that is
        // connected. Anything short of that — a resumable record, a session
        // still dialling, one that failed — says nothing here, and the
        // sessions tab is where a session's own state is spelled out.
        TesseraRowGlyph(
            icon = TesseraIcons.Hosts,
            badge = if (connected) tokens.green else null,
        )
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(
                host.displayName,
                style = TesseraType.rowTitle,
                color = tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = stringResource(
                    R.string.host_endpoint_format,
                    host.username,
                    host.hostname,
                    host.port,
                ),
                color = tokens.fgMuted,
                style = TesseraType.rowMeta,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // Transport and session mode are orthogonal, so the tag names both:
        // the transport always, the tmux mode only when one is set.
        Text(
            listOfNotNull(
                if (host.transportKind == TransportKinds.MOSH) "mosh" else "ssh",
                when (host.tmuxMode) {
                    TmuxModes.AUTOMATIC -> "tmux"
                    TmuxModes.PINNED -> "tmux:${host.tmuxTarget.orEmpty()}"
                    else -> null
                },
            ).joinToString(" · "),
            color = tokens.fgDim,
            style = TesseraType.rowMicro,
            maxLines = 1,
        )
        Box {
            TesseraIconButton(
                icon = TesseraIcons.MoreVertical,
                contentDescription = stringResource(R.string.host_actions, host.displayName),
                onClick = { menuOpen = true },
            )
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.host_open)) },
                    onClick = { menuOpen = false; onOpen() },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.host_edit)) },
                    onClick = { menuOpen = false; onEdit() },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.host_export)) },
                    onClick = { menuOpen = false; onExport() },
                )
                DropdownMenuItem(
                    text = { Text("port forwarding") },
                    onClick = { menuOpen = false; onForwarding() },
                )
                DropdownMenuItem(
                    text = {
                        Text(stringResource(R.string.host_delete), color = LocalTesseraTokens.current.red)
                    },
                    onClick = { menuOpen = false; onDelete() },
                )
            }
        }
    }
    TesseraHairline(Modifier.padding(start = 66.dp))
}

/**
 * Host editor.
 *
 * A full-screen form rather than an alert: seven controls plus two pickers do not
 * fit a centred dialog once the software keyboard is up, and the authentication
 * menu — anchored inside the old dialog's scrolling body — opened straight over its
 * own Save and Cancel row. Here the actions live in a fixed header the form scrolls
 * under, and each picker owns a surface of its own.
 */
@Composable
private fun HostEditorForm(
    host: SavedHost?,
    repository: HostRepository,
    availableHosts: List<SavedHost>,
    identities: List<SavedIdentity>,
    onDismiss: () -> Unit,
) {
    var displayName by remember(host?.id) { mutableStateOf(host?.displayName.orEmpty()) }
    var hostname by remember(host?.id) { mutableStateOf(host?.hostname.orEmpty()) }
    var port by remember(host?.id) { mutableStateOf(host?.port?.toString() ?: "22") }
    var username by remember(host?.id) { mutableStateOf(host?.username.orEmpty()) }
    var error by remember(host?.id) { mutableStateOf<String?>(null) }
    var saving by remember(host?.id) { mutableStateOf(false) }
    var jumpHostId by remember(host?.id) { mutableStateOf(host?.jumpHostId) }
    var identityId by remember(host?.id) { mutableStateOf(host?.identityId) }
    var jumpPicker by remember { mutableStateOf(false) }
    var identityPicker by remember { mutableStateOf(false) }
    var transportKind by remember(host?.id) { mutableStateOf(host?.transportKind ?: TransportKinds.SSH) }
    var tmuxMode by remember(host?.id) { mutableStateOf(host?.tmuxMode ?: TmuxModes.OFF) }
    var tmuxTarget by remember(host?.id) { mutableStateOf(host?.tmuxTarget.orEmpty()) }
    var launchCommand by remember(host?.id) { mutableStateOf(host?.launchCommand.orEmpty()) }
    var notes by remember(host?.id) { mutableStateOf(host?.notes.orEmpty()) }
    var envVars by remember(host?.id) { mutableStateOf(host?.envVars.orEmpty()) }
    var startupSnippet by remember(host?.id) { mutableStateOf(host?.startupSnippet.orEmpty()) }
    val scope = rememberCoroutineScope()

    fun save() {
        if (saving) return
        saving = true
        error = null
        scope.launch {
            try {
                repository.save(
                    HostDraft(
                        id = host?.id,
                        displayName = displayName,
                        hostname = hostname,
                        port = port.toIntOrNull()
                            ?: throw IllegalArgumentException("port must be a number"),
                        username = username,
                        jumpHostId = jumpHostId,
                        identityId = identityId,
                        transportKind = transportKind,
                        tmuxMode = tmuxMode,
                        tmuxTarget = tmuxTarget,
                        launchCommand = launchCommand.takeIf { it.isNotBlank() },
                        notes = notes.takeIf { it.isNotBlank() },
                        envVars = envVars.takeIf { it.isNotBlank() },
                        startupSnippet = startupSnippet.takeIf { it.isNotBlank() },
                    ),
                )
                onDismiss()
            } catch (failure: IllegalArgumentException) {
                error = failure.message
                saving = false
            }
        }
    }

    val jumpCandidates = remember(availableHosts, host?.id) { availableHosts.filter { it.id != host?.id } }
    val jumpLabels = listOf(stringResource(R.string.host_jump_direct)) +
        jumpCandidates.map { stringResource(R.string.host_jump_via, it.displayName) }
    val identityLabels = listOf(stringResource(R.string.host_auth_password)) +
        identities.map { it.displayName }
    val transportLabels = listOf(
        stringResource(R.string.host_transport_ssh_short),
        stringResource(R.string.host_transport_mosh_short),
    )
    val transportIndex = if (transportKind == TransportKinds.MOSH) 1 else 0
    val tmuxLabels = listOf(
        stringResource(R.string.host_tmux_off_short),
        stringResource(R.string.host_tmux_automatic_short),
        stringResource(R.string.host_tmux_pinned_short),
    )
    val tmuxIndex = when (tmuxMode) {
        TmuxModes.AUTOMATIC -> 1
        TmuxModes.PINNED -> 2
        else -> 0
    }

    TesseraFormDialog(
        title = stringResource(if (host == null) R.string.host_add else R.string.host_edit),
        onCancel = onDismiss,
        cancelLabel = stringResource(R.string.host_cancel),
        submitLabel = stringResource(R.string.host_save),
        onSubmit = ::save,
        submitEnabled = !saving,
    ) {
        TesseraTextField(
            value = displayName,
            onValueChange = { displayName = it },
            modifier = Modifier.fillMaxWidth(),
            inputTestTag = "host-name",
            label = stringResource(R.string.host_name),
        )
        TesseraTextField(
            value = hostname,
            onValueChange = { hostname = it },
            modifier = Modifier.fillMaxWidth(),
            inputTestTag = "host-address",
            label = stringResource(R.string.host_address),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TesseraTextField(
                value = username,
                onValueChange = { username = it },
                modifier = Modifier.weight(1f),
                inputTestTag = "host-username",
                label = stringResource(R.string.host_username),
            )
            TesseraTextField(
                value = port,
                onValueChange = { port = it.filter(Char::isDigit).take(5) },
                modifier = Modifier.weight(0.6f),
                inputTestTag = "host-port",
                label = stringResource(R.string.host_port),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        }
        TesseraSelectField(
            label = stringResource(R.string.host_jump_label),
            value = jumpHostId?.let { id -> availableHosts.firstOrNull { it.id == id }?.displayName }
                ?: stringResource(R.string.host_jump_direct),
            onClick = { jumpPicker = true },
            inputTestTag = "host-jump-selector",
        )
        // Transport (ssh / mosh) and session mode (off / tmux / pinned) are
        // orthogonal: every combination is a valid host, and the pairing
        // import can produce any of them, so the editor must show both or an
        // edit silently rewrites the one it cannot see.
        Column {
            Text(
                stringResource(R.string.host_transport_label),
                modifier = Modifier.padding(bottom = 6.dp),
                style = TesseraType.fieldLabel,
                color = LocalTesseraTokens.current.fgMuted,
            )
            TesseraSegmented(
                options = transportLabels,
                selectedIndex = transportIndex,
                onSelect = { index ->
                    transportKind = if (index == 1) TransportKinds.MOSH else TransportKinds.SSH
                },
                modifier = Modifier.testTag("host-transport"),
            )
            Text(
                if (transportKind == TransportKinds.MOSH) {
                    stringResource(R.string.host_transport_mosh)
                } else {
                    stringResource(R.string.host_transport_ssh)
                },
                modifier = Modifier.padding(top = 8.dp),
                style = TesseraType.bodySmall,
                color = LocalTesseraTokens.current.fgMuted,
            )
        }
        Column {
            Text(
                stringResource(R.string.host_tmux_label),
                modifier = Modifier.padding(bottom = 6.dp),
                style = TesseraType.fieldLabel,
                color = LocalTesseraTokens.current.fgMuted,
            )
            TesseraSegmented(
                options = tmuxLabels,
                selectedIndex = tmuxIndex,
                onSelect = { index ->
                    tmuxMode = when (index) {
                        1 -> TmuxModes.AUTOMATIC
                        2 -> TmuxModes.PINNED
                        else -> TmuxModes.OFF
                    }
                },
            )
            Text(
                when (tmuxMode) {
                    TmuxModes.AUTOMATIC -> stringResource(R.string.host_tmux_automatic)
                    TmuxModes.PINNED -> stringResource(R.string.host_tmux_pinned)
                    else -> stringResource(R.string.host_tmux_off)
                },
                modifier = Modifier.padding(top = 8.dp),
                style = TesseraType.bodySmall,
                color = LocalTesseraTokens.current.fgMuted,
            )
        }
        if (tmuxMode == TmuxModes.PINNED) {
            TesseraTextField(
                value = tmuxTarget,
                onValueChange = { tmuxTarget = it.take(100) },
                modifier = Modifier.fillMaxWidth(),
            inputTestTag = "host-tmux-target",
                label = stringResource(R.string.host_tmux_target),
            )
        }
        TesseraSelectField(
            label = stringResource(R.string.host_auth_label),
            value = identityId?.let { id -> identities.firstOrNull { it.id == id }?.displayName }
                ?: stringResource(R.string.host_auth_password),
            onClick = { identityPicker = true },
            inputTestTag = "host-auth-selector",
        )
        Text("Optional host data", style = TesseraType.body)
        Text("Stored only on this device unless explicitly selected during pairing. Shell fields run on connect; review imported commands before connecting.", style = TesseraType.bodySmall, color = LocalTesseraTokens.current.fgMuted)
        TesseraTextField(value = notes, onValueChange = { notes = it }, label = "notes", singleLine = false, modifier = Modifier.fillMaxWidth(), inputTestTag = "host-notes")
        TesseraTextField(value = envVars, onValueChange = { envVars = it }, label = "environment variables (KEY=value)", singleLine = false, modifier = Modifier.fillMaxWidth(), inputTestTag = "host-env-vars")
        TesseraTextField(value = startupSnippet, onValueChange = { startupSnippet = it }, label = "startup snippet", singleLine = false, modifier = Modifier.fillMaxWidth(), inputTestTag = "host-startup-snippet")
        TesseraTextField(value = launchCommand, onValueChange = { launchCommand = it }, label = "custom command (when tmux is off)", singleLine = false, modifier = Modifier.fillMaxWidth(), inputTestTag = "host-launch-command")
        error?.let { TesseraBanner(text = it) }
        Spacer(Modifier.height(8.dp))
    }

    if (jumpPicker) {
        TesseraOptionPicker(
            title = stringResource(R.string.host_jump_label),
            options = jumpLabels,
            selectedIndex = jumpHostId?.let { id -> jumpCandidates.indexOfFirst { it.id == id } + 1 } ?: 0,
            onSelect = { index ->
                jumpHostId = if (index == 0) null else jumpCandidates[index - 1].id
                jumpPicker = false
            },
            onDismiss = { jumpPicker = false },
        )
    }
    if (identityPicker) {
        TesseraOptionPicker(
            title = stringResource(R.string.host_auth_label),
            options = identityLabels,
            selectedIndex = identityId?.let { id -> identities.indexOfFirst { it.id == id } + 1 } ?: 0,
            onSelect = { index ->
                identityId = if (index == 0) null else identities[index - 1].id
                identityPicker = false
            },
            onDismiss = { identityPicker = false },
        )
    }
}

@Composable
fun IdentityListScreen(
    repository: IdentityRepository,
    hostRepository: HostRepository,
    knownHostsRepository: KnownHostsRepository,
    credentialStore: AndroidKeystoreCredentialStore,
    modifier: Modifier = Modifier,
    onSystemUiActiveChanged: (Boolean) -> Unit = {},
) {
    val tokens = LocalTesseraTokens.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val loadedIdentities by repository.loadedIdentities.collectAsState()
    val identities = loadedIdentities.orEmpty()
    val hosts = hostRepository.loadedHosts.collectAsState().value.orEmpty()
    val referencedIdentityIds = hosts.mapNotNull(SavedHost::identityId).toSet()
    var displayName by remember { mutableStateOf("") }
    var ownerAuth by remember { mutableStateOf(false) }
    var selectedIdentity by remember { mutableStateOf<SavedIdentity?>(null) }
    var installingIdentity by remember { mutableStateOf<SavedIdentity?>(null) }
    var deletingIdentity by remember { mutableStateOf<SavedIdentity?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun generate() {
        if (displayName.isBlank() || busy) return
        val requestedName = displayName.trim()
        val requestedOwnerAuth = ownerAuth
        busy = true
        error = null
        scope.launch {
            try {
                val id = UUID.randomUUID().toString()
                val alias = "tessera-identity-$id"
                Log.i("TesseraKeystore", "Generating P-256 identity")
                withContext(Dispatchers.IO) {
                    credentialStore.generateP256(
                        alias = alias,
                        ownerAuthenticationRequired = requestedOwnerAuth,
                        ownerAuthenticationValiditySeconds = if (requestedOwnerAuth) 30 else null,
                    )
                    try {
                        repository.save(
                            displayName = requestedName,
                            credentialKind = CredentialKinds.ANDROID_KEYSTORE_P256,
                            credentialReference = alias,
                            id = id,
                        )
                    } catch (failure: Throwable) {
                        credentialStore.delete(alias)
                        throw failure
                    }
                }
                Log.i("TesseraKeystore", "Stored P-256 identity")
                displayName = ""
                ownerAuth = false
                focusManager.clearFocus(force = true)
                keyboardController?.hide()
            } catch (failure: Throwable) {
                Log.e("TesseraKeystore", "Identity generation failed", failure)
                error = failure.message ?: failure::class.java.simpleName
            } finally {
                busy = false
            }
        }
    }

    Column(modifier.background(tokens.bg).imePadding()) {
        TesseraPageHeader(stringResource(R.string.identities_title).lowercase())
        TesseraHairline()
        if (loadedIdentities == null) {
            Spacer(Modifier.fillMaxWidth().weight(1f))
        } else if (identities.isEmpty()) {
            TesseraEmptyState(
                title = stringResource(R.string.identities_empty_title),
                body = stringResource(R.string.identities_empty_body),
                icon = TesseraIcons.Keys,
                modifier = Modifier.fillMaxWidth().weight(1f),
            )
        } else {
            LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                items(identities, key = SavedIdentity::id) { identity ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 70.dp)
                            .padding(start = 18.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TesseraRowGlyph(icon = TesseraIcons.Keys)
                        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                            Text(
                                identity.displayName,
                                style = TesseraType.rowTitle,
                                color = tokens.fg,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            IdentityStatusLine(identity, credentialStore)
                        }
                        TesseraButton(
                            text = stringResource(R.string.identity_details).lowercase(),
                            onClick = { selectedIdentity = identity },
                            modifier = Modifier.testTag("identity-details-${identity.id}"),
                            compact = true,
                            enabled = !busy,
                        )
                    }
                    TesseraHairline(Modifier.padding(start = 66.dp))
                }
            }
        }

        TesseraHairline()
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(18.dp),
        ) {
            TesseraCard {
                TesseraKicker(stringResource(R.string.identity_new))
                Spacer(Modifier.height(12.dp))
                TesseraTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    modifier = Modifier.fillMaxWidth(),
                    inputTestTag = "identity-name",
                    label = stringResource(R.string.identity_name),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(
                        onDone = {
                            Log.i("TesseraKeystore", "Submitting identity generation from keyboard")
                            generate()
                        },
                    ),
                )
                Spacer(Modifier.height(4.dp))
                TesseraToggleRow(
                    title = stringResource(R.string.identity_owner_auth),
                    subtitle = stringResource(R.string.identity_owner_auth_body),
                    checked = ownerAuth,
                    onCheckedChange = { ownerAuth = it },
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 10.dp),
                )
                error?.let {
                    TesseraBanner(text = it, modifier = Modifier.padding(bottom = 10.dp))
                }
                TesseraButton(
                    text = stringResource(R.string.identity_generate),
                    onClick = ::generate,
                    modifier = Modifier.fillMaxWidth().testTag("identity-generate"),
                    style = TesseraButtonStyle.Primary,
                    icon = TesseraIcons.Plus,
                    enabled = displayName.isNotBlank() && !busy,
                )
            }
        }
    }

    selectedIdentity?.let { identity ->
        IdentityDetailsDialog(
            identity = identity,
            credentialStore = credentialStore,
            deletable = identity.id !in referencedIdentityIds,
            onInstall = { installingIdentity = identity; selectedIdentity = null },
            onDelete = { deletingIdentity = identity; selectedIdentity = null },
            onDismiss = { selectedIdentity = null },
        )
    }
    installingIdentity?.let { identity ->
        InstallKeyToHostDialog(
            identity = identity,
            hosts = hosts,
            hostRepository = hostRepository,
            identityRepository = repository,
            knownHostsRepository = knownHostsRepository,
            credentialStore = credentialStore,
            onSystemUiActiveChanged = onSystemUiActiveChanged,
            onDismiss = { installingIdentity = null },
        )
    }
    deletingIdentity?.let { identity ->
        TesseraConfirmDialog(
            title = stringResource(R.string.identity_delete_title, identity.displayName),
            body = stringResource(R.string.identity_delete_body),
            confirmLabel = stringResource(R.string.identity_delete),
            cancelLabel = stringResource(R.string.host_cancel),
            destructive = true,
            onConfirm = {
                busy = true
                scope.launch {
                    withContext(Dispatchers.IO) {
                        credentialStore.delete(identity.credentialReference)
                        repository.delete(identity.id)
                    }
                    busy = false
                    deletingIdentity = null
                }
            },
            onDismiss = { deletingIdentity = null },
        )
    }
}

@Composable
private fun IdentityStatusLine(
    identity: SavedIdentity,
    credentialStore: AndroidKeystoreCredentialStore,
) {
    val tokens = LocalTesseraTokens.current
    val result by produceState<Result<com.bambouville.tessera.security.StoredKeystoreCredential>?>(
        initialValue = null,
        key1 = identity.credentialReference,
    ) {
        value = withContext(Dispatchers.IO) { runCatching { credentialStore.load(identity.credentialReference) } }
    }
    val credential = result?.getOrNull()
    val unavailable = result != null && credential == null
    Text(
        when {
            result == null -> stringResource(R.string.identity_loading)
            credential == null -> stringResource(R.string.identity_needs_replacement)
            credential.capabilities.ownerAuthenticationRequired -> stringResource(R.string.identity_protected)
            else -> stringResource(R.string.identity_device_bound)
        },
        modifier = Modifier.padding(top = 2.dp),
        color = if (unavailable) tokens.red else tokens.fgMuted,
        style = TesseraType.rowMeta,
    )
}

/**
 * Key details.
 *
 * Install, Copy, and Share are peers, not a confirm/cancel pair, so they sit in the
 * body as a stack and the dialog keeps a single Done action. Routing them through
 * Material's confirm/dismiss slots was what produced the cramped, overlapping row on
 * a compact phone: those slots reflow into a `FlowRow` sized for two short labels.
 */
@Composable
private fun IdentityDetailsDialog(
    identity: SavedIdentity,
    credentialStore: AndroidKeystoreCredentialStore,
    deletable: Boolean,
    onInstall: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val tokens = LocalTesseraTokens.current
    val sharePublicKeyTitle = stringResource(R.string.identity_share_public_key)
    val credentialResult by produceState<Result<com.bambouville.tessera.security.StoredKeystoreCredential>?>(
        initialValue = null,
        key1 = identity.credentialReference,
    ) {
        value = withContext(Dispatchers.IO) {
            runCatching { credentialStore.load(identity.credentialReference) }
                .onSuccess { Log.i("TesseraKeystore", "Loaded P-256 identity details") }
                .onFailure { Log.e("TesseraKeystore", "Identity detail load failed", it) }
        }
    }
    val credential = credentialResult?.getOrNull()
    val publicKey = credential?.let {
        "ecdsa-sha2-nistp256 ${Base64.encodeToString(it.publicKeyBlob, Base64.NO_WRAP)} ${identity.displayName.openSshComment()}"
    }
    val fingerprint = credential?.let {
        "SHA256:" + Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(it.publicKeyBlob),
            Base64.NO_WRAP or Base64.NO_PADDING,
        )
    }
    TesseraDialog(
        title = identity.displayName,
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("identity-details-dialog"),
        actions = {
            if (deletable) {
                TesseraButton(
                    text = stringResource(R.string.identity_delete),
                    onClick = onDelete,
                    style = TesseraButtonStyle.Danger,
                    compact = true,
                )
            }
            TesseraButton(
                text = stringResource(R.string.host_close),
                onClick = onDismiss,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        },
    ) {
        when {
            credentialResult == null -> Text(
                stringResource(R.string.identity_loading),
                style = TesseraType.body,
                color = tokens.fgMuted,
            )
            credential == null -> TesseraBanner(text = stringResource(R.string.identity_unavailable))
            else -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TesseraTag(credential.capabilities.securityLevel.name.lowercase().replace('_', ' '))
                    TesseraTag(
                        if (credential.capabilities.ownerAuthenticationRequired) {
                            stringResource(R.string.identity_protected)
                        } else {
                            stringResource(R.string.identity_device_bound)
                        },
                        tone = tokens.green,
                    )
                }
                DetailBlock(label = stringResource(R.string.identity_fingerprint), value = fingerprint.orEmpty())
                DetailBlock(
                    label = stringResource(R.string.identity_public_key),
                    value = publicKey.orEmpty(),
                    maxLines = 4,
                )
                TesseraActionStack {
                    TesseraButton(
                        text = stringResource(R.string.identity_install_to_host),
                        onClick = onInstall,
                        modifier = Modifier.fillMaxWidth(),
                        style = TesseraButtonStyle.Primary,
                        icon = TesseraIcons.Install,
                        enabled = publicKey != null,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TesseraButton(
                            text = stringResource(R.string.identity_copy_public_key),
                            onClick = {
                                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                clipboard.setPrimaryClip(ClipData.newPlainText("SSH public key", publicKey))
                            },
                            modifier = Modifier.weight(1f),
                            icon = TesseraIcons.Copy,
                            enabled = publicKey != null,
                        )
                        TesseraButton(
                            text = stringResource(R.string.identity_share),
                            onClick = {
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND).apply {
                                            type = "text/plain"
                                            putExtra(Intent.EXTRA_TEXT, publicKey)
                                        },
                                        sharePublicKeyTitle,
                                    ),
                                )
                            },
                            modifier = Modifier.weight(1f),
                            icon = TesseraIcons.Share,
                            enabled = publicKey != null,
                        )
                    }
                }
            }
        }
    }
}

/** Labelled verbatim value: fingerprints and public keys, in a bordered mono block. */
@Composable
private fun DetailBlock(label: String, value: String, maxLines: Int = 2) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxWidth()) {
        TesseraKicker(label, Modifier.padding(bottom = 6.dp))
        Text(
            value,
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.inputBg, RoundedCornerShape(8.dp))
                .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            style = TesseraType.code,
            color = tokens.fg,
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun InstallKeyToHostDialog(
    identity: SavedIdentity,
    hosts: List<SavedHost>,
    hostRepository: HostRepository,
    identityRepository: IdentityRepository,
    knownHostsRepository: KnownHostsRepository,
    credentialStore: AndroidKeystoreCredentialStore,
    onSystemUiActiveChanged: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val tokens = LocalTesseraTokens.current
    val scope = rememberCoroutineScope()
    val controller = remember(identity.id, hostRepository, identityRepository, knownHostsRepository) {
        AuthorizedKeyInstallController(
            hosts = hostRepository,
            identities = identityRepository,
            knownHosts = knownHostsRepository,
            credentialStore = credentialStore,
            scope = scope,
        )
    }
    val state by controller.state.collectAsState()
    var selectedHost by remember { mutableStateOf<SavedHost?>(null) }
    var hostPicker by remember { mutableStateOf(false) }
    var password by remember((state as? AuthorizedKeyInstallState.AwaitingPassword)?.hop?.id) {
        mutableStateOf("")
    }
    val ownerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        onSystemUiActiveChanged(false)
        controller.decideOwnerAuthorization(result.resultCode == Activity.RESULT_OK)
    }
    val ownerRequest = state as? AuthorizedKeyInstallState.AwaitingOwnerAuthorization
    LaunchedEffect(ownerRequest?.requestId) {
        val request = ownerRequest ?: return@LaunchedEffect
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val intent = keyguard.createConfirmDeviceCredentialIntent(
            "Unlock Tessera key",
            "Use ${request.hop.username}@${request.hop.endpoint.host} key",
        )
        if (intent == null) controller.decideOwnerAuthorization(false) else {
            onSystemUiActiveChanged(true)
            ownerLauncher.launch(intent)
        }
    }
    fun dismiss() {
        controller.cancel()
        onDismiss()
    }
    TesseraDialog(
        title = stringResource(R.string.identity_install_title, identity.displayName),
        onDismissRequest = ::dismiss,
        dismissOnClickOutside = false,
        actions = {
            when (val value = state) {
                AuthorizedKeyInstallState.Idle -> {
                    TesseraButton(
                        text = stringResource(R.string.host_cancel),
                        onClick = ::dismiss,
                        compact = true,
                    )
                    TesseraButton(
                        text = stringResource(R.string.identity_continue),
                        onClick = { selectedHost?.let { controller.install(it, identity) } },
                        style = TesseraButtonStyle.Primary,
                        enabled = selectedHost != null,
                        compact = true,
                    )
                }
                is AuthorizedKeyInstallState.AwaitingPassword -> {
                    TesseraButton(
                        text = stringResource(R.string.host_cancel),
                        onClick = ::dismiss,
                        compact = true,
                    )
                    TesseraButton(
                        text = stringResource(R.string.identity_continue),
                        onClick = { controller.submitPassword(password); password = "" },
                        style = TesseraButtonStyle.Primary,
                        enabled = password.isNotEmpty(),
                        compact = true,
                    )
                }
                is AuthorizedKeyInstallState.AwaitingHostKey -> {
                    TesseraButton(
                        text = stringResource(R.string.host_cancel),
                        onClick = { controller.decideHostKey(false); dismiss() },
                        compact = true,
                    )
                    TesseraButton(
                        text = if (value.changed || value.reverted) {
                            stringResource(R.string.identity_replace_and_continue)
                        } else {
                            stringResource(R.string.identity_trust_and_continue)
                        },
                        onClick = { controller.decideHostKey(true) },
                        style = if (value.changed || value.reverted) {
                            TesseraButtonStyle.Danger
                        } else {
                            TesseraButtonStyle.Primary
                        },
                        compact = true,
                    )
                }
                AuthorizedKeyInstallState.Succeeded,
                is AuthorizedKeyInstallState.Failed -> TesseraButton(
                    text = stringResource(R.string.host_close),
                    onClick = ::dismiss,
                    style = TesseraButtonStyle.Primary,
                    compact = true,
                )
                else -> TesseraButton(
                    text = stringResource(R.string.host_cancel),
                    onClick = ::dismiss,
                    compact = true,
                )
            }
        },
    ) {
        when (val value = state) {
            AuthorizedKeyInstallState.Idle -> {
                Text(
                    stringResource(R.string.identity_install_body),
                    style = TesseraType.body,
                    color = tokens.fgMuted,
                )
                TesseraSelectField(
                    label = stringResource(R.string.identity_choose_host),
                    value = selectedHost?.displayName ?: stringResource(R.string.identity_choose_host),
                    onClick = { hostPicker = true },
                    enabled = hosts.isNotEmpty(),
                    inputTestTag = "install-host-selector",
                )
            }
            AuthorizedKeyInstallState.Connecting -> ProgressLine(stringResource(R.string.identity_install_connecting))
            AuthorizedKeyInstallState.Installing -> ProgressLine(stringResource(R.string.identity_install_running))
            AuthorizedKeyInstallState.Succeeded -> TesseraBanner(
                text = stringResource(R.string.identity_install_succeeded),
                tone = com.bambouville.tessera.design.TesseraBannerTone.Info,
            )
            is AuthorizedKeyInstallState.Failed -> TesseraBanner(text = value.message)
            is AuthorizedKeyInstallState.AwaitingPassword -> {
                TesseraTextField(
                    value = password,
                    onValueChange = { password = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = stringResource(
                        R.string.identity_password_for,
                        value.hop.username,
                        value.hop.endpoint.host,
                    ),
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                )
            }
            is AuthorizedKeyInstallState.AwaitingHostKey -> {
                if (value.changed || value.reverted) {
                    TesseraBanner(
                        text = if (value.reverted) {
                            stringResource(R.string.identity_host_key_reverted)
                        } else {
                            stringResource(R.string.identity_host_key_changed)
                        },
                    )
                } else {
                    Text(
                        stringResource(R.string.identity_host_key_unknown),
                        style = TesseraType.body,
                        color = tokens.fgMuted,
                    )
                }
                DetailBlock(
                    label = stringResource(R.string.identity_host_endpoint),
                    value = "${value.observation.host}:${value.observation.port}",
                )
                DetailBlock(label = stringResource(R.string.identity_fingerprint), value = value.fingerprint)
                value.previousFingerprint?.let {
                    DetailBlock(label = stringResource(R.string.identity_previous_fingerprint), value = it)
                }
            }
            is AuthorizedKeyInstallState.AwaitingOwnerAuthorization ->
                ProgressLine(stringResource(R.string.identity_install_authenticating))
        }
    }

    if (hostPicker) {
        TesseraOptionPicker(
            title = stringResource(R.string.identity_choose_host),
            options = hosts.map { it.displayName },
            selectedIndex = selectedHost?.let { current -> hosts.indexOfFirst { it.id == current.id } } ?: -1,
            onSelect = { index -> selectedHost = hosts[index]; hostPicker = false },
            onDismiss = { hostPicker = false },
        )
    }
}

@Composable
private fun ProgressLine(text: String) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxWidth()) {
        Text(text, style = TesseraType.body, color = tokens.fg)
        Spacer(Modifier.height(10.dp))
        com.bambouville.tessera.design.TesseraProgressTrack(progress = null)
    }
}

private fun String.openSshComment(): String =
    trim().replace(Regex("\\s+"), "-").filter { it.code in 33..126 }.take(64).ifEmpty { "tessera-android" }
