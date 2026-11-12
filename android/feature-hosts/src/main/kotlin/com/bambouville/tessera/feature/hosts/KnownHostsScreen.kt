package com.bambouville.tessera.feature.hosts

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.util.Base64
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedImportAction
import com.bambouville.tessera.core.bridge.SharedKnownHostsExportRecord
import com.bambouville.tessera.core.bridge.SharedKnownHostsImportPlan
import com.bambouville.tessera.core.bridge.SharedTrustPolicy
import com.bambouville.tessera.data.KnownHostKeys
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedKnownHost
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraBannerTone
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraRowGlyph
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.design.TesseraTag
import com.bambouville.tessera.design.TesseraType
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun KnownHostsScreen(
    repository: KnownHostsRepository,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val loadedKnownHosts by repository.loadedKnownHosts.collectAsState()
    val knownHosts = loadedKnownHosts.orEmpty()
    var selected by remember { mutableStateOf<SavedKnownHost?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }
    var importNotice by remember { mutableStateOf<String?>(null) }
    var reviewedPlan by remember { mutableStateOf<SharedKnownHostsImportPlan?>(null) }
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    val exportTitle = stringResource(R.string.hosts_known_export_title)
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                        ?: error(resources.getString(R.string.hosts_known_file_unavailable))
                }
                require(text.length <= 512 * 1024) { resources.getString(R.string.hosts_known_import_too_large) }
                // Build the plan; write nothing. The parser that mutated as it
                // went is what used to leave a half-imported store behind on
                // the first bad line, and made "review before you trust" a lie.
                //
                // Swift authority:
                // `Packages/TesseraCore/Sources/TesseraTrustCore/OpenSSHKnownHostsCodec.swift`
                // (`importPlan`) via `SharedTrustPolicy`.
                //
                // `normalizeEndpoints = true` keeps the plan and this store in
                // ONE key space. Room keys endpoints normalized (trimmed, one
                // trailing dot stripped, lowercased, IPv6 bracketed) and
                // `sharedEndpointKey` renders exactly that as the core's bare
                // `host:port`, so a file that spells a pinned host differently
                // — `Example.COM.`, `[2001:DB8::1]:2222` — still lands on the
                // pin it already has. Keyed verbatim instead, that host would
                // be planned as an `Add` with no prior fingerprint, which
                // `trustIfUnchanged` then refuses: the review sheet would
                // promise an import that never happens. It also makes two
                // case-variant lines for one host one endpoint again, so the
                // ambiguity rejection fires instead of both being applied and
                // the last one silently winning.
                val plan = withContext(Dispatchers.Default) {
                    SharedTrustPolicy.knownHostsImportPlan(
                        text = text,
                        existingFingerprints = knownHosts.associate { host ->
                            KnownHostKeys.sharedEndpointKey(host.normalizedEndpoint) to
                                KnownHostKeys.fingerprint(host.canonicalKeyBlob)
                        },
                        normalizeEndpoints = true,
                    )
                }
                if (plan.candidates.isEmpty() && plan.rejections.isEmpty()) {
                    importNotice = resources.getString(R.string.hosts_known_import_no_keys)
                } else {
                    reviewedPlan = plan
                }
            } catch (failure: Throwable) {
                importError = failure.message ?: resources.getString(R.string.hosts_known_import_failed_fallback)
            }
        }
    }
    val tokens = LocalTesseraTokens.current
    Column(modifier.background(tokens.bg)) {
        TesseraSubPageHeader(
            title = stringResource(R.string.hosts_known_title),
            onBack = onBack,
            backContentDescription = stringResource(R.string.hosts_known_back),
        ) {
            TesseraIconButton(
                icon = TesseraIcons.Download,
                contentDescription = stringResource(R.string.hosts_known_import),
                onClick = { importLauncher.launch(arrayOf("text/plain", "application/octet-stream")) },
            )
            TesseraIconButton(
                icon = TesseraIcons.Upload,
                contentDescription = stringResource(R.string.hosts_known_export),
                enabled = knownHosts.isNotEmpty(),
                onClick = {
                    // OpenSSH-canonical: a bare host at port 22, `[host]:port`
                    // otherwise, lines sorted. Writing our own `host:22` key
                    // round-trips through our importer but disagrees with the
                    // user's real known_hosts about the same machine.
                    //
                    // Swift authority:
                    // `Packages/TesseraCore/Sources/TesseraTrustCore/OpenSSHKnownHostsCodec.swift`
                    // (`exportText`) via `SharedTrustPolicy`.
                    val contents = SharedTrustPolicy.knownHostsExport(
                        knownHosts.map { host ->
                            SharedKnownHostsExportRecord(
                                endpointKey = KnownHostKeys.sharedEndpointKey(host.normalizedEndpoint),
                                keyString = KnownHostKeys.openSshKeyString(
                                    host.algorithm,
                                    host.canonicalKeyBlob,
                                ),
                            )
                        },
                    )
                    context.startActivity(
                        Intent.createChooser(
                            Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, contents)
                            },
                            exportTitle,
                        ),
                    )
                },
            )
        }
        TesseraHairline()
        if (loadedKnownHosts == null) {
            Spacer(Modifier.fillMaxSize())
        } else if (knownHosts.isEmpty()) {
            TesseraEmptyState(
                title = stringResource(R.string.hosts_known_empty_title),
                body = stringResource(R.string.hosts_known_empty_body),
                icon = TesseraIcons.Shield,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(knownHosts, key = SavedKnownHost::normalizedEndpoint) { host ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 66.dp)
                            .clickable { selected = host }
                            .padding(start = 18.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TesseraRowGlyph(icon = TesseraIcons.Shield)
                        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                            Text(
                                host.normalizedEndpoint,
                                style = TesseraType.rowTitle,
                                color = tokens.fg,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                host.algorithm,
                                color = tokens.fgMuted,
                                style = TesseraType.rowMeta,
                                maxLines = 1,
                            )
                        }
                        if (host.previousCanonicalKeyBlob != null) {
                            TesseraTag(stringResource(R.string.hosts_known_replaced), tone = tokens.amber)
                        }
                        androidx.compose.material3.Icon(
                            TesseraIcons.ChevronRight,
                            contentDescription = null,
                            tint = tokens.fgDim,
                            modifier = Modifier.padding(start = 8.dp).size(18.dp),
                        )
                    }
                    TesseraHairline(Modifier.padding(start = 66.dp))
                }
            }
        }
    }
    selected?.let { host ->
        KnownHostDetails(host, repository, onDismiss = { selected = null })
    }
    reviewedPlan?.let { plan ->
        KnownHostsImportReview(
            plan = plan,
            onDismiss = { reviewedPlan = null },
            onConfirm = {
                reviewedPlan = null
                scope.launch {
                    importNotice = applyImportPlan(repository, plan, resources)
                }
            },
        )
    }
    importError?.let { message ->
        TesseraDialog(
            title = stringResource(R.string.hosts_known_import_failed),
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
    importNotice?.let { message ->
        TesseraDialog(
            title = stringResource(R.string.hosts_known_import_result_title),
            onDismissRequest = { importNotice = null },
            actions = {
                TesseraButton(
                    text = stringResource(R.string.host_close),
                    onClick = { importNotice = null },
                    style = TesseraButtonStyle.Primary,
                    compact = true,
                )
            },
        ) {
            TesseraBanner(text = message, tone = TesseraBannerTone.Info)
        }
    }
}

/**
 * The reviewable plan, shown before anything is written.
 *
 * Rejections are named per line so a file with one bad entry still imports the
 * rest — the whole point of building a plan instead of mutating as we parse.
 */
@Composable
private fun KnownHostsImportReview(
    plan: SharedKnownHostsImportPlan,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    TesseraDialog(
        title = stringResource(R.string.hosts_known_review_title),
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = stringResource(R.string.host_cancel), onClick = onDismiss, compact = true)
            TesseraButton(
                text = stringResource(R.string.hosts_known_import_confirm),
                onClick = onConfirm,
                style = TesseraButtonStyle.Primary,
                enabled = !plan.isNoOp,
                compact = true,
            )
        },
    ) {
        Text(
            listOf(
                pluralStringResource(R.plurals.hosts_known_plan_add, plan.addCount, plan.addCount),
                pluralStringResource(R.plurals.hosts_known_plan_replace, plan.replaceCount, plan.replaceCount),
                pluralStringResource(R.plurals.hosts_known_plan_unchanged, plan.unchangedCount, plan.unchangedCount),
            ).joinToString(" · "),
            style = TesseraType.bodySmall,
            color = tokens.fg,
        )
        if (plan.replaceCount > 0) {
            TesseraBanner(
                text = stringResource(R.string.hosts_known_replace_warning),
                tone = TesseraBannerTone.Warning,
            )
        }
        if (plan.rejections.isNotEmpty()) {
            Column(Modifier.fillMaxWidth()) {
                TesseraKicker(stringResource(R.string.hosts_known_not_imported), Modifier.padding(bottom = 6.dp))
                plan.rejections.take(MAX_LISTED_IMPORT_LINES).forEach { rejection ->
                    Text(
                        stringResource(
                            R.string.hosts_known_rejection_line,
                            rejection.lineNumber,
                            rejectionText(rejection.reason, rejection.marker),
                        ),
                        style = TesseraType.bodySmall,
                        color = tokens.fgMuted,
                    )
                }
                if (plan.rejections.size > MAX_LISTED_IMPORT_LINES) {
                    val more = plan.rejections.size - MAX_LISTED_IMPORT_LINES
                    Text(
                        pluralStringResource(R.plurals.hosts_known_rejections_more, more, more),
                        style = TesseraType.bodySmall,
                        color = tokens.fgDim,
                    )
                }
            }
        }
        if (plan.warnings.isNotEmpty()) {
            Text(
                pluralStringResource(
                    R.plurals.hosts_known_duplicates_ignored,
                    plan.warnings.size,
                    plan.warnings.size,
                ),
                style = TesseraType.bodySmall,
                color = tokens.fgMuted,
            )
        }
    }
}

/**
 * Applies a reviewed plan, one candidate at a time, each guarded by the
 * fingerprint the plan was built against. A candidate whose expectation no
 * longer holds is skipped rather than overwriting a decision the user never
 * saw — a background connection may have accepted a rotation while the sheet
 * was open.
 *
 * A spelling difference between the file and this store is no longer one of
 * those reasons: the plan is built in the store's own normalized key space, so
 * `candidate.host` re-normalizes to the row the plan classified against and a
 * skip here means the store really did move.
 */
private suspend fun applyImportPlan(
    repository: KnownHostsRepository,
    plan: SharedKnownHostsImportPlan,
    resources: Resources,
): String {
    var applied = 0
    var skipped = 0
    plan.candidates.filter { it.action != SharedImportAction.Unchanged }.forEach { candidate ->
        val algorithm = candidate.keyString.substringBefore(' ')
        val encoded = candidate.keyString.substringAfter(' ')
        val blob = runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()
        if (algorithm.isEmpty() || blob == null || blob.isEmpty()) {
            skipped += 1
            return@forEach
        }
        val written = repository.trustIfUnchanged(
            hostname = candidate.host,
            port = candidate.port,
            algorithm = algorithm,
            canonicalKeyBlob = blob,
            expectedPriorFingerprint = candidate.expectedPriorFingerprint,
        )
        if (written) applied += 1 else skipped += 1
    }
    val pinned = resources.getQuantityString(R.plurals.hosts_known_import_pinned, applied, applied)
    if (skipped == 0) return pinned
    return resources.getString(
        R.string.hosts_known_import_summary,
        pinned,
        resources.getQuantityString(R.plurals.hosts_known_import_skipped, skipped, skipped),
    )
}

/** The core classifies; the platform words it. */
@Composable
private fun rejectionText(reason: String, marker: String?): String = when (reason) {
    "missingFields" -> stringResource(R.string.hosts_known_reject_missing_fields)
    "unsupportedMarker" -> stringResource(R.string.hosts_known_reject_unsupported_marker, marker ?: "@")
    "invalidPublicKey" -> stringResource(R.string.hosts_known_reject_invalid_key)
    "emptyHostField" -> stringResource(R.string.hosts_known_reject_empty_host)
    "hashedHost" -> stringResource(R.string.hosts_known_reject_hashed)
    "wildcardOrNegatedHost" -> stringResource(R.string.hosts_known_reject_pattern)
    "invalidBracketedHostPort" -> stringResource(R.string.hosts_known_reject_bracketed)
    "invalidHostOrPort" -> stringResource(R.string.hosts_known_reject_out_of_range)
    "ambiguousEndpoint" -> stringResource(R.string.hosts_known_reject_ambiguous)
    "unnormalizableHost" -> stringResource(R.string.hosts_known_reject_unnormalizable)
    else -> stringResource(R.string.hosts_known_reject_unusable)
}

private const val MAX_LISTED_IMPORT_LINES = 6

@Composable
private fun KnownHostDetails(
    host: SavedKnownHost,
    repository: KnownHostsRepository,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val tokens = LocalTesseraTokens.current
    val scope = rememberCoroutineScope()
    val fingerprint = host.canonicalKeyBlob.fingerprint()
    val fingerprintClipLabel = stringResource(R.string.hosts_known_fingerprint_clip_label)
    TesseraDialog(
        title = host.normalizedEndpoint,
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(
                text = stringResource(R.string.hosts_known_forget),
                onClick = {
                    val (hostname, port) = KnownHostKeys.splitEndpoint(host.normalizedEndpoint)
                        ?: (host.normalizedEndpoint to 22)
                    scope.launch {
                        repository.forget(hostname, port)
                        onDismiss()
                    }
                },
                style = TesseraButtonStyle.Danger,
                compact = true,
            )
            TesseraButton(
                text = stringResource(R.string.host_close),
                onClick = onDismiss,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        },
    ) {
        TesseraTag(host.algorithm, tone = tokens.green)
        Column(Modifier.fillMaxWidth()) {
            TesseraKicker(stringResource(R.string.identity_fingerprint), Modifier.padding(bottom = 6.dp))
            Text(
                fingerprint,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(tokens.inputBg, RoundedCornerShape(8.dp))
                    .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                style = TesseraType.code,
                color = tokens.fg,
            )
        }
        Text(
            stringResource(R.string.hosts_known_last_verified, host.lastVerifiedAtEpochMilliseconds.displayDate()),
            style = TesseraType.bodySmall,
            color = tokens.fgMuted,
        )
        if (host.previousCanonicalKeyBlob != null) {
            Text(
                stringResource(R.string.hosts_known_previous_retained),
                style = TesseraType.bodySmall,
                color = tokens.fgMuted,
            )
        }
        TesseraButton(
            text = stringResource(R.string.hosts_known_copy_fingerprint),
            onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText(fingerprintClipLabel, fingerprint))
            },
            modifier = Modifier.fillMaxWidth(),
            icon = TesseraIcons.Copy,
        )
    }
}

/**
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraTrustCore/HostKeyFingerprint.swift`
 * (`SSHHostPublicKey.sha256Fingerprint`) via `KnownHostKeys`.
 */
private fun ByteArray.fingerprint(): String = KnownHostKeys.fingerprint(this)

private fun Long.displayDate(): String = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    .withZone(ZoneId.systemDefault())
    .format(Instant.ofEpochMilli(this))
