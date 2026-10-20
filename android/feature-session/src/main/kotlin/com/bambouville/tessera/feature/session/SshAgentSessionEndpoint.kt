package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointCapabilities
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentExecExitStatus
import com.bambouville.tessera.agent.platform.AgentExecRequest
import com.bambouville.tessera.agent.platform.AgentCurrentShellStatus
import com.bambouville.tessera.agent.platform.AgentIntegrationCommand
import com.bambouville.tessera.agent.platform.AgentIntegrationConfigSnapshots
import com.bambouville.tessera.agent.platform.AgentIntegrationOperation
import com.bambouville.tessera.agent.platform.AgentIntegrationProtocol
import com.bambouville.tessera.agent.platform.AgentIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryCommands
import com.bambouville.tessera.agent.platform.AgentLifecycleFrame
import com.bambouville.tessera.agent.platform.AgentLifecycleOscScanner
import com.bambouville.tessera.agent.platform.AgentProcessProof
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryScope
import com.bambouville.tessera.agent.platform.AgentProcessDiscoverySnapshot
import com.bambouville.tessera.agent.platform.AgentOccupancyPane
import com.bambouville.tessera.agent.platform.AgentOccupancyProcess
import com.bambouville.tessera.agent.platform.AgentOccupancySnapshot
import com.bambouville.tessera.agent.platform.AgentProofProvider
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentRemoteStreamDrain
import com.bambouville.tessera.agent.platform.AgentSemanticKey
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentShellActivationCommand
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.agent.platform.AgentTmuxLaunchReceipt
import com.bambouville.tessera.agent.platform.AgentTmuxPlacement
import com.bambouville.tessera.agent.platform.AgentTmuxPlacementReceipt
import com.bambouville.tessera.agent.platform.withoutTerminalEscapes
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallFailure
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.core.bridge.SharedAgentProcessDescriptor
import com.bambouville.tessera.core.bridge.SharedAgentProviderClassification
import com.bambouville.tessera.networking.SshExecRequest
import com.bambouville.tessera.networking.SshExecStream
import com.bambouville.tessera.networking.SshRemoteOperation
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.sshExecFailureCode
import com.bambouville.tessera.networking.sshExecFailureNeedsNewRoute
import com.bambouville.tessera.networking.mosh.MoshInputNotAdmittedException
import com.bambouville.tessera.terminal.TerminalTextSnapshot
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.UUID
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/**
 * Android remote-session implementation of the platform endpoint. SSH is the
 * authenticated data side channel for all four interactive transports; the
 * terminal writer/control port still belongs to the live SSH or Mosh carrier.
 * It owns no SSHJ type outside this feature and never touches a terminal View.
 */
internal class SshAgentSessionEndpoint(
    override val key: AgentSessionKey,
    hostID: String,
    private val transport: AgentEndpointTransport,
    hostDisplayLabel: String = hostID,
    route: SshRouteOwner,
    private val tmuxSession: String? = null,
    private val rawWriter: (suspend (ByteArray) -> Unit)? = null,
    private val tmuxControl: TmuxAgentControlPort? = null,
    private val routeMarker: String? = null,
    private val processRootPID: (() -> Int?)? = null,
    // Every agent proof and every integration probe costs one SSH exec channel
    // on the carrier the reader is typing through. A device log that shows a
    // transport dying has no way to say how many of those were in flight unless
    // this side counts them, so it does.
    private val diagnostics: ((String, Map<String, String>) -> Unit)? = null,
    private val attachmentUpload: (suspend (SshRouteOwner, String) -> AgentEndpointResult<String>)? = null,
    private val hostAsset: ((String) -> ByteArray)? = null,
    renewAuxiliaryRoute: (suspend (SshRouteOwner) -> SshRouteOwner)? = null,
    publishAuxiliaryRoute: (SshRouteOwner, SshRouteOwner) -> Boolean = { _, _ -> true },
    private val retireFailedControlRoute: ((SshRouteOwner) -> Unit)? = null,
) : AgentSessionEndpoint {
    private val originalRoute = route
    private val auxiliaryRoute = renewAuxiliaryRoute?.let { renew ->
        AgentAuxiliaryRouteLease(route, { it.isConnected }, publishAuxiliaryRoute, renew)
    }
    private val route: SshRouteOwner get() = auxiliaryRoute?.current ?: originalRoute
    private val closed = AtomicBoolean(false)
    private val execOpens = java.util.concurrent.atomic.AtomicLong(0)
    private val mutableBinding = MutableStateFlow(
        AgentEndpointBinding(key = key, hostID = hostID, hostDisplayLabel = hostDisplayLabel, transport = transport, tmuxSession = tmuxSession),
    )
    override val binding: StateFlow<AgentEndpointBinding> = mutableBinding.asStateFlow()
    override val ingestionBinding: AgentEndpointBinding get() = mutableBinding.value.copy(windowID = null, paneID = null)
    override fun isCurrentIngestion(candidate: AgentEndpointBinding): Boolean =
        !closed.get() && candidate.sameRouteAs(ingestionBinding)
    private val mutableCapabilities = MutableStateFlow(capabilitiesFor(transport, rawWriter, tmuxControl))
    override val capabilities: StateFlow<AgentEndpointCapabilities> = mutableCapabilities.asStateFlow()
    private val mutableLifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>(replay = 64, extraBufferCapacity = 64)
    override val lifecycleFrames: SharedFlow<AgentLifecycleFrame> = mutableLifecycleFrames.asSharedFlow()
    override fun retainedLifecycleFrame(binding: AgentEndpointBinding): AgentLifecycleFrame? {
        if (closed.get() || !isTmuxTransport || binding.paneID == null) return null
        return synchronized(tails) {
            val address = tmuxAddresses[binding.paneID] ?: return@synchronized null
            val json = lastAgentStateJSON[binding.paneID] ?: return@synchronized null
            if (!address.sameRouteAs(binding)) return@synchronized null
            AgentLifecycleFrame(address, json.encodeToByteArray())
        }
    }
    private val tails = linkedMapOf<String, BoundedTail>()
    private val scanners = linkedMapOf<String, AgentLifecycleOscScanner>()
    private val tmuxAddresses = linkedMapOf<String, AgentEndpointBinding>()
    private val lifecycleDeliveryScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val pendingLifecycleFrames = linkedMapOf<String, AgentLifecycleFrame>()
    private var lifecycleDrain: Job? = null
    /** Latest `@tessera_agent_state`, delivered or awaiting the bounded flow. */
    private val lastAgentStateJSON = linkedMapOf<String, String>()
    private val latestRawSnapshot = AtomicReference<TerminalTextSnapshot?>(null)
    @Volatile private var rawSnapshotSource: (suspend () -> TerminalTextSnapshot?)? = null
    // Known tmux panes are independent routes on one carrier. A busy sibling
    // must not reserve all helper admission while an input proof waits.
    private val execBindingGate = AgentExecBindingGate<AgentEndpointBinding> { first, next ->
        first.key == next.key && first.hostID == next.hostID &&
            first.transport == next.transport && first.tmuxSession == next.tmuxSession
    }
    /**
     * A ceiling on exec channels open at once on this one SSH connection.
     *
     * The binding gate deliberately lets helpers for the same binding run
     * concurrently, so nothing above it bounded the fan-out: a single
     * inventory refresh opened five projector channels inside one millisecond,
     * and a busy agent adds a proof channel per lifecycle frame on top. OpenSSH
     * allows `MaxSessions` channels per connection and defaults to 10, of which
     * the carrier already holds one for tmux control mode, so an unbounded
     * fan-out reaches the server limit on any host with a few stored sessions.
     * Queue instead: the work still happens, just not all at once behind the
     * reader's keystrokes.
     */
    private val execChannels = Semaphore(MAX_CONCURRENT_EXEC_CHANNELS)

    fun noteRawOutput(bytes: ByteArray) = noteOutput("raw", mutableBinding.value, bytes)
    fun noteRawSnapshot(snapshot: TerminalTextSnapshot?) {
        if (isRawTransport) latestRawSnapshot.set(snapshot)
    }

    /**
     * Where [inspect] reads the visible screen from, on demand. Pushing a full
     * text snapshot after every rendered chunk instead cost one whole-screen
     * extraction per Mosh frame on every transport, tmux ones included, where
     * the result was then discarded.
     */
    fun setRawSnapshotSource(source: (suspend () -> TerminalTextSnapshot?)?) {
        rawSnapshotSource = source
    }

    fun noteTmuxOutput(windowID: Int, paneID: Int, bytes: ByteArray) {
        val pane = "%$paneID"
        val address = mutableBinding.value.copy(windowID = "@$windowID", paneID = pane)
        synchronized(tails) { tmuxAddresses[pane] = address }
        noteOutput(pane, address, bytes)
    }

    /**
     * A lifecycle payload the shared runtime read from a pane's
     * `@tessera_agent_state`.
     *
     * [noteTmuxOutput] only ever sees a pane with a render surface, which is a
     * pane of the window on screen. tmux publishes this option for every pane
     * of the attached session, so this is how an agent working in a window the
     * user is not looking at reaches Agent Center at all. The payload is the
     * same JSON the OSC carries base64-encoded, so it enters the same frame
     * flow without passing through the OSC scanner.
     */
    fun noteTmuxAgentState(windowID: Int, paneID: Int, json: String) {
        if (closed.get() || !isTmuxTransport) return
        val payload = json.encodeToByteArray()
        if (payload.isEmpty()) return
        val pane = "%$paneID"
        val address = mutableBinding.value.copy(windowID = "@$windowID", paneID = pane)
        val repeated = synchronized(tails) {
            tmuxAddresses[pane] = address
            // tmux republishes the whole metadata line whenever any of its
            // fields changes and an agent pane retitles constantly, so the
            // same payload arrives many times over; each delivered frame costs
            // a remote process proof. Suppressing repeats belongs here and not
            // in the shared runtime: this map is created with the endpoint, so
            // a payload is only ever called a repeat by the very consumer that
            // already received it. An endpoint built after tmux announced a
            // pane's option starts empty and still learns about that agent.
            if (lastAgentStateJSON.size > MAX_TRACKED_AGENT_PANES) lastAgentStateJSON.clear()
            lastAgentStateJSON.put(pane, json) == json
        }
        if (repeated) return
        val frame = AgentLifecycleFrame(address, payload)
        synchronized(tails) {
            if (closed.get()) return
            // Keep the latest quiet pane even when a slow proof fills the flow.
            // One drain per endpoint coalesces overflow without one coroutine per hook.
            if (lifecycleDrain == null && pendingLifecycleFrames.isEmpty() && mutableLifecycleFrames.tryEmit(frame)) return
            pendingLifecycleFrames[pane] = frame
            if (lifecycleDrain != null) return
            val job = lifecycleDeliveryScope.launch(start = CoroutineStart.LAZY) {
                while (true) {
                    val pending = synchronized(tails) {
                        val next = pendingLifecycleFrames.entries.firstOrNull()
                        if (next == null) { lifecycleDrain = null; return@launch }
                        pendingLifecycleFrames.remove(next.key)
                        next.value
                    }
                    if (!closed.get() && isCurrentRoute(pending.binding)) mutableLifecycleFrames.emit(pending)
                }
            }
            lifecycleDrain = job
            job.start()
        }
    }

    fun updateActiveTmuxTarget(windowID: Int?, paneID: Int?): Boolean {
        if (!isTmuxTransport) return false
        val next = mutableBinding.value.copy(
            windowID = windowID?.let { "@$it" },
            paneID = paneID?.let { "%$it" },
        )
        if (next == mutableBinding.value) return false
        mutableBinding.value = next
        next.paneID?.let { pane -> synchronized(tails) { tmuxAddresses[pane] = next } }
        return true
    }

    override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (isRawTransport) {
            val capture = rawSnapshotSource
            var snapshot = if (capture != null) capture() else latestRawSnapshot.get()
            var waitedForFrame = false
            if (capture != null && snapshot?.framePending == true) {
                // Only an explicit in-progress frame can improve by waiting.
                // Missing/invalid/oversized surfaces fail immediately.
                repeat(20) {
                    if (snapshot?.framePending == true) {
                        waitedForFrame = true
                        kotlinx.coroutines.delay(50)
                        if (!matches(binding)) return AgentEndpointResult.StaleBinding
                        snapshot = capture()
                    }
                }
            }
            if (!matches(binding)) return AgentEndpointResult.StaleBinding
            if (snapshot?.framePending == true || snapshot == null) return AgentEndpointResult.Unavailable("terminal_capture_unavailable")
            snapshot?.let { snapshot ->
                val physical = snapshot.physicalRows?.joinToString("\n") ?: snapshot.visibleText
                val bytes = physical.encodeToByteArray()
                val truncated = bytes.size > MAX_TAIL_BYTES
                return AgentEndpointResult.Success(
                    AgentTerminalObservation(
                        binding = binding,
                        visibleTail = bytes.takeLast(MAX_TAIL_BYTES).toByteArray(),
                        truncated = truncated,
                        authoritative = true,
                        currentCursorLine = snapshot.currentLine?.let(::cursorLinePrefix),
                        cursorRow = snapshot.cursorRow.takeUnless { truncated },
                        cursorVisible = snapshot.cursorVisible,
                        cursorColumn = snapshot.cursorColumn.takeUnless { truncated },
                        screenEvidence = snapshot.screenEvidence.takeUnless { truncated },
                        captureWaitedForFrame = waitedForFrame,
                    ),
                )
            }
        }
        if (isTmuxTransport) {
            val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
            val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
            repeat(3) {
                val before = control.send("display-message -p -t $pane '#{cursor_y}:#{cursor_x}:#{cursor_flag}'")
                val cursor = before.lines.singleOrNull()?.trim()?.split(':')?.takeIf { before.success && it.size == 3 }
                    ?: return AgentEndpointResult.Failed("tmux_cursor_unavailable")
                val row = cursor.first().toIntOrNull()?.takeIf { it in 0..10_000 }
                    ?: return AgentEndpointResult.Failed("tmux_cursor_unavailable")
                val column = cursor.getOrNull(1)?.toIntOrNull()?.takeIf { it in 0..10_000 }
                    ?: return AgentEndpointResult.Failed("tmux_cursor_unavailable")
                val capture = control.send("capture-pane -p -e -N -t $pane")
                if (!capture.success) return AgentEndpointResult.Failed("tmux_capture_failed")
                val after = control.send("display-message -p -t $pane '#{cursor_y}:#{cursor_x}:#{cursor_flag}'")
                if (!after.success || after.lines.singleOrNull()?.trim()?.split(':') != cursor) return@repeat
                val bytes = capture.lines.joinToString("\n").encodeToByteArray()
                val truncated = bytes.size > MAX_TAIL_BYTES
                val fresh = bytes.takeLast(MAX_TAIL_BYTES).toByteArray()
                synchronized(tails) { tails.getOrPut(pane) { BoundedTail() }.replace(fresh) }
                return AgentEndpointResult.Success(AgentTerminalObservation(binding, fresh, truncated, true,
                    // The row keeps its SGR (`-e`); its cells are what count, as on iOS.
                    currentCursorLine = capture.lines.getOrNull(row)?.let { cursorLinePrefix(withoutTerminalEscapes(it)) },
                    cursorRow = row.takeUnless { truncated }, cursorVisible = when (cursor.getOrNull(2)) { "1" -> true; "0" -> false; else -> null },
                    cursorColumn = column.takeUnless { truncated }))
            }
            return AgentEndpointResult.Failed("tmux_cursor_moved")
        }
        val tail = synchronized(tails) { tails[binding.paneID ?: "raw"]?.snapshot() }
            ?: return AgentEndpointResult.Unavailable("fresh terminal evidence is unavailable")
        return AgentEndpointResult.Success(
            AgentTerminalObservation(
                binding,
                tail.bytes,
                tail.truncated,
                authoritative = isTmuxTransport,
                currentCursorLine = null,
            ),
        )
    }

    override suspend fun execute(
        binding: AgentEndpointBinding,
        request: AgentExecRequest,
    ): AgentEndpointResult<AgentRemoteExecStream> {
        val native = request.executable == "tessera-agent-host"
        fun current() = if (native) isCurrentIngestion(binding) else matches(binding)
        if (!current()) return AgentEndpointResult.StaleBinding
        if (!capabilities.value.remoteData) return AgentEndpointResult.Unavailable(capabilities.value.reason ?: "remote data unavailable")
        val execLease: AutoCloseable = if (native) {
            // A process-long observational channel must not hold the exclusive
            // pane binding gate and starve proofs/actions in sibling panes.
            execChannels.acquire()
            if (!current()) { execChannels.release(); return AgentEndpointResult.StaleBinding }
            AutoCloseable { execChannels.release() }
        } else execBindingGate.acquire(binding, execChannels) { matches(binding) }
            ?: return AgentEndpointResult.StaleBinding
        if (!current()) { execLease.close(); return AgentEndpointResult.StaleBinding }
        var stream: SshExecStream? = null
        return try {
            noteExec(request.executable)
            val opened = openExec(
                SshExecRequest(
                    operation = request.executable.toSshOperation(),
                    maxStdinBytes = request.stdin.size.coerceAtLeast(1),
                    maxStdoutBytes = request.maxStdoutBytes,
                    maxStderrBytes = request.maxStderrBytes,
                ),
            )
            stream = opened
            if (request.stdin.isNotEmpty()) opened.writeStdin(request.stdin)
            if (request.executable != "tessera-agent-host") opened.closeStdin()
            AgentEndpointResult.Success(
                SshAgentRemoteExecStream(opened) {
                    execLease.close()
                },
            )
        } catch (failure: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { stream?.cancel() }
            execLease.close()
            if (failure is CancellationException) throw failure
            // The class name is the whole diagnostic value here: an exec that
            // never opens looks identical to a proof that returned nonsense
            // unless the log says which throwable ended it.
            diagnostics?.invoke("agent_exec_failed", mapOf(
                "op" to request.executable,
                "outcome" to sshExecFailureCode(failure),
                "active" to route.activeExecChannels.toString(),
                "transport" to transport.name,
            ))
            AgentEndpointResult.Failed("exec_unavailable:${sshExecFailureCode(failure)}")
        }
    }

    override suspend fun probeIntegration(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentIntegrationStatus> = executeIntegration(
        binding = binding,
        command = command,
        expected = AgentIntegrationOperation.PROBE,
        failureCode = "integration_probe_failed",
        parser = AgentIntegrationProtocol::parseStatus,
    )

    override suspend fun installIntegration(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (command.operation != AgentIntegrationOperation.INSTALL) return AgentEndpointResult.Failed("invalid_integration_command")
        try { installHostArtifact(binding) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: NewerIntegrationInstalled) {
            return AgentEndpointResult.Success(
                SharedAgentIntegrationInstallOutcome.Failed(SharedAgentIntegrationInstallFailure.NewerInstalled),
            )
        }
        catch (_: Throwable) { return AgentEndpointResult.Failed("agent_host_artifact_install_failed") }
        return executeIntegration(binding, command, AgentIntegrationOperation.INSTALL,
            "integration_install_failed", AgentIntegrationProtocol::parseInstallOutcome)
    }

    private suspend fun installHostArtifact(binding: AgentEndpointBinding) {
        suspend fun invoke(request: JSONObject): JSONObject {
            val result = executeIntegration(binding, AgentIntegrationCommand.hostDeploymentFromSharedCore(request.toString()),
                AgentIntegrationOperation.INSTALL, "artifact_failed") { output ->
                if (output.size <= 4096) runCatching { JSONObject(output.decodeToString()) }.getOrNull() else null
            }
            return (result as? AgentEndpointResult.Success)?.value ?: error("Artifact operation failed")
        }
        val probe = invoke(JSONObject().put("operation", "probe"))
        // Checked before any upload, so a newer app's host is never touched.
        if (probe.optBoolean("newerIntegration", false)) throw NewerIntegrationInstalled()
        val target = probe.getString("target")
        check(target in listOf("darwin-arm64", "darwin-x86_64", "linux-aarch64", "linux-x86_64"))
        val loader = checkNotNull(hostAsset)
        val (artifact, entry) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val manifestBytes = loader("manifest.json"); check(manifestBytes.size <= 16384)
            val entries = JSONObject(manifestBytes.decodeToString()).getJSONArray("artifacts")
            val entry = (0 until entries.length()).map { entries.getJSONObject(it) }.single { it.getString("target") == target }
            val bytes = loader("tessera-agent-host-$target")
            check(bytes.size in 1..(16 * 1024 * 1024) && bytes.size == entry.getInt("bytes"))
            val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            check(hash == entry.getString("sha256"))
            bytes to entry
        }
        val upload = UUID.randomUUID().toString().replace("-", "")
        fun request(operation: String) = JSONObject().put("operation", operation).put("upload", upload)
            .put("sha256", entry.getString("sha256")).put("bytes", artifact.size)
        try {
            check(invoke(request("begin")).getBoolean("ready"))
            for (offset in artifact.indices step 32768) {
                val chunk = artifact.copyOfRange(offset, minOf(artifact.size, offset + 32768))
                check(invoke(request("write").put("offset", offset).put("content", Base64.encodeToString(chunk, Base64.NO_WRAP))).getBoolean("written"))
            }
            check(invoke(request("activate")).getBoolean("installed"))
        } catch (failure: Throwable) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                runCatching { kotlinx.coroutines.withTimeout(5_000) { invoke(request("abort")) } }
            }
            throw failure
        }
    }

    override suspend fun readIntegrationConfigs(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentIntegrationConfigSnapshots> = executeIntegration(
        binding = binding,
        command = command,
        expected = AgentIntegrationOperation.READ_CONFIGS,
        failureCode = "integration_config_read_failed",
        parser = AgentIntegrationProtocol::parseConfigSnapshots,
    )

    override suspend fun inspectCurrentShell(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentCurrentShellStatus> = executeIntegration(
        binding = binding,
        command = command,
        expected = AgentIntegrationOperation.CURRENT_SHELL,
        failureCode = "current_shell_failed",
        parser = AgentIntegrationProtocol::parseCurrentShell,
    )

    override suspend fun discoverProcesses(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentProcessDiscoverySnapshot> {
        if (command.operation != AgentIntegrationOperation.PROCESS_DISCOVERY) {
            return AgentEndpointResult.Failed("invalid_integration_command")
        }
        val expectedScope = command.processDiscoveryScope
            ?: return AgentEndpointResult.Failed("invalid_process_discovery_scope")
        val freshScope = processDiscoveryScope(binding)
        val scope = (freshScope as? AgentEndpointResult.Success)?.value ?: return freshScope.asFailure()
        if (scope != expectedScope) return AgentEndpointResult.Failed("process_discovery_scope_changed")
        return executeIntegration(
            binding = binding,
            command = command,
            expected = AgentIntegrationOperation.PROCESS_DISCOVERY,
            failureCode = "process_discovery_failed",
            parser = { output -> AgentIntegrationProtocol.parseProcessDiscovery(scope, output) },
        )
    }

    override suspend fun observeOccupancy(
        bindings: List<AgentEndpointBinding>,
    ): AgentEndpointResult<AgentOccupancySnapshot> {
        val carrier = ingestionBinding
        if (!isCurrentIngestion(carrier) || bindings.isEmpty() || bindings.size > MAX_TRACKED_AGENT_PANES ||
            bindings.any { !it.copy(windowID = null, paneID = null).sameRouteAs(carrier) }) {
            return AgentEndpointResult.StaleBinding
        }
        return withTimeoutOrNull(15_000) {
            suspend fun inventory(scope: AgentProcessDiscoveryScope): AgentProcessDiscoverySnapshot? {
                if (!isCurrentIngestion(carrier)) return null
                val result = executeIntegration(binding.value, AgentProcessDiscoveryCommands.command(scope),
                    AgentIntegrationOperation.PROCESS_DISCOVERY, "process_discovery_failed",
                    parser = { AgentIntegrationProtocol.parseProcessDiscovery(scope, it) })
                return (result as? AgentEndpointResult.Success)?.value?.takeIf { isCurrentIngestion(carrier) }
            }
            // Discovery reports `comm` only: a Node launcher or a versioned
            // native binary names no provider, but its PID is still present.
            fun pane(id: String?, processes: AgentProcessDiscoverySnapshot): AgentOccupancyPane {
                val classified = processes.processes.associate { process ->
                    process.processID to SharedAgentProviderClassification.classify(listOf(SharedAgentProcessDescriptor(process.executable)))
                        .mapNotNull(AgentProofProvider::fromWire)
                }
                return AgentOccupancyPane(
                    id, exists = true, complete = !processes.truncated,
                    processes = classified.flatMap { (pid, providers) -> providers.map { AgentOccupancyProcess(pid, it) } },
                    unclassifiedPIDs = classified.filterValues { it.isEmpty() }.keys.sorted(),
                )
            }
            if (isRawTransport) {
                val scope = (processDiscoveryScope(binding.value) as? AgentEndpointResult.Success)?.value
                    ?: return@withTimeoutOrNull AgentEndpointResult.Unavailable("Process root is unavailable")
                val processes = inventory(scope) ?: return@withTimeoutOrNull AgentEndpointResult.Failed("occupancy_read_failed")
                return@withTimeoutOrNull AgentEndpointResult.Success(AgentOccupancySnapshot(listOf(pane(null, processes))))
            }
            val control = tmuxControl ?: return@withTimeoutOrNull AgentEndpointResult.Unavailable("tmux control is unavailable")
            val listed = parseAgentOccupancyPanes(control.send("list-panes -a -F '#{pane_id} #{pane_pid}'"))
                ?: return@withTimeoutOrNull AgentEndpointResult.Failed("occupancy_panes_failed")
            val panes = mutableListOf<AgentOccupancyPane>()
            for (id in bindings.map { it.paneID }.distinct()) {
                if (id == null || !validTmuxID(id, '%')) return@withTimeoutOrNull AgentEndpointResult.StaleBinding
                val root = listed.roots[id]
                if (root == null) {
                    if (listed.complete) panes.add(AgentOccupancyPane(id, exists = false, complete = true, emptyList()))
                    continue
                }
                val processes = inventory(AgentProcessDiscoveryScope.RootProcess(root)) ?: continue
                panes.add(pane(id, processes))
            }
            if (!isCurrentIngestion(carrier)) return@withTimeoutOrNull AgentEndpointResult.StaleBinding
            AgentEndpointResult.Success(AgentOccupancySnapshot(panes, listed.roots.keys.toList().takeIf { listed.complete }))
        } ?: AgentEndpointResult.Failed("occupancy_timeout")
    }

    override suspend fun activateCurrentShell(
        binding: AgentEndpointBinding,
        expectedProcessIDs: Set<Int>,
        command: AgentShellActivationCommand,
    ): AgentEndpointResult<Unit> {
        val fixedCommandBytes = command.payload
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (expectedProcessIDs.isEmpty() || expectedProcessIDs.size > MAX_DISCOVERY_PROCESS_IDS ||
            expectedProcessIDs.any { it <= 1 } || fixedCommandBytes.isEmpty() ||
            fixedCommandBytes.size > MAX_ACTIVATION_BYTES || fixedCommandBytes.any { it == 0.toByte() }
        ) return AgentEndpointResult.Failed("invalid_shell_activation")
        val scope = (processDiscoveryScope(binding) as? AgentEndpointResult.Success)?.value
            ?: return AgentEndpointResult.Unavailable("foreground shell proof is unavailable")
        val discovered = discoverProcesses(binding, AgentProcessDiscoveryCommands.command(scope))
        val foregroundShellIDs = (discovered as? AgentEndpointResult.Success)?.value
            ?.foregroundShellProcessIDs
            ?: return AgentEndpointResult.Failed("current_shell_unavailable")
        if (foregroundShellIDs.singleOrNull { it in expectedProcessIDs } == null) {
            return AgentEndpointResult.Failed("current_shell_changed")
        }
        // The payload is generated by Core and is complete; do not append a
        // second Enter or a caller-defined suffix after this freshness check.
        return sendInput(binding, fixedCommandBytes.copyOf())
    }

    override suspend fun proveProcess(
        binding: AgentEndpointBinding,
        claimedPID: Int,
        provider: AgentProofProvider,
        requireForeground: Boolean,
    ): AgentEndpointResult<AgentProcessProof> = withTimeoutOrNull(
        com.bambouville.tessera.core.bridge.SharedAgentReadRecoveryPolicy.processProofTimeoutMilliseconds,
    ) { proveProcessWithinDeadline(binding, claimedPID, provider, requireForeground) }
        ?: AgentEndpointResult.Failed("proof_timeout")

    private suspend fun proveProcessWithinDeadline(
        binding: AgentEndpointBinding,
        claimedPID: Int,
        provider: AgentProofProvider,
        requireForeground: Boolean,
    ): AgentEndpointResult<AgentProcessProof> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (claimedPID <= 1) return AgentEndpointResult.Failed("invalid_process")
        val request = JSONObject().put("v", 1).put("claimedPID", claimedPID).put("provider", provider.wireID)
        if (requireForeground) request.put("requireForeground", true)
        when (transport) {
            AgentEndpointTransport.SSH -> {
                val marker = routeMarker
                    ?: return AgentEndpointResult.Unavailable("remote server did not accept the route proof marker")
                request.put("routeMarker", marker)
            }
            AgentEndpointTransport.MOSH -> {
                val rootPID = processRootPID?.invoke()?.takeIf { it > 1 }
                    ?: return AgentEndpointResult.Unavailable("mosh process root is unavailable")
                request.put("rootPID", rootPID)
            }
            AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX -> {
                val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
                if (!validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
                val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
                val response = control.send("display-message -p -t $pane '#{pane_pid}'")
                val panePID = response.lines.asSequence().map(String::trim)
                    .firstNotNullOfOrNull(String::toIntOrNull)
                    ?.takeIf { it > 1 }
                    ?: return AgentEndpointResult.Failed("tmux_process_unavailable")
                request.put("rootPID", panePID)
            }
        }
        val opened = execute(
            binding,
            AgentExecRequest(
                executable = "tessera-agent-prove",
                stdin = request.toString().encodeToByteArray(),
                maxStdoutBytes = 16_384,
                maxStderrBytes = 4_096,
            ),
        )
        val stream = (opened as? AgentEndpointResult.Success)?.value ?: return opened.asFailure()
        return try {
            // Cancel the child before waiting for blocking SSH pipe/exit
            // readers. A timeout around coroutineScope alone waits for those
            // readers before it reaches the cancellation handler.
            val drained = AgentRemoteStreamDrain.drain(stream, 16_384,
                com.bambouville.tessera.core.bridge.SharedAgentReadRecoveryPolicy.processProofTimeoutMilliseconds)
            val complete = when (drained) {
                is AgentRemoteStreamDrain.Result.Complete -> drained
                AgentRemoteStreamDrain.Result.TimedOut -> return AgentEndpointResult.Failed("proof_timeout")
                is AgentRemoteStreamDrain.Result.Failed -> return AgentEndpointResult.Failed("proof_read_failed")
            }
            val output = complete.stdout
            val status = complete.exit
            if (status.code != 0) {
                // The helper reports why it refused on stdout ({"valid":false,
                // "error":X}); a dead or unrelated process is definitive, an
                // unreadable start time is not.
                val reason = runCatching { JSONObject(output.decodeToString()) }.getOrNull()
                    ?.takeIf { it.optInt("v") == 1 && !it.optBoolean("valid", true) }
                    ?.optString("error")?.takeIf { it.length in 1..64 && it.all(Char::isLetter) }
                return AgentEndpointResult.Failed("proof_exit_${status.code}", proofReason = reason)
            }
            val value = JSONObject(output.decodeToString())
            if (value.optInt("v") != 1) return AgentEndpointResult.Failed("proof_version=${value.optInt("v")}")
            if (!value.optBoolean("valid", false)) return AgentEndpointResult.Failed("proof_not_valid")
            if (value.optString("provider") != provider.wireID) {
                return AgentEndpointResult.Failed("proof_provider=${value.optString("provider")}/${provider.wireID}")
            }
            val ids = value.optJSONArray("processIDs") ?: return AgentEndpointResult.Failed("proof_no_process_ids")
            val processIDs = buildSet {
                for (index in 0 until minOf(ids.length(), 128)) {
                    ids.optInt(index, -1).takeIf { it > 1 }?.let(::add)
                }
            }
            val processStart = value.optString("processStart").takeIf {
                it.length in 1..128 && it.all { character -> character.code in 0x20..0x7e }
            } ?: return AgentEndpointResult.Failed("proof_no_process_start")
            if (claimedPID !in processIDs) AgentEndpointResult.Failed("proof_pid_unlisted=$claimedPID/$processIDs")
            else {
                // Capability upgrade is a consequence of independent proof,
                // never of the lifecycle frame that supplied the claimed PID.
                if (isRawTransport && rawWriter != null) {
                    mutableCapabilities.value = mutableCapabilities.value.copy(
                        freshTerminalObservation = true,
                        verifiedInput = true,
                        semanticKeys = true,
                        guardedFocus = true,
                        reason = null,
                    )
                }
                AgentEndpointResult.Success(AgentProcessProof(processIDs, provider, processStart))
            }
        } catch (failure: Throwable) {
            stream.cancel()
            if (failure is CancellationException) throw failure
            AgentEndpointResult.Failed("proof_threw:${failure::class.simpleName}")
        } finally {
            stream.close()
        }
    }

    override suspend fun processDiscoveryScope(
        binding: AgentEndpointBinding,
    ): AgentEndpointResult<AgentProcessDiscoveryScope> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        return when (transport) {
            AgentEndpointTransport.SSH -> routeMarker
                ?.let { AgentEndpointResult.Success(AgentProcessDiscoveryScope.RouteMarker(it)) }
                ?: AgentEndpointResult.Unavailable("remote server did not accept the route proof marker")
            AgentEndpointTransport.MOSH -> processRootPID?.invoke()?.takeIf { it > 1 }
                ?.let { AgentEndpointResult.Success(AgentProcessDiscoveryScope.RootProcess(it)) }
                ?: AgentEndpointResult.Unavailable("mosh process root is unavailable")
            AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX -> {
                val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
                if (!validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
                val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
                val panePID = control.send("display-message -p -t $pane '#{pane_pid}'")
                    .lines.asSequence().map(String::trim).firstNotNullOfOrNull(String::toIntOrNull)
                    ?.takeIf { it > 1 }
                    ?: return AgentEndpointResult.Failed("tmux_process_unavailable")
                AgentEndpointResult.Success(AgentProcessDiscoveryScope.RootProcess(panePID))
            }
        }
    }

    override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (!isTmuxTransport) {
            // A raw route has no control-mode pane path proof. Do not broaden
            // the exec allow-list with `pwd` or guess from terminal text.
            return AgentEndpointResult.Unavailable("launch requires a proven SSH+tmux pane directory")
        }
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
        if (!validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
        val response = control.send("display-message -p -t $pane '#{pane_current_path}'")
        val directory = response.lines.asSequence().map(String::trim).firstOrNull(::validRemoteDirectory)
            ?: return AgentEndpointResult.Failed("pane_directory_unavailable")
        return AgentEndpointResult.Success(listOf(directory))
    }

    override suspend fun uploadAttachment(binding: AgentEndpointBinding, sourceURI: String): AgentEndpointResult<String> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        val upload = attachmentUpload ?: return AgentEndpointResult.Unavailable("File uploads are unavailable")
        val uploadRoute = try { auxiliaryRoute?.acquire() ?: originalRoute }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Throwable) { return AgentEndpointResult.Failed("attachment_route_unavailable") }
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        // Success describes a file transfer, not fresh terminal authority. The
        // caller rechecks the originating thread before inserting this path.
        return upload(uploadRoute, sourceURI)
    }

    // Proved pane-targeted replies leave grid authority unchanged.
    override fun inputRefusal(binding: AgentEndpointBinding): String? = when {
        !matches(binding) -> "stale_binding"
        isRawTransport && rawWriter == null -> "raw_input_unavailable"
        transport == AgentEndpointTransport.SSH && !originalRoute.isConnected -> "raw_input_unavailable"
        else -> null
    }

    private fun placementRefusal(): String? =
        if (tmuxControl?.mutationRefusal() != null) TMUX_CONTROLLED_ELSEWHERE else null

    override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
        if (!matches(binding)) return AgentEndpointResult.Failed("staleBinding", inputNotAdmitted = true)
        if (bytes.isEmpty() || bytes.size > MAX_INPUT_BYTES) return AgentEndpointResult.Failed("invalid_input")
        return when (transport) {
            AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH -> rawWriter?.let { writer ->
                if (transport == AgentEndpointTransport.SSH && !originalRoute.isConnected) {
                    return AgentEndpointResult.Failed("raw_input_unavailable", inputNotAdmitted = true)
                }
                try {
                    writer(bytes.copyOf())
                    AgentEndpointResult.Success(Unit)
                } catch (_: MoshInputNotAdmittedException) {
                    AgentEndpointResult.Failed("raw_input_unavailable", inputNotAdmitted = true)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    AgentEndpointResult.Failed("raw_write_failed")
                }
            } ?: AgentEndpointResult.Failed("raw_input_unavailable", inputNotAdmitted = true)
            AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX -> sendTmuxBytes(binding, bytes)
        }
    }

    override suspend fun sendSemanticKey(
        binding: AgentEndpointBinding,
        key: AgentSemanticKey,
    ): AgentEndpointResult<Unit> {
        if (!isTmuxTransport) return sendInput(binding, key.encoded())
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
        if (!validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
        val name = key.tmuxName
        return if (control.send("send-keys -t $pane $name").success) AgentEndpointResult.Success(Unit)
        else AgentEndpointResult.Failed("tmux_write_failed")
    }

    override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = focus(binding) { true }

    override suspend fun focus(binding: AgentEndpointBinding, isCurrentRequest: () -> Boolean): AgentEndpointResult<Unit> {
        if (!isCurrentRequest() || !matches(binding)) return AgentEndpointResult.StaleBinding
        if (!isTmuxTransport) return AgentEndpointResult.Unavailable("raw transport has one focused terminal")
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val window = binding.windowID ?: return AgentEndpointResult.StaleBinding
        val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
        if (!validTmuxID(window, '@') || !validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
        placementRefusal()?.let { return AgentEndpointResult.Failed(it) }
        val selectWindow = control.selectWindow(window)
        if (!selectWindow.success) return AgentEndpointResult.Failed(placementRefusal() ?: "tmux_focus_failed")
        if (!isCurrentRequest() || !matches(binding)) return AgentEndpointResult.StaleBinding
        placementRefusal()?.let { return AgentEndpointResult.Failed(it) }
        val selectPane = control.selectPane(pane, preservingWindowZoom = true)
        return if (!isCurrentRequest() || !matches(binding)) AgentEndpointResult.StaleBinding
        else if (selectPane.success) AgentEndpointResult.Success(Unit)
        else AgentEndpointResult.Failed(placementRefusal() ?: "tmux_focus_failed")
    }

    override suspend fun placeTmux(
        binding: AgentEndpointBinding,
        placement: AgentTmuxPlacement,
    ): AgentEndpointResult<AgentTmuxPlacementReceipt> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (!isTmuxTransport) return AgentEndpointResult.Unavailable("spawn and fork require tmux")
        // The sender refuses it regardless; this names the reason (D13).
        placementRefusal()?.let { return AgentEndpointResult.Failed(it) }
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val command = when (placement) {
            is AgentTmuxPlacement.NewWindow -> {
                SharedTmuxCommands.newWindowAtEnd(
                    name = placement.name?.takeIf { it.isNotBlank() }?.take(128),
                    printFormat = PLACEMENT_FORMAT,
                )
            }
            is AgentTmuxPlacement.Split -> {
                if (!validTmuxID(placement.targetPaneID, '%')) return AgentEndpointResult.StaleBinding
                "split-window ${if (placement.vertical) "-v" else "-h"} -P -F '$PLACEMENT_FORMAT' -t ${placement.targetPaneID}"
            }
        }
        val response = control.send(command)
        if (!response.success) return AgentEndpointResult.Failed("tmux_placement_failed")
        val receipt = response.lines.asSequence().mapNotNull(::parsePlacement).firstOrNull()
            ?: return AgentEndpointResult.Failed("tmux_placement_unacknowledged")
        return AgentEndpointResult.Success(receipt)
    }

    override suspend fun launchTmux(
        binding: AgentEndpointBinding,
        placement: AgentTmuxPlacement,
        requestID: String,
        request: ByteArray,
    ): AgentEndpointResult<AgentTmuxLaunchReceipt> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (!isTmuxTransport) return AgentEndpointResult.Unavailable("spawn and fork require tmux")
        if (runCatching { UUID.fromString(requestID) }.isFailure || request.isEmpty() || request.size > 65_536) {
            return AgentEndpointResult.Failed("invalid_launch_request")
        }
        placementRefusal()?.let { return AgentEndpointResult.Failed(it) }
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val buffer = "tessera-agent-launch-${requestID.lowercase()}"
        val encoded = Base64.encodeToString(request, Base64.NO_WRAP)
        if (!control.send("set-buffer -b $buffer '$encoded'").success) {
            return AgentEndpointResult.Failed("tmux_buffer_failed")
        }
        val helper = "{ tmux show-buffer -b $buffer; tmux delete-buffer -b $buffer; } | \"\$HOME/.config/tessera/tessera-agent-launch\" --request-base64-stdin"
        val command = when (placement) {
            is AgentTmuxPlacement.NewWindow -> {
                SharedTmuxCommands.newWindowAtEnd(
                    detached = true,
                    name = placement.name?.takeIf { it.isNotBlank() }?.take(128),
                    printFormat = PLACEMENT_FORMAT,
                    command = helper,
                )
            }
            is AgentTmuxPlacement.Split -> {
                if (!validTmuxID(placement.targetPaneID, '%')) {
                    control.send("delete-buffer -b $buffer")
                    return AgentEndpointResult.StaleBinding
                }
                "split-window -d ${if (placement.vertical) "-v" else "-h"} -P -F '$PLACEMENT_FORMAT' -t ${placement.targetPaneID} ${tmuxQuote(helper)}"
            }
        }
        val placed = control.send(command)
        val placementReceipt = placed.lines.asSequence().mapNotNull(::parsePlacement).firstOrNull()
        if (!placed.success || placementReceipt == null) {
            control.send("delete-buffer -b $buffer")
            return AgentEndpointResult.Failed("tmux_placement_unacknowledged")
        }
        val receipt = pollTmuxUntil(
            attempts = 50,
            intervalMillis = 100,
            budgetMillis = TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS,
            poll = { control.send("show-options -p -v -t ${placementReceipt.paneID} @tessera_agent_launch_receipt") },
        ) { response ->
            response.lines.asSequence().mapNotNull { line ->
                runCatching { JSONObject(line) }.getOrNull()
            }.firstOrNull { value ->
                value.optInt("v") == 1 && value.optString("kind") == "launchReceipt" &&
                    value.optString("requestID").equals(requestID, ignoreCase = true)
            }
        } ?: return AgentEndpointResult.Failed("launch_receipt_missing")
        return AgentEndpointResult.Success(
            AgentTmuxLaunchReceipt(
                requestID = requestID,
                windowID = placementReceipt.windowID,
                paneID = placementReceipt.paneID,
                worktreeCreated = receipt.optBoolean("worktreeCreated", false),
            ),
        )
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        lifecycleDeliveryScope.cancel()
        auxiliaryRoute?.close()
        execBindingGate.close()
        mutableCapabilities.value = AgentEndpointCapabilities(reason = "session closed")
        synchronized(tails) {
            tails.clear()
            scanners.clear()
            tmuxAddresses.clear()
            lastAgentStateJSON.clear()
            pendingLifecycleFrames.clear()
            lifecycleDrain = null
        }
    }

    /**
     * Every integration action opens a child non-PTY channel on [route]. This
     * makes SSH, SSH+tmux, mosh, and mosh+tmux use one authenticated side
     * channel and avoids injecting a probe or installer into the visible PTY.
     */
    private fun noteExec(executable: String) {
        diagnostics?.invoke(
            "agent_exec_open",
            mapOf(
                "op" to executable,
                "opened" to execOpens.incrementAndGet().toString(),
                "active" to route.activeExecChannels.toString(),
                "transport" to transport.name,
            ),
        )
    }

    private suspend fun openExec(request: SshExecRequest): SshExecStream {
        val candidate = auxiliaryRoute?.acquire() ?: originalRoute
        try {
            return candidate.execute(request)
        } catch (failure: Throwable) {
            if (failure !is CancellationException && sshExecFailureNeedsNewRoute(failure)) {
                auxiliaryRoute?.invalidate(candidate)
                retireFailedControlRoute?.invoke(candidate)
            }
            throw failure
        }
    }

    private suspend fun <T> executeIntegration(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
        expected: AgentIntegrationOperation,
        failureCode: String,
        parser: (ByteArray) -> T?,
    ): AgentEndpointResult<T> {
        if (!matches(binding)) return AgentEndpointResult.StaleBinding
        if (command.operation != expected) return AgentEndpointResult.Failed("invalid_integration_command")
        if (!capabilities.value.remoteData) {
            return AgentEndpointResult.Unavailable(capabilities.value.reason ?: "remote data unavailable")
        }
        val startedAt = System.nanoTime()
        val execLease = execBindingGate.acquire(binding, execChannels) { matches(binding) }
            ?: return AgentEndpointResult.StaleBinding
        if (!matches(binding)) { execLease.close(); return AgentEndpointResult.StaleBinding }
        val acquiredAt = System.nanoTime()
        var stage = "open"
        var outcome = "cancelled"
        var stream: SshExecStream? = null
        return try {
            val payload = command.payload
            noteExec("tessera-agent-integration")
            val opened = openExec(
                SshExecRequest(
                    operation = SshRemoteOperation.AGENT_INTEGRATION_SHELL,
                    maxStdinBytes = payload.size,
                    maxStdoutBytes = command.maxStdoutBytes,
                    maxStderrBytes = command.maxStderrBytes,
                ),
            )
            stream = opened
            stage = "write"
            for (offset in payload.indices step SshExecRequest.DEFAULT_MAX_STDIN_BYTES) {
                val end = minOf(offset + SshExecRequest.DEFAULT_MAX_STDIN_BYTES, payload.size)
                opened.writeStdin(payload.copyOfRange(offset, end))
            }
            opened.closeStdin()
            stage = "drain"
            val result = when (
                val drained = AgentRemoteStreamDrain.drain(
                    stream = SshAgentRemoteExecStream(opened),
                    maxStdoutBytes = command.maxStdoutBytes,
                    timeoutMillis = INTEGRATION_TIMEOUT_MILLIS,
                )
            ) {
                is AgentRemoteStreamDrain.Result.Complete -> {
                    stage = "parse"
                    if (drained.exit.code != 0) AgentEndpointResult.Failed(failureCode)
                    else parser(drained.stdout)?.let { AgentEndpointResult.Success(it) }
                        ?: AgentEndpointResult.Failed("${failureCode}_malformed")
                }
                AgentRemoteStreamDrain.Result.TimedOut -> AgentEndpointResult.Failed("${failureCode}_timeout")
                is AgentRemoteStreamDrain.Result.Failed -> AgentEndpointResult.Failed(failureCode)
            }
            outcome = when (result) {
                is AgentEndpointResult.Success -> "success"
                is AgentEndpointResult.Failed -> result.code
                else -> "unavailable"
            }
            result
        } catch (failure: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { stream?.cancel() }
            if (failure is CancellationException) throw failure
            outcome = sshExecFailureCode(failure)
            AgentEndpointResult.Failed(failureCode)
        } finally {
            execLease.close()
            // Never include stdout, stderr, command payloads, or remote paths.
            diagnostics?.invoke(
                "agent_integration_exec",
                mapOf(
                    "op" to expected.name,
                    "stage" to stage,
                    "outcome" to outcome,
                    "active" to route.activeExecChannels.toString(),
                    "transport" to transport.name,
                    "queueMs" to ((acquiredAt - startedAt) / 1_000_000).toString(),
                    "elapsedMs" to ((System.nanoTime() - startedAt) / 1_000_000).toString(),
                ),
            )
        }
    }

    private suspend fun sendTmuxBytes(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
        val control = tmuxControl ?: return AgentEndpointResult.Unavailable("tmux control is unavailable")
        val pane = binding.paneID ?: return AgentEndpointResult.StaleBinding
        if (!validTmuxID(pane, '%')) return AgentEndpointResult.StaleBinding
        for (chunk in bytes.asList().chunked(MAX_TMUX_INPUT_BYTES)) {
            val hex = chunk.joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
            if (!control.send("send-keys -t $pane -H $hex").success) return AgentEndpointResult.Failed("tmux_write_failed")
        }
        return AgentEndpointResult.Success(Unit)
    }

    private fun noteOutput(target: String, address: AgentEndpointBinding, bytes: ByteArray) {
        if (closed.get() || bytes.isEmpty()) return
        val frames = synchronized(tails) {
            tails.getOrPut(target) { BoundedTail() }.append(bytes)
            scanners.getOrPut(target) { AgentLifecycleOscScanner() }.feed(bytes)
        }
        frames.forEach { frame -> mutableLifecycleFrames.tryEmit(AgentLifecycleFrame(address, frame.copyOf())) }
    }

    override fun isCurrentRoute(candidate: AgentEndpointBinding): Boolean = matches(candidate)

    private fun matches(candidate: AgentEndpointBinding): Boolean {
        val current = binding.value
        if (closed.get() || candidate.key != current.key || candidate.hostID != current.hostID ||
            candidate.transport != current.transport || candidate.tmuxSession != current.tmuxSession) return false
        if (isRawTransport) return candidate.sameRouteAs(current)
        if (candidate.paneID == null) return candidate.sameRouteAs(current)
        return synchronized(tails) { tmuxAddresses[candidate.paneID]?.sameRouteAs(candidate) == true }
    }

    private fun parsePlacement(line: String): AgentTmuxPlacementReceipt? {
        val parts = line.split('\t')
        if (parts.size != 3 || parts[0] != PLACEMENT_MARKER || !validTmuxID(parts[1], '@') || !validTmuxID(parts[2], '%')) return null
        return AgentTmuxPlacementReceipt(parts[1], parts[2])
    }

    private fun validTmuxID(value: String, prefix: Char): Boolean =
        value.length in 2..32 && value.firstOrNull() == prefix && value.drop(1).all(Char::isDigit)

    private fun validRemoteDirectory(value: String): Boolean =
        value.isNotEmpty() && value.encodeToByteArray().size <= 2_048 &&
            (value.startsWith('/') || value.startsWith("~/")) &&
            value.none { it == '\u0000' || it.code < 0x20 || it.code == 0x7f } &&
            value.split('/').none { it == ".." }

    private fun tmuxQuote(value: String): String = "'" + value.replace("'", "'\"'\"'") + "'"

    private val isRawTransport: Boolean
        get() = transport == AgentEndpointTransport.SSH || transport == AgentEndpointTransport.MOSH

    private val isTmuxTransport: Boolean
        get() = transport == AgentEndpointTransport.SSH_TMUX || transport == AgentEndpointTransport.MOSH_TMUX

    private class BoundedTail {
        private var bytes = ByteArray(0)
        private var truncated = false
        fun append(incoming: ByteArray) {
            val boundedIncoming = if (incoming.size <= MAX_TAIL_BYTES) incoming else {
                truncated = true
                incoming.copyOfRange(incoming.size - MAX_TAIL_BYTES, incoming.size)
            }
            val combined = if (bytes.size + boundedIncoming.size <= MAX_TAIL_BYTES) bytes + boundedIncoming
            else (bytes + boundedIncoming).takeLast(MAX_TAIL_BYTES).toByteArray()
            truncated = truncated || combined.size < bytes.size + boundedIncoming.size
            bytes = combined
        }
        fun replace(incoming: ByteArray) {
            bytes = incoming.copyOf()
            truncated = false
        }
        fun snapshot() = Snapshot(bytes.copyOf(), truncated)
        data class Snapshot(val bytes: ByteArray, val truncated: Boolean)
    }

    private companion object {
        const val MAX_INPUT_BYTES = 256 * 1024
        const val MAX_TMUX_INPUT_BYTES = 256
        /** A tmux reply refused before its first byte because another device holds the grid (D7). */
        const val TMUX_CONTROLLED_ELSEWHERE = "tmux_controlled_elsewhere"
        const val MAX_DISCOVERY_PROCESS_IDS = 128
        const val MAX_ACTIVATION_BYTES = 65_536
        const val INTEGRATION_TIMEOUT_MILLIS = 10_000L
        const val MAX_TAIL_BYTES = 64 * 1024
        const val MAX_CURRENT_LINE_BYTES = 2 * 1024

        /** The row's first MAX_CURRENT_LINE_BYTES chars, never half a surrogate pair. */
        fun cursorLinePrefix(line: String): String {
            val prefix = line.take(MAX_CURRENT_LINE_BYTES)
            return if (prefix.length < line.length && prefix.last().isHighSurrogate()) prefix.dropLast(1) else prefix
        }

        /**
         * Panes whose last lifecycle payload is remembered for the repeat
         * check. Forgetting costs one repeated frame per pane and only on a
         * session larger than any real one.
         */
        const val MAX_TRACKED_AGENT_PANES = 256
        /**
         * Four leaves room under the OpenSSH default of ten for the carrier's
         * own tmux control channel and for a reconnect overlapping a teardown,
         * while still letting an inventory refresh overlap a proof.
         */
        const val MAX_CONCURRENT_EXEC_CHANNELS = 4
        const val PLACEMENT_MARKER = "__tessera_agent_placement__"
        const val PLACEMENT_FORMAT = "__tessera_agent_placement__\t#{window_id}\t#{pane_id}"

        fun capabilitiesFor(
            transport: AgentEndpointTransport,
            rawWriter: (suspend (ByteArray) -> Unit)?,
            tmuxControl: TmuxAgentControlPort?,
        ): AgentEndpointCapabilities = when (transport) {
            AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH -> AgentEndpointCapabilities(
                lifecycleFeed = true,
                freshTerminalObservation = false,
                remoteData = true,
                verifiedInput = false,
                semanticKeys = false,
                reason = if (rawWriter == null) "raw terminal route unavailable" else
                    "raw transport has no authoritative prompt capture yet",
            )
            AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX -> AgentEndpointCapabilities(
                lifecycleFeed = true,
                freshTerminalObservation = true,
                remoteData = true,
                verifiedInput = tmuxControl != null,
                semanticKeys = tmuxControl != null,
                guardedFocus = tmuxControl != null,
                acknowledgedTmuxPlacement = tmuxControl != null,
                reason = if (tmuxControl == null) "tmux control route unavailable" else null,
            )
        }
    }
}

internal data class AgentOccupancyPaneList(val roots: Map<String, Int>, val complete: Boolean)

internal fun parseAgentOccupancyPanes(reply: AgentTmuxControlAck, limit: Int = 256): AgentOccupancyPaneList? {
    if (!reply.success) return null
    val roots = linkedMapOf<String, Int>()
    for (line in reply.lines.take(limit)) {
        val fields = line.trim().split(Regex("\\s+"))
        if (fields.size != 2 || !fields[0].matches(Regex("%[0-9]+"))) return null
        val pid = fields[1].toIntOrNull()?.takeIf { it > 1 } ?: return null
        if (roots.put(fields[0], pid) != null) return null
    }
    return AgentOccupancyPaneList(roots, complete = reply.lines.size <= limit)
}

/**
 * How long a launch waits for its receipt. An unanswered tmux command fails
 * its ack only after the control port's 15 s timeout instead of throwing, so
 * the poll count alone no longer bounds the wait.
 */
internal const val TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS = 15_000L

/**
 * Sends [poll] until [found] reads an answer: at most [attempts] times,
 * [intervalMillis] apart, and never past [budgetMillis] however slowly each
 * ack arrives. Running out is a missing answer (null), not the caller's
 * cancellation, which still propagates.
 */
internal suspend fun <T : Any> pollTmuxUntil(
    attempts: Int,
    intervalMillis: Long,
    budgetMillis: Long,
    poll: suspend () -> AgentTmuxControlAck,
    found: (AgentTmuxControlAck) -> T?,
): T? = withTimeoutOrNull(budgetMillis) {
    repeat(attempts) {
        found(poll())?.let { return@withTimeoutOrNull it }
        delay(intervalMillis)
    }
    null
}

private fun <T> AgentEndpointResult<*>.asFailure(): AgentEndpointResult<T> = when (this) {
    AgentEndpointResult.StaleBinding -> AgentEndpointResult.StaleBinding
    is AgentEndpointResult.Unavailable -> this
    is AgentEndpointResult.Failed -> this
    is AgentEndpointResult.Success -> AgentEndpointResult.Failed("invalid_endpoint_result")
}

private fun String.toSshOperation(): SshRemoteOperation = when (this) {
    "tessera-agent-host" -> SshRemoteOperation.AGENT_HOST
    "tessera-agent-project" -> SshRemoteOperation.AGENT_PROJECT
    "tessera-agent-launch" -> SshRemoteOperation.AGENT_LAUNCH
    "tessera-agent-prove" -> SshRemoteOperation.AGENT_PROVE
    else -> error("unsupported agent executable")
}

internal class SshAgentRemoteExecStream(
    private val stream: SshExecStream,
    private val onClose: () -> Unit = {},
) : AgentRemoteExecStream {
    private val closed = AtomicBoolean(false)
    override val stdout: Flow<ByteArray> = stream.stdout()
    override val stderr: Flow<ByteArray> = stream.stderr()
    override suspend fun awaitExit(): AgentExecExitStatus = AgentExecExitStatus(stream.awaitExit().code)
    override suspend fun send(bytes: ByteArray) = stream.writeStdin(bytes)
    override fun cancel() = finish(cancelled = true)
    override fun close() = finish(cancelled = false)
    private fun finish(cancelled: Boolean) {
        if (!closed.compareAndSet(false, true)) return
        try {
            if (cancelled) stream.cancel() else stream.close()
        } finally {
            onClose()
        }
    }
}

/**
 * Allows independent helpers in one carrier generation to share admission,
 * while placing a drain barrier between incompatible generations. Exact pane
 * currency is checked by the endpoint before and after channel admission.
 */
internal class AgentExecBindingGate<T>(private val canShare: (T, T) -> Boolean = { first, next -> first == next }) {
    private val lock = Any()
    private val active = linkedMapOf<T, Int>()
    private val mutableVersion = MutableStateFlow(0L)
    private var closed = false

    suspend fun acquire(binding: T, channels: Semaphore, isValid: () -> Boolean): AutoCloseable? {
        val bindingLease = acquire(binding, isValid) ?: return null
        try {
            channels.acquire()
        } catch (failure: Throwable) {
            // A cancelled channel waiter must not keep the old pane reserved.
            // Semaphore.acquire returns its permit on cancellation itself.
            bindingLease.close()
            throw failure
        }
        return Lease {
            channels.release()
            bindingLease.close()
        }
    }

    suspend fun acquire(binding: T, isValid: () -> Boolean = { true }): AutoCloseable? {
        while (isValid()) {
            val observedVersion = mutableVersion.value
            val acquired = synchronized(lock) {
                if (closed) {
                    null
                } else if (active.keys.all { canShare(it, binding) }) {
                    active[binding] = active.getOrDefault(binding, 0) + 1
                    true
                } else {
                    false
                }
            }
            if (acquired == null) return null
            if (acquired) return Lease { release(binding) }
            mutableVersion.first { it != observedVersion }
        }
        return null
    }

    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            mutableVersion.value = mutableVersion.value + 1
        }
    }

    private fun release(binding: T) {
        synchronized(lock) {
            val count = active[binding] ?: return
            if (count == 1) active.remove(binding) else active[binding] = count - 1
            mutableVersion.value = mutableVersion.value + 1
        }
    }

    private class Lease(private val release: () -> Unit) : AutoCloseable {
        private val closed = AtomicBoolean(false)
        override fun close() {
            if (closed.compareAndSet(false, true)) release()
        }
    }
}

/** The host holds a newer app's integration; see Core's install refusal. */
private class NewerIntegrationInstalled : Exception()
