package com.bambouville.tessera.agent.platform

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import com.bambouville.tessera.core.bridge.AgentIntegrationConfigSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationCommands
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationParsing
import com.bambouville.tessera.core.bridge.SharedAgentProcessDiscoveryScope

/**
 * Transport-neutral Android boundary for a live Agent Center terminal route.
 *
 * This module intentionally exposes only bounded values and streams. SSHJ,
 * terminal Views, provider JSON, and JNI handles remain below or above it.
 */
data class AgentSessionKey(
    val liveSessionID: String,
    val carrierGeneration: Long,
) {
    init {
        require(liveSessionID.length in 1..128)
        require(carrierGeneration > 0)
    }
}

enum class AgentEndpointTransport { SSH, SSH_TMUX, MOSH, MOSH_TMUX }

/**
 * Provider identity carried from a validated lifecycle frame into the
 * lower-layer process proof.  A PID is never meaningful without this exact
 * provider constraint: any ordinary descendant of a shell is otherwise a
 * plausible forged OSC target.
 */
enum class AgentProofProvider(val wireID: String) {
    CLAUDE("claude"),
    CODEX("codex"),
    KIMI("kimi");

    companion object {
        fun fromWire(value: String): AgentProofProvider? = entries.firstOrNull { it.wireID == value }
    }
}

data class AgentEndpointBinding(
    val key: AgentSessionKey,
    val hostID: String,
    val transport: AgentEndpointTransport,
    val tmuxSession: String? = null,
    val windowID: String? = null,
    val paneID: String? = null,
    val hostDisplayLabel: String = hostID,
) {
    /** Display metadata is not part of the Core-issued terminal address. */
    fun sameRouteAs(other: AgentEndpointBinding): Boolean =
        key == other.key && hostID == other.hostID && transport == other.transport &&
            tmuxSession == other.tmuxSession && windowID == other.windowID && paneID == other.paneID
}

/** Capabilities are deliberately false until the endpoint can prove them. */
data class AgentEndpointCapabilities(
    val lifecycleFeed: Boolean = false,
    val freshTerminalObservation: Boolean = false,
    val remoteData: Boolean = false,
    val verifiedInput: Boolean = false,
    val semanticKeys: Boolean = false,
    val guardedFocus: Boolean = false,
    val acknowledgedTmuxPlacement: Boolean = false,
    val reason: String? = null,
)

data class AgentLifecycleFrame(
    val binding: AgentEndpointBinding,
    /** Opaque, bounded decoded JSON bytes. TesseraAgentCore performs validation. */
    val payload: ByteArray,
)

data class AgentTerminalObservation(
    val binding: AgentEndpointBinding,
    val visibleTail: ByteArray,
    val truncated: Boolean,
    /** True only when the endpoint just captured the exact tmux pane. */
    val authoritative: Boolean,
    /** Current terminal cursor row, never inferred from a persisted transcript. */
    val currentCursorLine: String? = null,
    /** Physical row in this same coherent visible capture; disambiguates blank/wrapped input. */
    val cursorRow: Int? = null,
    val cursorVisible: Boolean? = null,
    /** Physical cell column in this capture; a suggestion is not typed input. */
    val cursorColumn: Int? = null,
    val screenEvidence: com.bambouville.tessera.core.bridge.SharedTerminalScreenEvidence? = null,
    /** Re-prove the process and recapture before mutation after a frame wait. */
    val captureWaitedForFrame: Boolean = false,
)

data class AgentExecRequest(
    val executable: String,
    val stdin: ByteArray = ByteArray(0),
    val maxStdoutBytes: Int = DEFAULT_MAX_STDOUT_BYTES,
    val maxStderrBytes: Int = DEFAULT_MAX_STDERR_BYTES,
) {
    init {
        require(executable.length in 1..256 && executable.first().isLetterOrDigit())
        require(executable.all { it.isLetterOrDigit() || it in "._-" })
        require(executable in setOf("tessera-agent-project", "tessera-agent-launch", "tessera-agent-prove", "tessera-agent-host"))
        require(stdin.size <= MAX_STDIN_BYTES)
        require(maxStdoutBytes in 1..MAX_TOTAL_BYTES)
        require(maxStderrBytes in 1..MAX_TOTAL_BYTES)
        require(maxStdoutBytes <= MAX_TOTAL_BYTES - maxStderrBytes)
    }

    companion object {
        const val MAX_TOTAL_BYTES = 1_048_576
        const val MAX_STDIN_BYTES = 262_144
        const val DEFAULT_MAX_STDOUT_BYTES = 262_144
        const val DEFAULT_MAX_STDERR_BYTES = 16_384
    }
}

/**
 * The only integration jobs that may run through the authenticated SSH side
 * channel.  Core owns the shell program payload; platform code selects only
 * this semantic operation, never a remote command line.
 */
enum class AgentIntegrationOperation {
    PROBE,
    READ_CONFIGS,
    INSTALL,
    CURRENT_SHELL,
    PROCESS_DISCOVERY,
}

/**
 * A process-tree root that the shared core must carry into a discovery script.
 * It deliberately cannot name an arbitrary user PID: raw SSH uses the route
 * marker accepted by the interactive carrier, while mosh and tmux expose only
 * roots already owned by the live route.
 */
sealed interface AgentProcessDiscoveryScope {
    data class RouteMarker(val marker: String) : AgentProcessDiscoveryScope {
        init { require(marker.matches(Regex("[A-Fa-f0-9-]{36}"))) }
    }

    data class RootProcess(val processID: Int) : AgentProcessDiscoveryScope {
        init { require(processID > 1) }
    }
}

internal fun AgentProcessDiscoveryScope.toSharedScope(): SharedAgentProcessDiscoveryScope = when (this) {
    is AgentProcessDiscoveryScope.RouteMarker -> SharedAgentProcessDiscoveryScope.RouteMarker(marker)
    is AgentProcessDiscoveryScope.RootProcess -> SharedAgentProcessDiscoveryScope.RootProcess(processID)
}

/**
 * BSD `ps` does not expose Linux's `tpgid` column. Its `stat` column instead
 * includes `+` for members of the foreground process group of their
 * controlling TTY. A shell is actionable only when it is also that group's
 * leader, so a foreground child cannot make an ancestor shell look current.
 */
internal object AgentBsdForegroundTtyStrategy {
    fun syntheticTerminalProcessGroup(processGroupID: Int, stat: String): Int =
        if (processGroupID > 1 && stat.contains('+')) processGroupID else -1

    fun isForegroundGroupLeader(processID: Int, processGroupID: Int, stat: String): Boolean =
        processID > 1 && processID == processGroupID &&
            syntheticTerminalProcessGroup(processGroupID, stat) == processGroupID
}

/** Android carries only a validated route marker/root PID into the Core ABI.
 * The process-tree script itself is an opaque Core-owned payload. */
object AgentProcessDiscoveryCommands {
    fun command(scope: AgentProcessDiscoveryScope): AgentIntegrationCommand {
        return AgentIntegrationCommand.processDiscovery(
            scope,
            SharedAgentIntegrationCommands.processDiscoveryCommand(scope.toSharedScope()).encodeToByteArray(),
        )
    }
}

/**
 * Opaque, bounded stdin produced by the shared core integration-command
 * builder.  It is deliberately not a command-string API: the networking
 * layer always runs its one fixed integration shell entrypoint.
 */
class AgentIntegrationCommand private constructor(
    val operation: AgentIntegrationOperation,
    payload: ByteArray,
    val maxStdoutBytes: Int,
    val maxStderrBytes: Int,
    val processDiscoveryScope: AgentProcessDiscoveryScope? = null,
) {
    private val storedPayload = payload.copyOf()
    /** A fresh copy prevents a caller from mutating an already-validated payload. */
    val payload: ByteArray get() = storedPayload.copyOf()

    init {
        require(payload.isNotEmpty() && payload.size <= MAX_STDIN_BYTES)
        require(payload.none { it == 0.toByte() })
        require(maxStdoutBytes in 1..MAX_OUTPUT_BYTES)
        require(maxStderrBytes in 1..MAX_OUTPUT_BYTES)
        require(maxStdoutBytes <= MAX_OUTPUT_BYTES - maxStderrBytes)
        require((operation == AgentIntegrationOperation.PROCESS_DISCOVERY) == (processDiscoveryScope != null))
    }

    companion object {
        // The shared installer may carry three bounded one-megabyte provider
        // snapshots plus shell quoting overhead. Keep the side-channel ceiling
        // explicit while leaving ordinary projector stdin at 256 KiB.
        const val MAX_STDIN_BYTES = 33_554_432
        // Three config reads are individually capped at 1 MiB, while base64
        // framing expands each present snapshot by 4/3. Keep this separate
        // from the ordinary 1 MiB Agent-runtime payload ceiling.
        const val MAX_OUTPUT_BYTES = 8_388_608

        internal fun probe(payload: ByteArray) = AgentIntegrationCommand(
            operation = AgentIntegrationOperation.PROBE,
            payload = payload,
            maxStdoutBytes = 16_384,
            maxStderrBytes = 16_384,
        )

        internal fun install(payload: ByteArray) = AgentIntegrationCommand(
            operation = AgentIntegrationOperation.INSTALL,
            payload = payload,
            maxStdoutBytes = 32_768,
            maxStderrBytes = 32_768,
        )

        internal fun readConfigs(payload: ByteArray) = AgentIntegrationCommand(
            operation = AgentIntegrationOperation.READ_CONFIGS,
            payload = payload,
            maxStdoutBytes = MAX_OUTPUT_BYTES - 16_384,
            maxStderrBytes = 16_384,
        )

        internal fun currentShell(payload: ByteArray) = AgentIntegrationCommand(
            operation = AgentIntegrationOperation.CURRENT_SHELL,
            payload = payload,
            maxStdoutBytes = 8_192,
            maxStderrBytes = 8_192,
        )

        internal fun processDiscovery(
            scope: AgentProcessDiscoveryScope,
            payload: ByteArray,
        ) = AgentIntegrationCommand(
            operation = AgentIntegrationOperation.PROCESS_DISCOVERY,
            payload = payload,
            maxStdoutBytes = 65_536,
            maxStderrBytes = 16_384,
            processDiscoveryScope = scope,
        )

        /** The exact read-only v9 status program from TesseraAgentCore. */
        fun probeFromSharedCore(): AgentIntegrationCommand = probe(
            SharedAgentIntegrationCommands.statusCommand().encodeToByteArray(),
        )

        fun hostDeploymentFromSharedCore(request: String): AgentIntegrationCommand = install(
            SharedAgentIntegrationCommands.hostDeploymentCommand(request).encodeToByteArray(),
        )

        fun readConfigsFromSharedCore(): AgentIntegrationCommand = readConfigs(
            listOf(
                SharedAgentIntegrationCommands.codexHooksReadCommand(),
                SharedAgentIntegrationCommands.claudeSettingsReadCommand(),
                SharedAgentIntegrationCommands.kimiConfigReadCommand(),
            ).joinToString("; ").encodeToByteArray(),
        )

        fun currentShellFromSharedCore(processIDs: Set<Int>): AgentIntegrationCommand = currentShell(
            SharedAgentIntegrationCommands.shellStatusCommand(processIDs).encodeToByteArray(),
        )

        /**
         * The exact v9 compare-and-swap installer from TesseraAgentCore. The
         * remote snapshots stay typed until Core serializes the fixed program.
         */
        fun installFromSharedCore(
            codex: AgentIntegrationConfigSnapshot,
            claude: AgentIntegrationConfigSnapshot,
            kimi: AgentIntegrationConfigSnapshot,
        ): AgentIntegrationCommand = install(
            SharedAgentIntegrationCommands.installCommand(codex, claude, kimi).encodeToByteArray(),
        )
    }
}

class AgentShellActivationCommand private constructor(payload: ByteArray) {
    private val storedPayload = payload.copyOf()
    val payload: ByteArray get() = storedPayload.copyOf()

    init {
        require(payload.isNotEmpty() && payload.size <= 65_536 && payload.none { it == 0.toByte() })
    }

    companion object {
        fun applyFromSharedCore(): AgentShellActivationCommand =
            AgentShellActivationCommand(SharedAgentIntegrationCommands.applyCurrentShellCommand())

        fun persistAndApplyFromSharedCore(): AgentShellActivationCommand =
            AgentShellActivationCommand(SharedAgentIntegrationCommands.persistAndApplyCurrentShellCommand())
    }
}

sealed interface AgentIntegrationStatus {
    data object Missing : AgentIntegrationStatus
    data object Current : AgentIntegrationStatus
    data class Outdated(val version: Int?) : AgentIntegrationStatus

    /** A newer Tessera installed [version] (null when the host marker is
     * unreadable) on this host. This app must not treat it as outdated or
     * overwrite it. */
    data class RequiresAppUpdate(val version: Int?) : AgentIntegrationStatus
}

data class AgentCurrentShellStatus(val active: Boolean)

data class AgentIntegrationConfigSnapshots(
    val codex: AgentIntegrationConfigSnapshot,
    val claude: AgentIntegrationConfigSnapshot,
    val kimi: AgentIntegrationConfigSnapshot,
)

/** A bounded process fact returned by the core-generated discovery probe. */
data class AgentDiscoveredProcess(
    val processID: Int,
    val parentProcessID: Int?,
    val executable: String,
    val foreground: Boolean = false,
)

data class AgentProcessDiscoverySnapshot(
    val processes: List<AgentDiscoveredProcess>,
    val foreground: SharedAgentIntegrationForeground,
    val foregroundShellProcessIDs: Set<Int>,
    val foregroundProviderProcessIDs: Set<Int>,
    val foregroundLifecycleProviderProcessIDs: Set<Int>,
    val foregroundRequiresLifecycleHook: Boolean,
    val truncated: Boolean = false,
)

/** Only complete observations can prove a process or pane absent. */
data class AgentOccupancyProcess(val pid: Int, val provider: AgentProofProvider)

data class AgentOccupancyPane(
    val paneID: String?,
    val exists: Boolean,
    val complete: Boolean,
    val processes: List<AgentOccupancyProcess>,
    /** Present PIDs no provider could be named for: never proof of absence. */
    val unclassifiedPIDs: List<Int> = emptyList(),
)

data class AgentOccupancySnapshot(
    val panes: List<AgentOccupancyPane>,
    val allPaneIDs: List<String>? = null,
)

/**
 * Parsers for the content-free, line-framed integration protocol.  The last
 * matching status line wins so diagnostic noise before it cannot change the
 * outcome.  Process discovery is exactly one JSON frame to prevent partial
 * process trees from becoming an authority signal.
 */
object AgentIntegrationProtocol {
    fun parseStatus(output: ByteArray): AgentIntegrationStatus? = runCatching {
        SharedAgentIntegrationParsing.installation(output).let { fact ->
            when (fact.installation) {
                com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation.Missing -> AgentIntegrationStatus.Missing
                com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation.Current -> AgentIntegrationStatus.Current
                com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation.Outdated -> AgentIntegrationStatus.Outdated(fact.version)
                com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation.RequiresAppUpdate ->
                    AgentIntegrationStatus.RequiresAppUpdate(fact.version)
            }
        }
    }.getOrNull()

    fun parseInstallOutcome(output: ByteArray): SharedAgentIntegrationInstallOutcome? = runCatching {
        SharedAgentIntegrationParsing.installOutcome(output)
    }.getOrNull()

    fun parseCurrentShell(output: ByteArray): AgentCurrentShellStatus? = runCatching {
        AgentCurrentShellStatus(active = SharedAgentIntegrationParsing.shellActive(output))
    }.getOrNull()

    fun parseConfigSnapshots(output: ByteArray): AgentIntegrationConfigSnapshots? = runCatching {
        SharedAgentIntegrationParsing.configSnapshots(output).let { (codex, claude, kimi) ->
            AgentIntegrationConfigSnapshots(codex, claude, kimi)
        }
    }.getOrNull()

    fun parseProcessDiscovery(
        scope: AgentProcessDiscoveryScope,
        output: ByteArray,
    ): AgentProcessDiscoverySnapshot? = runCatching {
        val fact = SharedAgentIntegrationParsing.processDiscovery(scope.toSharedScope(), output)
        AgentProcessDiscoverySnapshot(
            processes = fact.processes.map {
                AgentDiscoveredProcess(it.processID, it.parentProcessID, it.executable, it.foreground)
            },
            foreground = fact.foreground,
            foregroundShellProcessIDs = fact.foregroundShellProcessIDs,
            foregroundProviderProcessIDs = fact.foregroundProviderProcessIDs,
            foregroundLifecycleProviderProcessIDs = fact.foregroundLifecycleProviderProcessIDs,
            foregroundRequiresLifecycleHook = fact.foregroundRequiresLifecycleHook,
            // Older discovery programs cap at 128 without reporting truncation.
            truncated = output.decodeToString().lineSequence()
                .map(String::trim).first { it.startsWith("TESSERA_AGENT_PROCESS_DISCOVERY ") }
                .removePrefix("TESSERA_AGENT_PROCESS_DISCOVERY ").let(::JSONObject)
                .let { if (it.has("truncated")) it.opt("truncated") != false else fact.processes.size >= 128 },
        )
    }.getOrNull()

}

interface AgentRemoteExecStream : AutoCloseable {
    val stdout: Flow<ByteArray>
    val stderr: Flow<ByteArray>
    suspend fun awaitExit(): AgentExecExitStatus
    suspend fun send(bytes: ByteArray) { error("duplex exec unavailable") }
    fun cancel()
}

data class AgentExecExitStatus(val code: Int?)

enum class AgentSemanticKey {
    RETURN, ESCAPE, TAB, SHIFT_TAB, UP, DOWN, LEFT, RIGHT, SHIFT_LEFT, CONTROL_RIGHT_BRACKET;

    val tmuxName: String get() = when (this) {
        RETURN -> "Enter"
        ESCAPE -> "Escape"
        TAB -> "Tab"
        SHIFT_TAB -> "BTab"
        UP -> "Up"
        DOWN -> "Down"
        LEFT -> "Left"
        RIGHT -> "Right"
        SHIFT_LEFT -> "S-Left"
        CONTROL_RIGHT_BRACKET -> "C-]"
    }

    fun encoded(): ByteArray = when (this) {
        RETURN -> byteArrayOf(0x0d)
        ESCAPE -> byteArrayOf(0x1b)
        TAB -> byteArrayOf(0x09)
        SHIFT_TAB -> byteArrayOf(0x1b, '['.code.toByte(), 'Z'.code.toByte())
        UP -> "\u001b[A".encodeToByteArray()
        DOWN -> "\u001b[B".encodeToByteArray()
        LEFT -> "\u001b[D".encodeToByteArray()
        RIGHT -> "\u001b[C".encodeToByteArray()
        SHIFT_LEFT -> "\u001b[1;2D".encodeToByteArray()
        CONTROL_RIGHT_BRACKET -> byteArrayOf(0x1d)
    }

    companion object {
        fun fromTmuxName(name: String): AgentSemanticKey? = entries.firstOrNull { it.tmuxName == name }
    }
}

sealed interface AgentTerminalFocusOutcome {
    data object Success : AgentTerminalFocusOutcome
    data object AuthorityPending : AgentTerminalFocusOutcome
    data object RouteGone : AgentTerminalFocusOutcome
    data class Failed(val code: String) : AgentTerminalFocusOutcome
}

fun AgentEndpointResult<Unit>.terminalFocusOutcome(): AgentTerminalFocusOutcome = when (this) {
    is AgentEndpointResult.Success -> AgentTerminalFocusOutcome.Success
    AgentEndpointResult.StaleBinding -> AgentTerminalFocusOutcome.RouteGone
    is AgentEndpointResult.Unavailable -> AgentTerminalFocusOutcome.Failed(reason)
    is AgentEndpointResult.Failed -> if (code == "tmux_controlled_elsewhere") AgentTerminalFocusOutcome.AuthorityPending
        else AgentTerminalFocusOutcome.Failed(code)
}

sealed interface AgentTmuxPlacement {
    data class NewWindow(val name: String? = null) : AgentTmuxPlacement
    data class Split(val targetPaneID: String, val vertical: Boolean) : AgentTmuxPlacement
}

data class AgentTmuxPlacementReceipt(
    val windowID: String,
    val paneID: String,
)

data class AgentTmuxLaunchReceipt(
    val requestID: String,
    val windowID: String,
    val paneID: String,
    val worktreeCreated: Boolean,
)

/** Fresh lower-layer proof that a provider process belongs to this exact route. */
data class AgentProcessProof(
    val processIDs: Set<Int>,
    val provider: AgentProofProvider,
    /** Kernel/process start identity for the claimed provider PID. */
    val processStart: String,
) {
    init {
        require(processIDs.isNotEmpty() && processIDs.size <= 128)
        require(processIDs.all { it > 1 })
        require(processStart.length in 1..128)
        require(processStart.all { it.code in 0x20..0x7e })
    }
}

internal fun AgentProcessProof.matchesProcessIdentity(
    claimedPID: Int,
    expectedProvider: AgentProofProvider,
    expectedStart: String,
): Boolean = provider == expectedProvider &&
    processStart == expectedStart &&
    claimedPID in processIDs

/** A bounded response from the existing tmux control client. */
data class AgentTmuxControlAck(
    val success: Boolean,
    val lines: List<String>,
)

sealed interface AgentEndpointResult<out T> {
    data class Success<T>(val value: T) : AgentEndpointResult<T>
    data class Unavailable(val reason: String) : AgentEndpointResult<Nothing>
    data object StaleBinding : AgentEndpointResult<Nothing>
    data class Failed(
        val code: String,
        /** The transport proved that none of this call's input was admitted. */
        val inputNotAdmitted: Boolean = false,
        val proofReason: String? = null,
    ) : AgentEndpointResult<Nothing>
}

/** Streaming transport primitive consumed by the shared projector protocol. */
interface AgentRemoteDataChannel {
    suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream>
}

interface AgentSessionEndpoint : AutoCloseable, AgentRemoteDataChannel {
    val key: AgentSessionKey
    val binding: StateFlow<AgentEndpointBinding>
    /** Read-only host carrier, separate from pane-scoped action authority. */
    val ingestionBinding: AgentEndpointBinding get() = binding.value
    fun isCurrentIngestion(candidate: AgentEndpointBinding): Boolean = isCurrentRoute(candidate)
    val capabilities: StateFlow<AgentEndpointCapabilities>
    val lifecycleFrames: Flow<AgentLifecycleFrame>
    /** The last lifecycle state delivered for this visible tmux pane, if retained. */
    fun retainedLifecycleFrame(binding: AgentEndpointBinding): AgentLifecycleFrame? = null

    /**
     * Whether this endpoint still addresses [candidate]'s exact route.
     *
     * Deliberately a different question from `binding.value == candidate`,
     * which asks whether the route is the pane the user happens to be looking
     * at. tmux hands one client every pane of the session at once, and an
     * agent is almost always working in a window nobody is watching: asking
     * the active-pane question instead of this one made every such agent
     * unaddressable, which is Agent Center showing nothing on a host running
     * several agents. Address equality is not weakened — an implementation
     * must still compare every field of the route.
     */
    fun isCurrentRoute(candidate: AgentEndpointBinding): Boolean = candidate.sameRouteAs(binding.value)

    suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation>
    /**
     * [requireForeground]: an action about to type must also find the agent
     * in the pane's foreground process group (helper reason `backgroundProcess`
     * otherwise); lifecycle, discovery and liveness proofs leave it false.
     */
    suspend fun proveProcess(
        binding: AgentEndpointBinding,
        claimedPID: Int,
        provider: AgentProofProvider,
        requireForeground: Boolean = false,
    ): AgentEndpointResult<AgentProcessProof>
    /** Returns the only root a core-generated discovery command may inspect. */
    suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope>
    suspend fun probeIntegration(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentIntegrationStatus>
    suspend fun readIntegrationConfigs(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentIntegrationConfigSnapshots>
    /**
     * Yields Core's classification of the run, not a status: only Core decides
     * which outcome is a retryable compare-and-swap race.
     */
    suspend fun installIntegration(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<SharedAgentIntegrationInstallOutcome>
    suspend fun inspectCurrentShell(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentCurrentShellStatus>
    suspend fun discoverProcesses(
        binding: AgentEndpointBinding,
        command: AgentIntegrationCommand,
    ): AgentEndpointResult<AgentProcessDiscoverySnapshot>
    /** Reads requested process roots on this carrier, including vanished panes. */
    suspend fun observeOccupancy(bindings: List<AgentEndpointBinding>): AgentEndpointResult<AgentOccupancySnapshot> =
        AgentEndpointResult.Unavailable("Process occupancy is unavailable for this terminal")
    /**
     * Sends only a core-generated activation byte sequence after a fresh
     * foreground shell check. It never appends caller-defined shell text.
     */
    suspend fun activateCurrentShell(
        binding: AgentEndpointBinding,
        expectedProcessIDs: Set<Int>,
        command: AgentShellActivationCommand,
    ): AgentEndpointResult<Unit>
    /** Exact route/pane working-directory proof used to authorize a launch. */
    suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>>
    /** Upload to this session's private temporary storage; never writes terminal input. */
    suspend fun uploadAttachment(binding: AgentEndpointBinding, sourceURI: String): AgentEndpointResult<String> =
        AgentEndpointResult.Unavailable("File uploads are unavailable for this terminal")
    /**
     * Why [sendInput] would refuse [binding] before its first byte, or null.
     * The sender still decides admission; only an explicit
     * [AgentEndpointResult.Failed.inputNotAdmitted] proves a later refusal
     * was unwritten.
     */
    fun inputRefusal(binding: AgentEndpointBinding): String? = null
    suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit>
    suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit>
    suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit>
    suspend fun focus(binding: AgentEndpointBinding, isCurrentRequest: () -> Boolean): AgentEndpointResult<Unit> =
        if (isCurrentRequest()) focus(binding) else AgentEndpointResult.StaleBinding
    suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt>
    suspend fun launchTmux(
        binding: AgentEndpointBinding,
        placement: AgentTmuxPlacement,
        requestID: String,
        request: ByteArray,
    ): AgentEndpointResult<AgentTmuxLaunchReceipt>
}
