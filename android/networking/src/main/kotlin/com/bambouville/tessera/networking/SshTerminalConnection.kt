package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InputStream
import java.security.KeyPair
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.delay
import com.bambouville.tessera.forwarding.ForwardingTransport
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.PTYMode
import net.schmizz.sshj.connection.channel.direct.Session

data class SshEndpoint(
    val host: String,
    val port: Int = 22,
)

sealed interface SshAuthentication {
    data object Password : SshAuthentication
    data class AndroidKeystoreP256(val alias: String) : SshAuthentication
}

data class SshRouteHop(
    val id: String,
    val endpoint: SshEndpoint,
    val username: String,
    val authentication: SshAuthentication,
)

data class SshRouteRequest(
    val hops: List<SshRouteHop>,
    val initialColumns: Int = 80,
    val initialRows: Int = 24,
)

fun interface SshPasswordProvider {
    suspend fun passwordFor(hop: SshRouteHop): CharArray
}

fun interface SshKeyAuthorizationProvider {
    suspend fun authorize(hop: SshRouteHop)
}

class SshPasswordRequest(
    val endpoint: SshEndpoint,
    val username: String,
    val password: CharArray,
    val initialColumns: Int = 80,
    val initialRows: Int = 24,
)

fun interface SshHostKeyPolicy {
    suspend fun verify(observation: SshHostKeyObservation): Boolean
}

class AndroidSshBackend {
    /**
     * Executes a bounded bootstrap command through the same direct/jump SSH
     * route and credential/host-key challenges used by terminals and tmux.
     * It intentionally returns only the captured transcript; no SSH resource
     * survives this call, which is the required handoff model for Mosh.
     */
    suspend fun executeRouteCommand(
        request: SshRouteRequest,
        commandText: String,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
    ): SshCommandTranscript = withContext(Dispatchers.IO) {
        require(request.hops.isNotEmpty() && request.hops.size <= MAX_ROUTE_HOPS)
        require(commandText.isNotBlank() && commandText.length <= MAX_BOOTSTRAP_COMMAND_BYTES)

        val resources = mutableListOf<Closeable>()
        var previousClient: SSHClient? = null
        try {
            for (hop in request.hops) {
                require(hop.endpoint.host.isNotBlank())
                require(hop.endpoint.port in 1..65535)
                require(hop.username.isNotBlank())
                val client = SshjClientFactory { observation ->
                    runBlocking {
                        withTimeout(HOST_KEY_DECISION_TIMEOUT_MILLISECONDS) {
                            hostKeyPolicy.verify(observation)
                        }
                    }
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
                authenticateRouteHop(client, hop, passwordProvider, keyAuthorizationProvider)
                ensureActive()
                previousClient = client
            }
            val session = checkNotNull(previousClient).startSession()
            resources += session
            val command = session.exec(commandText)
            resources += command
            coroutineScope {
                // SSH channels can block command completion when either pipe
                // fills. Drain both concurrently, retaining only the bounded
                // diagnostic prefix, before inspecting the exit status.
                val standardOutput = async(Dispatchers.IO) { command.inputStream.readBoundedUtf8() }
                val standardError = async(Dispatchers.IO) { command.errorStream.readBoundedUtf8() }
                command.join(BOOTSTRAP_COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                if (command.exitStatus == null) {
                    command.close()
                    standardOutput.await()
                    standardError.await()
                    error("SSH bootstrap command timed out")
                }
                val output = standardOutput.await()
                val error = standardError.await()
                check(!output.overflowed && !error.overflowed) {
                    "SSH bootstrap transcript exceeds limit"
                }
                SshCommandTranscript(
                    standardOutput = output.text,
                    standardError = error.text,
                    exitStatus = command.exitStatus,
                )
            }
        } finally {
            resources.asReversed().forEach { runCatching { it.close() } }
        }
    }

    /**
     * Authenticates the final direct or jump-host route once.  Feature modules
     * receive child-channel wrappers, never the underlying SSHJ client.
     */
    suspend fun openRoute(
        request: SshRouteRequest,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
        construction: SshRouteConstruction? = null,
    ): SshRouteOwner = acquireSshResource {
        require(request.hops.isNotEmpty())
        require(request.hops.size <= MAX_ROUTE_HOPS)
        require(request.hops.map(SshRouteHop::id).distinct().size == request.hops.size)
        require(request.initialColumns >= 4 && request.initialRows >= 4)

        val resources = mutableListOf<Closeable>()
        var previousClient: SSHClient? = null
        // The key the final hop was trusted with, which ties the route's
        // identity to that machine rather than to whatever answers its address.
        val trustedHostKey = AtomicReference<SshHostKeyObservation?>()
        try {
            for (hop in request.hops) {
                require(hop.endpoint.host.isNotBlank())
                require(hop.endpoint.port in 1..65535)
                require(hop.username.isNotBlank())
                trustedHostKey.set(null)
                val client = SshjClientFactory(socketFactory = construction?.socketFactory()) { observation ->
                    runBlocking {
                        withTimeout(HOST_KEY_DECISION_TIMEOUT_MILLISECONDS) {
                            hostKeyPolicy.verify(observation)
                        }
                    }.also { trusted -> if (trusted) trustedHostKey.set(observation) }
                }.create()
                resources += client
                construction?.adopt(client)
                val parent = previousClient
                if (parent == null) {
                    client.connect(hop.endpoint.host, hop.endpoint.port)
                } else {
                    val tunnel = parent.newDirectConnection(hop.endpoint.host, hop.endpoint.port)
                    resources += tunnel
                    construction?.adopt(tunnel)
                    client.connectVia(tunnel)
                }
                ensureActive()
                when (val authentication = hop.authentication) {
                    SshAuthentication.Password -> {
                        val password = passwordProvider.passwordFor(hop)
                        try {
                            client.authPassword(hop.username, password)
                        } finally {
                            password.fill('\u0000')
                        }
                    }
                    is SshAuthentication.AndroidKeystoreP256 -> {
                        keyAuthorizationProvider.authorize(hop)
                        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val privateKey = keyStore.getKey(authentication.alias, null) as? PrivateKey
                            ?: error("Android Keystore credential is unavailable")
                        val publicKey = keyStore.getCertificate(authentication.alias)?.publicKey
                            ?: error("Android Keystore public certificate is unavailable")
                        client.authPublickey(hop.username, client.loadKeys(KeyPair(publicKey, privateKey)))
                    }
                }
                ensureActive()
                previousClient = client
            }

            SshRouteOwner(checkNotNull(previousClient), resources, routeIdentity(request.hops, trustedHostKey.get()))
                .also { construction?.release() }
        } catch (failure: Throwable) {
            resources.asReversed().forEach { runCatching { it.close() } }
            throw failure
        }
    }

    suspend fun connectRoute(
        request: SshRouteRequest,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
    ): SshTerminalConnection = acquireSshResource {
        require(request.hops.isNotEmpty())
        require(request.hops.size <= MAX_ROUTE_HOPS)
        require(request.hops.map(SshRouteHop::id).distinct().size == request.hops.size)
        require(request.initialColumns >= 4 && request.initialRows >= 4)

        val resources = mutableListOf<Closeable>()
        var previousClient: SSHClient? = null
        try {
            for (hop in request.hops) {
                require(hop.endpoint.host.isNotBlank())
                require(hop.endpoint.port in 1..65535)
                require(hop.username.isNotBlank())
                val client = SshjClientFactory { observation ->
                    runBlocking {
                        withTimeout(HOST_KEY_DECISION_TIMEOUT_MILLISECONDS) {
                            hostKeyPolicy.verify(observation)
                        }
                    }
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
                authenticateRouteHop(client, hop, passwordProvider, keyAuthorizationProvider)
                ensureActive()
                previousClient = client
            }

            val finalClient = checkNotNull(previousClient)
            val session = finalClient.startSession()
            resources += session
            try {
                session.allocatePTY(
                    "xterm-256color",
                    request.initialColumns,
                    request.initialRows,
                    0,
                    0,
                    emptyMap<PTYMode, Int>(),
                )
                val shell = session.startShell()
                resources += shell
                ensureActive()
                SshTerminalConnection(
                    session = session,
                    shell = shell,
                    resources = resources,
                    forwardingRuntimeFactory = AuthenticatedForwardingRuntimeFactory(finalClient),
                )
            } catch (failure: Throwable) {
                resources.asReversed().forEach { runCatching { it.close() } }
                throw failure
            }
        } catch (failure: Throwable) {
            resources.asReversed().forEach { runCatching { it.close() } }
            throw failure
        }
    }

    suspend fun connectPassword(
        request: SshPasswordRequest,
        hostKeyPolicy: SshHostKeyPolicy,
    ): SshTerminalConnection {
        try {
            return connectRoute(
                request = SshRouteRequest(
                    hops = listOf(
                        SshRouteHop(
                            id = "password",
                            endpoint = request.endpoint,
                            username = request.username,
                            authentication = SshAuthentication.Password,
                        ),
                    ),
                    initialColumns = request.initialColumns,
                    initialRows = request.initialRows,
                ),
                passwordProvider = SshPasswordProvider { request.password },
                hostKeyPolicy = hostKeyPolicy,
            )
        } finally {
            request.password.fill('\u0000')
        }
    }

    /**
     * Creates an authenticated SSH route without a PTY for Mosh forwarding.
     * The caller owns the returned side channel and must close it before its
     * Mosh transport is released. Credentials and SSHClient stay private.
     */
    suspend fun openForwardingSideChannel(
        request: SshRouteRequest,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
    ): AuthenticatedForwardingSideChannel = acquireSshResource {
        require(request.hops.isNotEmpty() && request.hops.size <= MAX_ROUTE_HOPS)
        require(request.hops.map(SshRouteHop::id).distinct().size == request.hops.size)

        val resources = mutableListOf<Closeable>()
        var previousClient: SSHClient? = null
        try {
            for (hop in request.hops) {
                require(hop.endpoint.host.isNotBlank())
                require(hop.endpoint.port in 1..65535)
                require(hop.username.isNotBlank())
                val client = SshjClientFactory { observation ->
                    runBlocking {
                        withTimeout(HOST_KEY_DECISION_TIMEOUT_MILLISECONDS) {
                            hostKeyPolicy.verify(observation)
                        }
                    }
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
                authenticateRouteHop(client, hop, passwordProvider, keyAuthorizationProvider)
                ensureActive()
                previousClient = client
            }
            AuthenticatedForwardingSideChannel(checkNotNull(previousClient), resources)
        } catch (failure: Throwable) {
            resources.asReversed().forEach { runCatching { it.close() } }
            throw failure
        }
    }

    internal companion object {
        /**
         * Every hop's account and endpoint, outermost first, then the final
         * host's key fingerprint: the same address can reach another machine
         * on another network. Independent of hop ids and authentication.
         */
        fun routeIdentity(hops: List<SshRouteHop>, finalHostKey: SshHostKeyObservation?): String {
            val accounts = hops.joinToString(" > ") { "${it.username}@${it.endpoint.host}:${it.endpoint.port}" }
            val key = finalHostKey?.let {
                val digest = MessageDigest.getInstance("SHA-256").digest(it.canonicalKeyBlob)
                " ${it.algorithm} SHA256:${Base64.getEncoder().withoutPadding().encodeToString(digest)}"
            }
            return accounts + key.orEmpty()
        }

        const val HOST_KEY_DECISION_TIMEOUT_MILLISECONDS = 120_000L
        const val MAX_ROUTE_HOPS = 8
        const val MAX_BOOTSTRAP_COMMAND_BYTES = 4 * 1024 * 1024
        const val MAX_BOOTSTRAP_TRANSCRIPT_BYTES = 128 * 1024
        const val BOOTSTRAP_COMMAND_TIMEOUT_SECONDS = 120L
    }

    private suspend fun authenticateRouteHop(
        client: SSHClient,
        hop: SshRouteHop,
        passwordProvider: SshPasswordProvider,
        keyAuthorizationProvider: SshKeyAuthorizationProvider,
    ) {
        when (val authentication = hop.authentication) {
            SshAuthentication.Password -> {
                val password = passwordProvider.passwordFor(hop)
                try {
                    client.authPassword(hop.username, password)
                } finally {
                    password.fill('\u0000')
                }
            }
            is SshAuthentication.AndroidKeystoreP256 -> {
                keyAuthorizationProvider.authorize(hop)
                val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                val privateKey = keyStore.getKey(authentication.alias, null) as? PrivateKey
                    ?: error("Android Keystore credential is unavailable")
                val publicKey = keyStore.getCertificate(authentication.alias)?.publicKey
                    ?: error("Android Keystore public certificate is unavailable")
                client.authPublickey(hop.username, client.loadKeys(KeyPair(publicKey, privateKey)))
            }
        }
    }

    private fun InputStream.readBoundedUtf8(): BoundedTranscript {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        var overflowed = false
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            val remaining = MAX_BOOTSTRAP_TRANSCRIPT_BYTES - output.size()
            if (remaining > 0) {
                output.write(buffer, 0, minOf(count, remaining))
            }
            if (count > remaining) overflowed = true
        }
        return BoundedTranscript(output.toByteArray().decodeToString(), overflowed)
    }

    private data class BoundedTranscript(val text: String, val overflowed: Boolean)
}

data class SshCommandTranscript(
    val standardOutput: String,
    val standardError: String,
    val exitStatus: Int?,
) {
    /** Mosh's connect banner may arrive on either stream depending on the remote shell. */
    val combinedOutput: String
        get() = listOf(standardOutput, standardError).filter(String::isNotEmpty).joinToString("\n")
}

class SshTerminalConnection internal constructor(
    private val session: Session,
    private val shell: Session.Shell,
    private val resources: List<Closeable>? = null,
    private val forwardingRuntimeFactory: AuthenticatedForwardingRuntimeFactory? = null,
    private val owner: SshRouteOwner? = null,
    private val closeRouteOnClose: Boolean = false,
    /** Non-null only when the remote server acknowledged the LC_* env request. */
    val routeMarker: String? = null,
) : Closeable {
    val standardOutput: InputStream = shell.inputStream
    val standardError: InputStream = shell.errorStream

    /** Non-null only when the remote shell actually reported an exit status. */
    val remoteExitStatus: Int?
        // SSHJ's concrete SessionChannel implements both Shell and Command;
        // the public Shell interface simply omits the protocol exit-status accessor.
        get() = (session as? Session.Command)?.exitStatus

    suspend fun awaitRemoteExitStatus(): Int? = withTimeoutOrNull(REMOTE_EXIT_STATUS_GRACE_MILLISECONDS) {
        while (remoteExitStatus == null) delay(10)
        remoteExitStatus
    }

    suspend fun write(bytes: ByteArray) = withContext(Dispatchers.IO) {
        if (bytes.isEmpty()) return@withContext
        synchronized(shell.outputStream) {
            shell.outputStream.write(bytes)
            shell.outputStream.flush()
        }
    }

    suspend fun resize(columns: Int, rows: Int) = withContext(Dispatchers.IO) {
        require(columns >= 4 && rows >= 4)
        shell.changeWindowDimensions(columns, rows, 0, 0)
    }

    /** A forwarding-only capability; it does not expose the SSH client. */
    fun createForwardingRuntime(
        transport: ForwardingTransport = ForwardingTransport.Ssh,
    ): PortForwardingRuntime = checkNotNull(forwardingRuntimeFactory) {
        "forwarding is unavailable on a shared SSH route"
    }.create(transport)

    override fun close() {
        val routeOwner = owner
        if (routeOwner == null) {
            resources.orEmpty().asReversed().forEach { runCatching { it.close() } }
        } else {
            runCatching { shell.close() }
            runCatching { session.close() }
            routeOwner.release(this)
            if (closeRouteOnClose) routeOwner.close()
        }
    }

    private companion object {
        const val REMOTE_EXIT_STATUS_GRACE_MILLISECONDS = 300L
    }
}
