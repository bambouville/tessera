package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * The mosh bootstrap grammar and the app-wide diagnostic redaction authority.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/MoshBootstrapGrammar.swift`
 * and `SensitiveDataRedaction.swift`. The ABI seam is
 * `Sources/TesseraCoreABI/MoshABI.swift`.
 *
 * The parse is deliberately stricter than the Kotlin original: a literal
 * `"MOSH CONNECT "` prefix with exactly four fields. The old lenient
 * whitespace split also accepted `MOSH\tCONNECT`, a shape mosh-server never
 * emits, and every extra accepted shape widens what a garbled or hostile
 * transcript can talk the client into dialling.
 */

/** Ephemeral credentials from a `mosh-server new` transcript. Never log one. */
data class SharedMoshCredentials(
    val udpPort: Int,
    val base64Key: String,
    /**
     * From mosh-server's own `[mosh-server detached, pid = N]` banner. Null
     * whenever the banner is absent or unparseable — treat a missing pid as
     * "cannot safely signal the server".
     */
    val serverProcessId: Int?,
)

/** Why a bootstrap transcript yielded no credentials. */
enum class SharedMoshBootstrapFailure(val wireValue: String) {
    /** The remote shell could not find `mosh-server`. The one failure with a
     * useful remedy, so it is classified before the connect-line parse. */
    MissingServer("missingServer"),

    /** No `MOSH CONNECT` line at all — usually something else ate the channel. */
    MissingConnect("missingConnect"),

    /** A line was present but its port or key is unusable: the server ran and
     * we cannot trust what it said. */
    MalformedConnect("malformedConnect");

    companion object {
        fun fromWire(value: String): SharedMoshBootstrapFailure =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared mosh bootstrap failure")
    }
}

/** Either credentials or a classified failure. */
sealed interface SharedMoshConnectResult {
    data class Success(val credentials: SharedMoshCredentials) : SharedMoshConnectResult
    data class Failure(val reason: SharedMoshBootstrapFailure) : SharedMoshConnectResult
}

/** The ordered redaction stages. */
enum class SharedRedactionPattern(val wireValue: String) {
    /** `MOSH CONNECT <port> <key>` as mosh-server prints it. */
    MoshConnectLine("moshConnectLine"),

    /** A bare 22-character base64 mosh key anywhere in the text. */
    MoshConnectKey("moshConnectKey"),

    /** `password=`, `passphrase=`, `secret=`, `token=` pairs. */
    CredentialAssignment("credentialAssignment"),

    /** Anything shaped like `user@host`. */
    EndpointIdentifier("endpointIdentifier"),
}

/** What the shared read-only probe learned about the detached server. */
enum class SharedMoshServerLiveness { ALIVE, GONE, UNKNOWN }

/** Timing authority: `TesseraSessionCore/MoshServerLivenessPolicy.swift`, via MoshABI. */
object SharedMoshServerLivenessPolicy {
    enum class Outcome(val wireValue: Int) { UNKNOWN(0), ALIVE(1), GONE(2), HOST_UNREACHABLE(3) }

    fun graceMillis(): Long {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.moshServerLivenessGraceMilliseconds()
    }

    /** When to ask again: never, after a delay, or only on the next wake signal. */
    sealed interface NextProbe {
        data object None : NextProbe
        data class After(val millis: Long) : NextProbe
        data object OnWake : NextProbe
    }

    /**
     * [askedOwner]: the probe put an owner-authorization challenge in front of
     * the user, which keeps the next one off a short timer.
     */
    fun nextProbe(outcome: Outcome, consecutiveHostFailures: Int, askedOwner: Boolean): NextProbe {
        NativeLibraries.ensureLoaded()
        val millis = NativeCoreBindings.moshServerLivenessNextProbeMilliseconds(
            outcome.wireValue, consecutiveHostFailures, if (askedOwner) 1 else 0,
        )
        return when {
            millis >= 0 -> NextProbe.After(millis)
            millis == ON_WAKE -> NextProbe.OnWake
            else -> NextProbe.None
        }
    }

    private const val ON_WAKE = -2L
}

/** Typed facade over `Sources/TesseraCoreABI/MoshABI.swift`. */
object SharedMoshGrammar {
    /** Read-only PID-reuse-fenced probe from the Swift bootstrap grammar. */
    fun serverLivenessScript(processId: Int): String {
        require(processId > 0) { "a mosh-server pid must be positive" }
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.moshServerLivenessScript(processId)
    }

    fun serverLiveness(output: String): SharedMoshServerLiveness {
        NativeLibraries.ensureLoaded()
        val bytes = output.encodeToByteArray()
        return when (NativeCoreBindings.moshServerLivenessVerdict(
            if (bytes.isEmpty()) null else bytes.toDirectBuffer(), bytes.size,
        )) {
            1 -> SharedMoshServerLiveness.ALIVE
            2 -> SharedMoshServerLiveness.GONE
            else -> SharedMoshServerLiveness.UNKNOWN
        }
    }

    /**
     * Reads a bootstrap transcript. Both streams are supplied because
     * mosh-server prints `MOSH CONNECT` on either one depending on the remote
     * shell; the parser reads one combined view.
     */
    fun parseConnectResponse(
        standardOutput: String,
        standardError: String = "",
    ): SharedMoshConnectResult {
        NativeLibraries.ensureLoaded()
        val out = standardOutput.encodeToByteArray()
        val err = standardError.encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.moshParseConnectResponse(
                if (out.isEmpty()) null else out.toDirectBuffer(),
                out.size,
                if (err.isEmpty()) null else err.toDirectBuffer(),
                err.size,
            ),
        )
        if (!value.getBoolean("ok")) {
            return SharedMoshConnectResult.Failure(
                SharedMoshBootstrapFailure.fromWire(value.getString("failure")),
            )
        }
        val credentials = value.getJSONObject("credentials")
        return SharedMoshConnectResult.Success(
            SharedMoshCredentials(
                udpPort = credentials.getInt("udpPort"),
                base64Key = credentials.getString("base64Key"),
                serverProcessId = if (credentials.isNull("serverPID")) {
                    null
                } else {
                    credentials.getInt("serverPID")
                },
            ),
        )
    }

    /**
     * `mosh-server new`, with the optional trailing `-- <argv>` the launch
     * mode asked for. An all-whitespace launch command is treated as absent,
     * so a misconfigured host still gets a plain login shell.
     */
    fun serverNewCommand(launchCommand: String? = null): String {
        NativeLibraries.ensureLoaded()
        val bytes = launchCommand?.encodeToByteArray()
        return NativeCoreBindings.moshServerNewCommand(
            if (bytes == null || bytes.isEmpty()) null else bytes.toDirectBuffer(),
            bytes?.size ?: 0,
        )
    }

    /**
     * The PID-reuse-fenced termination script.
     *
     * The pid comes from mosh-server's detached banner and may be arbitrarily
     * stale by the time anything wants the server gone, so the script
     * re-checks `ps -o comm=` for `*mosh-server*` immediately before
     * signalling, treats an already-exited server as success, and never
     * escalates past TERM. Script exit codes: 0 gone, 64 the pid is alive but
     * is not a mosh-server.
     */
    fun serverTerminationScript(processId: Int): String {
        require(processId > 0) { "a mosh-server pid must be positive" }
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.moshServerTerminationScript(processId)
    }

    /**
     * Whether the transcript says `mosh-server` is not installed, as opposed
     * to saying the bootstrap failed. Both markers must be present: an
     * ordinary transcript mentioning mosh-server is not a diagnosis, and
     * neither is a bare "command not found" for something else.
     */
    fun transcriptSuggestsMissingServer(
        standardOutput: String,
        standardError: String = "",
    ): Boolean {
        NativeLibraries.ensureLoaded()
        val out = standardOutput.encodeToByteArray()
        val err = standardError.encodeToByteArray()
        return NativeCoreBindings.moshTranscriptSuggestsMissingServer(
            if (out.isEmpty()) null else out.toDirectBuffer(),
            out.size,
            if (err.isEmpty()) null else err.toDirectBuffer(),
            err.size,
        ) == 1
    }

    /** The pid from the detached banner, or null when it is absent. */
    fun detachedServerProcessId(transcript: String): Int? {
        require(transcript.isNotEmpty())
        NativeLibraries.ensureLoaded()
        val bytes = transcript.encodeToByteArray()
        val pid = NativeCoreBindings.moshDetachedServerPid(bytes.toDirectBuffer(), bytes.size)
        return if (pid > 0) pid else null
    }

    /** The canonical 22-character key form, or null when it is not usable. */
    fun normalizedConnectKey(rawKey: String): String? {
        NativeLibraries.ensureLoaded()
        val bytes = rawKey.encodeToByteArray()
        if (bytes.isEmpty()) return null
        return try {
            NativeCoreBindings.moshNormalizedConnectKey(bytes.toDirectBuffer(), bytes.size)
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    /**
     * Byte counts and whether the credential marker was present — never the
     * transcript. Safe to log in full.
     */
    fun bootstrapTranscriptSummary(
        standardOutput: String,
        standardError: String = "",
    ): String {
        NativeLibraries.ensureLoaded()
        val out = standardOutput.encodeToByteArray()
        val err = standardError.encodeToByteArray()
        return NativeCoreBindings.moshBootstrapTranscriptSummary(
            if (out.isEmpty()) null else out.toDirectBuffer(),
            out.size,
            if (err.isEmpty()) null else err.toDirectBuffer(),
            err.size,
        )
    }
}

/**
 * The diagnostic redaction authority.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/SensitiveDataRedaction.swift`.
 */
object SharedRedaction {
    /**
     * Removes secrets from text bound for a log or the diagnostic file.
     *
     * [patterns] selects a subset; omit it for the full ordered list. The
     * APPLIED order is always the core's, never the argument order: the
     * `MOSH CONNECT` line scrub runs before the bare-key scrub so a
     * well-formed line keeps its validated port for diagnosis, and the key
     * scrub then catches split or exception-bridged key material the line
     * scrub could not see.
     */
    fun redact(text: String, patterns: List<SharedRedactionPattern>? = null): String {
        if (text.isEmpty()) return text
        NativeLibraries.ensureLoaded()
        val body = text.encodeToByteArray()
        val encoded = patterns?.let { selected ->
            JSONArray().also { array -> selected.forEach { array.put(it.wireValue) } }
                .toString()
                .encodeToByteArray()
        }
        return NativeCoreBindings.redactSensitive(
            body.toDirectBuffer(),
            body.size,
            encoded?.toDirectBuffer(),
            encoded?.size ?: 0,
        )
    }

    /**
     * The mosh-only subset applied to transport detail that can still reach a
     * user-facing failure message. Endpoint and credential-assignment
     * scrubbing is deliberately absent: the user is entitled to see which host
     * they failed to reach.
     */
    fun redactTransportDetail(text: String): String = redact(
        text,
        listOf(SharedRedactionPattern.MoshConnectLine, SharedRedactionPattern.MoshConnectKey),
    )
}
