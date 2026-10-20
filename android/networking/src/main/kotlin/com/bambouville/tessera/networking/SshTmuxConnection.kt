package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InputStream
import java.security.KeyPair
import java.security.KeyStore
import java.security.PrivateKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.delay
import com.bambouville.tessera.core.bridge.SharedTargetValidation
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.forwarding.ForwardingTransport
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.PTYMode
import net.schmizz.sshj.connection.channel.direct.Session

class SshTmuxConnection internal constructor(
    private val command: Session.Command,
    private val resources: List<Closeable>? = null,
    private val forwardingRuntimeFactory: AuthenticatedForwardingRuntimeFactory? = null,
    private val owner: SshRouteOwner? = null,
    private val session: Session? = null,
    private val closeRouteOnClose: Boolean = false,
) : Closeable {
    val standardOutput: InputStream = command.inputStream
    val standardError: InputStream = command.errorStream

    /** Non-null only when the remote tmux control command actually exited. */
    val remoteExitStatus: Int?
        get() = command.exitStatus

    suspend fun awaitRemoteExitStatus(): Int? = withTimeoutOrNull(REMOTE_EXIT_STATUS_GRACE_MILLISECONDS) {
        while (remoteExitStatus == null) delay(10)
        remoteExitStatus
    }

    fun createForwardingRuntime(
        transport: ForwardingTransport = ForwardingTransport.Ssh,
    ): PortForwardingRuntime = checkNotNull(forwardingRuntimeFactory) {
        "forwarding is unavailable on a shared SSH route"
    }.create(transport)

    suspend fun sendControl(commandText: String) = withContext(Dispatchers.IO) {
        require(commandText.isNotBlank() && '\n' !in commandText && '\r' !in commandText)
        synchronized(command.outputStream) {
            command.outputStream.write(commandText.encodeToByteArray())
            command.outputStream.write('\n'.code)
            command.outputStream.flush()
        }
    }

    override fun close() {
        val routeOwner = owner
        if (routeOwner == null) {
            resources.orEmpty().asReversed().forEach { runCatching { it.close() } }
        } else {
            runCatching { command.close() }
            runCatching { session?.close() }
            routeOwner.release(this)
            if (closeRouteOnClose) routeOwner.close()
        }
    }


    private companion object {
        const val REMOTE_EXIT_STATUS_GRACE_MILLISECONDS = 300L
    }
}

suspend fun AndroidSshBackend.connectTmux(
    request: SshRouteRequest,
    sessionTarget: String,
    preserveInitialGeometry: Boolean = false,
    moshViewSession: Boolean = false,
    passwordProvider: SshPasswordProvider,
    hostKeyPolicy: SshHostKeyPolicy,
    keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
): SshTmuxConnection = acquireSshResource {
    require(request.hops.isNotEmpty() && request.hops.size <= 8)
    require(SharedTargetValidation.isValidTmuxSessionName(sessionTarget))
    val resources = mutableListOf<Closeable>()
    var previousClient: SSHClient? = null
    try {
        for (hop in request.hops) {
            val client = SshjClientFactory { observation ->
                runBlocking { withTimeout(120_000L) { hostKeyPolicy.verify(observation) } }
            }.create()
            resources += client
            val parent = previousClient
            if (parent == null) client.connect(hop.endpoint.host, hop.endpoint.port)
            else {
                val tunnel = parent.newDirectConnection(hop.endpoint.host, hop.endpoint.port)
                resources += tunnel
                client.connectVia(tunnel)
            }
            ensureActive()
            when (val auth = hop.authentication) {
                SshAuthentication.Password -> {
                    val password = passwordProvider.passwordFor(hop)
                    try { client.authPassword(hop.username, password) }
                    finally { password.fill('\u0000') }
                }
                is SshAuthentication.AndroidKeystoreP256 -> {
                    keyAuthorizationProvider.authorize(hop)
                    val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    val privateKey = store.getKey(auth.alias, null) as? PrivateKey
                        ?: error("Android Keystore credential is unavailable")
                    val publicKey = store.getCertificate(auth.alias)?.publicKey
                        ?: error("Android Keystore public certificate is unavailable")
                    client.authPublickey(hop.username, client.loadKeys(KeyPair(publicKey, privateKey)))
                }
            }
            ensureActive()
            previousClient = client
        }
        val session = checkNotNull(previousClient).startSession()
        resources += session
        // tmux -CC still calls tcgetattr and refuses to enter control mode without a PTY.
        // Visible sizing is subsequently owned by refresh-client -C through the shared core.
        session.allocatePTY("xterm-256color", 80, 24, 0, 0, emptyMap<PTYMode, Int>())
        val command = session.exec(
            tmuxControlCommand(sessionTarget, preserveInitialGeometry, moshViewSession),
        )
        resources += command
        SshTmuxConnection(
            command,
            resources,
            AuthenticatedForwardingRuntimeFactory(checkNotNull(previousClient)),
        )
    } catch (failure: Throwable) {
        resources.asReversed().forEach { runCatching { it.close() } }
        throw failure
    }
}

/**
 * Build the inline `-CC` control-client command.
 *
 * The command text itself is owned by the shared core, so this device attaches
 * with exactly the geometry semantics the Apple clients use. The control client
 * is this device's sizing participant: it advertises the local
 * (compact-projected) grid through `refresh-client -C` and contends for grid
 * authority, on phones exactly as on tablets. `preserveInitialGeometry` is the
 * reverse-attach observer capability only — a client that has ceded the grid to
 * a larger peer — and must not be requested at attach time, or the device can
 * never fit its own viewport nor take control back.
 */
internal fun tmuxControlCommand(
    sessionTarget: String,
    preserveInitialGeometry: Boolean,
    moshViewSession: Boolean = false,
): String {
    // The shared builder quotes the target, but tmux still reads it as target
    // syntax however the shell quotes it, so keep the charset narrow before
    // handing it over. The grammar itself is the core's — this platform used to
    // restate it in three places, and they had drifted.
    // Swift authority:
    // `Packages/TesseraCore/Sources/TesseraProtocolCore/TmuxTargetValidation.swift`.
    require(SharedTargetValidation.isValidTmuxSessionName(sessionTarget))
    // Mosh's control channel joins Tessera's own view of the session, the one
    // its visible client attaches to; the inline SSH client attaches straight
    // to the user's session, where control mode never draws a status line and
    // so has nothing to hide.
    return if (moshViewSession) {
        SharedTmuxCommands.moshControlChannelCommand(
            sessionTarget = sessionTarget,
            preserveInitialGeometry = preserveInitialGeometry,
        )
    } else {
        SharedTmuxCommands.controlModeSessionCommand(
            sessionTarget = sessionTarget,
            preserveInitialGeometry = preserveInitialGeometry,
        )
    }
}
