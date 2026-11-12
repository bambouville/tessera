package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraType
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

/** Capture mutable store inputs on main; the returned search only uses copies. */
internal interface ArtifactQuickOpenSuggestionSource {
    fun prepareQuickOpenSuggestions(input: String, currentHostId: String?): () -> List<SharedArtifactsSuggestion>
}

internal data class ArtifactQuickOpenSuggestionRequest(
    val input: String,
    val hostId: String?,
    val state: SharedArtifactsState,
    val revision: Long,
)

/** One in-flight search and one pending request, even while native work cannot cancel. */
internal fun <Request, Result> artifactQuickOpenResults(
    requests: Flow<Request>,
    worker: CoroutineDispatcher = Dispatchers.Default,
    prepare: (Request) -> () -> Result,
): Flow<Pair<Request, Result>> = flow {
    var latest: Request? = null
    requests.distinctUntilChanged().onEach { latest = it }.conflate().collect { request ->
        val search = prepare(request)
        val result = withContext(worker) { search() }
        if (latest == request) emit(request to result)
    }
}

/**
 * The new-tab sheet: the + control, Ctrl+T, and the overview's open field.
 * Return always opens a new tab, even beside a tab at the same address; an
 * open tab is offered as a "switch to tab" row instead.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ArtifactQuickOpen(
    store: ArtifactsUiStore,
    state: SharedArtifactsState,
    revision: Long,
    currentHostId: String?,
    onOpened: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    var input by rememberSaveable { mutableStateOf("") }
    var hostId by rememberSaveable(currentHostId) {
        mutableStateOf(currentHostId ?: store.quickOpenHosts.singleOrNull()?.id)
    }
    val keyboard = LocalSoftwareKeyboardController.current
    val submitter = rememberArtifactOpenSubmitter(store, ArtifactOpenPlacement.NewTab) { keyboard?.hide(); onOpened(it) }
    submitter.onDirectory = { hostId = it }
    val suggestions = artifactSuggestions(store, state, revision, input, hostId)
    val focus = remember { FocusRequester() }
    var fieldFocused by remember { mutableStateOf(false) }
    val submitting = submitter.submitting

    ModalBottomSheet(
        onDismissRequest = { keyboard?.hide(); onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = tokens.panelBg,
        dragHandle = null,
        modifier = Modifier.imePadding(),
    ) {
        // The sheet composes its content in its own window after it opens, so
        // the field asks for focus from in here, once it exists. A hardware
        // Ctrl+T or Ctrl+L can then type straight into it.
        LaunchedEffect(Unit) {
            repeat(10) {
                if (fieldFocused) return@LaunchedEffect
                runCatching { focus.requestFocus() }
                withFrameNanos { }
            }
        }
        // Only the field stays fixed. Hosts, messages and suggestions share the
        // remaining scroll area, including short landscape keyboard viewports.
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.94f).imePadding().padding(horizontal = 16.dp).testTag("artifacts-quick-open-sheet")) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.artifacts_new_tab), Modifier.weight(1f), style = TesseraType.sheet, color = tokens.fg)
                TesseraIconButton(TesseraIcons.Close, stringResource(R.string.artifacts_close), { keyboard?.hide(); onDismiss() })
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                TesseraTextField(
                    input, { input = it; submitter.clearMessage() },
                    modifier = Modifier.weight(1f),
                    inputModifier = Modifier.focusRequester(focus).onFocusChanged { fieldFocused = it.isFocused }
                        .heightIn(min = 24.dp).onPreviewKeyEvent { event ->
                        // A hardware Return opens, like the keyboard's Go.
                        if (event.key != Key.Enter && event.key != Key.NumPadEnter) return@onPreviewKeyEvent false
                        if (event.type == KeyEventType.KeyDown) submitter.submit(input, hostId)
                        true
                    },
                    placeholder = stringResource(R.string.artifacts_address_placeholder), inputTestTag = "artifacts-new-tab-field",
                    enabled = !submitting,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                    keyboardActions = KeyboardActions(onGo = { submitter.submit(input, hostId) }),
                )
                TesseraButton(stringResource(R.string.artifacts_go), { submitter.submit(input, hostId) }, enabled = input.isNotBlank() && !submitting,
                    modifier = Modifier.testTag("artifacts-quick-open-go"))
            }
            LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("artifacts-suggestions")) {
                item(key = "hosts") {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        for (host in store.quickOpenHosts) {
                            TesseraButton(host.label, { hostId = host.id; submitter.clearMessage() },
                                style = if (hostId == host.id) TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                                enabled = !submitting,
                                modifier = Modifier.semantics { selected = hostId == host.id }.testTag("artifacts-quick-host-${host.id}"))
                        }
                    }
                }
                submitter.message?.let { text ->
                    item(key = "message") {
                        Text(artifactMessageText(text), Modifier.fillMaxWidth().padding(vertical = 12.dp).testTag("artifacts-quick-open-message"),
                            style = TesseraType.bodySmall, color = if (submitter.failed) tokens.red else tokens.fgMuted)
                    }
                }
                if (hostId == null && input.isBlank()) item(key = "host-hint") {
                    Text(stringResource(R.string.artifacts_quick_open_host_hint), Modifier.padding(vertical = 8.dp),
                        style = TesseraType.bodySmall, color = tokens.fgMuted)
                }
                artifactSuggestionItems(suggestions, enabled = !submitting) { suggestion ->
                    submitter.choose(suggestion, hostId) { input = it }
                }
                if (suggestions.isEmpty()) item(key = "hint") {
                    Text(stringResource(R.string.artifacts_quick_open_hint), Modifier.padding(vertical = 16.dp),
                        style = TesseraType.bodySmall, color = tokens.fgMuted)
                }
            }
        }
    }
}
