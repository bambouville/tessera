package com.bambouville.tessera.files

import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Turns a text share into something the upload path can read.
 *
 * Uploads move bytes from a content URI, so "upload as file" needs the shared
 * text to become one. Staging goes under the same FileProvider cache root the
 * Remote Files exports use, which keeps every externally visible artifact in
 * one reaped place rather than scattering temp files through the cache.
 */
object SharedTextStaging {
    private const val FOLDER = "exports/shared-text"
    private val stampFormatter = DateTimeFormatter
        .ofPattern("yyyyMMdd-HHmmss", Locale.US)
        .withZone(ZoneId.systemDefault())

    fun stage(context: Context, text: String, now: Instant = Instant.now()): Uri {
        val appContext = context.applicationContext
        val directory = File(appContext.cacheDir, FOLDER).apply { mkdirs() }
        reap(directory)
        val file = File(directory, "shared-${stampFormatter.format(now)}.txt")
        file.writeText(text)
        return FileProvider.getUriForFile(appContext, "${appContext.packageName}.files", file)
    }

    private fun reap(directory: File, nowMillis: Long = System.currentTimeMillis()) {
        directory.listFiles().orEmpty()
            .filter { it.isFile && nowMillis - it.lastModified() > MAX_AGE_MILLIS }
            .forEach { runCatching { it.delete() } }
    }

    private const val MAX_AGE_MILLIS = 24 * 60 * 60 * 1000L
}
