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

private val Context.pendingContinuationPreferences by preferencesDataStore(name = "tessera_pending_continuation")

/**
 * The durable handoff between pairing's accepted descriptor and the first
 * destination terminal frame. It contains routing metadata only; the
 * authenticated descriptor and all pairing keys remain in the shared runtime.
 */
data class PendingContinuationRecovery(
    val attemptId: String,
    val hostId: String,
    val transportKind: String,
    val tmuxTarget: String?,
    /**
     * Secret-free route binding from the authenticated continuation descriptor:
     * `routeKey#fingerprint` (transport-free), derived by the shared
     * `ContinuationRouteIdentity` in
     * `Packages/TesseraCore/Sources/TesseraProtocolCore`.
     *
     * Treat it as opaque. It is compared, never parsed, and its rendering
     * belongs to the shared core — a record staged by an older build whose
     * route carried non-ASCII text simply stops matching and retires early,
     * which is the same outcome as a route the user has since changed.
     */
    val routeIdentity: String,
    val stagedAtEpochMilliseconds: Long,
) {
    init {
        require(attemptId.isNotBlank())
        require(hostId.isNotBlank())
        require(transportKind == "ssh" || transportKind == "mosh")
        require(tmuxTarget == null || tmuxTarget.isNotBlank())
        require(routeIdentity.isNotBlank())
        require(stagedAtEpochMilliseconds >= 0)
    }
}

/** A pairing destination recovery is an immediate crash-resume affordance, not a durable job. */
fun PendingContinuationRecovery.isFreshAt(
    nowEpochMilliseconds: Long,
    maximumAgeMilliseconds: Long = MAX_PENDING_CONTINUATION_AGE_MILLISECONDS,
): Boolean {
    if (nowEpochMilliseconds < 0 || maximumAgeMilliseconds < 0) return false
    val age = nowEpochMilliseconds - stagedAtEpochMilliseconds
    return age in 0..maximumAgeMilliseconds
}

const val MAX_PENDING_CONTINUATION_AGE_MILLISECONDS: Long = 15 * 60 * 1_000L

class AndroidPendingContinuationRecoveryStore(private val context: Context) {
    val pending: Flow<PendingContinuationRecovery?> = context.pendingContinuationPreferences.data.map { preferences ->
        preferences[PendingKey]?.let(PendingContinuationRecoveryCodec::decodeOrNull)
    }

    suspend fun load(): PendingContinuationRecovery? = pending.first()

    suspend fun stage(record: PendingContinuationRecovery) {
        context.pendingContinuationPreferences.edit { preferences ->
            preferences[PendingKey] = PendingContinuationRecoveryCodec.encode(record)
        }
    }

    /** Clear only the attempt that completed; never erase a newer replacement. */
    suspend fun clearIfAttempt(attemptId: String) {
        context.pendingContinuationPreferences.edit { preferences ->
            val current = preferences[PendingKey]?.let(PendingContinuationRecoveryCodec::decodeOrNull)
            if (current?.attemptId == attemptId) preferences.remove(PendingKey)
        }
    }

    suspend fun clear() {
        context.pendingContinuationPreferences.edit { preferences -> preferences.remove(PendingKey) }
    }

    private companion object {
        val PendingKey = stringPreferencesKey("pending_continuation_v1")
    }
}

internal object PendingContinuationRecoveryCodec {
    private const val NULL = "~"
    private const val SEPARATOR = '|'

    fun encode(record: PendingContinuationRecovery): String = listOf(
        field(record.attemptId),
        field(record.hostId),
        field(record.transportKind),
        field(record.tmuxTarget),
        field(record.routeIdentity),
        record.stagedAtEpochMilliseconds.toString(),
    ).joinToString(SEPARATOR.toString())

    fun decodeOrNull(encoded: String): PendingContinuationRecovery? = runCatching {
        require(encoded.toByteArray(StandardCharsets.UTF_8).size <= 4 * 1024)
        val fields = encoded.split(SEPARATOR)
        require(fields.size == 6)
        PendingContinuationRecovery(
            attemptId = requiredField(fields[0]),
            hostId = requiredField(fields[1]),
            transportKind = requiredField(fields[2]),
            tmuxTarget = nullableField(fields[3]),
            routeIdentity = requiredField(fields[4]),
            stagedAtEpochMilliseconds = fields[5].toLong(),
        )
    }.getOrNull()

    private fun field(value: String?): String = value?.let {
        Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(StandardCharsets.UTF_8))
    } ?: NULL

    private fun requiredField(value: String): String = checkNotNull(nullableField(value))

    private fun nullableField(value: String): String? = if (value == NULL) null
    else String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8)
}
