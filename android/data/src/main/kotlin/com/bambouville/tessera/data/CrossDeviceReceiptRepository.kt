package com.bambouville.tessera.data

import android.content.Context

interface CrossDeviceReceiptRepository {
    suspend fun record(receipt: CrossDeviceReceipt)
    suspend fun receipt(attemptId: String): CrossDeviceReceipt?
    suspend fun stagePendingAccess(record: PendingCrossDeviceAccess)
    suspend fun pendingAccess(attemptId: String): List<PendingCrossDeviceAccess>
    suspend fun pendingAccess(): List<PendingCrossDeviceAccess>
    suspend fun clearPendingAccess(attemptId: String, hostId: String)
    suspend fun clearPendingAccessForHost(hostId: String)
}

class AndroidCrossDeviceReceiptRepository private constructor(
    private val dao: CrossDeviceReceiptDao,
) : CrossDeviceReceiptRepository {
    constructor(context: Context) : this(TesseraDatabase.get(context).crossDeviceReceiptDao())

    override suspend fun record(receipt: CrossDeviceReceipt) {
        require(receipt.attemptId.isNotBlank())
        dao.upsert(
            CrossDeviceReceiptEntity(
                receiptId = "${receipt.attemptId}:${receipt.kind}",
                attemptId = receipt.attemptId,
                kind = receipt.kind,
                hostIds = receipt.hostIds.distinct().sorted().joinToString(","),
                recordedAtEpochMilliseconds = receipt.recordedAtEpochMilliseconds,
            ),
        )
    }

    override suspend fun receipt(attemptId: String): CrossDeviceReceipt? = dao.get(attemptId)?.let {
        CrossDeviceReceipt(it.attemptId, it.kind, it.hostIds.split(',').filter(String::isNotEmpty), it.recordedAtEpochMilliseconds)
    }

    override suspend fun stagePendingAccess(record: PendingCrossDeviceAccess) {
        val hostId = java.util.UUID.fromString(record.hostId).toString()
        require(record.attemptId.isNotBlank() && record.identityId.isNotBlank())
        dao.upsertPending(
            PendingCrossDeviceAccessEntity(
                pendingId = "${record.attemptId}:$hostId",
                attemptId = record.attemptId,
                hostId = hostId,
                identityId = record.identityId,
                createdAtEpochMilliseconds = record.createdAtEpochMilliseconds,
            ),
        )
    }

    override suspend fun pendingAccess(attemptId: String): List<PendingCrossDeviceAccess> =
        dao.pending(attemptId).map {
            PendingCrossDeviceAccess(it.attemptId, it.hostId, it.identityId, it.createdAtEpochMilliseconds)
        }

    override suspend fun pendingAccess(): List<PendingCrossDeviceAccess> =
        dao.pendingAll().map {
            PendingCrossDeviceAccess(it.attemptId, it.hostId, it.identityId, it.createdAtEpochMilliseconds)
        }

    override suspend fun clearPendingAccess(attemptId: String, hostId: String) {
        dao.deletePending(attemptId, java.util.UUID.fromString(hostId).toString())
    }

    override suspend fun clearPendingAccessForHost(hostId: String) {
        dao.deletePendingForHost(java.util.UUID.fromString(hostId).toString())
    }
}
