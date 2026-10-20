package com.bambouville.tessera.data

import android.content.Context
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
    private val scope: CoroutineScope = repositoryScope(),
) : HostRepository {
    constructor(context: Context) : this(
        dao = TesseraDatabase.get(context).hostDao(),
        clock = System::currentTimeMillis,
    )

    override val loadedHosts: StateFlow<List<SavedHost>?> =
        observeHosts().loadedState(scope)

    override fun observeHosts(): Flow<List<SavedHost>> =
        dao.observeAll().map { hosts -> hosts.map(HostEntity::toSavedHost) }

    override suspend fun host(id: String): SavedHost? = dao.get(normalizeUuid(id))?.toSavedHost()

    override suspend fun save(draft: HostDraft): SavedHost {
        val normalized = HostDraftValidator.normalize(draft)
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
        require(entity.jumpHostId != entity.id) { "a host cannot jump through itself" }
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
            require(visited.add(next)) { "jump route contains a cycle" }
            require(reversed.size < MAX_ROUTE_HOPS) { "jump route exceeds $MAX_ROUTE_HOPS hosts" }
            val host = dao.get(next)?.toSavedHost() ?: error("route host is unavailable")
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
            require(visited.add(next)) { "jump route contains a cycle" }
            require(count++ < MAX_ROUTE_HOPS) { "jump route exceeds $MAX_ROUTE_HOPS hosts" }
            val jumpHost = dao.get(next) ?: error("jump host is unavailable")
            next = jumpHost.jumpHostId
        }
    }

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
        require(hostname.isNotEmpty()) { "hostname is required" }
        require(hostname.none(Char::isWhitespace)) { "hostname cannot contain whitespace" }
        require(hostname.none(Char::isISOControl)) { "hostname cannot contain control characters" }
        require(username.isNotEmpty()) { "username is required" }
        require(username.none(Char::isWhitespace)) { "username cannot contain whitespace" }
        require(username.none(Char::isISOControl)) { "username cannot contain control characters" }
        require(displayName.none(Char::isISOControl)) { "name cannot contain control characters" }
        require(draft.port in 1..65535) { "port must be between 1 and 65535" }
        listOf(draft.launchCommand, draft.notes, draft.envVars, draft.startupSnippet).forEach {
            require(it == null || (it.toByteArray(Charsets.UTF_8).size <= 65_536 && '\u0000' !in it)) { "host text exceeds 64 KiB or contains a NUL character" }
        }
        require(draft.tmuxMode in setOf(TmuxModes.OFF, TmuxModes.AUTOMATIC, TmuxModes.PINNED)) {
            "invalid tmux mode"
        }
        require(draft.transportKind in setOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            "invalid transport kind"
        }
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
                    throw IllegalArgumentException("a pinned tmux target is required")
                SharedTmuxNameRejection.TooLong ->
                    throw IllegalArgumentException("tmux target is too long")
                SharedTmuxNameRejection.UnsafeCharacter ->
                    throw IllegalArgumentException(
                        "tmux target must use letters, digits, underscore, dash, or dot",
                    )
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
}
