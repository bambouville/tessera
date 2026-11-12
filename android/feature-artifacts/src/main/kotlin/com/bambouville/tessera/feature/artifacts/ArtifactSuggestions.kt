package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestionKind
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Submits typed or picked input to one placement, keeping its message and busy state. */
@Stable
internal class ArtifactOpenSubmitter(
    private val store: ArtifactsUiStore,
    private val scope: CoroutineScope,
    private val placement: () -> ArtifactOpenPlacement,
    private val opened: (String) -> Unit,
) {
    var message by mutableStateOf<ArtifactMessage?>(null)
    var failed by mutableStateOf(false)
    var submitting by mutableStateOf(false)
        private set
    /** A directory answer moves the host to the one that was browsed. */
    var onDirectory: (String) -> Unit = {}

    fun clearMessage() { message = null }

    fun submit(text: String, hostId: String?) {
        if (submitting || text.isBlank()) return
        submitting = true
        message = null
        scope.launch {
            try {
                when (val outcome = store.quickOpen(text, hostId, placement())) {
                    is ArtifactQuickOpenOutcome.Opened -> opened(outcome.tabId)
                    is ArtifactQuickOpenOutcome.Directory -> {
                        onDirectory(outcome.hostId)
                        message = ArtifactMessage.Resource(R.string.artifacts_browse_in_files, listOf(outcome.path))
                        failed = false
                    }
                    is ArtifactQuickOpenOutcome.Failed -> { message = outcome.message; failed = true }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                message = artifactFailureMessage(failure, R.string.artifacts_open_failed)
                failed = true
            } finally {
                submitting = false
            }
        }
    }

    /** An open tab switches to it; a change suggestion keeps its immutable snapshot. */
    fun choose(suggestion: SharedArtifactsSuggestion, hostId: String?, onSearch: (String) -> Unit = {}) {
        if (submitting) return
        when (val choice = artifactSuggestionChoice(suggestion)) {
            is ArtifactSuggestionChoice.SwitchTo -> { store.select(choice.tabId); opened(choice.tabId) }
            is ArtifactSuggestionChoice.Open -> submit(choice.input, choice.hostId)
            is ArtifactSuggestionChoice.Search -> { onSearch(choice.text); submit(choice.text, hostId) }
            is ArtifactSuggestionChoice.Invalid -> { message = artifactQuickOpenFailure(choice.reason); failed = true }
        }
    }
}

@Composable
internal fun rememberArtifactOpenSubmitter(
    store: ArtifactsUiStore,
    placement: ArtifactOpenPlacement,
    onOpened: (String) -> Unit,
): ArtifactOpenSubmitter {
    val scope = rememberCoroutineScope()
    val currentPlacement by rememberUpdatedState(placement)
    val currentOpened by rememberUpdatedState(onOpened)
    // A tab's address field starts over, message included, when another tab takes its place.
    return remember(store, scope, (placement as? ArtifactOpenPlacement.Navigate)?.tabId) { ArtifactOpenSubmitter(store, scope, { currentPlacement }, { currentOpened(it) }) }
}

/** The latest suggestions for [input], searched off the main thread when the store allows it. */
@Composable
internal fun artifactSuggestions(
    store: ArtifactsUiStore,
    state: SharedArtifactsState,
    revision: Long,
    input: String,
    hostId: String?,
): List<SharedArtifactsSuggestion> {
    val request by rememberUpdatedState(ArtifactQuickOpenSuggestionRequest(input, hostId, state, revision))
    var result by remember(store) {
        mutableStateOf<Pair<ArtifactQuickOpenSuggestionRequest, List<SharedArtifactsSuggestion>>?>(null)
    }
    LaunchedEffect(store) {
        artifactQuickOpenResults(snapshotFlow { request }) { key ->
            if (store is ArtifactQuickOpenSuggestionSource) {
                store.prepareQuickOpenSuggestions(key.input, key.hostId)
            } else {
                // Fixture/protocol-only stores retain their main-thread contract.
                val values = store.quickOpenSuggestions(key.input, key.hostId)
                val search: () -> List<SharedArtifactsSuggestion> = { values }
                search
            }
        }.collect { if (it.first == request) result = it }
    }
    return result?.takeIf { it.first == request }?.second.orEmpty()
}

/** Suggestion rows grouped by source. Each open tab says "switch to tab". */
internal fun LazyListScope.artifactSuggestionItems(
    suggestions: List<SharedArtifactsSuggestion>,
    enabled: Boolean,
    onChoose: (SharedArtifactsSuggestion) -> Unit,
) {
    for ((kind, group) in suggestions.groupBy { it.kind }) {
        item(key = "group-${kind.wireValue}") {
            val tokens = LocalTesseraTokens.current
            Text(
                stringResource(when (kind) {
                    SharedArtifactsSuggestionKind.HostPrefix -> R.string.artifacts_suggestions_host_paths
                    SharedArtifactsSuggestionKind.ActiveForward -> R.string.artifacts_suggestions_active_tunnels
                    SharedArtifactsSuggestionKind.OpenTab -> R.string.artifacts_suggestions_open_tabs
                    SharedArtifactsSuggestionKind.ListeningPort -> R.string.artifacts_suggestions_listening_ports
                    SharedArtifactsSuggestionKind.Recent -> R.string.artifacts_suggestions_recent
                }),
                Modifier.fillMaxWidth().padding(vertical = 10.dp).semantics { heading() },
                style = TesseraType.rowMicro, color = tokens.fgDim,
            )
        }
        itemsIndexed(group, key = { index, _ -> "${kind.wireValue}-$index" }) { index, suggestion ->
            ArtifactSuggestionRow(suggestion, enabled, Modifier.testTag("artifacts-suggestion-${kind.wireValue}-$index")) { onChoose(suggestion) }
        }
    }
}

@Composable
private fun ArtifactSuggestionRow(suggestion: SharedArtifactsSuggestion, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    val kind = suggestion.kind
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .background(tokens.panelBg)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .then(modifier).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val tunnel = kind == SharedArtifactsSuggestionKind.ActiveForward || kind == SharedArtifactsSuggestionKind.ListeningPort
        Icon(if (tunnel) TesseraIcons.Tunnels else TesseraIcons.File,
            contentDescription = null, tint = tokens.fgMuted, modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f)) {
            Text(suggestion.title, style = TesseraType.rowTitle, color = tokens.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(suggestion.subtitle, style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (kind == SharedArtifactsSuggestionKind.OpenTab) {
            Text(stringResource(R.string.artifacts_switch_to_tab), style = TesseraType.rowMicro, color = tokens.fgMuted, maxLines = 1)
        }
    }
    TesseraHairline()
}
