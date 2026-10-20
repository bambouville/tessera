package com.bambouville.tessera.lifecycle

import android.content.Context
import com.bambouville.tessera.core.bridge.SharedRedaction
import java.io.File
import java.time.Instant
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Append-only on-device report. [record] never blocks the caller: the tmux
 * control reader and the Mosh output pump record from inside their transport
 * locks, and redaction (a shared-core JNI call) plus the file append used to
 * run there synchronously. Lines are stamped on the calling thread and
 * written in submission order by one writer thread, so [read] and [clear]
 * queue behind every record that preceded them.
 */
class DiagnosticLogStore(context: Context) {
    private val directory = context.applicationContext.filesDir
    private val file = File(directory, FILE_NAME)
    private val previousFile = File(directory, "$FILE_NAME.previous")

    fun record(code: String, values: Map<String, String> = emptyMap()) {
        val stamp = Instant.now()
        // Snapshot the entries now; the caller may reuse a mutable map.
        val entries = values.entries
            .filter { it.key.isNotBlank() }
            .map { it.key to it.value }
        try {
            writer.execute { append(stamp, code, entries) }
        } catch (_: RejectedExecutionException) {
            // Process shutdown; the report is best-effort.
        }
    }

    private fun append(stamp: Instant, code: String, entries: List<Pair<String, String>>) {
        val safeCode = code.sanitized(64)
        // Every key is kept. A fixed whitelist used to drop any key it did not
        // know (`window`, `reason`, `pane`, `attempt`, ...), which silently
        // removed the most useful half of a report; keys are developer
        // constants, so bounding and redacting them is enough.
        val safeValues = entries.joinToString(" ") { (key, value) ->
            "${key.sanitized(40)}=${value.sanitized(VALUE_LIMIT)}"
        }
        val line = "$stamp $safeCode${if (safeValues.isEmpty()) "" else " $safeValues"}\n"
        synchronized(fileLock) {
            if (file.length() > MAX_BYTES) {
                if (previousFile.exists()) previousFile.delete()
                file.renameTo(previousFile)
            }
            file.appendText(line, Charsets.UTF_8)
        }
    }

    /**
     * The report's shape without its contents. The diagnostics page shows this
     * instead of the text: a rotated report is a megabyte, and laying that out
     * as one composable costs seconds on the main thread for something nobody
     * reads on the phone.
     */
    data class Info(val byteCount: Long, val modifiedAt: Instant?) {
        val isEmpty: Boolean get() = byteCount == 0L

        companion object {
            val EMPTY = Info(0L, null)
        }
    }

    fun info(): Info = flushed {
        synchronized(fileLock) {
            val parts = listOf(previousFile, file).filter(File::exists)
            Info(
                byteCount = parts.sumOf(File::length),
                modifiedAt = parts.maxOfOrNull(File::lastModified)
                    ?.takeIf { it > 0L }
                    ?.let(Instant::ofEpochMilli),
            )
        }
    }

    /**
     * Copies the retained report to [destination] in chronological order.
     * Streamed, because export and upload run on a report that may be twice
     * [MAX_BYTES]. Returns false when nothing has been recorded yet.
     */
    fun copyTo(destination: File): Boolean = flushed {
        synchronized(fileLock) {
            val parts = listOf(previousFile, file).filter(File::exists)
            if (parts.isEmpty()) {
                false
            } else {
                destination.outputStream().use { sink ->
                    parts.forEach { part -> part.inputStream().use { it.copyTo(sink) } }
                }
                true
            }
        }
    }

    /** Returns the retained report in chronological order, including the rotated segment. */
    fun read(): String = flushed {
        synchronized(fileLock) {
            buildString {
                if (previousFile.exists()) append(previousFile.readText())
                if (file.exists()) append(file.readText())
            }
        }
    }

    fun clear() {
        flushed {
            synchronized(fileLock) {
                if (file.exists()) file.delete()
                if (previousFile.exists()) previousFile.delete()
            }
        }
    }

    /** Runs [block] on the writer after every record queued so far. */
    private fun <T> flushed(block: () -> T): T =
        try {
            writer.submit(block).get()
        } catch (_: RejectedExecutionException) {
            block()
        }

    /**
     * Removes secrets, then control characters, then length — in that order.
     *
     * Redaction runs before truncation because a 22-character Mosh key cut in
     * half stops looking like one, and the surviving prefix is still key
     * material.
     *
     * Swift authority:
     * `Packages/TesseraCore/Sources/TesseraSessionCore/SensitiveDataRedaction.swift`,
     * reached through `SharedRedaction`. The full ordered list applies here:
     * this file's own `password|passphrase|secret|token` rule is one of its
     * stages verbatim, and adopting the rest is what finally scrubs Mosh
     * session keys and `user@host` endpoints out of the diagnostic report.
     */
    private fun String.sanitized(limit: Int): String =
        SharedRedaction.redact(this).bounded(limit)

    private fun String.bounded(limit: Int): String =
        filter { it >= ' ' && it != '\u007f' }.take(limit)

    companion object {
        const val FILE_NAME = "tessera-diagnostics.log"
        const val MAX_BYTES = 512 * 1024L
        /**
         * Long enough for one shared-core lifecycle trace or a Mosh pump
         * summary; the 512 KB rotation still bounds the file.
         */
        const val VALUE_LIMIT = 400
        private val fileLock = Any()
        /** One process-wide writer: every instance appends to the same file. */
        private val writer: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "tessera-diagnostics").apply { isDaemon = true }
        }
    }
}
