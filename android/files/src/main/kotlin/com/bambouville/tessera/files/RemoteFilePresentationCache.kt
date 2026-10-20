package com.bambouville.tessera.files

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

/**
 * Owns every externally visible Remote Files artifact. Files live below the
 * existing FileProvider `cache-path` and are reaped opportunistically, so an
 * open/share action never leaks a remote download into public storage.
 */
internal class RemoteFilePresentationCache(context: Context) {
    private val appContext = context.applicationContext
    private val directory = File(appContext.cacheDir, "exports/remote-files")

    fun create(name: String): File {
        reap()
        directory.mkdirs()
        return File(directory, "${UUID.randomUUID()}-${safeName(name)}")
    }

    fun dispatch(file: File, displayName: String, action: RemoteFilePresentationAction, images: Map<String, File> = emptyMap()) {
        check(file.isFile) { "The staged remote file is unavailable" }
        val uri = FileProvider.getUriForFile(appContext, "${appContext.packageName}.files", file)
        val mime = mimeType(displayName)
        val intent = when (action) {
            RemoteFilePresentationAction.OPEN -> if (shouldPreviewText(displayName, mime, file.textSample())) {
                Intent(appContext, RemoteFileTextPreviewActivity::class.java).apply {
                    data = uri
                    putExtra(RemoteFileTextPreviewActivity.EXTRA_DISPLAY_NAME, displayName)
                    val stagedImages = android.os.Bundle()
                    images.forEach { (destination, image) ->
                        stagedImages.putString(destination, FileProvider.getUriForFile(
                            appContext, "${appContext.packageName}.files", image,
                        ).toString())
                    }
                    putExtra(RemoteFileTextPreviewActivity.EXTRA_IMAGES, stagedImages)
                }
            } else Intent(Intent.ACTION_VIEW).apply { setDataAndType(uri, mime) }
            RemoteFilePresentationAction.SHARE -> Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
            }
        }.apply {
            clipData = ClipData.newRawUri(displayName, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val title = if (action == RemoteFilePresentationAction.OPEN) "Open $displayName" else "Share $displayName"
        val launched = if (action == RemoteFilePresentationAction.OPEN &&
            intent.component?.className == RemoteFileTextPreviewActivity::class.java.name
        ) intent else Intent.createChooser(intent, title)
        appContext.startActivity(launched.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun reap(nowMillis: Long = System.currentTimeMillis()) {
        if (!directory.isDirectory) return
        directory.listFiles().orEmpty()
            .filter { it.isFile && nowMillis - it.lastModified() > MAX_AGE_MILLIS }
            .forEach { runCatching { it.delete() } }
    }

    private fun safeName(name: String): String = name
        .filterNot { it == '/' || it == '\\' || it.isISOControl() }
        .trim()
        .take(180)
        .ifBlank { "remote-file" }

    private fun mimeType(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: when (extension) {
                "md", "markdown", "log", "conf", "service" -> "text/plain"
                else -> "application/octet-stream"
            }
    }

    private companion object {
        const val MAX_AGE_MILLIS = 24 * 60 * 60 * 1000L
    }
}

internal fun shouldPreviewText(name: String, mime: String, sample: ByteArray): Boolean {
    if (RemoteFileQuickView.isMarkdown(name)) return true
    if (mime.startsWith("text/")) return true
    val basename = name.lowercase()
    val extension = basename.substringAfterLast('.', "")
    if (extension in TEXT_EXTENSIONS || basename in TEXT_BASENAMES) return true
    if (sample.isEmpty() || sample.any { it == 0.toByte() }) return false
    val controls = sample.count { byte ->
        val value = byte.toInt() and 0xff
        value < 0x20 && value !in setOf(0x09, 0x0a, 0x0d, 0x0c)
    }
    return controls * 20 <= sample.size
}

private fun File.textSample(): ByteArray = inputStream().use { input ->
    val buffer = ByteArray(8 * 1024)
    val count = input.read(buffer)
    if (count <= 0) byteArrayOf() else buffer.copyOf(count)
}

private val TEXT_EXTENSIONS = setOf(
    "txt", "md", "markdown", "log", "conf", "config", "ini", "json", "xml", "yaml", "yml", "toml",
    "properties", "service", "sh", "bash", "zsh", "fish", "py", "rb", "go", "rs", "c", "cc", "cpp",
    "h", "hpp", "m", "mm", "swift", "kt", "kts", "java", "js", "jsx", "ts", "tsx", "css", "html",
    "htm", "sql", "gradle",
)

private val TEXT_BASENAMES = setOf(
    "license", "readme", "makefile", "dockerfile", ".bashrc", ".bash_profile", ".bash_logout", ".profile",
    ".zshrc", ".zprofile", ".gitconfig", ".editorconfig",
)
