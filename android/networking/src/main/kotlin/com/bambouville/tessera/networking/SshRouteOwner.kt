package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.PTYMode
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.TesseraChannelCancellation
import net.schmizz.sshj.connection.channel.OpenFailException
import net.schmizz.sshj.connection.ConnectionException
import net.schmizz.sshj.transport.TransportException

/**
 * One authenticated final SSH route and the bounded channels opened through it.
 *
 * The owner deliberately hides SSHJ from feature modules. A terminal, tmux
 * control client, SFTP client, or projector exec stream is a child channel of
 * the same authenticated route; closing one child never closes the user's
 * other channels. Closing the owner retires its transports and every child.
 */
class SshRouteOwner internal constructor(
    private val finalClient: SSHClient,
    private val routeResources: List<Closeable>,
    /** Which remote filesystem this reaches: see [AndroidSshBackend.routeIdentity]. */
    val routeIdentity: String,
) : Closeable {
    /** A route whose identity nothing keys on, as unit tests build it. */
    internal constructor(finalClient: SSHClient, routeResources: List<Closeable>) : this(finalClient, routeResources, "")

    private val lifecycleLock = Any()
    private val children = linkedSetOf<Closeable>()
    private var closed = false

    /** Live child count, unlike the endpoint's lifetime count of open attempts. */
    val activeExecChannels: Int
        get() = synchronized(lifecycleLock) { children.count { it is SshExecStream } }

    val isConnected: Boolean
        get() = synchronized(lifecycleLock) { !closed && finalClient.isConnected && finalClient.isAuthenticated }

    suspend fun openTerminal(
        columns: Int,
        rows: Int,
        closeRouteOnClose: Boolean = false,
        routeMarker: String? = null,
    ): SshTerminalConnection = acquireSshResource {
        require(columns >= 4 && rows >= 4)
        require(routeMarker == null || ROUTE_MARKER.matches(routeMarker))
        val session = finalClient.startSession()
        try {
            // LC_* is accepted by the common OpenSSH AcceptEnv policy. Servers
            // that reject it simply leave raw-PTY Agent actions unavailable;
            // no terminal input is used to manufacture proof.
            val acceptedRouteMarker = routeMarker?.takeIf {
                runCatching { session.setEnvVar("LC_TESSERA_ROUTE", it) }.isSuccess
            }
            session.allocatePTY(
                "xterm-256color",
                columns,
                rows,
                0,
                0,
                emptyMap<PTYMode, Int>(),
            )
            val shell = session.startShell()
            register(
                SshTerminalConnection(
                    owner = this@SshRouteOwner,
                    session = session,
                    shell = shell,
                    closeRouteOnClose = closeRouteOnClose,
                    routeMarker = acceptedRouteMarker,
                ),
            )
        } catch (failure: Throwable) {
            runCatching { session.close() }
            throw failure
        }
    }

    suspend fun openTmux(
        sessionTarget: String,
        preserveInitialGeometry: Boolean = false,
        closeRouteOnClose: Boolean = false,
        moshViewSession: Boolean = false,
        commandTransform: (String) -> String = { it },
    ): SshTmuxConnection = acquireSshResource {
        openTmuxControlCommand(
            commandTransform(tmuxControlCommand(sessionTarget, preserveInitialGeometry, moshViewSession)),
            closeRouteOnClose,
        )
    }

    private fun openTmuxControlCommand(
        commandText: String,
        closeRouteOnClose: Boolean = false,
    ): SshTmuxConnection {
        require(commandText.isNotBlank() && commandText.length <= MAX_REMOTE_COMMAND_LENGTH)
        val session = finalClient.startSession()
        try {
            // tmux -CC calls tcgetattr and therefore refuses a non-PTY channel.
            session.allocatePTY("xterm-256color", 80, 24, 0, 0, emptyMap<PTYMode, Int>())
            val command = session.exec(commandText)
            return register(
                SshTmuxConnection(
                    owner = this,
                    session = session,
                    command = command,
                    closeRouteOnClose = closeRouteOnClose,
                ),
            )
        } catch (failure: Throwable) {
            runCatching { session.close() }
            throw failure
        }
    }

    suspend fun openFiles(closeRouteOnClose: Boolean = false): SshFileConnection = acquireSshResource {
        val sftp = finalClient.newSFTPClient()
        try {
            register(SshFileConnection(this@SshRouteOwner, sftp, closeRouteOnClose))
        } catch (failure: Throwable) {
            runCatching { sftp.close() }
            throw failure
        }
    }

    /**
     * Executes one bounded bootstrap/cleanup command on this already
     * authenticated route. Mosh retains the route so an explicit disconnect
     * can retire its exact detached server without asking the Android
     * Keystore to authorize a second SSH authentication.
     */
    suspend fun executeBoundedCommand(commandText: String): SshCommandTranscript =
        withContext(Dispatchers.IO) {
            require(commandText.isNotBlank() && commandText.length <= MAX_BOUND_COMMAND_LENGTH)
            val session = finalClient.startSession()
            try {
                val command = session.exec(commandText)
                try {
                    coroutineScope {
                        val standardOutput = async(Dispatchers.IO) {
                            command.inputStream.readBoundedCommandOutput()
                        }
                        val standardError = async(Dispatchers.IO) {
                            command.errorStream.readBoundedCommandOutput()
                        }
                        command.join(BOUND_COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                        if (command.exitStatus == null) command.close()
                        val output = standardOutput.await()
                        val error = standardError.await()
                        check(!output.overflowed && !error.overflowed) {
                            "SSH command transcript exceeds limit"
                        }
                        SshCommandTranscript(
                            standardOutput = output.text,
                            standardError = error.text,
                            exitStatus = command.exitStatus,
                        )
                    }
                } finally {
                    runCatching { command.close() }
                }
            } finally {
                runCatching { session.close() }
            }
        }

    /**
     * Opens a non-PTY exec channel on this authenticated route. The command is
     * intentionally a single safe executable token; structured projector
     * requests belong on stdin rather than in a shell command string.
     */
    suspend fun execute(request: SshExecRequest): SshExecStream = acquireSshResource(dispose = { it.cancel() }) {
        val session = finalClient.startSession()
        try {
            val command = session.exec(request.remoteCommand)
            register(SshExecStream(this@SshRouteOwner, session, command, request))
        } catch (failure: Throwable) {
            runCatching { session.close() }
            throw failure
        }
    }

    internal fun release(child: Closeable) {
        synchronized(lifecycleLock) { children.remove(child) }
    }

    override fun close() {
        val toClose = synchronized(lifecycleLock) {
            if (closed) return
            closed = true
            children.toList().also { children.clear() }
        }
        // Whole-route retirement must unblock child readers first. Waiting
        // for each child's CLOSE acknowledgement on a blackholed socket can
        // otherwise cost the SSH timeout once per child before disconnecting
        // the transport. Child-only close/cancel still preserves the route.
        routeResources.asReversed().forEach { resource -> runCatching { resource.close() } }
        toClose.asReversed().forEach { child -> runCatching { child.close() } }
    }

    private fun <T : Closeable> register(child: T): T {
        val closeImmediately = synchronized(lifecycleLock) {
            if (closed) true else {
                children += child
                false
            }
        }
        if (closeImmediately) {
            child.close()
            throw IllegalStateException("SSH route is closed")
        }
        return child
    }

    private fun InputStream.readBoundedCommandOutput(): BoundedCommandOutput {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4_096)
        var overflowed = false
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            val remaining = MAX_BOUND_COMMAND_OUTPUT_BYTES - output.size()
            if (remaining > 0) output.write(buffer, 0, minOf(count, remaining))
            if (count > remaining) overflowed = true
        }
        return BoundedCommandOutput(output.toByteArray().decodeToString(), overflowed)
    }

    private data class BoundedCommandOutput(val text: String, val overflowed: Boolean)

    private companion object {
        // Up to three 64 KiB optional shell fields, including nested quote expansion.
        const val MAX_REMOTE_COMMAND_LENGTH = 4 * 1_024 * 1_024
        const val MAX_BOUND_COMMAND_LENGTH = MAX_REMOTE_COMMAND_LENGTH
        const val MAX_BOUND_COMMAND_OUTPUT_BYTES = 128 * 1_024
        const val BOUND_COMMAND_TIMEOUT_SECONDS = 120L
        val ROUTE_MARKER = Regex("[A-Fa-f0-9-]{36}")
    }
}

/** Host-provided exception messages can contain private paths or command text. */
fun sshExecFailureCode(failure: Throwable): String = when (failure) {
    is OpenFailException -> "OpenFailException:${failure.reason.name}"
    else -> failure::class.java.simpleName
}

/** Policy rejections do not become an SSH authentication/reconnect loop. */
fun sshExecFailureNeedsNewRoute(failure: Throwable): Boolean = when (failure) {
    is OpenFailException -> failure.reason == OpenFailException.Reason.RESOURCE_SHORTAGE ||
        failure.reason == OpenFailException.Reason.CONNECT_FAILED
    is ConnectionException, is TransportException, is java.io.IOException -> true
    else -> false
}

/** Fixed remote programs admitted on an authenticated route. */
enum class SshRemoteOperation {
    AGENT_HOST,
    AGENT_PROJECT,
    AGENT_LAUNCH,
    AGENT_PROVE,
    /** Runs a core-generated integration payload through a fixed POSIX shell. */
    AGENT_INTEGRATION_SHELL,
}

/** A bounded, shell-injection-resistant remote exec request. */
data class SshExecRequest(
    val operation: SshRemoteOperation,
    val maxStdinBytes: Int = DEFAULT_MAX_STDIN_BYTES,
    val maxStdoutBytes: Int = DEFAULT_MAX_OUTPUT_BYTES,
    val maxStderrBytes: Int = DEFAULT_MAX_ERROR_BYTES,
) {
    init {
        val streamLimit = if (operation == SshRemoteOperation.AGENT_INTEGRATION_SHELL) {
            MAX_STREAM_BYTES
        } else {
            MAX_AGENT_STREAM_BYTES
        }
        require(maxStdinBytes in 1..MAX_STDIN_BYTES) { "invalid stdin limit" }
        require(maxStdoutBytes in 1..streamLimit) { "invalid stdout limit" }
        require(maxStderrBytes in 1..streamLimit) { "invalid stderr limit" }
        require(maxStdoutBytes <= streamLimit - maxStderrBytes) {
            "combined exec stream limits exceed the core payload ceiling"
        }
    }

    companion object {
        const val DEFAULT_MAX_STDIN_BYTES = 262_144
        const val DEFAULT_MAX_OUTPUT_BYTES = 262_144
        const val DEFAULT_MAX_ERROR_BYTES = 16_384
        const val MAX_STDIN_BYTES = 33_554_432
        const val MAX_AGENT_STREAM_BYTES = 1_048_576
        // Three integration config snapshots are base64-framed and may each
        // expand a valid 1 MiB file beyond the ordinary Agent payload ceiling.
        const val MAX_STREAM_BYTES = 8_388_608
    }

    /** Fixed install paths; no caller data is interpolated into a shell command. */
    internal val remoteCommand: String
        get() = when (operation) {
            SshRemoteOperation.AGENT_HOST -> "\"\$HOME/.config/tessera/tessera-agent-host\" connect --stdio --runtime-base \"\$HOME/.config/tessera/agent-host\" --context-from-hello"
            SshRemoteOperation.AGENT_PROJECT -> "\$HOME/.config/tessera/tessera-agent-project"
            SshRemoteOperation.AGENT_LAUNCH -> "\$HOME/.config/tessera/tessera-agent-launch"
            SshRemoteOperation.AGENT_PROVE -> "\$HOME/.config/tessera/tessera-agent-prove"
            // This is the only shell-bearing operation. Its script travels on
            // bounded stdin from the shared core command builder, never from
            // a remote-command string supplied by feature or UI code.
            SshRemoteOperation.AGENT_INTEGRATION_SHELL -> "/bin/sh -s"
        }
}

data class SshExecExitStatus(val code: Int?)

class SshExecStreamLimitExceeded(val stream: String, val limit: Int) : IllegalStateException(
    "$stream exceeded its bounded SSH exec limit",
)

/**
 * Incremental exec I/O. Callers collect stdout/stderr concurrently when the
 * remote program can write both; [cancel] closes this child only, leaving the
 * route, terminal, tmux control client, and SFTP channels alive.
 */
class SshExecStream internal constructor(
    private val owner: SshRouteOwner,
    private val session: Session,
    private val command: Session.Command,
    private val request: SshExecRequest,
) : Closeable {
    private val isClosed = AtomicBoolean(false)
    private var writtenStdinBytes = 0

    fun stdout(): Flow<ByteArray> = boundedChunks(command.inputStream, request.maxStdoutBytes, "stdout")

    fun stderr(): Flow<ByteArray> = boundedChunks(command.errorStream, request.maxStderrBytes, "stderr")

    suspend fun writeStdin(bytes: ByteArray) = withContext(Dispatchers.IO) {
        require(bytes.size <= MAX_STDIN_CHUNK_BYTES) { "stdin chunk exceeds bound" }
        check(!isClosed.get()) { "SSH exec stream is closed" }
        if (bytes.isEmpty()) return@withContext
        synchronized(command.outputStream) {
            val duplex = request.operation == SshRemoteOperation.AGENT_HOST
            require(bytes.size <= if (duplex) 65_540 else request.maxStdinBytes - writtenStdinBytes) { "stdin exceeds bound" }
            command.outputStream.write(bytes)
            command.outputStream.flush()
            if (!duplex) writtenStdinBytes += bytes.size
        }
    }

    suspend fun closeStdin() = withContext(Dispatchers.IO) {
        if (!isClosed.get()) runCatching { command.outputStream.close() }
    }

    suspend fun awaitExit(): SshExecExitStatus = withContext(Dispatchers.IO) {
        command.join()
        SshExecExitStatus(command.exitStatus)
    }

    fun cancel() = close(terminate = true)

    override fun close() = close(terminate = false)

    private fun close(terminate: Boolean) {
        if (!isClosed.compareAndSet(false, true)) return
        // Closing an exec channel does not terminate a silent remote child.
        // Request termination on this channel before waiting for its close;
        // no signal targets a PID supplied by the host or another channel.
        if (terminate) {
            runCatching { TesseraChannelCancellation.terminate(command, false) }
            // Give cooperative helpers a brief chance to clean up. Keep the
            // channel open until escalation: after CLOSE a later signal would
            // address a retired channel. KILL remains scoped to this exec.
            runCatching { command.join(CANCEL_GRACE_MILLIS, TimeUnit.MILLISECONDS) }
            runCatching { TesseraChannelCancellation.terminate(command, true) }
        }
        runCatching { command.close() }
        runCatching { session.close() }
        owner.release(this)
    }

    private fun boundedChunks(input: InputStream, limit: Int, stream: String): Flow<ByteArray> = flow {
        val buffer = ByteArray(16 * 1024)
        var total = 0
        try {
            while (!isClosed.get()) {
                currentCoroutineContext().ensureActive()
                val count = withContext(Dispatchers.IO) { input.read(buffer) }
                if (count < 0) break
                if (count == 0) continue
                val persistentOutput = request.operation == SshRemoteOperation.AGENT_HOST && stream == "stdout"
                if (!persistentOutput && count > limit - total) {
                    withContext(NonCancellable + Dispatchers.IO) { cancel() }
                    throw SshExecStreamLimitExceeded(stream, limit)
                }
                // Flow backpressure bounds persistent stdout to this 16 KiB
                // chunk; the ingestion decoder separately caps every frame
                // and pending page. A lifetime byte counter would eventually
                // disconnect a healthy long-running subscription.
                if (!persistentOutput) total += count
                emit(buffer.copyOf(count))
            }
        } catch (failure: CancellationException) {
            withContext(NonCancellable + Dispatchers.IO) { cancel() }
            throw failure
        }
    }

    private companion object {
        const val MAX_STDIN_CHUNK_BYTES = 262_144
        const val CANCEL_GRACE_MILLIS = 250L
    }
}
