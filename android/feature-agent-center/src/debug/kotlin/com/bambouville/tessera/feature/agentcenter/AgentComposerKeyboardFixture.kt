package com.bambouville.tessera.feature.agentcenter

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.net.toUri
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers

/** Debug-only native layout fixture. No presenter, session, database or network. */
@Composable
fun AgentComposerKeyboardFixture(modifier: Modifier = Modifier, onSendObserved: (Boolean) -> Unit = {}) {
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var uploading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val send: (Boolean) -> Unit = { queue ->
        val text = draft
        sending = true
        onSendObserved(queue)
        scope.launch {
            delay(4_000)
            if (draft == text) draft = ""
            sending = false
        }
    }
    val attach = rememberAgentAttachmentPicker { uris ->
        if (uris.isNotEmpty()) {
            uploading = true
            scope.launch {
                try {
                    for (uri in uris) {
                        withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri.toUri())!!.use { it.readBytes() } }
                        delay(4_000)
                        draft = listOf(draft, quoteAgentAttachmentPath("/fixture/private-upload/tessera-attachment-fixture.txt"))
                            .filter { it.isNotEmpty() }.joinToString("\n")
                    }
                } finally { uploading = false }
            }
        }
    }
    val detail = remember {
        AgentThreadDetail(
            row = AgentThreadRow(key = "fixture:codex:composer", title = "Composer fixture",
                provider = "Codex", providerID = "codex", model = null, preview = null, status = "working", attention = "none",
                location = "host-free fixture", queuedCount = null, isFork = false,
                actionAvailable = true, spawnAvailable = false, forkAvailable = false),
            live = listOf(AgentBlock("assistant", "Ready for the next instruction.", kind = "text", recordID = "fixture-reply")),
            activity = emptyList(), changes = emptyList(), binding = com.bambouville.tessera.core.bridge.SharedAgentValue.ObjectValue(emptyMap()), hasMore = false, prompt = null,
        )
    }
    AgentDetailPane(detail, draft, { draft = it }, { send(false) }, {}, { _, _ -> }, {}, {}, {}, {}, {}, modifier,
        onAttach = attach, onQueue = { send(true) }, sending = sending, uploading = uploading)
}
