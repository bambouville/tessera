package com.bambouville.tessera.data.continuity

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.foregroundRestorePreferences by preferencesDataStore(name = "tessera_foreground_restore")

/**
 * Atomic on-disk store for the background-edge snapshot. A process death can
 * therefore re-seed the foreground cohort without trusting stale in-memory
 * tabs. Corrupt or obsolete documents are rejected rather than partially
 * restored.
 */
class AndroidForegroundRestoreStore(private val context: Context) {
    val restorePolicy: Flow<SessionRestorePolicy> = context.foregroundRestorePreferences.data.map { preferences ->
        preferences[PolicyKey]?.let { raw ->
            runCatching { SessionRestorePolicy.valueOf(raw) }.getOrNull()
        } ?: SessionRestorePolicy.ASK
    }

    val documents: Flow<ForegroundRestoreDocument?> = context.foregroundRestorePreferences.data.map { preferences ->
        preferences[DocumentKey]?.let(ForegroundRestoreDocumentCodec::decodeOrNull)
    }

    suspend fun load(): ForegroundRestoreDocument? = documents.first()

    suspend fun save(document: ForegroundRestoreDocument) {
        context.foregroundRestorePreferences.edit { preferences ->
            preferences[DocumentKey] = ForegroundRestoreDocumentCodec.encode(document)
        }
    }

    suspend fun updateRestorePolicy(policy: SessionRestorePolicy) {
        context.foregroundRestorePreferences.edit { preferences -> preferences[PolicyKey] = policy.name }
    }

    suspend fun clear() {
        context.foregroundRestorePreferences.edit { preferences -> preferences.remove(DocumentKey) }
    }

    /** Retire an ended/explicitly closed host without disturbing a newer cohort. */
    suspend fun removeForHost(hostId: String) {
        context.foregroundRestorePreferences.edit { preferences ->
            val current = preferences[DocumentKey]?.let(ForegroundRestoreDocumentCodec::decodeOrNull)
                ?: return@edit
            val remaining = current.snapshots.filterNot { it.hostId == hostId }
            if (remaining.isEmpty()) {
                preferences.remove(DocumentKey)
            } else {
                preferences[DocumentKey] = ForegroundRestoreDocumentCodec.encode(
                    current.copy(
                        snapshots = remaining,
                        selectedSessionId = current.selectedSessionId?.takeIf { selected ->
                            remaining.any { it.sessionId == selected }
                        },
                    ),
                )
            }
        }
    }

    private companion object {
        val PolicyKey = stringPreferencesKey("session_restore_policy_v1")
        val DocumentKey = stringPreferencesKey("foreground_restore_document_v1")
    }
}

/** Compact canonical codec so the persistence boundary remains testable on the JVM. */
internal object ForegroundRestoreDocumentCodec {
    private const val NULL = "~"
    private const val FIELD_SEPARATOR = '|'
    private const val RECORD_SEPARATOR = '\n'
    private const val MAX_DOCUMENT_BYTES = 64 * 1024

    fun encode(document: ForegroundRestoreDocument): String = buildString {
        append(document.schemaVersion)
        append(FIELD_SEPARATOR)
        append(document.savedAtEpochMilliseconds)
        append(FIELD_SEPARATOR)
        append(field(document.selectedSessionId))
        document.snapshots.forEach { snapshot ->
            append(RECORD_SEPARATOR)
            append(listOf(
                field(snapshot.sessionId),
                field(snapshot.hostId),
                field(snapshot.displayName),
                snapshot.createdAtEpochMilliseconds.toString(),
                field(snapshot.transportKind),
                field(snapshot.tmuxTarget),
                field(snapshot.lastSelection),
                if (snapshot.reconnectRequired) "1" else "0",
            ).joinToString(FIELD_SEPARATOR.toString()))
        }
    }

    fun decodeOrNull(encoded: String): ForegroundRestoreDocument? = runCatching {
        require(encoded.toByteArray(StandardCharsets.UTF_8).size <= MAX_DOCUMENT_BYTES)
        val lines = encoded.split(RECORD_SEPARATOR)
        require(lines.size >= 2)
        val header = lines.first().split(FIELD_SEPARATOR)
        require(header.size == 3)
        val schema = header[0].toInt()
        val savedAt = header[1].toLong()
        val snapshots = lines.drop(1).map { line ->
            val fields = line.split(FIELD_SEPARATOR)
            require(fields.size == 8)
            ForegroundRestoreSnapshot(
                sessionId = requiredField(fields[0]),
                hostId = requiredField(fields[1]),
                displayName = requiredField(fields[2]),
                createdAtEpochMilliseconds = fields[3].toLong(),
                transportKind = requiredField(fields[4]),
                tmuxTarget = nullableField(fields[5]),
                lastSelection = nullableField(fields[6]),
                reconnectRequired = when (fields[7]) {
                    "0" -> false
                    "1" -> true
                    else -> error("invalid reconnect flag")
                },
            )
        }
        ForegroundRestoreDocument(
            schemaVersion = schema,
            savedAtEpochMilliseconds = savedAt,
            snapshots = snapshots,
            selectedSessionId = nullableField(header[2]),
        )
    }.getOrNull()

    private fun field(value: String?): String = value?.let {
        Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(StandardCharsets.UTF_8))
    } ?: NULL

    private fun requiredField(value: String): String = checkNotNull(nullableField(value))

    private fun nullableField(value: String): String? {
        if (value == NULL) return null
        return String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8)
    }
}
