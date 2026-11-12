package com.bambouville.tessera.feature.session

import android.content.Context
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxOwnedGeometryRecord
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import org.json.JSONArray
import org.json.JSONObject

/**
 * The grids each tmux session's controller owned under this device's stamps,
 * kept across a process death (§6.9) so a relaunch whose stamp still stands
 * is not veiled as another device: iOS's `TmuxOwnedGeometryFileStore`. One
 * small no-backup file, read ahead of the first attach and rewritten off the
 * caller's thread (and its lock) after every change, since a process can die
 * at any moment; keeps that land before the writer runs share one write, and
 * the writer always writes the newest entries. Keyed by a hash of the
 * host's `user@host:port` and the stamp's tmux session, so no host or session
 * name is stored; each session keeps the newest
 * [SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT] generations, and the file the
 * [SESSION_LIMIT] sessions kept most recently.
 */
internal class TmuxOwnedGeometryStore(
    private val file: File,
    private val writer: Executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tessera-tmux-owned-geometry").apply { isDaemon = true }
    },
    private val onWriteFailed: (Throwable) -> Unit = {},
) {
    private class Entry(val key: String, val records: List<SharedTmuxOwnedGeometryRecord>)

    private val lock = Any()

    /** Least recently kept first; null until the file is read. Guarded by [lock]. */
    private var entries: MutableList<Entry>? = null

    /** The newest entries not yet written, which the writer takes. Guarded by [lock]. */
    private var pendingWrite: List<Entry>? = null

    fun records(hostKey: String, session: String): List<SharedTmuxOwnedGeometryRecord> {
        val key = key(hostKey, session)
        return synchronized(lock) { loadedEntries().firstOrNull { it.key == key }?.records.orEmpty() }
    }

    fun keep(hostKey: String, session: String, record: SharedTmuxOwnedGeometryRecord) {
        val key = key(hostKey, session)
        val queued = synchronized(lock) {
            val entries = loadedEntries()
            val index = entries.indexOfFirst { it.key == key }
            val earlier = if (index >= 0) entries.removeAt(index).records else emptyList()
            entries.add(Entry(key, SharedTmuxOwnedGeometryRecord.keeping(record, earlier)))
            while (entries.size > SESSION_LIMIT) entries.removeAt(0)
            (pendingWrite != null).also { pendingWrite = entries.toList() }
        }
        if (queued) return
        try {
            writer.execute(::writePending)
        } catch (error: RejectedExecutionException) {
            // Nothing will take these entries; the next keep queues again.
            synchronized(lock) { pendingWrite = null }
            onWriteFailed(error)
        }
    }

    /** Reads the file on the writer, ahead of the writes queued after it; a read that got there first wins. */
    fun preload() {
        try {
            writer.execute {
                val read = read()
                synchronized(lock) { if (entries == null) entries = read.toMutableList() }
            }
        } catch (_: RejectedExecutionException) {
            // The first read on the caller's thread reads the file instead.
        }
    }

    /** Caller holds [lock]. */
    private fun loadedEntries(): MutableList<Entry> = entries ?: read().toMutableList().also { entries = it }

    private fun read(): List<Entry> = decode(runCatching { file.readText() }.getOrNull())

    private fun writePending() {
        val document = synchronized(lock) { pendingWrite.also { pendingWrite = null } } ?: return
        // A failed write keeps nothing new: the next relaunch reads as it
        // did before records were kept.
        runCatching {
            file.parentFile?.mkdirs()
            val staged = File(file.parentFile, "${file.name}.tmp")
            FileOutputStream(staged).use { stream ->
                stream.write(encode(document).encodeToByteArray())
                stream.fd.sync()
            }
            check(staged.renameTo(file)) { "rename failed" }
        }.onFailure(onWriteFailed)
    }

    companion object {
        const val SESSION_LIMIT = 64
        private const val FILE_NAME = "tmux-owned-geometry.json"

        @Volatile
        private var shared: TmuxOwnedGeometryStore? = null

        fun shared(context: Context): TmuxOwnedGeometryStore =
            shared ?: synchronized(this) {
                shared ?: run {
                    val diagnostics = DiagnosticLogStore(context.applicationContext)
                    TmuxOwnedGeometryStore(
                        File(context.applicationContext.noBackupFilesDir, FILE_NAME),
                        onWriteFailed = { error ->
                            diagnostics.record("tmux_owned_geometry_write_failed", mapOf("type" to error.javaClass.simpleName))
                        },
                    ).also {
                        it.preload()
                        shared = it
                    }
                }
            }

        /** iOS's `HostRuntimeStateStore.key(for:)` spelling. */
        fun hostKey(username: String, hostname: String, port: Int): String = "$username@$hostname:$port"

        internal fun key(hostKey: String, session: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest("$hostKey\u0000$session".encodeToByteArray())
                .joinToString("") { "%02x".format(it) }

        private fun encode(entries: List<Entry>): String =
            JSONArray().apply {
                entries.forEach { entry ->
                    put(
                        JSONObject().put("key", entry.key).put(
                            "records",
                            JSONArray().apply {
                                entry.records.forEach { record ->
                                    put(
                                        JSONObject().put("generation", record.generation).put(
                                            "sizes",
                                            JSONArray().apply {
                                                record.sizes.forEach {
                                                    put(JSONObject().put("columns", it.columns).put("rows", it.rows))
                                                }
                                            },
                                        ),
                                    )
                                }
                            },
                        ),
                    )
                }
            }.toString()

        /** A missing or unreadable file keeps nothing. */
        private fun decode(document: String?): List<Entry> = runCatching {
            val entries = JSONArray(checkNotNull(document))
            List(entries.length()) { index ->
                val entry = entries.getJSONObject(index)
                val records = entry.getJSONArray("records")
                Entry(
                    entry.getString("key"),
                    List(records.length()) { recordIndex ->
                        val record = records.getJSONObject(recordIndex)
                        val sizes = record.getJSONArray("sizes")
                        SharedTmuxOwnedGeometryRecord(
                            generation = record.getLong("generation"),
                            sizes = List(sizes.length()) { sizeIndex ->
                                val size = sizes.getJSONObject(sizeIndex)
                                SharedTmuxGridSize(size.getInt("columns"), size.getInt("rows"))
                            },
                        )
                    },
                )
            }
        }.getOrDefault(emptyList())
    }
}
