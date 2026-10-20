package com.bambouville.tessera.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import androidx.room.Transaction
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow

@Dao
internal interface HostDao {
    @Query("SELECT * FROM hosts ORDER BY displayName COLLATE NOCASE, hostname COLLATE NOCASE")
    fun observeAll(): Flow<List<HostEntity>>

    @Query("SELECT * FROM hosts WHERE id = :id")
    suspend fun get(id: String): HostEntity?

    @Upsert
    suspend fun upsert(host: HostEntity)

    @Query("DELETE FROM hosts WHERE id = :id")
    suspend fun delete(id: String): Int
}

@Dao
internal interface IdentityDao {
    @Upsert
    suspend fun upsert(identity: IdentityEntity)

    @Query("SELECT * FROM identities WHERE id = :id")
    suspend fun get(id: String): IdentityEntity?

    @Query("SELECT * FROM identities ORDER BY displayName COLLATE NOCASE")
    fun observeAll(): Flow<List<IdentityEntity>>

    @Query("DELETE FROM identities WHERE id = :id")
    suspend fun delete(id: String): Int
}

@Dao
internal interface KnownHostDao {
    @Query("SELECT * FROM known_hosts ORDER BY normalizedEndpoint COLLATE NOCASE")
    fun observeAll(): Flow<List<KnownHostEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(host: KnownHostEntity)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertIfAbsent(host: KnownHostEntity): Long

    @Query(
        "SELECT * FROM known_hosts " +
            "WHERE normalizedEndpoint = :endpoint",
    )
    suspend fun get(endpoint: String): KnownHostEntity?

    @Query(
        "DELETE FROM known_hosts " +
            "WHERE normalizedEndpoint = :endpoint",
    )
    suspend fun delete(endpoint: String): Int
}

@Dao
internal interface SessionRestoreDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(record: SessionRestoreEntity)

    @Query("SELECT * FROM session_restore ORDER BY updatedAtEpochMilliseconds DESC")
    fun observeAll(): Flow<List<SessionRestoreEntity>>

    @Query("SELECT * FROM session_restore WHERE sessionId = :sessionId")
    suspend fun get(sessionId: String): SessionRestoreEntity?

    @Query("DELETE FROM session_restore WHERE sessionId = :sessionId")
    suspend fun delete(sessionId: String)

    @Query("DELETE FROM session_restore WHERE hostId = :hostId")
    suspend fun deleteForHost(hostId: String)

    @Query("DELETE FROM session_restore")
    suspend fun deleteAll()
}

@Dao
internal interface CrossDeviceReceiptDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(receipt: CrossDeviceReceiptEntity)

    @Query("SELECT * FROM cross_device_receipts WHERE attemptId = :attemptId ORDER BY recordedAtEpochMilliseconds DESC LIMIT 1")
    suspend fun get(attemptId: String): CrossDeviceReceiptEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertPending(record: PendingCrossDeviceAccessEntity)

    @Query("SELECT * FROM pending_cross_device_access WHERE attemptId = :attemptId ORDER BY hostId")
    suspend fun pending(attemptId: String): List<PendingCrossDeviceAccessEntity>

    @Query("SELECT * FROM pending_cross_device_access ORDER BY createdAtEpochMilliseconds, hostId")
    suspend fun pendingAll(): List<PendingCrossDeviceAccessEntity>

    @Query("DELETE FROM pending_cross_device_access WHERE attemptId = :attemptId AND hostId = :hostId")
    suspend fun deletePending(attemptId: String, hostId: String): Int

    @Query("DELETE FROM pending_cross_device_access WHERE hostId = :hostId")
    suspend fun deletePendingForHost(hostId: String): Int
}

/** Metadata-only persistence boundary for Agent Center restoration and routing. */
@Dao
internal interface AgentMetadataDao {
    @Upsert
    suspend fun upsertThread(metadata: AgentThreadMetadataEntity)

    @Query("SELECT * FROM agent_thread_metadata WHERE threadKey = :threadKey")
    suspend fun thread(threadKey: String): AgentThreadMetadataEntity?

    @Query("SELECT * FROM agent_thread_metadata ORDER BY updatedAtEpochMilliseconds DESC LIMIT 1024")
    suspend fun threads(): List<AgentThreadMetadataEntity>

    @Query("DELETE FROM agent_thread_metadata WHERE threadKey = :threadKey")
    suspend fun deleteThread(threadKey: String)

    /** A read keeps the completion identities; only `rememberCompletion` writes them. */
    @Transaction
    suspend fun rememberRead(metadata: AgentThreadMetadataEntity) {
        val existing = thread(metadata.threadKey)
        upsertThread(metadata.copy(
            unreadCompletionKey = existing?.unreadCompletionKey,
            acknowledgedCompletionKey = existing?.acknowledgedCompletionKey,
        ))
    }

    @Transaction
    suspend fun rememberCompletion(threadKey: String, unreadKey: String?, acknowledgedKey: String?, now: Long) {
        val existing = thread(threadKey)
        if (existing == null) {
            if (unreadKey == null && acknowledgedKey == null) return
            upsertThread(AgentThreadMetadataEntity(threadKey, null, unreadKey != null, now, unreadKey, acknowledgedKey))
            return
        }
        if (existing.unreadCompletionKey == unreadKey && existing.acknowledgedCompletionKey == acknowledgedKey) return
        upsertThread(existing.copy(
            unreadCompletionKey = unreadKey,
            acknowledgedCompletionKey = acknowledgedKey,
            updatedAtEpochMilliseconds = maxOf(existing.updatedAtEpochMilliseconds, now),
        ))
    }

    /** Serialize repair with read acknowledgements across every repository instance. */
    @Transaction
    suspend fun repairThreadKeys(): List<AgentThreadMetadataEntity> {
        val rows = threads()
        val merged = LinkedHashMap<String, AgentThreadMetadataEntity>()
        for (row in rows) {
            val key = canonicalAgentThreadKey(row.threadKey)
            val newest = merged[key]
            if (newest == null || row.updatedAtEpochMilliseconds > newest.updatedAtEpochMilliseconds) {
                merged[key] = row.copy(threadKey = key)
            }
        }
        for (row in rows) {
            val key = canonicalAgentThreadKey(row.threadKey)
            if (key != row.threadKey) {
                merged[key]?.let { upsertThread(it) }
                deleteThread(row.threadKey)
            }
        }
        return merged.values.toList()
    }

    @Upsert
    suspend fun upsertRoute(route: AgentRouteTokenEntity)

    @Query("SELECT * FROM agent_route_tokens WHERE routeToken = :routeToken AND carrierGeneration = :generation AND expiresAtEpochMilliseconds >= :now LIMIT 1")
    suspend fun route(routeToken: String, generation: Long, now: Long): AgentRouteTokenEntity?

    @Query("DELETE FROM agent_route_tokens WHERE expiresAtEpochMilliseconds < :now")
    suspend fun deleteExpiredRoutes(now: Long): Int

    @Upsert
    suspend fun upsertLineage(lineage: AgentThreadLineageEntity)

    @Query("SELECT * FROM agent_thread_lineage WHERE threadKey = :threadKey")
    suspend fun lineage(threadKey: String): AgentThreadLineageEntity?

    @Upsert
    suspend fun upsertLaunchReceipt(receipt: AgentLaunchReceiptEntity)

    @Query("SELECT * FROM agent_launch_receipts WHERE threadKey = :threadKey")
    suspend fun launchReceipt(threadKey: String): AgentLaunchReceiptEntity?
}

@Database(
    entities = [
        HostEntity::class,
        IdentityEntity::class,
        KnownHostEntity::class,
        SessionRestoreEntity::class,
        CrossDeviceReceiptEntity::class,
        PendingCrossDeviceAccessEntity::class,
        AgentThreadMetadataEntity::class,
        AgentRouteTokenEntity::class,
        AgentThreadLineageEntity::class,
        AgentLaunchReceiptEntity::class,
    ],
    version = 8,
    exportSchema = true,
)
internal abstract class TesseraDatabase : RoomDatabase() {
    abstract fun hostDao(): HostDao
    abstract fun identityDao(): IdentityDao
    abstract fun knownHostDao(): KnownHostDao
    abstract fun sessionRestoreDao(): SessionRestoreDao
    abstract fun crossDeviceReceiptDao(): CrossDeviceReceiptDao
    abstract fun agentMetadataDao(): AgentMetadataDao

    companion object {
        @Volatile private var instance: TesseraDatabase? = null

        fun get(context: Context): TesseraDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext,
                    TesseraDatabase::class.java,
                    "tessera.db",
                ).addMigrations(Migration1To2, Migration2To3, Migration3To4, Migration4To5, Migration5To6, Migration6To7,
                    Migration7To8).build().also { instance = it }
            }

        internal val Migration1To2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE known_hosts ADD COLUMN previousAlgorithm TEXT")
                db.execSQL("ALTER TABLE known_hosts ADD COLUMN previousCanonicalKeyBlob BLOB")
            }
        }

        internal val Migration2To3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE hosts ADD COLUMN tmuxMode TEXT NOT NULL DEFAULT 'off'")
                db.execSQL("ALTER TABLE hosts ADD COLUMN tmuxTarget TEXT")
            }
        }

        internal val Migration3To4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE hosts ADD COLUMN transportKind TEXT NOT NULL DEFAULT 'ssh'")
                db.execSQL(
                    "CREATE TABLE cross_device_receipts (receiptId TEXT NOT NULL, attemptId TEXT NOT NULL, " +
                        "kind TEXT NOT NULL, hostIds TEXT NOT NULL, recordedAtEpochMilliseconds INTEGER NOT NULL, " +
                        "PRIMARY KEY(receiptId))",
                )
                db.execSQL(
                    "CREATE TABLE pending_cross_device_access (pendingId TEXT NOT NULL, attemptId TEXT NOT NULL, " +
                        "hostId TEXT NOT NULL, identityId TEXT NOT NULL, createdAtEpochMilliseconds INTEGER NOT NULL, " +
                        "PRIMARY KEY(pendingId))",
                )
                db.execSQL("CREATE INDEX index_pending_cross_device_access_attemptId ON pending_cross_device_access (attemptId)")
                db.execSQL("CREATE INDEX index_pending_cross_device_access_hostId ON pending_cross_device_access (hostId)")
            }
        }

        /**
         * Only opaque identifiers and read/lineage state are added. Do not add
         * transcript text, cursors, paths, or notification copy to these tables.
         */
        internal val Migration4To5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE agent_thread_metadata (threadKey TEXT NOT NULL, lastReadRecordID TEXT, unread INTEGER NOT NULL, updatedAtEpochMilliseconds INTEGER NOT NULL, PRIMARY KEY(threadKey))",
                )
                db.execSQL(
                    "CREATE TABLE agent_route_tokens (routeToken TEXT NOT NULL, threadKey TEXT NOT NULL, carrierGeneration INTEGER NOT NULL, expiresAtEpochMilliseconds INTEGER NOT NULL, PRIMARY KEY(routeToken))",
                )
                db.execSQL("CREATE INDEX index_agent_route_tokens_threadKey ON agent_route_tokens (threadKey)")
                db.execSQL(
                    "CREATE TABLE agent_thread_lineage (threadKey TEXT NOT NULL, parentThreadKey TEXT, parentRecordID TEXT, updatedAtEpochMilliseconds INTEGER NOT NULL, PRIMARY KEY(threadKey))",
                )
                db.execSQL("CREATE INDEX index_agent_thread_lineage_parentThreadKey ON agent_thread_lineage (parentThreadKey)")
            }
        }

        internal val Migration6To7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                listOf("launchCommand", "notes", "envVars", "startupSnippet").forEach {
                    db.execSQL("ALTER TABLE hosts ADD COLUMN $it TEXT")
                }
            }
        }

        /**
         * Nullable, content-free completion identities from shared Core, so a
         * relaunch keeps a finish's read state. Existing rows read as unknown.
         */
        internal val Migration7To8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE agent_thread_metadata ADD COLUMN unreadCompletionKey TEXT")
                db.execSQL("ALTER TABLE agent_thread_metadata ADD COLUMN acknowledgedCompletionKey TEXT")
            }
        }

        /** Launch receipts retain only typed route/lineage facts for audit UI. */
        internal val Migration5To6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE agent_launch_receipts (threadKey TEXT NOT NULL, requestID TEXT NOT NULL, " +
                        "parentThreadKey TEXT, parentRecordID TEXT, windowID TEXT NOT NULL, paneID TEXT NOT NULL, " +
                        "worktreeCreated INTEGER NOT NULL, recordedAtEpochMilliseconds INTEGER NOT NULL, PRIMARY KEY(threadKey))",
                )
                db.execSQL("CREATE INDEX index_agent_launch_receipts_parentThreadKey ON agent_launch_receipts (parentThreadKey)")
            }
        }
    }
}
