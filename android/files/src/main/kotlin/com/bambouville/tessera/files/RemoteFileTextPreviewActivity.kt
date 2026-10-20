package com.bambouville.tessera.files

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.markdown.TesseraMarkdownText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class RemoteFileTextPreviewActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent.data
        if (uri == null) {
            finish()
            return
        }
        val displayName = intent.getStringExtra(EXTRA_DISPLAY_NAME).orEmpty().ifBlank { "remote file" }
        enableEdgeToEdge()
        setContent {
            TesseraTheme {
                RemoteFileTextPreview(
                    displayName = displayName,
                    load = { readPreview(uri) },
                    onBack = ::finish,
                    images = intent.getBundleExtra(EXTRA_IMAGES)?.let { bundle ->
                        bundle.keySet().associateWith { Uri.parse(bundle.getString(it)) }
                    }.orEmpty(),
                )
            }
        }
    }

    private fun readPreview(uri: Uri): RemoteFilePreviewContent = contentResolver.openInputStream(uri)?.use { input ->
        val buffer = ByteArray(MAX_PREVIEW_BYTES + 1)
        var total = 0
        while (total < buffer.size) {
            val count = input.read(buffer, total, buffer.size - total)
            if (count < 0) break
            total += count
        }
        val shown = minOf(total, MAX_PREVIEW_BYTES)
        RemoteFilePreviewContent(
            source = buffer.decodeToString(endIndex = shown),
            limited = total > MAX_PREVIEW_BYTES,
        )
    } ?: error("The staged remote file is unavailable")

    companion object {
        const val EXTRA_IMAGES = "com.bambouville.tessera.files.IMAGES"
        const val EXTRA_DISPLAY_NAME = "com.bambouville.tessera.files.DISPLAY_NAME"
        private const val MAX_PREVIEW_BYTES = 2 * 1024 * 1024
    }
}

private const val PREVIEW_LIMIT_NOTICE = "… preview limited to 2 MiB"

private data class RemoteFilePreviewContent(val source: String, val limited: Boolean) {
    val rawText: String get() = source + if (limited) "\n\n$PREVIEW_LIMIT_NOTICE" else ""
}

@Composable
private fun RemoteFileTextPreview(
    displayName: String,
    load: () -> RemoteFilePreviewContent,
    onBack: () -> Unit,
    images: Map<String, Uri>,
) {
    val content by produceState<Result<RemoteFilePreviewContent>?>(initialValue = null, displayName) {
        value = withContext(Dispatchers.IO) { runCatching(load) }
    }
    val context = LocalContext.current
    val bitmaps by produceState<Map<Uri, androidx.compose.ui.graphics.ImageBitmap>>(emptyMap(), images) {
        value = withContext(Dispatchers.IO) {
            val decoded = mutableMapOf<Uri, androidx.compose.ui.graphics.ImageBitmap>()
            var remainingPixels = 16 * 1024 * 1024L
            for (uri in images.values.distinct()) {
                val bitmap = runCatching {
                    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
                    val pixels = options.outWidth.toLong() * options.outHeight
                    if (options.outWidth <= 0 || options.outHeight <= 0 || pixels > remainingPixels) null
                    else context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it)?.asImageBitmap() }
                }.getOrNull()
                if (bitmap != null) {
                    remainingPixels -= bitmap.width.toLong() * bitmap.height
                    decoded[uri] = bitmap
                }
            }
            decoded
        }
    }
    val tokens = LocalTesseraTokens.current
    val isMarkdown = RemoteFileQuickView.isMarkdown(displayName)
    var showSource by rememberSaveable(displayName) { mutableStateOf(false) }
    // Paint the page: this activity has its own window, and a rendered Markdown
    // table or code fence draws its own surface, which only reads as a surface
    // against a page the theme owns.
    Column(Modifier.fillMaxSize().background(tokens.bg)) {
        TesseraSubPageHeader(
            title = displayName,
            onBack = onBack,
            backContentDescription = "Close preview",
            modifier = Modifier.statusBarsPadding(),
            trailing = {
                if (isMarkdown) {
                    TesseraIconButton(
                        icon = TesseraIcons.File,
                        contentDescription = if (showSource) "Show rendered Markdown" else "Show Markdown source",
                        selected = showSource,
                        onClick = { showSource = !showSource },
                    )
                }
            },
        )
        TesseraHairline()
        val preview = content?.getOrNull()
        val contentModifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
        if (isMarkdown && !showSource && preview != null && preview.source.isNotEmpty()) {
            Column(contentModifier) {
                TesseraMarkdownText(preview.source, Modifier.fillMaxWidth()) { destination, alt ->
                    RemoteMarkdownImage(bitmaps[images[destination]], alt)
                }
                // Keep the read-cap notice outside Markdown so a fence or the
                // shared parser's own bounds cannot swallow it.
                if (preview.limited) {
                    Text(
                        PREVIEW_LIMIT_NOTICE,
                        modifier = Modifier.padding(top = 16.dp),
                        style = TesseraType.code,
                        color = tokens.fg,
                    )
                }
            }
        } else {
            Text(
                text = content?.fold(
                    onSuccess = { it.rawText.ifEmpty { "Empty file" } },
                    onFailure = { "Unable to preview this file: ${it.message ?: it.javaClass.simpleName}" },
                ) ?: "Loading…",
                modifier = contentModifier,
                style = TesseraType.code,
                color = tokens.fg,
            )
        }
    }
}

@Composable
private fun RemoteMarkdownImage(bitmap: androidx.compose.ui.graphics.ImageBitmap?, alt: String) {
    if (bitmap != null) {
        Image(bitmap, contentDescription = alt, modifier = Modifier.fillMaxWidth().aspectRatio(bitmap.width.toFloat() / bitmap.height), contentScale = ContentScale.Fit)
    } else {
        Text("[image: $alt]", style = TesseraType.body, color = LocalTesseraTokens.current.fgDim)
    }
}
