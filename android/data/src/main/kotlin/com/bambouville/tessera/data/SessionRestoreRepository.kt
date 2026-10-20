package com.bambouville.tessera.data

import android.content.Context
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

data class SessionRestoreRecord(
    val sessionId: String,
    val hostId: String,
    val transportKind: String,
    val tmuxTarget: String?,
    val lastSelection: String?,
    val reconnectRequired: Boolean,
    val updatedAtEpochMilliseconds: Long,
)

interface SessionRestoreRepository {
    fun observeRecords(): Flow<List<SessionRestoreRecord>>
    suspend fun records(): List<SessionRestoreRecord>
    suspend fun record(sessionId: String): SessionRestoreRecord?
    suspend fun save(record: SessionRestoreRecord)
    suspend fun delete(sessionId: String)
    suspend fun deleteForHost(hostId: String)
    suspend fun deleteAll()
}

class AndroidSessionRestoreRepository private constructor(
    private val dao: SessionRestoreDao,
) : SessionRestoreRepository {
    constructor(context: Context) : this(TesseraDatabase.get(context).sessionRestoreDao())

    override fun observeRecords(): Flow<List<SessionRestoreRecord>> =
        dao.observeAll().map { records -> records.map(SessionRestoreEntity::toRecord) }

    override suspend fun records(): List<SessionRestoreRecord> =
        observeRecords().first()

    override suspend fun record(sessionId: String): SessionRestoreRecord? = dao.get(sessionId)?.toRecord()

    override suspend fun save(record: SessionRestoreRecord) {
        dao.upsert(
            SessionRestoreEntity(
                sessionId = record.sessionId,
                hostId = record.hostId,
                transportKind = record.transportKind,
                tmuxTarget = record.tmuxTarget,
                lastSelection = record.lastSelection,
                reconnectRequired = record.reconnectRequired,
                updatedAtEpochMilliseconds = record.updatedAtEpochMilliseconds,
            ),
        )
    }

    override suspend fun delete(sessionId: String) = dao.delete(sessionId)

    override suspend fun deleteForHost(hostId: String) = dao.deleteForHost(hostId)

    override suspend fun deleteAll() = dao.deleteAll()
}

private fun SessionRestoreEntity.toRecord() = SessionRestoreRecord(
    sessionId = sessionId,
    hostId = hostId,
    transportKind = transportKind,
    tmuxTarget = tmuxTarget,
    lastSelection = lastSelection,
    reconnectRequired = reconnectRequired,
    updatedAtEpochMilliseconds = updatedAtEpochMilliseconds,
)
