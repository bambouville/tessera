package com.bambouville.tessera.data

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "hosts",
    foreignKeys = [
        ForeignKey(
            entity = HostEntity::class,
            parentColumns = ["id"],
            childColumns = ["jumpHostId"],
            onDelete = ForeignKey.RESTRICT,
            onUpdate = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index("jumpHostId")],
)
data class HostEntity(
    @PrimaryKey val id: String,
    val displayName: String,
    val hostname: String,
    val port: Int,
    val username: String,
    val jumpHostId: String?,
    val identityId: String?,
    val transportKind: String = TransportKinds.SSH,
    val tmuxMode: String = TmuxModes.OFF,
    val tmuxTarget: String? = null,
    val createdAtEpochMilliseconds: Long,
    val updatedAtEpochMilliseconds: Long,
    val launchCommand: String? = null,
    val notes: String? = null,
    val envVars: String? = null,
    val startupSnippet: String? = null,
)

@Entity(tableName = "identities")
data class IdentityEntity(
    @PrimaryKey val id: String,
    val displayName: String,
    val credentialKind: String,
    val credentialReference: String,
    val createdAtEpochMilliseconds: Long,
)

@Entity(
    tableName = "known_hosts",
)
data class KnownHostEntity(
    @PrimaryKey val normalizedEndpoint: String,
    val algorithm: String,
    val canonicalKeyBlob: ByteArray,
    val previousAlgorithm: String? = null,
    val previousCanonicalKeyBlob: ByteArray? = null,
    val firstSeenAtEpochMilliseconds: Long,
    val lastVerifiedAtEpochMilliseconds: Long,
)

@Entity(tableName = "session_restore")
data class SessionRestoreEntity(
    @PrimaryKey val sessionId: String,
    val hostId: String,
    val transportKind: String,
    val tmuxTarget: String?,
    val lastSelection: String?,
    val reconnectRequired: Boolean,
    val updatedAtEpochMilliseconds: Long,
)

/** Durable, secret-free evidence that a cross-device transaction completed. */
@Entity(tableName = "cross_device_receipts")
data class CrossDeviceReceiptEntity(
    @PrimaryKey val receiptId: String,
    val attemptId: String,
    val kind: String,
    val hostIds: String,
    val recordedAtEpochMilliseconds: Long,
)

/**
 * Reconstructible bootstrap state. The generated private key remains in Android
 * Keystore; this row stores only the identity capability and the host that may
 * be linked after the source reports a verified authorized_keys mutation.
 */
@Entity(
    tableName = "pending_cross_device_access",
    indices = [Index("attemptId"), Index("hostId")],
)
data class PendingCrossDeviceAccessEntity(
    @PrimaryKey val pendingId: String,
    val attemptId: String,
    val hostId: String,
    val identityId: String,
    val createdAtEpochMilliseconds: Long,
)

/**
 * Reconstructible Agent Center metadata. These rows intentionally contain no
 * transcript blocks, provider cursors, working directories, paths, or prompt
 * text. A process restart must rebind and reproject over a fresh live route.
 */
@Entity(tableName = "agent_thread_metadata")
data class AgentThreadMetadataEntity(
    @PrimaryKey val threadKey: String,
    val lastReadRecordID: String?,
    val unread: Boolean,
    val updatedAtEpochMilliseconds: Long,
    /**
     * Shared Core's content-free completion identities (hook source time and
     * PID): a finish still unread, and the newest one the reader acknowledged.
     */
    val unreadCompletionKey: String? = null,
    val acknowledgedCompletionKey: String? = null,
)

/** Opaque notification route tokens only; they never carry a transcript preview. */
@Entity(tableName = "agent_route_tokens", indices = [Index("threadKey")])
data class AgentRouteTokenEntity(
    @PrimaryKey val routeToken: String,
    val threadKey: String,
    val carrierGeneration: Long,
    val expiresAtEpochMilliseconds: Long,
)

/** Stable fork relationship identifiers, without the source record body or location. */
@Entity(tableName = "agent_thread_lineage", indices = [Index("parentThreadKey")])
data class AgentThreadLineageEntity(
    @PrimaryKey val threadKey: String,
    val parentThreadKey: String?,
    val parentRecordID: String?,
    val updatedAtEpochMilliseconds: Long,
)

/**
 * Receipt facts returned by the remote launch helper.  This is intentionally
 * identifiers-only: no task, path, prompt, transcript, or provider output is
 * durable across process death.
 */
@Entity(tableName = "agent_launch_receipts", indices = [Index("parentThreadKey")])
data class AgentLaunchReceiptEntity(
    @PrimaryKey val threadKey: String,
    val requestID: String,
    val parentThreadKey: String?,
    val parentRecordID: String?,
    val windowID: String,
    val paneID: String,
    val worktreeCreated: Boolean,
    val recordedAtEpochMilliseconds: Long,
)

data class CrossDeviceReceipt(
    val attemptId: String,
    val kind: String,
    val hostIds: List<String>,
    val recordedAtEpochMilliseconds: Long,
)

data class PendingCrossDeviceAccess(
    val attemptId: String,
    val hostId: String,
    val identityId: String,
    val createdAtEpochMilliseconds: Long,
)

data class SavedHost(
    val id: String,
    val displayName: String,
    val hostname: String,
    val port: Int,
    val username: String,
    val jumpHostId: String?,
    val identityId: String?,
    /** `ssh` or `mosh`; orthogonal to [tmuxMode], every combination is valid. */
    val transportKind: String = TransportKinds.SSH,
    val tmuxMode: String = TmuxModes.OFF,
    val tmuxTarget: String? = null,
    val launchCommand: String? = null,
    val notes: String? = null,
    val envVars: String? = null,
    val startupSnippet: String? = null,
)

object TmuxModes {
    const val OFF = "off"
    const val AUTOMATIC = "automatic"
    const val PINNED = "pinned"
}

object TransportKinds {
    const val SSH = "ssh"
    const val MOSH = "mosh"
}

data class SavedIdentity(
    val id: String,
    val displayName: String,
    val credentialKind: String,
    /** Opaque Android Keystore alias or another capability reference; never secret key bytes. */
    val credentialReference: String,
)

data class SavedKnownHost(
    val normalizedEndpoint: String,
    val algorithm: String,
    val canonicalKeyBlob: ByteArray,
    val previousAlgorithm: String?,
    val previousCanonicalKeyBlob: ByteArray?,
    val firstSeenAtEpochMilliseconds: Long,
    val lastVerifiedAtEpochMilliseconds: Long,
)

object CredentialKinds {
    const val ANDROID_KEYSTORE_P256 = "android_keystore_p256"
}

data class HostDraft(
    val id: String? = null,
    val displayName: String,
    val hostname: String,
    val port: Int = 22,
    val username: String,
    val jumpHostId: String? = null,
    val identityId: String? = null,
    val transportKind: String = TransportKinds.SSH,
    val tmuxMode: String = TmuxModes.OFF,
    val tmuxTarget: String? = null,
    val launchCommand: String? = null,
    val notes: String? = null,
    val envVars: String? = null,
    val startupSnippet: String? = null,
)

internal fun HostEntity.toSavedHost() = SavedHost(
    id = id,
    displayName = displayName,
    hostname = hostname,
    port = port,
    username = username,
    jumpHostId = jumpHostId,
    identityId = identityId,
    transportKind = transportKind,
    tmuxMode = tmuxMode,
    tmuxTarget = tmuxTarget,
    launchCommand = launchCommand,
    notes = notes,
    envVars = envVars,
    startupSnippet = startupSnippet,
)

internal fun IdentityEntity.toSavedIdentity() = SavedIdentity(
    id = id,
    displayName = displayName,
    credentialKind = credentialKind,
    credentialReference = credentialReference,
)

internal fun KnownHostEntity.toSavedKnownHost() = SavedKnownHost(
    normalizedEndpoint = normalizedEndpoint,
    algorithm = algorithm,
    canonicalKeyBlob = canonicalKeyBlob.copyOf(),
    previousAlgorithm = previousAlgorithm,
    previousCanonicalKeyBlob = previousCanonicalKeyBlob?.copyOf(),
    firstSeenAtEpochMilliseconds = firstSeenAtEpochMilliseconds,
    lastVerifiedAtEpochMilliseconds = lastVerifiedAtEpochMilliseconds,
)
