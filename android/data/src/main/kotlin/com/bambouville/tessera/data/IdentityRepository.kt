package com.bambouville.tessera.data

import android.content.Context
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map

interface IdentityRepository {
    fun observeIdentities(): Flow<List<SavedIdentity>>

    /** Latest rows, or null until the first load answers. */
    val loadedIdentities: StateFlow<List<SavedIdentity>?>
    suspend fun identity(id: String): SavedIdentity?
    suspend fun save(
        displayName: String,
        credentialKind: String,
        credentialReference: String,
        id: String? = null,
    ): SavedIdentity
    suspend fun delete(id: String): Boolean
}

class AndroidIdentityRepository private constructor(
    private val dao: IdentityDao,
    private val clock: () -> Long,
    private val scope: CoroutineScope = repositoryScope(),
) : IdentityRepository {
    constructor(context: Context) : this(
        TesseraDatabase.get(context).identityDao(),
        System::currentTimeMillis,
    )

    override val loadedIdentities: StateFlow<List<SavedIdentity>?> =
        observeIdentities().loadedState(scope)

    override fun observeIdentities(): Flow<List<SavedIdentity>> =
        dao.observeAll().map { values -> values.map(IdentityEntity::toSavedIdentity) }

    override suspend fun identity(id: String): SavedIdentity? = dao.get(id)?.toSavedIdentity()

    override suspend fun save(
        displayName: String,
        credentialKind: String,
        credentialReference: String,
        id: String?,
    ): SavedIdentity {
        val name = displayName.trim()
        require(name.isNotEmpty()) { "identity name is required" }
        require(name.none(Char::isISOControl)) { "identity name cannot contain control characters" }
        require(credentialKind.isNotBlank())
        require(credentialReference.isNotBlank())
        val entity = IdentityEntity(
            id = id ?: UUID.randomUUID().toString(),
            displayName = name,
            credentialKind = credentialKind,
            credentialReference = credentialReference,
            createdAtEpochMilliseconds = id?.let { dao.get(it)?.createdAtEpochMilliseconds } ?: clock(),
        )
        dao.upsert(entity)
        return entity.toSavedIdentity()
    }

    override suspend fun delete(id: String): Boolean = dao.delete(id) > 0
}
