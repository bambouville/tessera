package com.bambouville.tessera.feature.agentcenter

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.File
import java.util.Locale

internal data class AgentPhotoAttachmentPlan(val fileName: String, val transcodeToJpeg: Boolean)

/** Mirrors AgentAttachmentPhotos.copyImage: content type wins over the provider's extension. */
internal fun agentPhotoAttachmentPlan(
    displayName: String?,
    mimeType: String?,
    header: ByteArray = byteArrayOf(),
): AgentPhotoAttachmentPlan {
    val mime = mimeType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
    val extension = when (mime) {
        "image/png", "image/x-png" -> "png"
        "image/jpeg", "image/jpg", "image/pjpeg" -> "jpg"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        // Missing, generic or unrecognized types require sniffing, never the filename.
        else -> sniffAgentPhotoExtension(header)
    }
    val basename = displayName.orEmpty().substringAfterLast('/').substringAfterLast('\\')
    val stem = basename.substringBeforeLast('.', basename)
        .filterNot(Char::isISOControl).trim()
        .takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "Photo"
    return AgentPhotoAttachmentPlan("$stem.${extension ?: "jpg"}", transcodeToJpeg = extension == null)
}

private fun sniffAgentPhotoExtension(header: ByteArray): String? {
    fun startsWith(vararg bytes: Int): Boolean = header.size >= bytes.size &&
        bytes.indices.all { (header[it].toInt() and 0xff) == bytes[it] }
    fun textAt(offset: Int, text: String): Boolean = header.size >= offset + text.length &&
        text.indices.all { header[offset + it].toInt() == text[it].code }
    return when {
        startsWith(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) -> "png"
        startsWith(0xff, 0xd8, 0xff) -> "jpg"
        textAt(0, "GIF87a") || textAt(0, "GIF89a") -> "gif"
        textAt(0, "RIFF") && textAt(8, "WEBP") -> "webp"
        else -> null
    }
}

/** Bound allocation before decoding, preserving aspect ratio without upscaling. */
internal fun agentPhotoDecodeSize(width: Int, height: Int): Pair<Int, Int> {
    require(width > 0 && height > 0)
    val longest = maxOf(width, height)
    if (longest <= 4096) return width to height
    return maxOf(1, (width.toLong() * 4096 / longest).toInt()) to
        maxOf(1, (height.toLong() * 4096 / longest).toInt())
}

/** Runs on IO; the caller owns [directory] until the existing upload has finished. */
internal fun copyAgentPhotoAttachments(
    context: Context,
    sources: List<Uri>,
    directory: File,
    checkActive: () -> Unit,
): List<String> {
    val resolver = context.contentResolver
    return sources.mapIndexed { index, uri ->
        checkActive()
        val photoDirectory = File(directory, index.toString())
        check(photoDirectory.mkdirs()) { "The selected photo could not be staged" }
        val input = File(photoDirectory, "source")
        resolver.openInputStream(uri)?.use { source ->
            input.outputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    checkActive()
                    val count = source.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
            }
        } ?: error("The selected photo could not be loaded")
        val displayName = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) cursor.getString(column) else null
            }
        }.getOrNull()
        val header = input.inputStream().use { it.readNBytes(12) }
        val plan = agentPhotoAttachmentPlan(displayName, runCatching { resolver.getType(uri) }.getOrNull(), header)
        val destination = File(photoDirectory, plan.fileName)
        checkActive()
        if (plan.transcodeToJpeg) {
            // ImageDecoder applies EXIF orientation to the pixels. Software allocation
            // permits JPEG compression; target size is set before allocating the bitmap.
            val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(input)) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val (width, height) = agentPhotoDecodeSize(info.size.width, info.size.height)
                decoder.setTargetSize(width, height)
            }
            try {
                checkActive()
                destination.outputStream().use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output)) { "The selected photo could not be converted" }
                }
            } finally {
                bitmap.recycle()
            }
            check(input.delete())
        } else {
            check(input.renameTo(destination)) { "The selected photo could not be staged" }
        }
        checkActive()
        FileProvider.getUriForFile(context, "${context.packageName}.files", destination).toString()
    }
}
