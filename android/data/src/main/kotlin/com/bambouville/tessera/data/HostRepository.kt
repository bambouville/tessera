package com.bambouville.tessera.data

import android.content.Context
import androidx.annotation.StringRes
import com.bambouville.tessera.core.bridge.SharedTargetValidation
import com.bambouville.tessera.core.bridge.SharedTmuxNameRejection
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map

interface HostRepository {
    fun observeHosts(): Flow<List<SavedHost>>

    /** Latest rows, or null until the first load answers. */
    val loadedHosts: StateFlow<List<SavedHost>?>
    suspend fun host(id: String): SavedHost?
    suspend fun save(draft: HostDraft): SavedHost
    suspend fun delete(id: String): Boolean
    suspend fun resolveRoute(hostId: String): List<SavedHost>
}

class AndroidHostRepository private constructor(
    private val dao: HostDao,
    private val clock: () -> Long,
    /** Resolves the validation messages the host editor shows. */
    private val appContext: Context,
    private val scope: CoroutineScope = repositoryScope(),
) : HostRepository {
    constructor(context: Context) : this(
        dao = TesseraDatabase.get(context).hostDao(),
        clock = System::currentTimeMillis,
        appContext = context.applicationContext,
    )

    override val loadedHosts: StateFlow<List<SavedHost>?> =
        observeHosts().loadedState(scope)

    override fun observeHosts(): Flow<List<SavedHost>> =
        dao.observeAll().map { hosts -> hosts.map(HostEntity::toSavedHost) }

    override suspend fun host(id: String): SavedHost? = dao.get(normalizeUuid(id))?.toSavedHost()

    override suspend fun save(draft: HostDraft): SavedHost {
        val normalized = try {
            HostDraftValidator.normalize(draft)
        } catch (invalid: HostDraftInvalidException) {
            throw IllegalArgumentException(appContext.getString(invalid.messageRes), invalid)
        }
        val existing = normalized.id?.let { dao.get(it) }
        val now = clock()
        val entity = HostEntity(
            id = normalized.id ?: UUID.randomUUID().toString(),
            displayName = normalized.displayName,
            hostname = normalized.hostname,
            port = normalized.port,
            username = normalized.username,
            jumpHostId = normalized.jumpHostId,
            identityId = normalized.identityId,
            transportKind = normalized.transportKind,
            tmuxMode = normalized.tmuxMode,
            tmuxTarget = normalized.tmuxTarget,
            launchCommand = normalized.launchCommand,
            notes = normalized.notes,
            envVars = normalized.envVars,
            startupSnippet = normalized.startupSnippet,
            createdAtEpochMilliseconds = existing?.createdAtEpochMilliseconds ?: now,
            updatedAtEpochMilliseconds = now,
        )
        require(entity.jumpHostId != entity.id) { appContext.getString(R.string.data_host_jump_through_itself) }
        validateJumpRoute(entity.id, entity.jumpHostId)
        dao.upsert(entity)
        return entity.toSavedHost()
    }

    override suspend fun delete(id: String): Boolean = dao.delete(normalizeUuid(id)) > 0

    override suspend fun resolveRoute(hostId: String): List<SavedHost> {
        val reversed = mutableListOf<SavedHost>()
        val visited = mutableSetOf<String>()
        var next: String? = normalizeUuid(hostId)
        while (next != null) {
            require(visited.add(next)) { appContext.getString(R.string.data_jump_route_cycle) }
            require(reversed.size < MAX_ROUTE_HOPS) { jumpRouteTooLong() }
            val host = dao.get(next)?.toSavedHost() ?: error(appContext.getString(R.string.data_route_host_unavailable))
            reversed += host
            next = host.jumpHostId
        }
        return reversed.asReversed()
    }

    private suspend fun validateJumpRoute(hostId: String, firstJumpHostId: String?) {
        val visited = mutableSetOf(hostId)
        var next = firstJumpHostId
        var count = 1
        while (next != null) {
            require(visited.add(next)) { appContext.getString(R.string.data_jump_route_cycle) }
            require(count++ < MAX_ROUTE_HOPS) { jumpRouteTooLong() }
            val jumpHost = dao.get(next) ?: error(appContext.getString(R.string.data_jump_host_unavailable))
            next = jumpHost.jumpHostId
        }
    }

    private fun jumpRouteTooLong(): String =
        appContext.resources.getQuantityString(R.plurals.data_jump_route_too_long, MAX_ROUTE_HOPS, MAX_ROUTE_HOPS)

    private companion object {
        const val MAX_ROUTE_HOPS = 8
        fun normalizeUuid(value: String): String = UUID.fromString(value).toString()
    }
}

object HostDraftValidator {
    fun normalize(draft: HostDraft): HostDraft {
        val rawHostname = draft.hostname.trim()
        val hostname = if (rawHostname.startsWith("[") && rawHostname.endsWith("]")) {
            rawHostname.substring(1, rawHostname.lastIndex)
        } else {
            rawHostname
        }
        val username = draft.username.trim()
        val displayName = draft.displayName.trim().ifEmpty { hostname }
        invalidUnless(hostname.isNotEmpty(), R.string.data_hostname_required)
        invalidUnless(hostname.none(Char::isWhitespace), R.string.data_hostname_whitespace)
        invalidUnless(hostname.none(Char::isISOControl), R.string.data_hostname_control_characters)
        invalidUnless(username.isNotEmpty(), R.string.data_username_required)
        invalidUnless(username.none(Char::isWhitespace), R.string.data_username_whitespace)
        invalidUnless(username.none(Char::isISOControl), R.string.data_username_control_characters)
        invalidUnless(displayName.none(Char::isISOControl), R.string.data_name_control_characters)
        invalidUnless(draft.port in 1..65535, R.string.data_port_range)
        listOf(draft.launchCommand, draft.notes, draft.envVars, draft.startupSnippet).forEach {
            invalidUnless(
                it == null || (it.toByteArray(Charsets.UTF_8).size <= 65_536 && '\u0000' !in it),
                R.string.data_host_text_too_long,
            )
        }
        invalidUnless(
            draft.tmuxMode in setOf(TmuxModes.OFF, TmuxModes.AUTOMATIC, TmuxModes.PINNED),
            R.string.data_invalid_tmux_mode,
        )
        invalidUnless(
            draft.transportKind in setOf(TransportKinds.SSH, TransportKinds.MOSH),
            R.string.data_invalid_transport_kind,
        )
        val tmuxTarget = draft.tmuxTarget?.trim()?.takeIf(String::isNotEmpty)
        if (draft.tmuxMode == TmuxModes.PINNED) {
            // One grammar, owned by the shared core: this field, the tmux
            // attach command, and the control-mode guard had drifted into
            // three different charset literals.
            // Swift authority:
            // `Packages/TesseraCore/Sources/TesseraProtocolCore/TmuxTargetValidation.swift`.
            when (SharedTargetValidation.tmuxSessionNameRejection(tmuxTarget.orEmpty())) {
                null -> Unit
                SharedTmuxNameRejection.Empty ->
                    throw HostDraftInvalidException(R.string.data_tmux_target_required)
                SharedTmuxNameRejection.TooLong ->
                    throw HostDraftInvalidException(R.string.data_tmux_target_too_long)
                SharedTmuxNameRejection.UnsafeCharacter ->
                    throw HostDraftInvalidException(R.string.data_tmux_target_characters)
            }
        }
        return draft.copy(
            id = draft.id?.let { UUID.fromString(it).toString() },
            jumpHostId = draft.jumpHostId?.let { UUID.fromString(it).toString() },
            displayName = displayName,
            hostname = hostname,
            username = username,
            tmuxTarget = tmuxTarget,
        )
    }

    private fun invalidUnless(valid: Boolean, @StringRes messageRes: Int) {
        if (!valid) throw HostDraftInvalidException(messageRes)
    }
}

/**
 * A draft the host editor must correct. [messageRes] is what the user reads;
 * [AndroidHostRepository.save] rethrows it with that text resolved.
 */
class HostDraftInvalidException(@param:StringRes val messageRes: Int) : IllegalArgumentException()
