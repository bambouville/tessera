package com.bambouville.tessera.data

import android.content.Context
import android.util.Base64
import com.bambouville.tessera.core.bridge.SharedHostKeyVerdict
import com.bambouville.tessera.core.bridge.SharedHostPublicKey
import com.bambouville.tessera.core.bridge.SharedTrustPolicy
import com.bambouville.tessera.core.bridge.SharedTrustedHostKey
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map

sealed interface HostTrustEvaluation {
    data object Unknown : HostTrustEvaluation
    data object Trusted : HostTrustEvaluation
    data class Changed(val previousCanonicalKeyBlob: ByteArray) : HostTrustEvaluation
    data class Reverted(val currentCanonicalKeyBlob: ByteArray) : HostTrustEvaluation
}

interface KnownHostsRepository {
    fun observeKnownHosts(): Flow<List<SavedKnownHost>>

    /** Latest rows, or null until the first load answers. */
    val loadedKnownHosts: StateFlow<List<SavedKnownHost>?>

    suspend fun evaluate(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
    ): HostTrustEvaluation

    suspend fun trust(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
    )

    /**
     * Applies one reviewed `known_hosts` import candidate, but only while the
     * store still holds what the plan was built against.
     *
     * A reviewed plan is a proposal about a *past* state, and the store can
     * have moved underneath it — a background connection accepting a rotation,
     * a second import. [expectedPriorFingerprint] is the fingerprint the plan
     * saw (null when the endpoint was unpinned); a mismatch returns false and
     * writes nothing rather than silently overwriting a decision the user
     * never saw.
     *
     * This default reads [loadedKnownHosts], which is null until the first
     * load answers. "Not loaded yet" is not "not pinned": read as the latter,
     * a plan built against an unpinned endpoint would pass its own guard
     * against a cache that has never spoken and write over a pin it never
     * saw. So it fails closed — no answer, no write. An implementation that
     * can re-read the store directly should override this and do that
     * instead, as [AndroidKnownHostsRepository] does.
     */
    suspend fun trustIfUnchanged(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
        expectedPriorFingerprint: String?,
    ): Boolean {
        val loaded = loadedKnownHosts.value ?: return false
        val endpoint = AndroidKnownHostsRepository.normalizeEndpoint(hostname, port)
        val pinned = loaded.firstOrNull { it.normalizedEndpoint == endpoint }
        if (pinned?.canonicalKeyBlob?.let(KnownHostKeys::fingerprint) != expectedPriorFingerprint) {
            return false
        }
        trust(hostname, port, algorithm, canonicalKeyBlob)
        return true
    }

    suspend fun forget(hostname: String, port: Int): Boolean
}

class AndroidKnownHostsRepository private constructor(
    private val dao: KnownHostDao,
    private val clock: () -> Long,
    private val scope: CoroutineScope = repositoryScope(),
) : KnownHostsRepository {
    constructor(context: Context) : this(
        dao = TesseraDatabase.get(context).knownHostDao(),
        clock = System::currentTimeMillis,
    )

    override val loadedKnownHosts: StateFlow<List<SavedKnownHost>?> =
        observeKnownHosts().loadedState(scope)

    override fun observeKnownHosts(): Flow<List<SavedKnownHost>> =
        dao.observeAll().map { hosts -> hosts.map(KnownHostEntity::toSavedKnownHost) }

    /**
     * The verdict belongs to the shared core.
     *
     * Swift authority:
     * `Packages/TesseraCore/Sources/TesseraTrustCore/TrustPolicy.swift`
     * (`KnownHostTrustPolicy.check`), reached through `SharedTrustPolicy`.
     * The stored rotation history is passed as `previous`, which is what turns
     * "this host went back to the key you replaced" into its own verdict
     * instead of a bare change — the distinction that separates a botched
     * server rollback from an attacker.
     */
    override suspend fun evaluate(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
    ): HostTrustEvaluation {
        val host = normalizedHost(hostname)
        val existing = dao.get(normalizeEndpoint(hostname, port))
            ?: return HostTrustEvaluation.Unknown
        val previous = existing.previousAlgorithm?.let { previousAlgorithm ->
            existing.previousCanonicalKeyBlob?.let { blob ->
                SharedHostPublicKey(KnownHostKeys.openSshKeyString(previousAlgorithm, blob))
            }
        }
        val decision = try {
            SharedTrustPolicy.check(
                host = host,
                port = port,
                presented = SharedHostPublicKey(
                    KnownHostKeys.openSshKeyString(algorithm, canonicalKeyBlob),
                ),
                trusted = SharedTrustedHostKey(
                    key = SharedHostPublicKey(
                        KnownHostKeys.openSshKeyString(
                            existing.algorithm,
                            existing.canonicalKeyBlob,
                        ),
                    ),
                    trustedAtMilliseconds = existing.lastVerifiedAtEpochMilliseconds,
                ),
                previous = previous,
            )
        } catch (rejected: IllegalArgumentException) {
            // A key the core cannot even parse structurally is one we cannot
            // reason about — a legacy row written by the old lenient importer,
            // say. A pin exists, so block and let the user compare
            // fingerprints rather than quietly admitting it. A linkage failure
            // is a different thing entirely and is deliberately not caught.
            return HostTrustEvaluation.Changed(existing.canonicalKeyBlob.copyOf())
        }
        return when (decision.verdict) {
            SharedHostKeyVerdict.Trusted -> HostTrustEvaluation.Trusted
            // Unknown cannot arrive here — a trusted record was supplied — but
            // an unpinned endpoint is exactly what it means, so say that.
            SharedHostKeyVerdict.Unknown -> HostTrustEvaluation.Unknown
            SharedHostKeyVerdict.Changed ->
                HostTrustEvaluation.Changed(existing.canonicalKeyBlob.copyOf())
            SharedHostKeyVerdict.RevertedToPrevious ->
                HostTrustEvaluation.Reverted(existing.canonicalKeyBlob.copyOf())
        }
    }

    override suspend fun trust(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
    ) {
        require(canonicalKeyBlob.isNotEmpty())
        val endpoint = normalizeEndpoint(hostname, port)
        val now = clock()
        val existing = dao.get(endpoint)
        dao.upsert(
            KnownHostEntity(
                normalizedEndpoint = endpoint,
                algorithm = algorithm,
                canonicalKeyBlob = canonicalKeyBlob.copyOf(),
                previousAlgorithm = existing?.algorithm
                    ?.takeUnless { it == algorithm && existing.canonicalKeyBlob.contentEquals(canonicalKeyBlob) }
                    ?: existing?.previousAlgorithm,
                previousCanonicalKeyBlob = if (
                    existing != null &&
                    !(existing.algorithm == algorithm && existing.canonicalKeyBlob.contentEquals(canonicalKeyBlob))
                ) {
                    existing.canonicalKeyBlob.copyOf()
                } else {
                    existing?.previousCanonicalKeyBlob?.copyOf()
                },
                firstSeenAtEpochMilliseconds = existing?.firstSeenAtEpochMilliseconds ?: now,
                lastVerifiedAtEpochMilliseconds = now,
            ),
        )
    }

    /** Re-reads the row itself rather than a cached projection of it. */
    override suspend fun trustIfUnchanged(
        hostname: String,
        port: Int,
        algorithm: String,
        canonicalKeyBlob: ByteArray,
        expectedPriorFingerprint: String?,
    ): Boolean {
        if (expectedPriorFingerprint == null) {
            require(canonicalKeyBlob.isNotEmpty())
            val now = clock()
            // One SQLite statement: a concurrent first-connect/rotation wins,
            // even if it lands after the import preview was shown.
            return dao.insertIfAbsent(KnownHostEntity(
                normalizedEndpoint = normalizeEndpoint(hostname, port),
                algorithm = algorithm,
                canonicalKeyBlob = canonicalKeyBlob.copyOf(),
                previousAlgorithm = null,
                previousCanonicalKeyBlob = null,
                firstSeenAtEpochMilliseconds = now,
                lastVerifiedAtEpochMilliseconds = now,
            )) != -1L
        }
        val pinned = dao.get(normalizeEndpoint(hostname, port))
        if (pinned?.canonicalKeyBlob?.let(KnownHostKeys::fingerprint) != expectedPriorFingerprint) {
            return false
        }
        trust(hostname, port, algorithm, canonicalKeyBlob)
        return true
    }

    override suspend fun forget(hostname: String, port: Int): Boolean =
        dao.delete(normalizeEndpoint(hostname, port)) > 0

    companion object {
        /**
         * The Room primary key for an endpoint. Deliberately NOT the shared
         * `host:port` storage key: this store has always bracketed IPv6
         * literals, and rewriting the key would orphan every existing pin.
         * `KnownHostKeys.sharedEndpointKey` converts at the one boundary that
         * needs the shared spelling.
         */
        fun normalizeEndpoint(hostname: String, port: Int): String {
            require(port in 1..65535)
            val normalizedHost = normalizedHost(hostname)
            return if (':' in normalizedHost && !normalizedHost.startsWith("[")) {
                "[$normalizedHost]:$port"
            } else {
                "$normalizedHost:$port"
            }
        }

        private fun normalizedHost(hostname: String): String {
            val normalized = hostname
                .trim()
                .removeSuffix(".")
                .lowercase(Locale.ROOT)
            require(normalized.isNotEmpty())
            require(normalized.none(Char::isWhitespace))
            return normalized
        }
    }
}

/**
 * The renderings of a pinned host key that the shared core speaks.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraTrustCore/HostKeyFingerprint.swift`
 * (`SSHHostPublicKey.sha256Fingerprint`, `openSSHKeyString`) via
 * `SharedTrustPolicy`. Nothing here recomputes a digest locally — three copies
 * of that formatting had already drifted across this app.
 */
object KnownHostKeys {
    /** `"algorithm base64blob"`, the OpenSSH `known_hosts` rendering. */
    fun openSshKeyString(algorithm: String, canonicalKeyBlob: ByteArray): String =
        "$algorithm ${Base64.encodeToString(canonicalKeyBlob, Base64.NO_WRAP)}"

    /**
     * `SHA256:` + unpadded base64 SHA-256 of the SSH wire-format blob — the
     * canonical cross-platform spelling, and what this app has always shown.
     */
    fun fingerprint(canonicalKeyBlob: ByteArray): String =
        SharedTrustPolicy.sha256Fingerprint(canonicalKeyBlob)

    /**
     * The shared `host:port` storage key for a Room endpoint key.
     *
     * The core stores IPv6 literals bare and re-applies brackets only when it
     * renders `known_hosts` text; this store brackets them in the key itself.
     * A value that is not a `host:port` pair is passed through untouched.
     */
    fun sharedEndpointKey(normalizedEndpoint: String): String {
        val (host, port) = splitEndpoint(normalizedEndpoint) ?: return normalizedEndpoint
        return "$host:$port"
    }

    /** Bare host and port for a Room endpoint key, or null if it is neither. */
    fun splitEndpoint(normalizedEndpoint: String): Pair<String, Int>? {
        val separator = normalizedEndpoint.lastIndexOf(':')
        if (separator <= 0) return null
        val port = normalizedEndpoint.substring(separator + 1).toIntOrNull() ?: return null
        if (port !in 1..65535) return null
        val host = normalizedEndpoint.substring(0, separator)
            .removeSurrounding("[", "]")
        if (host.isEmpty()) return null
        return host to port
    }
}
