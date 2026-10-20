package com.bambouville.tessera.data

import android.content.Context

/**
 * Small repository kept deliberately separate from projection data. Values are
 * stable opaque identifiers suitable for local routing, never a transcript cache.
 */
class AndroidAgentMetadataRepository {
    private val dao: AgentMetadataDao

    constructor(context: Context) {
        dao = TesseraDatabase.get(context.applicationContext).agentMetadataDao()
    }

    internal constructor(dao: AgentMetadataDao) {
        this.dao = dao
    }

    suspend fun rememberRead(threadKey: String, recordID: String?, unread: Boolean, now: Long) {
        dao.rememberRead(AgentThreadMetadataEntity(canonicalAgentThreadKey(threadKey), recordID, unread, now))
    }

    /** Shared Core's opaque completion identities; never transcript content. */
    suspend fun rememberCompletion(threadKey: String, unreadKey: String?, acknowledgedKey: String?, now: Long) {
        dao.rememberCompletion(canonicalAgentThreadKey(threadKey), unreadKey?.take(128), acknowledgedKey?.take(128), now)
    }

    /**
     * Rows written before thread keys were canonicalised spell the host UUID
     * in upper case, so one thread can own two rows. Core rejects a
     * `configure` that names a thread twice and the whole restore is lost, so
     * the rows are merged here (newest wins) and the table is repaired in
     * place before anything is forwarded.
     */
    suspend fun restoredThreads(): List<RestoredAgentThreadMetadata> {
        return dao.repairThreadKeys().map {
            RestoredAgentThreadMetadata(it.threadKey, it.lastReadRecordID, it.unreadCompletionKey, it.acknowledgedCompletionKey)
        }
    }

    suspend fun issueRoute(routeToken: String, threadKey: String, generation: Long, expiresAt: Long) {
        dao.upsertRoute(AgentRouteTokenEntity(routeToken, threadKey, generation, expiresAt))
    }

    suspend fun resolveRoute(routeToken: String, generation: Long, now: Long): AgentRouteTokenEntity? =
        dao.route(routeToken, generation, now)

    suspend fun clearExpiredRoutes(now: Long) = dao.deleteExpiredRoutes(now)

    suspend fun rememberLineage(threadKey: String, parentThreadKey: String?, parentRecordID: String?, now: Long) {
        dao.upsertLineage(AgentThreadLineageEntity(threadKey, parentThreadKey, parentRecordID, now))
    }

    suspend fun rememberLaunchReceipt(
        threadKey: String,
        requestID: String,
        parentThreadKey: String?,
        parentRecordID: String?,
        windowID: String,
        paneID: String,
        worktreeCreated: Boolean,
        now: Long,
    ) {
        dao.upsertLaunchReceipt(
            AgentLaunchReceiptEntity(
                threadKey = threadKey,
                requestID = requestID,
                parentThreadKey = parentThreadKey,
                parentRecordID = parentRecordID,
                windowID = windowID,
                paneID = paneID,
                worktreeCreated = worktreeCreated,
                recordedAtEpochMilliseconds = now,
            ),
        )
    }
}

data class RestoredAgentThreadMetadata(
    val threadKey: String,
    val lastReadRecordID: String?,
    val unreadCompletionKey: String? = null,
    val acknowledgedCompletionKey: String? = null,
)
