package com.bambouville.tessera.files

import android.content.Context
import androidx.core.content.edit
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** A remote file an upload may leave behind: its staging partial, or the original it moved aside. */
internal data class PendingRemoteUploadCleanup(
    val id: UUID,
    /** [com.bambouville.tessera.networking.SshRouteOwner.routeIdentity] of the connection that made it. */
    val route: String,
    val remotePath: String,
    /**
     * Set when [remotePath] is an original a replace moved aside: it goes back
     * here if nothing replaced it, and is deleted once something did. Null for
     * a file only ever to be deleted.
     */
    val restoreToRemotePath: String?,
    val createdAtEpochSeconds: Long,
)

/** Durable text for the journal: SharedPreferences in the app, memory in tests. */
internal interface RemoteUploadCleanupStore {
    fun read(): String?
    fun write(value: String?)
}

/**
 * Android's counterpart of iOS's RemoteUploadCleanupJournal. An upload records
 * each remote file it is about to create or move aside, and drops the record
 * once that file is gone or back in place. A record left behind by disposal on
 * a dead link, a failed restore or a killed process is retried by the next
 * connection to the same route. Records an upload in this process still owns
 * are active, and a retry never touches them.
 */
internal class RemoteUploadCleanupJournal(private val store: RemoteUploadCleanupStore) {
    // Guards the store's read-modify-write. The active set is concurrent so
    // deactivate, which runs on Main, never waits on another upload's disk write.
    private val storeLock = Any()
    private val active: MutableSet<UUID> = ConcurrentHashMap.newKeySet()

    /** Durable before it returns; a cancelled caller still gets the id, to remove or deactivate. */
    suspend fun register(route: String, remotePath: String, restoreToRemotePath: String? = null): UUID = durably {
        val record = PendingRemoteUploadCleanup(
            id = UUID.randomUUID(),
            route = route,
            remotePath = remotePath,
            restoreToRemotePath = restoreToRemotePath,
            createdAtEpochSeconds = System.currentTimeMillis() / 1_000,
        )
        synchronized(storeLock) {
            active += record.id
            save((load() + record).takeLast(MAXIMUM_RECORDS))
        }
        record.id
    }

    /**
     * The replacement is in place: the moved-aside original this record
     * covers is only ever deleted from now on, never put back, even if the
     * destination disappears before a retry.
     */
    suspend fun markReplaced(id: UUID) = durably {
        synchronized(storeLock) {
            val records = load()
            if (records.any { it.id == id && it.restoreToRemotePath != null }) {
                save(records.map { if (it.id == id) it.copy(restoreToRemotePath = null) else it })
            }
        }
    }

    /** Hands a record still on the host over to the next connection's retry. */
    fun deactivate(id: UUID) {
        active -= id
    }

    suspend fun remove(id: UUID) = durably {
        synchronized(storeLock) {
            val records = load()
            val kept = records.filterNot { it.id == id }
            if (kept.size != records.size) save(kept)
            // Only once it is gone from the store, so no claim can take it.
            active -= id
        }
    }

    /**
     * The route's inactive records, now active for the caller, which must
     * remove or deactivate each one. A cancelled caller still gets them.
     */
    suspend fun claimInactive(route: String): List<PendingRemoteUploadCleanup> = durably {
        synchronized(storeLock) {
            load().filter { it.route == route && active.add(it.id) }
        }
    }

    /** Every persisted record, for tests and diagnostics. */
    fun records(): List<PendingRemoteUploadCleanup> = synchronized(storeLock) { load() }

    /**
     * Runs a journal write on IO and always hands back its result. A bare
     * withContext(IO) discards the result when its caller was cancelled
     * meanwhile, NonCancellable or not; the caller would lose the ids it now
     * owns, and they would stay active for the life of the process.
     */
    private suspend fun <T> durably(block: () -> T): T =
        withContext(NonCancellable) { withContext(Dispatchers.IO) { block() } }

    private fun load(): List<PendingRemoteUploadCleanup> =
        store.read().orEmpty().lineSequence().mapNotNull(::decode).toList()

    private fun save(records: List<PendingRemoteUploadCleanup>) {
        store.write(records.takeIf { it.isNotEmpty() }?.joinToString("\n", transform = ::encode))
    }

    companion object {
        const val MAXIMUM_RECORDS = 256

        @Volatile
        private var shared: RemoteUploadCleanupJournal? = null

        /** One journal per process: every controller's uploads share its active set. */
        fun shared(context: Context): RemoteUploadCleanupJournal = shared ?: synchronized(this) {
            shared ?: RemoteUploadCleanupJournal(SharedPreferencesStore(context.applicationContext)).also { shared = it }
        }

        // One record per line, each field URL-encoded so no path can contain
        // the separators; an empty restore field means none.
        private fun encode(record: PendingRemoteUploadCleanup): String = listOf(
            record.id.toString(),
            record.route,
            record.remotePath,
            record.restoreToRemotePath.orEmpty(),
            record.createdAtEpochSeconds.toString(),
        ).joinToString(" ") { URLEncoder.encode(it, Charsets.UTF_8.name()) }

        private fun decode(line: String): PendingRemoteUploadCleanup? = runCatching {
            val fields = line.split(' ').map { URLDecoder.decode(it, Charsets.UTF_8.name()) }
            if (fields.size != 5 || fields[2].isEmpty()) return null
            PendingRemoteUploadCleanup(
                id = UUID.fromString(fields[0]),
                route = fields[1],
                remotePath = fields[2],
                restoreToRemotePath = fields[3].ifEmpty { null },
                createdAtEpochSeconds = fields[4].toLong(),
            )
        }.getOrNull()
    }
}

private class SharedPreferencesStore(context: Context) : RemoteUploadCleanupStore {
    private val preferences = context.getSharedPreferences("tessera_files_upload_cleanup", Context.MODE_PRIVATE)

    override fun read(): String? = preferences.getString(KEY, null)

    // commit, not apply: the record must be on disk before the remote file it
    // covers exists, or a killed process could strand that file unrecorded.
    override fun write(value: String?) {
        preferences.edit(commit = true) { if (value == null) remove(KEY) else putString(KEY, value) }
    }

    private companion object {
        const val KEY = "pendingRemoteUploadCleanup.v1"
    }
}
