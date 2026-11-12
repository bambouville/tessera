package com.bambouville.tessera.feature.artifacts.viewers

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.ArtifactFailureException
import com.bambouville.tessera.feature.artifacts.ArtifactMessage
import com.bambouville.tessera.feature.artifacts.R
import com.bambouville.tessera.feature.artifacts.artifactFailureMessage
import com.bambouville.tessera.feature.artifacts.artifactMessageText
import com.bambouville.tessera.markdown.TesseraMarkdownText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.Locale

/**
 * Displays only local cache contents. [stagedImages] is the destination-to-file
 * map produced by the files module's RemoteMarkdownImages.stage; missing images
 * retain their alt text. Increment [reloadToken] after replacing the cached file.
 */
@Composable
fun ArtifactDocumentView(
    file: File,
    displayName: String,
    modifier: Modifier = Modifier,
    stagedImages: Map<String, File> = emptyMap(),
    reloadToken: Long = 0L,
    /** Every Markdown link, as written; without it only web and mail links are tappable. */
    onLink: ((String) -> Unit)? = null,
) {
    if (artifactExportMime(displayName) == "application/pdf") {
        ArtifactPdfView(file, displayName, modifier, reloadToken)
        return
    }
    val tokens = LocalTesseraTokens.current
    // A reload preserves the scroll position; switching documents resets it.
    key(file.absolutePath, displayName) {
        val preview by produceState<Result<ArtifactDocumentContent>?>(null, reloadToken) {
            value = withContext(Dispatchers.IO) {
                try { Result.success(loadArtifactDocument(file, displayName)) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { Result.failure(failure) }
            }
        }
        val bitmaps by produceState<Map<File, ImageBitmap>>(emptyMap(), stagedImages, reloadToken) {
            value = withContext(Dispatchers.IO) {
                val decoded = mutableMapOf<File, ImageBitmap>()
                var remainingPixels = 16 * 1024 * 1024L
                // The stager already bounds and thumbnails these. Recheck the
                // decode budget here because this is also a public input seam.
                for (image in stagedImages.values.distinct().take(32)) {
                    currentCoroutineContext().ensureActive()
                    val bitmap = decodeArtifactImage(image, 2048, remainingPixels) ?: continue
                    remainingPixels -= bitmap.width.toLong() * bitmap.height
                    decoded[image] = bitmap
                }
                decoded
            }
        }
        val scroll = rememberScrollState()
        Box(modifier.fillMaxSize().background(tokens.bg).imePadding()) {
            val result = preview
            val content = result?.getOrNull()
            when (content) {
                is ArtifactDocumentContent.Text -> SelectionContainer {
                    Column(
                        Modifier.fillMaxSize().verticalScroll(scroll).padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        if (content.markdown && content.source.isNotEmpty()) {
                            TesseraMarkdownText(content.source, Modifier.fillMaxWidth(), onLink = onLink, imageContent = { destination, alt ->
                                val bitmap = bitmaps[stagedImages[destination]]
                                if (bitmap == null) Text(stringResource(R.string.artifacts_image_placeholder, alt), style = TesseraType.body, color = tokens.fgDim)
                                else Image(
                                    bitmap,
                                    contentDescription = alt,
                                    modifier = Modifier.fillMaxWidth().aspectRatio(bitmap.width.toFloat() / bitmap.height),
                                    contentScale = ContentScale.Fit,
                                )
                            })
                        } else {
                            Text(content.source.ifEmpty { stringResource(R.string.artifacts_empty_file) }, style = TesseraType.code, color = tokens.fg)
                        }
                        // Keep this outside Markdown so an open code fence or
                        // the shared parser's own cap cannot hide the notice.
                        if (content.limited) Text(stringResource(R.string.artifacts_preview_limited), style = TesseraType.code, color = tokens.fgMuted)
                    }
                }
                is ArtifactDocumentContent.Image -> Image(
                    bitmap = content.bitmap,
                    contentDescription = displayName,
                    modifier = Modifier.fillMaxSize().padding(16.dp),
                    contentScale = ContentScale.Fit,
                )
                ArtifactDocumentContent.Other -> ArtifactOpenWith(file, displayName)
                null -> Text(
                    if (result == null) stringResource(R.string.artifacts_loading)
                    else stringResource(
                        R.string.artifacts_preview_failed,
                        artifactMessageText(artifactFailureMessage(result.exceptionOrNull(), R.string.artifacts_file_unavailable)),
                    ),
                    Modifier.align(Alignment.Center).padding(24.dp),
                    style = TesseraType.bodySmall,
                    color = tokens.fgMuted,
                )
            }
        }
    }
}

@Composable
internal fun ArtifactOpenWith(file: File, displayName: String, previewFailure: ArtifactMessage? = null) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var opening by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<ArtifactMessage?>(null) }
    val chooserTitle = stringResource(R.string.artifacts_open_chooser, displayName)
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
    ) {
        if (previewFailure == null) {
            Text(displayName, style = TesseraType.section, color = tokens.fg)
        } else {
            Text(stringResource(R.string.artifacts_preview_failed, artifactMessageText(previewFailure)), Modifier.testTag("artifacts-document-failure"),
                style = TesseraType.bodySmall, color = tokens.fgMuted)
        }
        TesseraButton(
            text = stringResource(if (opening) R.string.artifacts_opening else R.string.artifacts_open_with),
            enabled = !opening,
            modifier = Modifier.fillMaxWidth().testTag("artifacts-open-with"),
            onClick = {
                opening = true
                failure = null
                scope.launch {
                    try {
                        val staged = stageArtifactExport(context.applicationContext, file, displayName)
                        val appContext = context.applicationContext
                        val uri = FileProvider.getUriForFile(appContext, "${appContext.packageName}.files", staged)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, artifactExportMime(displayName))
                            clipData = ClipData.newRawUri(displayName, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(Intent.createChooser(intent, chooserTitle).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (problem: Exception) {
                        failure = artifactFailureMessage(problem, R.string.artifacts_file_open_failed)
                    } finally {
                        opening = false
                    }
                }
            },
        )
        failure?.let { Text(artifactMessageText(it), style = TesseraType.bodySmall, color = tokens.fgMuted) }
    }
}

private sealed interface ArtifactDocumentContent {
    data class Text(val source: String, val markdown: Boolean, val limited: Boolean) : ArtifactDocumentContent
    data class Image(val bitmap: ImageBitmap) : ArtifactDocumentContent
    data object Other : ArtifactDocumentContent
}

private fun loadArtifactDocument(file: File, displayName: String): ArtifactDocumentContent {
    if (!file.isFile) throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_cached_file_unavailable))
    val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
    val mime = artifactExportMime(displayName)
    if (mime.startsWith("image/")) {
        return decodeArtifactImage(file, 4096, 16 * 1024 * 1024L)?.let { ArtifactDocumentContent.Image(it) }
            ?: ArtifactDocumentContent.Other
    }
    val markdown = extension in MARKDOWN_EXTENSIONS
    val sample = file.inputStream().use { it.readNBytes(8 * 1024) }
    val basename = displayName.substringAfterLast('/').lowercase(Locale.ROOT)
    val text = markdown || mime.startsWith("text/") || extension in TEXT_EXTENSIONS || basename in TEXT_BASENAMES || artifactBomEncoding(sample) != null ||
        (mime == "application/octet-stream" && sample.isNotEmpty() && sample.none { it == 0.toByte() } &&
            sample.count { (it.toInt() and 0xff) < 0x20 && it.toInt() !in listOf(9, 10, 12, 13) } * 20 <= sample.size)
    if (!text) return ArtifactDocumentContent.Other
    val bytes = file.inputStream().use { it.readNBytes(MAX_TEXT_BYTES + 1) }
    return ArtifactDocumentContent.Text(
        decodeArtifactText(bytes.copyOf(minOf(bytes.size, MAX_TEXT_BYTES)), truncated = bytes.size > MAX_TEXT_BYTES),
        markdown,
        bytes.size > MAX_TEXT_BYTES,
    )
}

internal data class ArtifactTextEncoding(val charset: Charset, val bomBytes: Int = 0)

internal fun artifactBomEncoding(bytes: ByteArray): ArtifactTextEncoding? = when {
    bytes.size >= 3 && bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() && bytes[2] == 0xbf.toByte() ->
        ArtifactTextEncoding(Charsets.UTF_8, 3)
    bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> ArtifactTextEncoding(Charsets.UTF_16LE, 2)
    bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> ArtifactTextEncoding(Charsets.UTF_16BE, 2)
    else -> null
}

/** Preserve browser encoding detection and inheritance; plain text previews still infer UTF-8. */
internal fun artifactTextEncoding(bytes: ByteArray, truncated: Boolean = false, mimeType: String = "text/html"): ArtifactTextEncoding? {
    val mime = mimeType.substringBefore(';').trim().lowercase(Locale.ROOT)
    val xml = mime == "application/xml" || mime == "text/xml" || mime.endsWith("+xml")
    artifactBomEncoding(bytes)?.let { return if (xml && it.charset != Charsets.UTF_8) null else it }
    if (xml || mime == "text/css" || mime == "text/javascript") return null
    if (mime == "text/html" && artifactHasDeclaredEncoding(bytes)) return null
    val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
    val result = decoder.decode(ByteBuffer.wrap(bytes), CharBuffer.allocate(bytes.size), !truncated)
    return if (result.isError) null else ArtifactTextEncoding(Charsets.UTF_8)
}

internal fun decodeArtifactText(bytes: ByteArray, truncated: Boolean = false): String {
    val encoding = artifactTextEncoding(bytes, truncated, mimeType = "text/plain") ?: ArtifactTextEncoding(Charsets.ISO_8859_1)
    if (!truncated) return String(bytes, encoding.bomBytes, bytes.size - encoding.bomBytes, encoding.charset)
    // The preview cap may split a character. Leave that partial character for
    // the full document rather than treating the whole file as Latin-1.
    val chars = CharBuffer.allocate(bytes.size)
    encoding.charset.newDecoder().onMalformedInput(CodingErrorAction.REPLACE).onUnmappableCharacter(CodingErrorAction.REPLACE)
        .decode(ByteBuffer.wrap(bytes, encoding.bomBytes, bytes.size - encoding.bomBytes), chars, false)
    chars.flip()
    return chars.toString()
}

private fun artifactHasDeclaredEncoding(bytes: ByteArray): Boolean {
    val size = minOf(bytes.size, 1024)
    // ASCII folding only: non-ASCII bytes cannot spell markup or whitespace.
    val source = buildString(size) {
        for (index in 0 until size) {
            val value = bytes[index].toInt() and 0xff
            append((if (value in 0x41..0x5a) value + 0x20 else value).toChar())
        }
    }
    return ARTIFACT_HTML_META.findAll(source).any { tag ->
        if (!tag.value.startsWith("<meta")) return@any false
        val attributes = artifactMarkupAttributes(tag.value)
        !attributes["charset"].isNullOrBlank() ||
            attributes["http-equiv"]?.trim { it in ARTIFACT_ASCII_SPACE } == "content-type" &&
            attributes["content"]?.let { ARTIFACT_CONTENT_CHARSET.containsMatchIn(it) } == true
    }
}

private fun artifactMarkupAttributes(tag: String): Map<String, String> {
    val attributes = mutableMapOf<String, String>()
    ARTIFACT_MARKUP_ATTRIBUTE.findAll(tag).forEach { match ->
        val value = match.groups[2]?.value ?: match.groups[3]?.value ?: match.groupValues[4]
        attributes.putIfAbsent(match.groupValues[1], value)
    }
    return attributes
}

private const val ARTIFACT_ASCII_SPACE = "\t\n\u000c\r "
private val ARTIFACT_HTML_META = Regex("""<!--[\s\S]*?-->|<meta(?=[\t\n\f\r />])(?:[^"'<>]++|"[^"]*"|'[^']*')*>""")
private val ARTIFACT_MARKUP_ATTRIBUTE = Regex("""[\t\n\f\r ]+([a-z_:][a-z0-9_.:-]*)[\t\n\f\r ]*=[\t\n\f\r ]*(?:"([^"]*)"|'([^']*)'|([^\t\n\f\r "'<>/=]+))""")
private val ARTIFACT_CONTENT_CHARSET = Regex("""(?:^|;)[\t\n\f\r ]*charset[\t\n\f\r ]*=[\t\n\f\r ]*["']?([^\t\n\f\r ;"']+)""")

private fun decodeArtifactImage(file: File, maxDimension: Int, maxPixels: Long): ImageBitmap? {
    if (maxPixels <= 0) return null
    return try {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > maxDimension ||
            ((options.outWidth.toLong() + options.inSampleSize - 1) / options.inSampleSize) *
            ((options.outHeight.toLong() + options.inSampleSize - 1) / options.inSampleSize) > maxPixels
        ) {
            if (options.inSampleSize >= (1 shl 30)) return null
            options.inSampleSize *= 2
        }
        options.inJustDecodeBounds = false
        BitmapFactory.decodeFile(file.path, options)?.asImageBitmap()
    } catch (_: Exception) { null }
}

private const val MAX_TEXT_BYTES = 2 * 1024 * 1024
private val MARKDOWN_EXTENSIONS = setOf("md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdtext", "mdtxt", "rmd", "qmd", "mdx")
private val TEXT_EXTENSIONS = setOf(
    "txt", "rst", "adoc", "org", "log", "conf", "config", "ini", "json", "xml", "yaml", "yml", "toml", "properties", "service",
    "sh", "bash", "zsh", "fish", "py", "rb", "go", "rs", "c", "cc", "cpp", "h", "hpp", "m", "mm", "swift", "kt", "kts",
    "java", "js", "jsx", "ts", "tsx", "css", "html", "htm", "sql", "gradle", "vue", "svelte", "lua", "pl", "r", "ex", "exs",
)
private val TEXT_BASENAMES = setOf(
    "license", "readme", "makefile", "dockerfile", ".bashrc", ".bash_profile", ".bash_logout", ".profile", ".zshrc", ".zprofile", ".gitconfig", ".editorconfig",
)
