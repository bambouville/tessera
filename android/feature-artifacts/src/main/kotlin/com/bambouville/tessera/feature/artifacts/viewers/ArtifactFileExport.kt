package com.bambouville.tessera.feature.artifacts.viewers

import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.bambouville.tessera.feature.artifacts.ArtifactFailureException
import com.bambouville.tessera.feature.artifacts.ArtifactMessage
import com.bambouville.tessera.feature.artifacts.R
import com.bambouville.tessera.files.fileShareIntent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * Copies a cached artifact where the app's FileProvider exposes it
 * (cache/exports), keeping its real filename in a directory of its own, so the
 * app that receives it (open with, or a share to a chat) shows that name. The
 * cache itself lives outside what the provider exposes.
 */
internal suspend fun stageArtifactExport(context: Context, source: File, displayName: String): File = withContext(Dispatchers.IO) {
    val root = File(context.cacheDir, "exports/artifacts")
    if (!(root.isDirectory || root.mkdirs())) throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_export_unavailable))
    reapArtifactExports(root, System.currentTimeMillis())
    val directory = File(root, UUID.randomUUID().toString())
    if (!directory.mkdirs()) throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_export_unavailable))
    val target = File(directory, artifactExportName(displayName))
    try {
        source.inputStream().use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
            }
        }
        target
    } catch (failure: Throwable) {
        directory.deleteRecursively()
        throw failure
    }
}

/** Exports are handed to other apps, which may read them a while later; a day is enough. */
internal fun reapArtifactExports(root: File, nowMillis: Long) {
    root.listFiles().orEmpty()
        .filter { nowMillis - it.lastModified() > MAX_EXPORT_AGE_MILLIS }
        .forEach { entry -> if (entry.isDirectory) entry.deleteRecursively() else entry.delete() }
}

/** A filename the filesystem accepts that still reads as [displayName], extension kept. */
internal fun artifactExportName(displayName: String): String {
    val cleaned = displayName.substringAfterLast('/').substringAfterLast('\\')
        .filterNot { it.isISOControl() }.trim()
    if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") return "file"
    if (cleaned.toByteArray(Charsets.UTF_8).size <= MAX_NAME_BYTES) return cleaned
    val extension = cleaned.substringAfterLast('.', "").takeIf { it.isNotEmpty() && it.length <= 16 }?.let { ".$it" }.orEmpty()
    val stem = cleaned.removeSuffix(extension)
    val budget = MAX_NAME_BYTES - extension.toByteArray(Charsets.UTF_8).size
    val kept = StringBuilder()
    var bytes = 0
    var index = 0
    while (index < stem.length) {
        val codePoint = stem.codePointAt(index)
        val text = String(Character.toChars(codePoint))
        val size = text.toByteArray(Charsets.UTF_8).size
        if (bytes + size > budget) break
        kept.append(text)
        bytes += size
        index += Character.charCount(codePoint)
    }
    return (kept.toString().trimEnd() + extension).ifBlank { "file" }
}

internal fun artifactExportMime(name: String): String {
    val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: artifactMimeType(name)
}

/** The system share sheet for a staged export: the file itself, its type, and a read grant. */
internal fun artifactShareChooser(context: Context, staged: File, displayName: String, title: String): Intent {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", staged)
    return Intent.createChooser(fileShareIntent(uri, displayName, artifactExportMime(displayName)), title)
}

private const val MAX_EXPORT_AGE_MILLIS = 24 * 60 * 60 * 1000L
private const val MAX_NAME_BYTES = 200
