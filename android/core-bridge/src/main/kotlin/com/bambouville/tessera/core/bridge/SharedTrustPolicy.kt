package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * Host-key trust.
 *
 * Swift authority: `Packages/TesseraCore/Sources/TesseraTrustCore/` —
 * `KnownHostTrustPolicy`, `KnownHostEndpoint`, `SSHHostPublicKey`,
 * `OpenSSHKnownHostsCodec`. The ABI seam is
 * `Sources/TesseraCoreABI/TrustABI.swift`.
 *
 * The import call returns a PLAN, never a mutation. Build it, show it, and
 * write to Room only after the user confirms: a parser that mutated as it went
 * is what left a half-imported store behind on the first bad line.
 */

/** An OpenSSH `"algorithm base64blob"` host key. */
data class SharedHostPublicKey(val keyString: String)

/** A pinned endpoint, as the store holds it. */
data class SharedTrustedHostKey(
    val key: SharedHostPublicKey,
    val trustedAtMilliseconds: Long,
    val recordId: String? = null,
)

/** How a presented key compares with the local pin. */
enum class SharedHostKeyVerdict(val wireValue: String) {
    /** Nothing is pinned for this endpoint yet. */
    Unknown("unknown"),

    Trusted("trusted"),

    /** The presented key is not the pinned one and is not the previous one. */
    Changed("changed"),

    /**
     * The presented key is the one this endpoint was pinned to before the last
     * rotation. Still a mismatch and still blocking, but a materially
     * different story to tell the user than an unrecognised key — collapsing
     * the two throws away the evidence separating a botched server rollback
     * from an attacker.
     */
    RevertedToPrevious("revertedToPrevious");

    companion object {
        fun fromWire(value: String): SharedHostKeyVerdict =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared host key verdict")
    }
}

data class SharedHostKeyDecision(
    val verdict: SharedHostKeyVerdict,
    val presentedFingerprint: String,
    /** The CURRENTLY pinned key's fingerprint, including on
     * [SharedHostKeyVerdict.RevertedToPrevious], so a caller that does not care
     * about the distinction can treat that case exactly like Changed. */
    val trustedFingerprint: String?,
    val comparisonHint: String?,
)

/** A normalized endpoint. */
data class SharedKnownHostEndpoint(
    val host: String,
    val port: Int,
    /** `"host:port"` — the key a pin store is indexed by. */
    val storageKey: String,
    /** The `ssh(1)`-shaped field: a bare host at port 22, `[host]:port`
     * otherwise. */
    val openSshHostField: String,
)

/** Why free-form host/port input could not become an endpoint. */
enum class SharedEndpointRejection(val wireValue: String) {
    EmptyHost("emptyHost"),
    HostContainsWhitespace("hostContainsWhitespace"),
    PortOutOfRange("portOutOfRange");

    companion object {
        fun fromWire(value: String): SharedEndpointRejection =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared endpoint rejection")
    }
}

sealed interface SharedEndpointNormalization {
    data class Normalized(val endpoint: SharedKnownHostEndpoint) : SharedEndpointNormalization
    data class Rejected(val reason: SharedEndpointRejection) : SharedEndpointNormalization
}

/** What applying one reviewed candidate would do to the pin store. */
enum class SharedImportAction(val wireValue: String) {
    Add("add"),
    Replace("replace"),
    Unchanged("unchanged");

    companion object {
        fun fromWire(value: String): SharedImportAction =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared import action")
    }
}

data class SharedImportCandidate(
    val lineNumber: Int,
    val endpointKey: String,
    val host: String,
    val port: Int,
    val keyString: String,
    val fingerprint: String,
    val action: SharedImportAction,
    /**
     * The fingerprint the store held when the plan was built, or null if the
     * endpoint was unpinned. Apply-time MUST re-check this: a reviewed plan is
     * a proposal about a past state, and the store can have moved underneath it
     * (a background connection accepting a rotation, a second import).
     */
    val expectedPriorFingerprint: String?,
)

/**
 * One line — or one host token inside a comma-separated list on that line —
 * that did not survive parsing. [reason] is one of `missingFields`,
 * `unsupportedMarker`, `invalidPublicKey`, `emptyHostField`, `hashedHost`,
 * `wildcardOrNegatedHost`, `invalidBracketedHostPort`, `invalidHostOrPort`,
 * `invalidHostField`, `ambiguousEndpoint`, `unnormalizableHost`. The platform
 * localizes it.
 */
data class SharedImportRejection(
    val lineNumber: Int,
    val source: String,
    val reason: String,
    /** The offending token for `unsupportedMarker`. */
    val marker: String?,
)

data class SharedImportWarning(
    val kind: String,
    val lineNumber: Int,
    val endpointKey: String,
)

data class SharedKnownHostsImportPlan(
    val candidates: List<SharedImportCandidate>,
    val rejections: List<SharedImportRejection>,
    val warnings: List<SharedImportWarning>,
    val addCount: Int,
    val replaceCount: Int,
    val unchangedCount: Int,
    /** True when confirming the plan would change nothing. */
    val isNoOp: Boolean,
)

/** One pin to render into `known_hosts` text. */
data class SharedKnownHostsExportRecord(
    val endpointKey: String,
    val keyString: String,
)

/** Typed facade over `Sources/TesseraCoreABI/TrustABI.swift`. */
object SharedTrustPolicy {
    /**
     * Classifies a presented host key against the local pin.
     *
     * Pass [previous] when this store keeps rotation history: it is what turns
     * a "went back to the old key" event into
     * [SharedHostKeyVerdict.RevertedToPrevious] instead of a bare Changed.
     * With [previous] null the result is identical to the pre-rotation-history
     * behavior.
     *
     * [padded] selects the fingerprint spelling: false is the canonical
     * cross-platform (unpadded) form this platform renders.
     */
    fun check(
        host: String,
        port: Int,
        presented: SharedHostPublicKey,
        trusted: SharedTrustedHostKey?,
        previous: SharedHostPublicKey? = null,
        comparisonHint: String? = null,
        padded: Boolean = false,
    ): SharedHostKeyDecision {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("endpoint", JSONObject().put("host", host).put("port", port))
            .put("presented", JSONObject().put("keyString", presented.keyString))
            .put("fingerprintPadding", if (padded) "padded" else "unpadded")
            .put("comparisonHint", comparisonHint ?: JSONObject.NULL)
            .put(
                "trusted",
                trusted?.let { record ->
                    JSONObject()
                        .put("key", JSONObject().put("keyString", record.key.keyString))
                        .put("trustedAtSeconds", record.trustedAtMilliseconds / 1_000.0)
                        .put("id", record.recordId ?: JSONObject.NULL)
                } ?: JSONObject.NULL,
            )
            .put(
                "previous",
                previous?.let { JSONObject().put("keyString", it.keyString) } ?: JSONObject.NULL,
            )
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.trustCheck(request.toDirectBuffer(), request.size),
        )
        return SharedHostKeyDecision(
            verdict = SharedHostKeyVerdict.fromWire(value.getString("verdict")),
            presentedFingerprint = value.getString("presentedFingerprint"),
            trustedFingerprint = if (value.isNull("trustedFingerprint")) {
                null
            } else {
                value.getString("trustedFingerprint")
            },
            comparisonHint = if (value.isNull("comparisonHint")) {
                null
            } else {
                value.getString("comparisonHint")
            },
        )
    }

    /**
     * Normalizes free-form host/port input: trim, strip one trailing dot and
     * one matched bracket pair, lowercase, reject empty or whitespace-bearing
     * hosts, require a port in 1..65535.
     *
     * This is normalization of INPUT. The import codec applies the same rules
     * to its host tokens only when asked (see [knownHostsImportPlan]'s
     * `normalizeEndpoints`), because a token must land on the same storage key
     * the calling store is itself keyed by.
     */
    fun normalizeEndpoint(host: String, port: Int): SharedEndpointNormalization {
        NativeLibraries.ensureLoaded()
        val bytes = host.encodeToByteArray()
        require(bytes.isNotEmpty()) { "an endpoint host must not be empty" }
        val value = JSONObject(
            NativeCoreBindings.trustNormalizeEndpoint(bytes.toDirectBuffer(), bytes.size, port),
        )
        if (!value.getBoolean("ok")) {
            return SharedEndpointNormalization.Rejected(
                SharedEndpointRejection.fromWire(value.getString("error")),
            )
        }
        val endpoint = value.getJSONObject("endpoint")
        return SharedEndpointNormalization.Normalized(
            SharedKnownHostEndpoint(
                host = endpoint.getString("host"),
                port = endpoint.getInt("port"),
                storageKey = value.getString("storageKey"),
                openSshHostField = value.getString("openSSHHostField"),
            ),
        )
    }

    /**
     * `"SHA256:" + base64(SHA-256(blob))` of an SSH wire-format public key.
     *
     * [padded] false is the canonical cross-platform form, which is what this
     * platform's Known Hosts screen renders. The padded spelling exists only
     * for iOS, whose store has persisted it since it shipped.
     */
    fun sha256Fingerprint(blob: ByteArray, padded: Boolean = false): String {
        require(blob.isNotEmpty())
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.trustSha256Fingerprint(
            blob.toDirectBuffer(),
            blob.size,
            padded,
        )
    }

    /**
     * Builds — and only builds — the plan for a `known_hosts` file.
     *
     * [existingFingerprints] maps endpoint storage key to currently pinned
     * fingerprint, and classifies each candidate as add/replace/unchanged.
     * Apply the plan to Room only after the user confirms it.
     *
     * [normalizeEndpoints] selects the ONE key space the whole plan is
     * computed in — candidate keys, the [existingFingerprints] lookup,
     * ambiguity detection and duplicate warnings. It defaults to true because
     * this app's pin store is itself keyed in the normalized space (trimmed,
     * one trailing dot and one bracket pair stripped, lowercased), so
     * [existingFingerprints] keys — built with `KnownHostKeys.sharedEndpointKey`
     * — are already in it. Passing false here would key the plan by whatever
     * spelling the file used: an already-pinned host would be planned as an
     * `Add` that `trustIfUnchanged` then refuses, and two case-variant lines
     * for one host would look like two endpoints, so neither the
     * `ambiguousEndpoint` rejection nor the duplicate warning would fire and
     * whichever line applied last would silently win.
     */
    fun knownHostsImportPlan(
        text: String,
        existingFingerprints: Map<String, String>,
        padded: Boolean = false,
        normalizeEndpoints: Boolean = true,
    ): SharedKnownHostsImportPlan {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("text", text)
            .put("fingerprintPadding", if (padded) "padded" else "unpadded")
            .put(
                "endpointNormalization",
                if (normalizeEndpoints) "normalized" else "verbatim",
            )
            .put(
                "existingFingerprints",
                JSONObject().also { entries ->
                    existingFingerprints.forEach { (key, fingerprint) ->
                        entries.put(key, fingerprint)
                    }
                },
            )
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.trustKnownHostsImportPlan(request.toDirectBuffer(), request.size),
        )
        val candidates = value.getJSONArray("candidates")
        val rejections = value.getJSONArray("rejections")
        val warnings = value.getJSONArray("warnings")
        return SharedKnownHostsImportPlan(
            candidates = List(candidates.length()) { index ->
                candidates.getJSONObject(index).let { candidate ->
                    SharedImportCandidate(
                        lineNumber = candidate.getInt("lineNumber"),
                        endpointKey = candidate.getString("endpointKey"),
                        host = candidate.getString("host"),
                        port = candidate.getInt("port"),
                        keyString = candidate.getString("keyString"),
                        fingerprint = candidate.getString("fingerprint"),
                        action = SharedImportAction.fromWire(candidate.getString("action")),
                        expectedPriorFingerprint =
                            if (candidate.isNull("expectedPriorFingerprint")) {
                                null
                            } else {
                                candidate.getString("expectedPriorFingerprint")
                            },
                    )
                }
            },
            rejections = List(rejections.length()) { index ->
                rejections.getJSONObject(index).let { rejection ->
                    SharedImportRejection(
                        lineNumber = rejection.getInt("lineNumber"),
                        source = rejection.getString("source"),
                        reason = rejection.getString("reason"),
                        marker = if (rejection.isNull("marker")) {
                            null
                        } else {
                            rejection.getString("marker")
                        },
                    )
                }
            },
            warnings = List(warnings.length()) { index ->
                warnings.getJSONObject(index).let { warning ->
                    SharedImportWarning(
                        kind = warning.getString("kind"),
                        lineNumber = warning.getInt("lineNumber"),
                        endpointKey = warning.getString("endpointKey"),
                    )
                }
            },
            addCount = value.getInt("addCount"),
            replaceCount = value.getInt("replaceCount"),
            unchangedCount = value.getInt("unchangedCount"),
            isNoOp = value.getBoolean("isNoOp"),
        )
    }

    /**
     * Renders stored pins as `known_hosts` text, lines sorted so the output is
     * stable across runs and diffable. A pin at the default port writes a bare
     * host, because that is what `ssh(1)` writes — writing `[host]:22` would
     * round-trip through our own importer but disagree with the user's real
     * `known_hosts` about the same machine.
     */
    fun knownHostsExport(records: List<SharedKnownHostsExportRecord>): String {
        NativeLibraries.ensureLoaded()
        val request = JSONArray().also { array ->
            records.forEach { record ->
                array.put(
                    JSONObject()
                        .put("endpointKey", record.endpointKey)
                        .put("keyString", record.keyString),
                )
            }
        }.toString().encodeToByteArray()
        return NativeCoreBindings
            .trustKnownHostsExport(request.toDirectBuffer(), request.size)
            .decodeToString()
    }
}
