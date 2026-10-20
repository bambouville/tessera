package com.bambouville.tessera.networking.mosh

import com.bambouville.tessera.core.bridge.SharedMoshBootstrapFailure
import com.bambouville.tessera.core.bridge.SharedMoshConnectResult
import com.bambouville.tessera.core.bridge.SharedMoshGrammar
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.SshRouteRequest

/**
 * The ephemeral credentials returned by `mosh-server new`.
 *
 * The key is represented as mutable bytes so callers can clear their copy as
 * soon as it crosses into the native C ABI.  Do not log this type.
 */
class MoshBootstrapResult(
    val host: String,
    val udpPort: Int,
    val base64Key: ByteArray,
    val serverPid: Int?,
) : AutoCloseable {
    init {
        require(host.isNotBlank())
        require(udpPort in 1..65535)
        require(base64Key.size == CONNECT_KEY_LENGTH)
    }

    override fun close() {
        base64Key.fill(0)
    }

    internal companion object {
        const val CONNECT_KEY_LENGTH = 22
    }
}

sealed interface MoshBootstrapFailure {
    data object MissingServer : MoshBootstrapFailure
    data object MissingConnect : MoshBootstrapFailure
    data object MalformedConnect : MoshBootstrapFailure
}

class MoshBootstrapException(val reason: MoshBootstrapFailure) : IllegalStateException(
    when (reason) {
        MoshBootstrapFailure.MissingServer -> "mosh-server is not available on the remote host"
        MoshBootstrapFailure.MissingConnect -> "mosh-server did not return MOSH CONNECT"
        MoshBootstrapFailure.MalformedConnect -> "mosh-server returned malformed MOSH CONNECT"
    },
)

/** The SSH boundary shared by plain Mosh and Mosh + tmux startup. */
fun interface MoshBootstrapper {
    suspend fun bootstrap(request: MoshBootstrapRequest): MoshBootstrapResult
}

data class MoshBootstrapRequest(
    val route: SshRouteRequest,
    /** Address the UDP client must contact, not necessarily route.hops.last().endpoint.host. */
    val udpHost: String,
    /** Must be an argv-safe command supplied by the host/launch-mode adapter. */
    val launchCommand: String? = null,
)

/**
 * Android projection of the iOS bootstrap hop. Authentication, host-key
 * prompts, and jump routing stay in [AndroidSshBackend]; this class only adds
 * the Mosh command and hands its deliberately tiny public response to the
 * shared grammar.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/MoshBootstrapGrammar.swift`,
 * reached through `SharedMoshGrammar`. The parse it applies is stricter than
 * the one this platform used to run: a literal `"MOSH CONNECT "` prefix with
 * exactly four fields. The old lenient whitespace split also accepted
 * `MOSH\tCONNECT`, a shape mosh-server never emits, and every extra accepted
 * shape widens what a garbled or hostile transcript can talk the client into
 * dialling.
 */
class AndroidSshMoshBootstrapper(
    private val backend: AndroidSshBackend,
    private val passwordProvider: SshPasswordProvider,
    private val hostKeyPolicy: SshHostKeyPolicy,
    private val keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
    private val authenticatedRoute: SshRouteOwner? = null,
) : MoshBootstrapper {
    override suspend fun bootstrap(request: MoshBootstrapRequest): MoshBootstrapResult {
        require(request.udpHost.isNotBlank())
        val command = SharedMoshGrammar.serverNewCommand(request.launchCommand)
        val transcript = authenticatedRoute?.executeBoundedCommand(command)
            ?: backend.executeRouteCommand(
                request = request.route,
                commandText = command,
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
                keyAuthorizationProvider = keyAuthorizationProvider,
            )
        // Both streams, unjoined: the core owns how they combine, and the
        // "mosh-server is not installed" diagnosis is classified inside the
        // same call rather than by a separate pre-pass here.
        val outcome = SharedMoshGrammar.parseConnectResponse(
            standardOutput = transcript.standardOutput,
            standardError = transcript.standardError,
        )
        return when (outcome) {
            is SharedMoshConnectResult.Failure ->
                throw MoshBootstrapException(outcome.reason.local())
            is SharedMoshConnectResult.Success -> MoshBootstrapResult(
                host = request.udpHost,
                udpPort = outcome.credentials.udpPort,
                base64Key = outcome.credentials.base64Key.encodeToByteArray(),
                serverPid = outcome.credentials.serverProcessId,
            )
        }
    }
}

private fun SharedMoshBootstrapFailure.local(): MoshBootstrapFailure = when (this) {
    SharedMoshBootstrapFailure.MissingServer -> MoshBootstrapFailure.MissingServer
    SharedMoshBootstrapFailure.MissingConnect -> MoshBootstrapFailure.MissingConnect
    SharedMoshBootstrapFailure.MalformedConnect -> MoshBootstrapFailure.MalformedConnect
}
