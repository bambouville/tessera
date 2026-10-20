package com.bambouville.tessera.core.bridge

import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

data class CoreRuntimeInfo(
    val abiVersion: Int,
    val maxPayloadBytes: Long,
)

/** Independently versioned Agent Core ABI contract. */
data class AgentRuntimeInfo(
    val abiVersion: Int,
    val maxPayloadBytes: Long,
)

/** Independently versioned stateless remote-integration command ABI. */
data class AgentIntegrationInfo(
    val abiVersion: Int,
    val maxConfigBytes: Long,
)

/** Cross-device pairing is independently versioned from the terminal ABI. */
data class CrossDeviceRuntimeInfo(
    val abiVersion: Int,
    val maxPayloadBytes: Long,
)

sealed interface CoreBridgeState {
    data class Ready(val runtime: CoreRuntimeInfo) : CoreBridgeState

    data class Failed(val reason: String) : CoreBridgeState
}

sealed interface AgentBridgeState {
    data class Ready(val runtime: AgentRuntimeInfo) : AgentBridgeState

    data class Failed(val reason: String) : AgentBridgeState
}

sealed interface AgentIntegrationBridgeState {
    data class Ready(val runtime: AgentIntegrationInfo) : AgentIntegrationBridgeState
    data class Failed(val reason: String) : AgentIntegrationBridgeState
}

sealed interface CrossDeviceBridgeState {
    data class Ready(val runtime: CrossDeviceRuntimeInfo) : CrossDeviceBridgeState
    data class Failed(val reason: String) : CrossDeviceBridgeState
}

data class CoreEvent(val bytes: ByteArray)

fun interface CoreEventListener {
    /** Called serially on an ABI-owned thread. Dispatch UI work explicitly. */
    fun onEvent(event: CoreEvent)
}

enum class CoreCallResult {
    Accepted,
    InvalidArguments,
    StaleHandle,
}

object CoreBridge {
    /**
     * Core command/runtime ABI. Render-ledger events changed this to v2; v4
     * creates the tmux runtime without a device ID and projects authority
     * into it, since only the shared authority session classifies stamps.
     */
    const val EXPECTED_ABI_VERSION = 4
    const val EXPECTED_MAX_PAYLOAD_BYTES = 1_048_576L
    /**
     * Render bytes alone ride a higher ceiling (`TESSERA_TMUX_ABI_MAX_RENDER_BYTES`).
     * A full-depth inline history capture of a dense 10 000-line pane measures
     * 470–680 KB and sat right at the old 1 MiB payload ceiling, so an inline
     * `scrollbackRequested` deepen could lose its capture to a size guard.
     * Every other payload keeps [EXPECTED_MAX_PAYLOAD_BYTES].
     */
    const val EXPECTED_MAX_RENDER_BYTES = 8_388_608L
    /** Pairing has its own v1 ABI and must not follow terminal ABI bumps. */
    const val EXPECTED_CROSS_DEVICE_ABI_VERSION = 1
    const val EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES = 1_048_576L
    const val EXPECTED_AGENT_ABI_VERSION = 1
    const val EXPECTED_AGENT_INTEGRATION_ABI_VERSION = 2
    const val EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES = 1_048_576L

    fun inspect(): CoreBridgeState = try {
        NativeLibraries.ensureLoaded()
        validateRuntime(
            abiVersion = NativeCoreBindings.abiVersion(),
            maxPayloadBytes = NativeCoreBindings.maxPayloadBytes(),
        )
    } catch (error: LinkageError) {
        CoreBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    } catch (error: SecurityException) {
        CoreBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    }

    internal fun validateRuntime(
        abiVersion: Int,
        maxPayloadBytes: Long,
    ): CoreBridgeState {
        if (abiVersion != EXPECTED_ABI_VERSION) {
            return CoreBridgeState.Failed(
                "Expected ABI $EXPECTED_ABI_VERSION, found $abiVersion",
            )
        }
        if (maxPayloadBytes != EXPECTED_MAX_PAYLOAD_BYTES) {
            return CoreBridgeState.Failed(
                "Expected max payload $EXPECTED_MAX_PAYLOAD_BYTES, found $maxPayloadBytes",
            )
        }
        return CoreBridgeState.Ready(
            CoreRuntimeInfo(
                abiVersion = abiVersion,
                maxPayloadBytes = maxPayloadBytes,
            ),
        )
    }

    fun inspectCrossDevice(): CrossDeviceBridgeState = try {
        NativeLibraries.ensureLoaded()
        validateCrossDeviceRuntime(
            abiVersion = NativeCoreBindings.crossDeviceAbiVersion(),
            maxPayloadBytes = NativeCoreBindings.crossDeviceMaxPayloadBytes(),
        )
    } catch (error: LinkageError) {
        CrossDeviceBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    } catch (error: SecurityException) {
        CrossDeviceBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    }

    internal fun validateCrossDeviceRuntime(
        abiVersion: Int,
        maxPayloadBytes: Long,
    ): CrossDeviceBridgeState {
        if (abiVersion != EXPECTED_CROSS_DEVICE_ABI_VERSION) {
            return CrossDeviceBridgeState.Failed(
                "Expected CrossDevice ABI $EXPECTED_CROSS_DEVICE_ABI_VERSION, found $abiVersion",
            )
        }
        if (maxPayloadBytes != EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES) {
            return CrossDeviceBridgeState.Failed(
                "Expected CrossDevice max payload $EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES, found $maxPayloadBytes",
            )
        }
        return CrossDeviceBridgeState.Ready(CrossDeviceRuntimeInfo(abiVersion, maxPayloadBytes))
    }

    /**
     * Agent Center is additive to the released terminal ABI.  It must never
     * alter the `tessera_core_*` startup contract while validating its own
     * independently versioned symbol family.
     */
    fun inspectAgent(): AgentBridgeState = try {
        NativeLibraries.ensureLoaded()
        validateAgentRuntime(
            abiVersion = NativeCoreBindings.agentAbiVersion(),
            maxPayloadBytes = NativeCoreBindings.agentMaxPayloadBytes(),
        )
    } catch (error: LinkageError) {
        AgentBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    } catch (error: SecurityException) {
        AgentBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    }

    internal fun validateAgentRuntime(
        abiVersion: Int,
        maxPayloadBytes: Long,
    ): AgentBridgeState {
        if (abiVersion != EXPECTED_AGENT_ABI_VERSION) {
            return AgentBridgeState.Failed(
                "Expected Agent ABI $EXPECTED_AGENT_ABI_VERSION, found $abiVersion",
            )
        }
        if (maxPayloadBytes != EXPECTED_MAX_PAYLOAD_BYTES) {
            return AgentBridgeState.Failed(
                "Expected Agent max payload $EXPECTED_MAX_PAYLOAD_BYTES, found $maxPayloadBytes",
            )
        }
        return AgentBridgeState.Ready(
            AgentRuntimeInfo(
                abiVersion = abiVersion,
                maxPayloadBytes = maxPayloadBytes,
            ),
        )
    }

    fun inspectAgentIntegration(): AgentIntegrationBridgeState = try {
        NativeLibraries.ensureLoaded()
        validateAgentIntegration(
            abiVersion = NativeCoreBindings.agentIntegrationAbiVersion(),
            maxConfigBytes = NativeCoreBindings.agentIntegrationMaxConfigBytes(),
        )
    } catch (error: LinkageError) {
        AgentIntegrationBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    } catch (error: SecurityException) {
        AgentIntegrationBridgeState.Failed(error.message ?: error.javaClass.simpleName)
    }

    internal fun validateAgentIntegration(
        abiVersion: Int,
        maxConfigBytes: Long,
    ): AgentIntegrationBridgeState {
        if (abiVersion != EXPECTED_AGENT_INTEGRATION_ABI_VERSION) {
            return AgentIntegrationBridgeState.Failed(
                "Expected Agent integration ABI $EXPECTED_AGENT_INTEGRATION_ABI_VERSION, found $abiVersion",
            )
        }
        if (maxConfigBytes != EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES) {
            return AgentIntegrationBridgeState.Failed(
                "Expected Agent integration config limit $EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES, found $maxConfigBytes",
            )
        }
        return AgentIntegrationBridgeState.Ready(AgentIntegrationInfo(abiVersion, maxConfigBytes))
    }
}

/**
 * Explicit owner for one shared-core runtime.
 *
 * Direct input buffers are borrowed only until [send] or [emit] returns. Native
 * callback buffers never escape this module: [NativeEventSink] copies them
 * before invoking the listener, matching the C ABI's callback lifetime.
 */
class CoreRuntime private constructor(
    handle: Long,
    private val eventSink: NativeEventSink,
) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)

    fun send(payload: ByteArray): CoreCallResult = send(payload.toDirectBuffer())

    fun send(payload: ByteBuffer): CoreCallResult = call(payload, NativeCoreBindings::sendRuntime)

    fun emit(payload: ByteArray): CoreCallResult = emit(payload.toDirectBuffer())

    fun emit(payload: ByteBuffer): CoreCallResult = call(payload, NativeCoreBindings::emitRuntime)

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle == 0L) return
        NativeCoreBindings.destroyRuntime(handle)
        eventSink.clear()
    }

    private fun call(
        payload: ByteBuffer,
        operation: (Long, ByteBuffer, Int, Int) -> Int,
    ): CoreCallResult {
        require(payload.isDirect) { "shared-core payloads must use a direct ByteBuffer" }
        val count = payload.remaining()
        require(count in 1..CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt()) {
            "shared-core payload must contain 1..${CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES} bytes"
        }
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return operation(handle, payload, payload.position(), count).toCoreCallResult()
    }

    companion object {
        fun create(listener: CoreEventListener): CoreRuntime {
            val state = CoreBridge.inspect()
            check(state is CoreBridgeState.Ready) {
                "shared core unavailable: ${(state as CoreBridgeState.Failed).reason}"
            }
            val sink = NativeEventSink(listener)
            val handle = NativeCoreBindings.createRuntime(sink)
            check(handle != 0L) { "shared core refused to create a runtime" }
            return CoreRuntime(handle, sink)
        }
    }
}

/** A remote provider configuration snapshot. Missing is intentionally distinct
 * from Present("") so Core can retain the remote file compare-and-swap check. */
sealed interface AgentIntegrationConfigSnapshot {
    data object Missing : AgentIntegrationConfigSnapshot
    data class Present(val contents: String) : AgentIntegrationConfigSnapshot
}

data class SharedAgentProcessDescriptor(val executableName: String, val arguments: String = "")

/**
 * Exact v9 Agent Center shell commands, generated only by TesseraAgentCore.
 * Android executes them over its already-authenticated route and must pass the
 * three unmodified read snapshots back to [installCommand].
 */
object SharedAgentIntegrationCommands {
    fun hostDeploymentCommand(request: String): String {
        requireReady()
        val bytes = request.encodeToByteArray()
        require(bytes.size in 1..65_536)
        return NativeCoreBindings.agentHostDeploymentCommand(bytes.toDirectBuffer(), bytes.size)
    }
    private fun requireReady() {
        check(CoreBridge.inspectAgentIntegration() is AgentIntegrationBridgeState.Ready) {
            "Agent integration command ABI is unavailable"
        }
    }

    fun statusCommand(): String {
        requireReady(); return NativeCoreBindings.agentIntegrationStatusCommand()
    }

    fun codexHooksReadCommand(): String {
        requireReady(); return NativeCoreBindings.agentIntegrationCodexHooksReadCommand()
    }

    fun claudeSettingsReadCommand(): String {
        requireReady(); return NativeCoreBindings.agentIntegrationClaudeSettingsReadCommand()
    }

    fun kimiConfigReadCommand(): String {
        requireReady(); return NativeCoreBindings.agentIntegrationKimiConfigReadCommand()
    }

    fun shellStatusCommand(processIDs: Set<Int>): String {
        requireReady()
        require(processIDs.isNotEmpty() && processIDs.size <= 128 && processIDs.all { it > 1 })
        val encoded = org.json.JSONArray(processIDs.sorted()).toString().encodeToByteArray()
        return NativeCoreBindings.agentIntegrationShellStatusCommand(encoded.toDirectBuffer(), encoded.size)
    }

    fun processDiscoveryCommand(scope: SharedAgentProcessDiscoveryScope): String {
        requireReady()
        val encoded = scope.encoded()
        return NativeCoreBindings.agentIntegrationProcessDiscoveryCommand(encoded.toDirectBuffer(), encoded.size)
    }

    fun applyCurrentShellCommand(): ByteArray {
        requireReady(); return (NativeCoreBindings.agentIntegrationApplyCurrentShellCommand() + "\r").encodeToByteArray()
    }

    fun persistAndApplyCurrentShellCommand(): ByteArray {
        requireReady(); return (NativeCoreBindings.agentIntegrationPersistApplyCurrentShellCommand() + "\r").encodeToByteArray()
    }

    fun installCommand(
        codex: AgentIntegrationConfigSnapshot,
        claude: AgentIntegrationConfigSnapshot,
        kimi: AgentIntegrationConfigSnapshot,
    ): String {
        requireReady()
        fun bytes(snapshot: AgentIntegrationConfigSnapshot): ByteArray? = when (snapshot) {
            AgentIntegrationConfigSnapshot.Missing -> null
            is AgentIntegrationConfigSnapshot.Present -> snapshot.contents.encodeToByteArray().also {
                require(it.size <= CoreBridge.EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES) {
                    "Agent integration config snapshot exceeds shared limit"
                }
            }
        }
        val codexBytes = bytes(codex)
        val claudeBytes = bytes(claude)
        val kimiBytes = bytes(kimi)
        return NativeCoreBindings.agentIntegrationInstallCommand(
            codex is AgentIntegrationConfigSnapshot.Present, codexBytes?.toDirectBuffer(), codexBytes?.size ?: 0,
            claude is AgentIntegrationConfigSnapshot.Present, claudeBytes?.toDirectBuffer(), claudeBytes?.size ?: 0,
            kimi is AgentIntegrationConfigSnapshot.Present, kimiBytes?.toDirectBuffer(), kimiBytes?.size ?: 0,
        )
    }
}

/** Platform supplies only an already-validated carrier root. Core serializes
 * the scope and owns the complete remote discovery program. */
sealed interface SharedAgentProcessDiscoveryScope {
    fun encoded(): ByteArray

    data class RouteMarker(val marker: String) : SharedAgentProcessDiscoveryScope {
        init { require(marker.matches(Regex("[A-Fa-f0-9-]{36}"))) }
        override fun encoded(): ByteArray = org.json.JSONObject()
            .put("kind", "routeMarker").put("marker", marker).toString().encodeToByteArray()
    }

    data class RootProcess(val processID: Int) : SharedAgentProcessDiscoveryScope {
        init { require(processID > 1) }
        override fun encoded(): ByteArray = org.json.JSONObject()
            .put("kind", "rootProcess").put("processID", processID).toString().encodeToByteArray()
    }
}

data class SharedAgentIntegrationInstallationFact(
    val installation: SharedAgentIntegrationInstallation,
    val version: Int?,
)

/**
 * What Core decided one install run means.  Only [ConfigurationRace] may be
 * retried; every other outcome is terminal and must be reported as itself.
 */
sealed interface SharedAgentIntegrationInstallOutcome {
    data object Completed : SharedAgentIntegrationInstallOutcome

    data object ConfigurationRace : SharedAgentIntegrationInstallOutcome

    /** [reason] is Core's bounded vocabulary, never remote output. */
    data class Failed(val reason: SharedAgentIntegrationInstallFailure) :
        SharedAgentIntegrationInstallOutcome
}

enum class SharedAgentIntegrationInstallFailure(val wireValue: String) {
    NotVerified("notVerified"),
    NotCurrent("notCurrent"),

    /** The install program refused: the host already carries a newer
     * integration than this app ships. Only an app update can resolve it. */
    NewerInstalled("newerInstalled");

    companion object {
        fun fromWire(value: String): SharedAgentIntegrationInstallFailure =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown Core install failure reason")
    }
}

data class SharedAgentProcessFact(
    val processID: Int,
    val parentProcessID: Int?,
    val executable: String,
    val foreground: Boolean,
)

data class SharedAgentProcessDiscoveryFact(
    val processes: List<SharedAgentProcessFact>,
    val foreground: SharedAgentIntegrationForeground,
    val foregroundShellProcessIDs: Set<Int>,
    val foregroundProviderProcessIDs: Set<Int>,
    val foregroundLifecycleProviderProcessIDs: Set<Int>,
    val foregroundRequiresLifecycleHook: Boolean,
)

data class SharedAgentLifecycleHookEvent(
    val version: Int,
    val providerID: String,
    val event: String,
    val status: String,
    val reason: String?,
    val timestampNanoseconds: Long,
    val providerSessionID: String?,
    val turnID: String?,
    val notificationType: String?,
    val permissionMode: String?,
    val agentPID: Int?,
    val transcriptRef: String?,
    val agentID: String?,
    val agentType: String?,
    val rootAgentID: String?,
)

/** Shared timing policy; native task owners keep clocks and cancellation. */
object SharedAgentIntegrationCheckPolicy {
    private fun policy(failureCount: Int): org.json.JSONObject {
        require(failureCount >= 0)
        check(CoreBridge.inspectAgentIntegration() is AgentIntegrationBridgeState.Ready) {
            "Agent integration check policy ABI is unavailable"
        }
        return org.json.JSONObject(NativeCoreBindings.agentIntegrationCheckPolicy(failureCount))
    }

    private val baseline by lazy { policy(0) }

    fun freshnessMillis(kind: SharedAgentIntegrationInstallation): Long = baseline.getLong(
        if (kind == SharedAgentIntegrationInstallation.Current) "currentInstallationFreshnessMilliseconds"
        else "otherInstallationFreshnessMilliseconds",
    )

    fun retryDelayMillis(failureCount: Int): Long =
        (if (failureCount == 0) baseline else policy(failureCount)).getLong("nextCheckDelayMilliseconds")

    val activityThrottleMillis: Long get() = baseline.getLong("activityThrottleMilliseconds")

    /** How long a warning-bearing status must hold continuously before any
     * platform surfaces it, so transient probe states never flash UI. */
    val warningPresentationDelayMillis: Long
        get() = SharedAgentIntegrationWireCodec.warningPresentationDelayMillis(baseline)
}

/** Typed Core ABI façade for raw install/shell probe and process-tree bytes. */
object SharedAgentIntegrationParsing {
    private fun requireReady() {
        check(CoreBridge.inspectAgentIntegration() is AgentIntegrationBridgeState.Ready) {
            "Agent integration parse ABI is unavailable"
        }
    }

    private fun boundedOutput(output: ByteArray): ByteArray {
        require(output.isNotEmpty() && output.size <= 65_536)
        return output
    }

    fun installation(output: ByteArray): SharedAgentIntegrationInstallationFact {
        requireReady()
        val bytes = boundedOutput(output)
        return SharedAgentIntegrationWireCodec.decodeInstallation(
            NativeCoreBindings.agentIntegrationParseStatus(bytes.toDirectBuffer(), bytes.size),
        )
    }

    fun installOutcome(output: ByteArray): SharedAgentIntegrationInstallOutcome {
        requireReady()
        val bytes = boundedOutput(output)
        return SharedAgentIntegrationWireCodec.decodeInstallOutcome(
            NativeCoreBindings.agentIntegrationClassifyInstallOutput(bytes.toDirectBuffer(), bytes.size),
        )
    }

    /** The shared retry budget; platforms must not choose their own. */
    fun maximumInstallAttempts(): Int {
        requireReady()
        return NativeCoreBindings.agentIntegrationMaxInstallAttempts()
    }

    fun shellActive(output: ByteArray): Boolean {
        requireReady()
        val bytes = boundedOutput(output)
        return org.json.JSONObject(NativeCoreBindings.agentIntegrationParseShellStatus(bytes.toDirectBuffer(), bytes.size)).getBoolean("active")
    }

    fun lifecycleHookEvent(input: ByteArray): SharedAgentLifecycleHookEvent {
        requireReady()
        val bytes = boundedOutput(input)
        val value = org.json.JSONObject(
            NativeCoreBindings.agentIntegrationParseLifecycleEvent(bytes.toDirectBuffer(), bytes.size),
        )
        fun optional(key: String): String? = if (value.isNull(key)) null else value.getString(key)
        return SharedAgentLifecycleHookEvent(
            version = value.getInt("version"),
            providerID = value.getJSONObject("providerID").getString("rawValue"),
            event = value.getString("event"),
            status = value.getString("status"),
            reason = optional("reason"),
            timestampNanoseconds = value.getLong("timestampNanoseconds"),
            providerSessionID = optional("providerSessionID"),
            turnID = optional("turnID"),
            notificationType = optional("notificationType"),
            permissionMode = optional("permissionMode"),
            agentPID = if (value.isNull("agentPID")) null else value.getInt("agentPID"),
            transcriptRef = optional("transcriptRef"),
            agentID = optional("agentID"),
            agentType = optional("agentType"),
            rootAgentID = optional("rootAgentID"),
        )
    }

    fun projectorDiagnostics(stdout: ByteArray): Map<String, String> {
        requireReady()
        require(stdout.isNotEmpty() && stdout.size <= 262_144)
        val fields = org.json.JSONObject(NativeCoreBindings.agentProjectorDiagnostics(stdout.toDirectBuffer(), stdout.size))
        return fields.keys().asSequence().associateWith(fields::getString)
    }

    fun configSnapshots(output: ByteArray): Triple<AgentIntegrationConfigSnapshot, AgentIntegrationConfigSnapshot, AgentIntegrationConfigSnapshot> {
        requireReady()
        require(output.isNotEmpty() && output.size <= 8_388_608)
        val value = org.json.JSONObject(NativeCoreBindings.agentIntegrationParseConfigs(output.toDirectBuffer(), output.size))
        fun snapshot(key: String): AgentIntegrationConfigSnapshot = value.getJSONObject(key).let { entry ->
            if (!entry.getBoolean("present")) AgentIntegrationConfigSnapshot.Missing
            else AgentIntegrationConfigSnapshot.Present(entry.getString("contents"))
        }
        return Triple(snapshot("codex"), snapshot("claude"), snapshot("kimi"))
    }

    fun processDiscovery(scope: SharedAgentProcessDiscoveryScope, output: ByteArray): SharedAgentProcessDiscoveryFact {
        requireReady()
        val scopeBytes = scope.encoded()
        val response = boundedOutput(output)
        return decodeProcessDiscovery(NativeCoreBindings.agentIntegrationParseProcessDiscovery(
            scopeBytes.toDirectBuffer(), scopeBytes.size, response.toDirectBuffer(), response.size,
        ))
    }

    /** Structural parsing remains Core-owned even at legacy call sites that
     * already proved the command scope when they constructed the command. */
    fun processDiscovery(output: ByteArray): SharedAgentProcessDiscoveryFact {
        requireReady()
        val response = boundedOutput(output)
        return decodeProcessDiscovery(
            NativeCoreBindings.agentIntegrationParseProcessDiscovery(null, 0, response.toDirectBuffer(), response.size),
        )
    }

    private fun decodeProcessDiscovery(encoded: String): SharedAgentProcessDiscoveryFact {
        val value = org.json.JSONObject(encoded)
        val processes = value.getJSONArray("processes").let { entries ->
            List(entries.length()) { index -> entries.getJSONObject(index).let { process ->
                SharedAgentProcessFact(
                    processID = process.getInt("pid"),
                    parentProcessID = if (process.isNull("ppid")) null else process.optInt("ppid").takeIf { it > 0 },
                    executable = process.getString("executable"), foreground = process.getBoolean("foreground"),
                )
            } }
        }
        fun ids(key: String): Set<Int> = value.getJSONArray(key).let { array -> buildSet { repeat(array.length()) { add(array.getInt(it)) } } }
        return SharedAgentProcessDiscoveryFact(
            processes, SharedAgentIntegrationForeground.entries.firstOrNull { it.wireValue == value.getString("foreground") }
                ?: throw IllegalArgumentException("unknown Core foreground fact"), ids("foregroundShellProcessIDs"), ids("foregroundProviderProcessIDs"), ids("foregroundLifecycleProviderProcessIDs"), value.getBoolean("foregroundRequiresLifecycleHook"),
        )
    }
}

enum class SharedAgentIntegrationInstallation(val wireValue: String) {
    Missing("missing"),
    Current("current"),
    Outdated("outdated"),

    /** The host carries a newer integration than this app ships. This app
     * must neither report it outdated nor overwrite it. */
    RequiresAppUpdate("requiresAppUpdate");

    companion object {
        fun fromWire(value: String): SharedAgentIntegrationInstallation =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown Core installation fact")
    }
}

enum class SharedAgentIntegrationForeground(val wireValue: String) {
    Shell("shell"),
    UnsupportedShell("unsupportedShell"),
    Agent("agent"),
    Other("other"),
}

enum class SharedAgentIntegrationDecisionKind(val wireValue: String) {
    Checking("checking"),
    Ready("ready"),
    NotInstalled("notInstalled"),
    Outdated("outdated"),
    InactiveShell("inactiveShell"),
    InsideAgent("insideAgent"),
    AwayFromShell("awayFromShell"),
    UnsupportedShell("unsupportedShell"),
    BusyProgram("busyProgram"),
    ManualCheckRequired("manualCheckRequired"),
    Repairing("repairing"),
    Unavailable("unavailable"),

    /** A newer app installed the host integration. No action is offered:
     * the only remedy is updating this app. */
    AppUpdateRequired("appUpdateRequired");

    companion object {
        fun fromWire(value: String): SharedAgentIntegrationDecisionKind =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared Agent integration state")
    }
}

enum class SharedAgentIntegrationDecisionAction(val wireValue: String) {
    InstallAndApply("installAndApply"),
    InstallOnly("installOnly"),
    Apply("apply"),
    PersistAndApply("persistAndApply"),
    Check("check"),
    Retry("retry");

    companion object {
        fun fromWire(value: String): SharedAgentIntegrationDecisionAction =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared Agent integration action")
    }
}

data class SharedAgentIntegrationObservation(
    val installation: SharedAgentIntegrationInstallation,
    val foreground: SharedAgentIntegrationForeground,
    val shellIntegrationActive: Boolean?,
    val agentIntegrationActive: Boolean,
    val agentRequiresLifecycleHook: Boolean? = null,
)

data class SharedAgentIntegrationDecision(
    val kind: SharedAgentIntegrationDecisionKind,
    val primaryAction: SharedAgentIntegrationDecisionAction?,
    val secondaryAction: SharedAgentIntegrationDecisionAction?,
    val effectiveAction: SharedAgentIntegrationDecisionAction?,
    val showsWarning: Boolean,
)

/** Typed facade over TesseraAgentCore's integration reducer. */
object SharedAgentIntegrationDecisions {
    fun resolve(
        observation: SharedAgentIntegrationObservation,
        requestedAction: SharedAgentIntegrationDecisionAction? = null,
    ): SharedAgentIntegrationDecision {
        check(CoreBridge.inspectAgentIntegration() is AgentIntegrationBridgeState.Ready) {
            "Agent integration decision ABI is unavailable"
        }
        val request = SharedAgentIntegrationWireCodec.encodeDecisionRequest(observation, requestedAction)
            .encodeToByteArray()
        return SharedAgentIntegrationWireCodec.decodeDecision(
            NativeCoreBindings.agentIntegrationResolve(request.toDirectBuffer(), request.size),
        )
    }
}

/**
 * Pure JSON codec for the Agent integration ABI. Kept free of native calls so
 * the wire vocabulary is verifiable on the JVM; every unknown value fails
 * closed instead of being mapped to a neighbouring state.
 */
internal object SharedAgentIntegrationWireCodec {
    fun decodeInstallation(encoded: String): SharedAgentIntegrationInstallationFact {
        val value = org.json.JSONObject(encoded)
        val kind = SharedAgentIntegrationInstallation.fromWire(value.getString("kind"))
        // Core bounds `version` for both outdated and newer installations, but
        // may omit it when the host's marker is unreadable; the kind alone is
        // authoritative for what this app may do.
        return SharedAgentIntegrationInstallationFact(kind, if (value.isNull("version")) null else value.getInt("version"))
    }

    fun decodeInstallOutcome(encoded: String): SharedAgentIntegrationInstallOutcome {
        val value = org.json.JSONObject(encoded)
        return when (value.getString("kind")) {
            "completed" -> SharedAgentIntegrationInstallOutcome.Completed
            "configurationRace" -> SharedAgentIntegrationInstallOutcome.ConfigurationRace
            "failed" -> SharedAgentIntegrationInstallOutcome.Failed(
                SharedAgentIntegrationInstallFailure.fromWire(value.optString("reason")),
            )
            else -> throw IllegalArgumentException("unknown Core install outcome")
        }
    }

    fun encodeDecisionRequest(
        observation: SharedAgentIntegrationObservation,
        requestedAction: SharedAgentIntegrationDecisionAction?,
    ): String = org.json.JSONObject()
        .put(
            "observation",
            org.json.JSONObject()
                .put("installation", observation.installation.wireValue)
                .put("foreground", observation.foreground.wireValue)
                .put("shellIntegrationActive", observation.shellIntegrationActive ?: org.json.JSONObject.NULL)
                .put("agentIntegrationActive", observation.agentIntegrationActive)
                .put("agentRequiresLifecycleHook", observation.agentRequiresLifecycleHook ?: org.json.JSONObject.NULL),
        )
        .put("requestedAction", requestedAction?.wireValue ?: org.json.JSONObject.NULL)
        .toString()

    fun decodeDecision(encoded: String): SharedAgentIntegrationDecision {
        val response = org.json.JSONObject(encoded)
        val decision = response.getJSONObject("decision")
        fun optionalAction(container: org.json.JSONObject, key: String): SharedAgentIntegrationDecisionAction? =
            container.optString(key).takeIf(String::isNotEmpty)?.let(SharedAgentIntegrationDecisionAction::fromWire)
        return SharedAgentIntegrationDecision(
            kind = SharedAgentIntegrationDecisionKind.fromWire(decision.getString("kind")),
            primaryAction = optionalAction(decision, "primaryAction"),
            secondaryAction = optionalAction(decision, "secondaryAction"),
            effectiveAction = optionalAction(response, "effectiveAction"),
            showsWarning = response.getBoolean("showsWarning"),
        )
    }

    fun warningPresentationDelayMillis(policy: org.json.JSONObject): Long =
        policy.getLong("warningPresentationDelayMilliseconds").also {
            require(it >= 0) { "negative warning presentation delay" }
        }
}

/** Pure Core classification; keeps the compiled provider registry authoritative. */
object SharedAgentProviderClassification {
    fun classify(descriptors: List<SharedAgentProcessDescriptor>): Set<String> {
        require(descriptors.size <= 128)
        val encoded = org.json.JSONArray().also { array ->
            descriptors.forEach { descriptor ->
                require(descriptor.executableName.isNotBlank() && descriptor.executableName.length <= 256)
                require(descriptor.arguments.length <= 4096)
                array.put(org.json.JSONObject().put("executableName", descriptor.executableName).put("arguments", descriptor.arguments))
            }
        }.toString().encodeToByteArray()
        NativeLibraries.ensureLoaded()
        return org.json.JSONArray(NativeCoreBindings.classifyAgentProviders(encoded.toDirectBuffer(), encoded.size))
            .let { result -> buildSet { repeat(result.length()) { add(result.getString(it)) } } }
    }
}

/** Direct JNI projection of the shared TmuxControlCore parser/topology runtime. */
class TmuxCoreRuntime private constructor(
    handle: Long,
    private val eventSink: NativeEventSink,
) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)

    fun feed(payload: ByteArray): CoreCallResult {
        require(payload.isNotEmpty() && payload.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        val buffer = payload.toDirectBuffer()
        return NativeCoreBindings.feedTmuxRuntime(handle, buffer, 0, payload.size).toCoreCallResult()
    }

    /**
     * [feed] at [nowMillis] on the attached authority session's clock; see
     * [attachAuthoritySession]. Returns the core's code:
     * [FEED_CARRIED_SESSION_RESULT] when the read's event carried the
     * session's result, else one [toCoreCallResult] maps.
     */
    internal fun feedAt(payload: ByteArray, nowMillis: Long): Int {
        require(payload.isNotEmpty() && payload.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        require(nowMillis >= 0)
        val handle = nativeHandle.get()
        if (handle == 0L) return -2
        val buffer = payload.toDirectBuffer()
        return NativeCoreBindings.feedTmuxRuntimeAt(handle, buffer, 0, payload.size, nowMillis)
    }

    /**
     * Deliver the last [feedAt]'s session result again, with the session's
     * state at [nowMillis]: right after that feed, outside a callback.
     * [CoreCallResult.InvalidArguments] when there is none.
     */
    fun redeliverAuthorityResult(nowMillis: Long): CoreCallResult {
        require(nowMillis >= 0)
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.redeliverTmuxRuntimeAuthorityResult(handle, nowMillis).toCoreCallResult()
    }

    /**
     * The authority session lifecycle handle [feed] with a clock reduces
     * stamp edges into; 0 detaches. [CoreCallResult.InvalidArguments] for a
     * session that is no longer live.
     */
    fun attachAuthoritySession(sessionHandle: Long): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.attachTmuxRuntimeAuthoritySession(handle, sessionHandle).toCoreCallResult()
    }

    fun sendCommand(command: String): SharedTmuxCommandSubmission = submitCommand(command, ordered = false)

    /** Wire delivery occurs in the native event queue; never write separately. */
    fun queueCommand(command: String): SharedTmuxCommandSubmission = submitCommand(command, ordered = true)

    private fun submitCommand(command: String, ordered: Boolean): SharedTmuxCommandSubmission {
        val bytes = command.encodeToByteArray()
        if (bytes.isEmpty() || bytes.size > CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES || bytes.any { it == 0.toByte() }) {
            return SharedTmuxCommandSubmission.InvalidArguments
        }
        val handle = nativeHandle.get()
        if (handle == 0L) return SharedTmuxCommandSubmission.StaleHandle
        val buffer = bytes.toDirectBuffer()
        val tag = if (ordered) {
            NativeCoreBindings.queueTmuxRuntimeCommand(handle, buffer, bytes.size)
        } else {
            NativeCoreBindings.sendTmuxRuntimeCommand(handle, buffer, bytes.size)
        }
        return when (tag) {
            -2L -> SharedTmuxCommandSubmission.StaleHandle
            in 1..Long.MAX_VALUE -> SharedTmuxCommandSubmission.Accepted(tag)
            else -> SharedTmuxCommandSubmission.InvalidArguments
        }
    }

    fun submitFact(canonicalFact: ByteArray): CoreCallResult {
        require(canonicalFact.isNotEmpty() && canonicalFact.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES) {
            "render fact must contain 1..${CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES} bytes"
        }
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.submitTmuxRenderFact(
            handle,
            canonicalFact.toDirectBuffer(),
            canonicalFact.size,
        ).toCoreCallResult()
    }

    /** Two-pass raw-copy projection of `RenderEffect.feed(bytesRef:)`. */
    fun takeRenderBytes(bytesRef: Long): SharedTmuxRenderBytes {
        if (bytesRef <= 0) return SharedTmuxRenderBytes.InvalidReference
        val handle = nativeHandle.get()
        if (handle == 0L) return SharedTmuxRenderBytes.StaleHandle
        val size = NativeCoreBindings.takeTmuxRenderBytes(handle, bytesRef, null, 0)
        when {
            size == -2 -> return SharedTmuxRenderBytes.StaleHandle
            size < 0 || size > CoreBridge.EXPECTED_MAX_RENDER_BYTES -> {
                return SharedTmuxRenderBytes.InvalidReference
            }
        }
        // A zero-byte payload is valid at the copy boundary. Some JNI VMs do
        // not expose a usable address for a zero-capacity direct buffer, so
        // retain one storage byte while truthfully advertising capacity zero.
        val storage = ByteBuffer.allocateDirect(maxOf(1, size))
        val copied = NativeCoreBindings.takeTmuxRenderBytes(handle, bytesRef, storage, size)
        return when {
            copied == -2 -> SharedTmuxRenderBytes.StaleHandle
            copied != size -> SharedTmuxRenderBytes.InvalidReference
            else -> ByteArray(size).also { output ->
                storage.position(0)
                storage.get(output)
            }.let(SharedTmuxRenderBytes::Available)
        }
    }

    /**
     * Projects the shared session's authority and hands back deferred render
     * work. Null means a stale handle; an empty byte array means refusal.
     * From a runtime callback the work queues behind earlier FIFO slots.
     */
    fun projectAuthorityReleasing(authorityJSON: ByteArray): ByteArray? =
        projectAuthorityReleasing(authorityJSON, CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt())

    /** A smaller initial buffer exercises the reject-before-mutate growth retry. */
    internal fun projectAuthorityReleasing(authorityJSON: ByteArray, initialOutputCapacity: Int): ByteArray? {
        require(authorityJSON.isNotEmpty() && authorityJSON.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        require(initialOutputCapacity in 1..CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        val handle = nativeHandle.get()
        if (handle == 0L) return null
        val input = authorityJSON.toDirectBuffer()
        var capacity = initialOutputCapacity
        while (true) {
            val output = ByteBuffer.allocateDirect(capacity)
            val written = NativeCoreBindings.projectTmuxAuthorityReleasing(
                handle, input, authorityJSON.size, output, capacity,
            )
            if (written == -2) return null
            if (written == -1 && capacity < CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES) {
                // Short output is refused before projection, so retrying at
                // the full ceiling cannot consume or reorder released work.
                capacity = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt()
                continue
            }
            if (written <= 0 || written > capacity) return byteArrayOf()
            return ByteArray(written).also { output.position(0); output.get(it) }
        }
    }

    /** Replaces the adapter-owned ledger switches ([SharedTmuxRenderLedgerOptions]) with exactly [options]. */
    fun setRenderLedgerOptions(options: Int): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.setTmuxRenderLedgerOptions(handle, options).toCoreCallResult()
    }

    fun setProgramStatusEnabled(enabled: Boolean): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.setTmuxProgramStatusEnabled(handle, enabled).toCoreCallResult()
    }

    fun setSubscriptions(subscriptions: SharedTmuxSubscriptions): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.setTmuxSubscriptions(
            handle, subscriptions.feeds, subscriptions.authorityOwnerSessionId?.toLong() ?: -1L,
        ).toCoreCallResult()
    }

    /** Two-pass copy; null for a stale handle or a snapshot that changed size during the copy. */
    fun copyProgramStatus(): ByteArray? {
        val handle = nativeHandle.get()
        if (handle == 0L) return null
        return copyProgramStatusDocument { output, capacity ->
            NativeCoreBindings.copyTmuxProgramStatus(handle, output, capacity)
        }
    }

    /** 1 changed, 0 unchanged, -1 invalid pane, -2 stale handle. */
    fun acknowledgeProgramStatus(paneId: Int, through: Long): Int {
        val handle = nativeHandle.get()
        if (handle == 0L) return -2
        return NativeCoreBindings.acknowledgeTmuxProgramStatus(handle, paneId.toLong(), through)
    }

    /**
     * Ask for a state event carrying the current snapshot, for an event
     * decoder that lost track of the one it holds. Called from inside a
     * callback, the answer is queued behind the callbacks already queued.
     */
    fun resyncSnapshot(): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.resyncTmuxRuntimeSnapshot(handle).toCoreCallResult()
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle == 0L) return
        NativeCoreBindings.destroyTmuxRuntime(handle)
        eventSink.clear()
    }

    companion object {
        /** [feedAt]: accepted, and the read's event carried the session's result. */
        internal const val FEED_CARRIED_SESSION_RESULT = 1

        fun create(listener: CoreEventListener): TmuxCoreRuntime {
            val state = CoreBridge.inspect()
            check(state is CoreBridgeState.Ready) {
                "shared core unavailable: ${(state as CoreBridgeState.Failed).reason}"
            }
            val sink = NativeEventSink(listener)
            val handle = NativeCoreBindings.createTmuxRuntime(sink)
            check(handle != 0L) { "shared tmux core refused to create a runtime" }
            return TmuxCoreRuntime(handle, sink)
        }
    }
}

data class SharedTmuxGridSize(val columns: Int, val rows: Int)

/**
 * Shared resize/targetless-latest-fence/unset sequence, followed by a tagged
 * size query. Each mutation has its own FIFO reply; write the query only
 * after all three succeeded. The JNI/ABI returns lines, with no fixed count.
 */
object SharedTmuxWindowSizeReplay {
    enum class Decision { FITTING, WAITING, REPLAY }

    fun decision(
        requested: SharedTmuxGridSize,
        observed: SharedTmuxGridSize?,
        lastAttempt: SharedTmuxGridSize?,
    ): Decision {
        NativeLibraries.ensureLoaded()
        val result = NativeCoreBindings.tmuxWindowSizeReplayDecision(
            requested.columns,
            requested.rows,
            observed?.columns ?: 0,
            observed?.rows ?: 0,
            lastAttempt?.columns ?: 0,
            lastAttempt?.rows ?: 0,
        )
        require(result >= 0) { "shared tmux window-size replay rejected the grid" }
        return when (result) {
            0 -> Decision.FITTING
            1 -> Decision.WAITING
            2 -> Decision.REPLAY
            else -> error("unknown shared tmux window-size replay decision")
        }
    }

    fun commands(windowId: Int, requested: SharedTmuxGridSize): List<String> {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxWindowSizeReplayCommands(
            windowId, requested.columns, requested.rows,
        ).split('\n').filter(String::isNotBlank)
    }

    fun confirms(windowId: Int, requested: SharedTmuxGridSize, reply: String): Boolean {
        val bytes = reply.encodeToByteArray()
        if (bytes.size > 256) return false
        NativeLibraries.ensureLoaded()
        val result = NativeCoreBindings.tmuxWindowSizeReplayConfirm(
            windowId, requested.columns, requested.rows, bytes.toDirectBuffer(), bytes.size,
        )
        require(result >= 0) { "shared tmux window-size confirmation rejected the arguments" }
        return when (result) {
            0 -> false
            1 -> true
            else -> error("unknown shared tmux window-size confirmation result")
        }
    }

    /**
     * The tagged size read alone: the confirmation [commands] ends with, and
     * a take-back claim's settle probe (§6.10 rule 5), written in its own
     * write after the claim's fence was acknowledged.
     */
    fun sizeQuery(windowId: Int): String {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxWindowSizeReplaySizeQuery(windowId)
    }

    /** The grid a [sizeQuery] reply reports for [windowId], or null for a malformed one or one naming another window. */
    fun reportedGeometry(windowId: Int, reply: String): SharedTmuxGridSize? {
        val bytes = reply.encodeToByteArray()
        if (bytes.size > 256) return null
        NativeLibraries.ensureLoaded()
        val result = NativeCoreBindings.tmuxWindowSizeReplayReportedGeometry(windowId, bytes.toDirectBuffer(), bytes.size)
        require(result >= 0) { "shared tmux window-size report rejected the arguments" }
        if (result == 0L) return null
        return SharedTmuxGridSize((result ushr 32).toInt(), (result and 0xFFFF_FFFFL).toInt())
    }

    fun provesExclusiveOwnership(
        windowId: Int,
        controlIdentity: String,
        visibleIdentity: String,
        inventory: String,
    ): Boolean {
        val controlBytes = controlIdentity.encodeToByteArray()
        val visibleBytes = visibleIdentity.encodeToByteArray()
        val inventoryBytes = inventory.encodeToByteArray()
        if (controlBytes.size > 256 || visibleBytes.size > 256 || inventoryBytes.size > 65_536) return false
        NativeLibraries.ensureLoaded()
        val result = NativeCoreBindings.tmuxWindowSizeReplayProvesExclusiveOwnership(
            windowId,
            controlBytes.toDirectBuffer(), controlBytes.size,
            visibleBytes.toDirectBuffer(), visibleBytes.size,
            inventoryBytes.toDirectBuffer(), inventoryBytes.size,
        )
        require(result >= 0) { "shared tmux ownership proof rejected the arguments" }
        return when (result) {
            0 -> false
            1 -> true
            else -> error("unknown shared tmux ownership proof result")
        }
    }
}

/**
 * JNI projection of the same compact split-layout math used by iPhone. With a
 * layout tree the size is solved against tmux's own window resize; without
 * one the window is scaled by the focused pane's share. A caller that sizes on
 * every runtime event should hold a [SharedTmuxCompactSizer] instead, which
 * keeps answers until an input changes and threads the reprojection memo.
 */
object SharedTmuxGeometry {
    fun compactClientSize(
        viewport: SharedTmuxGridSize,
        layout: SharedTmuxLayoutNode?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
    ): SharedTmuxGridSize = compactClientSizeForCells(
        viewport, layout?.tmuxLayoutCellBytes(), focusPaneId, window, focus,
    )

    /**
     * What a layout update does to this compact client's advertisement.
     * [memo] is the value the previous call for the same tmux client
     * returned, [SharedTmuxCompactReprojectionMemo.FRESH] for a fresh client.
     */
    fun compactReprojection(
        viewport: SharedTmuxGridSize,
        lastClientSize: SharedTmuxGridSize?,
        layout: SharedTmuxLayoutNode?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
        memo: SharedTmuxCompactReprojectionMemo,
    ): SharedTmuxCompactReprojectionResult = compactReprojectionForCells(
        viewport, lastClientSize, layout?.tmuxLayoutCellBytes(), focusPaneId, window, focus, memo,
    )

    internal fun compactClientSizeForCells(
        viewport: SharedTmuxGridSize,
        layoutCells: ByteArray?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
    ): SharedTmuxGridSize {
        require(viewport.columns > 0 && viewport.rows > 0)
        NativeLibraries.ensureLoaded()
        val packed = NativeCoreBindings.compactTmuxClientSize(
            viewport.columns,
            viewport.rows,
            layoutCells?.toDirectBuffer(),
            layoutCells?.size ?: 0,
            focusPaneId ?: -1,
            window?.columns ?: 0,
            window?.rows ?: 0,
            focus?.columns ?: 0,
            focus?.rows ?: 0,
        )
        check(packed != 0L) { "shared compact tmux sizing rejected valid geometry" }
        return SharedTmuxGridSize(
            columns = (packed ushr 32).toInt(),
            rows = (packed and 0xffff_ffffL).toInt(),
        )
    }

    internal fun compactReprojectionForCells(
        viewport: SharedTmuxGridSize,
        lastClientSize: SharedTmuxGridSize?,
        layoutCells: ByteArray?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
        memo: SharedTmuxCompactReprojectionMemo,
    ): SharedTmuxCompactReprojectionResult {
        require(viewport.columns > 0 && viewport.rows > 0)
        NativeLibraries.ensureLoaded()
        val words = longArrayOf(memo.first, memo.second)
        val code = NativeCoreBindings.compactTmuxReprojection(
            viewport.columns,
            viewport.rows,
            lastClientSize?.columns ?: 0,
            lastClientSize?.rows ?: 0,
            layoutCells?.toDirectBuffer(),
            layoutCells?.size ?: 0,
            focusPaneId ?: -1,
            window?.columns ?: 0,
            window?.rows ?: 0,
            focus?.columns ?: 0,
            focus?.rows ?: 0,
            words,
        )
        val decision = when (code) {
            0 -> SharedTmuxCompactReprojection.HOLD
            1 -> SharedTmuxCompactReprojection.REPROJECT
            // 3 is the call that stopped the cycle, 2 every one after it.
            2, 3 -> SharedTmuxCompactReprojection.HOLD_CYCLE
            else -> error("shared compact tmux reproject decision rejected valid geometry")
        }
        return SharedTmuxCompactReprojectionResult(
            decision,
            SharedTmuxCompactReprojectionMemo(words[0], words[1]),
            stoppedCycle = code == 3,
        )
    }
}

/**
 * Where a compact device frames a tmux window so the focused pane fills the
 * screen. Cell metrics and the viewport are in device-independent points.
 */
data class SharedTmuxCanvasProjection(
    val contentWidth: Double,
    val contentHeight: Double,
    val scale: Double,
    val offsetX: Double,
    val offsetY: Double,
)

/** A tmux window or pane rectangle, in cells, within its window's origin. */
data class SharedTmuxCellRect(
    val columns: Int,
    val rows: Int,
    val x: Int = 0,
    val y: Int = 0,
)

/** The compact canvas transform the iPhone renderer applies, shared verbatim. */
object SharedTmuxCanvas {
    /** Null when the inputs are degenerate: render at natural size, untransformed. */
    fun projection(
        window: SharedTmuxCellRect,
        focus: SharedTmuxCellRect,
        cellWidth: Double,
        cellHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
    ): SharedTmuxCanvasProjection? {
        NativeLibraries.ensureLoaded()
        val values = DoubleArray(5)
        return when (
            NativeCoreBindings.compactTmuxCanvasProjection(
                window.columns, window.rows, window.x, window.y,
                focus.columns, focus.rows, focus.x, focus.y,
                cellWidth, cellHeight, viewportWidth, viewportHeight,
                values,
            )
        ) {
            0 -> null
            1 -> SharedTmuxCanvasProjection(
                contentWidth = values[0],
                contentHeight = values[1],
                scale = values[2],
                offsetX = values[3],
                offsetY = values[4],
            )
            else -> error("shared compact tmux canvas rejected valid geometry")
        }
    }
}

/**
 * Detection of a grid takeover by a client that never stamps
 * `@tessera_authority`, so every platform veils on the same evidence.
 */
object SharedTmuxPeerDetection {
    @Suppress("LongParameterList")
    fun shouldRaisePeer(
        participatesInAuthority: Boolean,
        windowSizePolicyKnown: Boolean,
        windowSizePolicyIsLatest: Boolean,
        rederiveInFlight: Boolean,
        alreadyPeer: Boolean,
        reclaimInFlight: Boolean,
        layoutIsForRenderedWindow: Boolean,
        layout: SharedTmuxGridSize,
        local: SharedTmuxGridSize,
        secondsSinceLocalSizeReplay: Double?,
    ): Boolean {
        NativeLibraries.ensureLoaded()
        return when (
            NativeCoreBindings.stamplessTmuxPeerShouldRaise(
                participatesInAuthority,
                windowSizePolicyKnown,
                windowSizePolicyIsLatest,
                rederiveInFlight,
                alreadyPeer,
                reclaimInFlight,
                layoutIsForRenderedWindow,
                layout.columns,
                layout.rows,
                local.columns,
                local.rows,
                secondsSinceLocalSizeReplay ?: -1.0,
            )
        ) {
            0 -> false
            1 -> true
            else -> error("shared stamp-less peer detection rejected valid inputs")
        }
    }
}

/**
 * The remote command lines the Apple clients run, built by the shared core so
 * both platforms attach with identical geometry semantics.
 */
/**
 * Names whoever holds the shared tmux grid. The rule is the core's: a stamped
 * name renders verbatim only when this platform recognises it as one of its own
 * device classes, so a peer from the other platform reads as "another device"
 * on both ends rather than as a raw foreign stamp.
 */
object SharedTmuxPeerLabel {
    /** The device classes this app stamps, and so the only names it can render. */
    val KNOWN_DEVICE_NAMES = setOf("Android-Phone", "Android-Tablet")

    fun display(
        peerDisplayName: String?,
        selfDisplayName: String,
        knownDeviceNames: Set<String> = KNOWN_DEVICE_NAMES,
    ): String {
        require(selfDisplayName.isNotBlank())
        NativeLibraries.ensureLoaded()
        // JNI converts the Core result as ordinary UTF-8, including emoji. A
        // NUL cannot be represented by the remote tmux command protocol.
        val peer = peerDisplayName?.takeIf { name ->
            name.none { it == '\u0000' }
        }?.encodeToByteArray()
        val self = selfDisplayName.encodeToByteArray()
        val known = knownDeviceNames.joinToString("\t").encodeToByteArray()
        return NativeCoreBindings.tmuxPeerLabel(
            peer?.toDirectBuffer(),
            peer?.size ?: 0,
            self.toDirectBuffer(),
            self.size,
            known.toDirectBuffer(),
            known.size,
        )
    }
}

/** Why a tmux launch never produced a usable control session. */
enum class SharedTmuxLaunchFailure(val rawValue: Int) {
    UNAVAILABLE(1),
    START_FAILED(2),
    NESTED(3),
}

/**
 * Shared classification of a tmux launch that ended without ever engaging
 * control mode. iOS reaches the same taxonomy by scanning its PTY one-liner's
 * sentinels; this side reports the exec channel's exit status and output.
 *
 * The caller must establish non-engagement first — an exit status on its own
 * cannot tell a failed launch from a session that died hours later.
 */
object SharedTmuxLaunch {
    fun classifyFailure(exitStatus: Int?, output: String): SharedTmuxLaunchFailure? {
        val bytes = output.encodeToByteArray()
        val raw = NativeCoreBindings.tmuxClassifyLaunchFailure(
            exitStatus ?: 0,
            exitStatus != null,
            bytes.toDirectBuffer(),
            bytes.size,
        )
        return SharedTmuxLaunchFailure.entries.firstOrNull { it.rawValue == raw }
    }
}

enum class SharedTmuxWindowOperation(val wireValue: String) {
    NewWindowAtEnd("newWindowAtEnd"),
    NewWindowAfterCurrent("newWindowAfterCurrent"),
    SelectWindow("selectWindow"),
    KillWindow("killWindow"),
    RenameWindow("renameWindow"),
    MoveWindowAfter("moveWindowAfter"),
    MoveWindowBefore("moveWindowBefore"),
    SwapWindows("swapWindows"),
    Renumber("renumber"),
    SessionGroupQuery("sessionGroupQuery"),
}

data class SharedTmuxWindowCapabilities(
    val supportsMoveBefore: Boolean,
    val supportsSubscriptions: Boolean,
)

data class SharedTmuxWindowReorderPlan(
    val commands: List<String>,
    val expectedOrder: List<Int>,
)

data class SharedTmuxSessionGroupMember(
    val sessionId: Int,
    val activeWindowId: Int,
)

object SharedTmuxCommands {
    /**
     * The built command crosses JNI as validated ordinary UTF-8, so non-BMP
     * scalar values are preserved. Shell arguments still cannot contain NUL.
     */
    private fun requireBridgeableTarget(sessionTarget: String) {
        require(sessionTarget.isNotBlank()) { "tmux session target must not be blank" }
        require(sessionTarget.none { it == '\u0000' }) {
            "tmux session target must not contain NUL"
        }
    }

    private fun sharedWindowJSON(fields: Map<String, Any>): ByteArray =
        SharedTmuxRenderFactEncoder.encodeDocument(fields)

    /** Build one command in shared Swift. Kotlin only transports the result. */
    fun windowCommand(
        operation: SharedTmuxWindowOperation,
        windowId: Int? = null,
        target: String? = null,
        name: String? = null,
        detached: Boolean? = null,
        printFormat: String? = null,
        command: String? = null,
        sessionId: Int? = null,
    ): String {
        require(windowId == null || windowId >= 0) { "window id must be non-negative" }
        require(sessionId == null || sessionId >= 0) { "session id must be non-negative" }
        val request = sharedWindowJSON(buildMap {
            put("op", operation.wireValue)
            windowId?.let { put("windowId", "@$it") }
            target?.let { put("target", it) }
            name?.let { put("name", it) }
            detached?.let { put("detached", it) }
            printFormat?.let { put("printFormat", it) }
            command?.let { put("command", it) }
            sessionId?.let { put("sessionId", "\$$it") }
        })
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxWindowCommand(request.toDirectBuffer(), request.size)
    }

    fun newWindowAtEnd(
        target: String? = null,
        detached: Boolean = false,
        name: String? = null,
        printFormat: String? = null,
        command: String? = null,
    ): String = windowCommand(
        SharedTmuxWindowOperation.NewWindowAtEnd,
        target = target,
        name = name,
        detached = detached.takeIf { it },
        printFormat = printFormat,
        command = command,
    )

    fun newWindowAfterCurrent(): String =
        windowCommand(SharedTmuxWindowOperation.NewWindowAfterCurrent)

    fun selectWindow(windowId: Int): String =
        windowCommand(SharedTmuxWindowOperation.SelectWindow, windowId = windowId)

    /**
     * A tab switch in this client's own session: `select-window -t '$S:@W'`.
     * Never use the bare [selectWindow] for one: tmux resolves a bare `@W` to
     * the most recently active session holding the window, which in a session
     * group can be a sibling (the mosh view session, a user's `tmux new -t`),
     * so the switch lands on someone else's screen.
     */
    fun selectWindowInOwnSession(windowId: Int, ownSessionId: Int): String =
        windowCommand(
            SharedTmuxWindowOperation.SelectWindow,
            windowId = windowId,
            sessionId = ownSessionId,
        )

    /**
     * The one session-qualified target spelling, `'$S:@W'` or `'$S:@W.%P'`,
     * for commands that must resolve a window (or a pane in it) inside a
     * named session, such as the visible mosh client's `switch-client -t`.
     * Single-quoted in shared Swift so tmux never reads the `$` as an
     * environment expansion.
     */
    fun sessionWindowTarget(sessionId: Int, windowId: Int, paneId: Int? = null): String {
        require(sessionId >= 0 && windowId >= 0 && (paneId == null || paneId >= 0)) {
            "tmux ids must be non-negative"
        }
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxSessionWindowTarget(sessionId, windowId, paneId ?: -1)
    }

    fun killWindow(windowId: Int): String =
        windowCommand(SharedTmuxWindowOperation.KillWindow, windowId = windowId)

    fun renameWindow(windowId: Int, name: String): String =
        windowCommand(SharedTmuxWindowOperation.RenameWindow, windowId = windowId, name = name)

    fun moveWindowAfter(windowId: Int, targetWindowId: Int): String =
        windowCommand(
            SharedTmuxWindowOperation.MoveWindowAfter,
            windowId = windowId,
            target = "@$targetWindowId",
        )

    fun moveWindowBefore(windowId: Int, targetWindowId: Int): String =
        windowCommand(
            SharedTmuxWindowOperation.MoveWindowBefore,
            windowId = windowId,
            target = "@$targetWindowId",
        )

    fun swapWindows(firstWindowId: Int, secondWindowId: Int): String =
        windowCommand(
            SharedTmuxWindowOperation.SwapWindows,
            windowId = firstWindowId,
            target = "@$secondWindowId",
        )

    fun renumberWindows(target: String): String =
        windowCommand(SharedTmuxWindowOperation.Renumber, target = target)

    fun windowCapabilities(version: String): SharedTmuxWindowCapabilities {
        val request = sharedWindowJSON(mapOf("version" to version))
        NativeLibraries.ensureLoaded()
        val response = org.json.JSONObject(
            NativeCoreBindings.tmuxWindowCapabilities(request.toDirectBuffer(), request.size),
        )
        return SharedTmuxWindowCapabilities(
            supportsMoveBefore = response.getBoolean("supportsMoveBefore"),
            supportsSubscriptions = response.getBoolean("supportsSubscriptions"),
        )
    }

    fun windowReorderPlan(
        order: List<Int>,
        moving: Int,
        destination: Int,
        capabilities: SharedTmuxWindowCapabilities,
        sessionId: Int,
        activeWindowId: Int?,
        highestIndex: Int?,
    ): SharedTmuxWindowReorderPlan? {
        require(order.all { it >= 0 } && moving >= 0 && sessionId >= 0) {
            "tmux ids must be non-negative"
        }
        val request = sharedWindowJSON(buildMap {
            put("order", order.map { "@$it" })
            put("moving", "@$moving")
            put("destination", destination)
            put("capabilities", mapOf(
                "supportsMoveBefore" to capabilities.supportsMoveBefore,
                "supportsSubscriptions" to capabilities.supportsSubscriptions,
            ))
            put("sessionID", "\$$sessionId")
            activeWindowId?.let { put("activeWindowID", "@$it") }
            highestIndex?.let { put("highestIndex", it) }
        })
        NativeLibraries.ensureLoaded()
        val encoded = try {
            NativeCoreBindings.tmuxWindowReorderPlan(request.toDirectBuffer(), request.size)
        } catch (_: IllegalArgumentException) {
            return null
        }
        val response = org.json.JSONObject(encoded)
        fun stringList(key: String): List<String> = response.getJSONArray(key).let { values ->
            List(values.length()) { index -> values.getString(index) }
        }
        val expectedOrder = stringList("expectedOrder").map { value ->
            require(value.startsWith('@')) { "shared reorder plan returned an invalid window id" }
            value.substring(1).toInt()
        }
        return SharedTmuxWindowReorderPlan(
            commands = stringList("commands"),
            expectedOrder = expectedOrder,
        )
    }

    fun sessionGroupQueryCommand(): String =
        windowCommand(SharedTmuxWindowOperation.SessionGroupQuery)

    fun sessionGroupMembers(
        lines: List<String>,
        containingSessionId: Int,
    ): List<SharedTmuxSessionGroupMember>? {
        require(containingSessionId >= 0) { "session id must be non-negative" }
        val request = sharedWindowJSON(mapOf(
            "containingSessionID" to "\$$containingSessionId",
            "lines" to lines,
        ))
        NativeLibraries.ensureLoaded()
        val encoded = try {
            NativeCoreBindings.tmuxSessionGroupMembers(request.toDirectBuffer(), request.size)
        } catch (_: IllegalArgumentException) {
            return null
        }
        val values = org.json.JSONArray(encoded)
        return List(values.length()) { index ->
            val member = values.getJSONObject(index)
            SharedTmuxSessionGroupMember(
                sessionId = member.getString("sessionID").removePrefix("\$").toInt(),
                activeWindowId = member.getString("activeWindowID").removePrefix("@").toInt(),
            )
        }
    }

    fun renumberPlan(
        members: List<SharedTmuxSessionGroupMember>,
        attachedSessionId: Int,
    ): SharedTmuxWindowMutationPlan? {
        require(attachedSessionId >= 0) { "session id must be non-negative" }
        val request = sharedWindowJSON(mapOf(
            "structured" to true,
            "attachedSessionID" to "\$$attachedSessionId",
            "members" to members.map { member ->
                mapOf(
                    "activeWindowID" to "@${member.activeWindowId}",
                    "sessionID" to "\$${member.sessionId}",
                )
            },
        ))
        NativeLibraries.ensureLoaded()
        val encoded = try {
            NativeCoreBindings.tmuxSessionGroupRenumberCommands(
                request.toDirectBuffer(), request.size,
            )
        } catch (_: IllegalArgumentException) {
            return null
        }
        val value = org.json.JSONObject(encoded)
        fun strings(key: String): List<String> = value.getJSONArray(key).let { values ->
            List(values.length()) { values.getString(it) }
        }
        return SharedTmuxWindowMutationPlan(strings("mutationCommands"), strings("selectionRestoreCommands"))
    }

    fun renumberCommands(members: List<SharedTmuxSessionGroupMember>, attachedSessionId: Int): List<String>? =
        renumberPlan(members, attachedSessionId)?.let { it.mutationCommands + it.selectionRestoreCommands }

    fun splitPane(id: String, horizontal: Boolean, before: Boolean): String {
        val request = sharedWindowJSON(mapOf("op" to "splitPane", "paneId" to id, "horizontal" to horizontal, "before" to before))
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxWindowCommand(request.toDirectBuffer(), request.size)
    }

    /**
     * Open the live pane-metadata feed. tmux announces window renames but never
     * pane title changes, so without this a client's tab labels freeze at the
     * `#{window_name}` that was current when it attached. The runtime parses
     * the payloads itself; subscribing is the whole client-side job.
     */
    /**
     * The fixed hydration queries, in send order. Owned by the core because it
     * parses their tagged replies; a local copy drifts out of step with the
     * parser the moment a field is added.
     */
    fun hydrationCommands(): List<String> {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxHydrationCommands().split('\n').filter(String::isNotBlank)
    }

    /**
     * The fixed active-window query is useful as a causal fence after a
     * platform-owned `select-window`: its tagged reply is folded into the
     * shared runtime snapshot before the correlated platform reply is
     * delivered. Return null if the shared command inventory is ambiguous so
     * callers fail closed instead of issuing a locally reconstructed query.
     */
    fun activeWindowHydrationCommand(): String? = hydrationCommands()
        .filter { it.startsWith("display-message -p ") && it.contains("__tessera_active_window__") }
        .singleOrNull()

    /** Exact causal result paired with [activeWindowHydrationCommand]. */
    fun activeWindowHydrationMatches(windowId: Int, lines: List<String>): Boolean {
        if (windowId < 0) return false
        val row = lines.filter(String::isNotBlank).singleOrNull() ?: return false
        val fields = row.split('\t')
        // Current attach queries carry `#{version}` in field three so the
        // shared runtime can derive window capabilities. Keep accepting the
        // two-field legacy vector exactly as the shared parser does.
        return fields.size in 2..3 &&
            fields[0] == "__tessera_active_window__" &&
            fields[1] == "@$windowId"
    }

    /** Core-owned causal active-pane query paired with the runtime parser. */
    fun activePaneHydrationCommand(windowId: Int): String? {
        if (windowId < 0) return null
        NativeLibraries.ensureLoaded()
        return runCatching { NativeCoreBindings.tmuxActivePaneCommand(windowId) }
            .getOrNull()
            ?.takeIf(String::isNotBlank)
    }

    /** Exact causal result paired with [activePaneHydrationCommand]. */
    fun activePaneHydrationMatches(
        windowId: Int,
        paneId: Int,
        lines: List<String>,
    ): Boolean = windowId >= 0 && paneId >= 0 &&
        lines.filter(String::isNotBlank) == listOf(
            "__tessera_active_pane__\t@$windowId\t%$paneId",
        )

    /**
     * The commands that advertise this device's grid, in send order. Owned by
     * the core: on the inline path `refresh-client -C` is fenced with a
     * targetless no-op `select-window` so this client becomes tmux's `latest`
     * and the size is applied even after another client attached or typed;
     * the mosh side channel uses [SharedTmuxWindowSizeReplay] to fence latest
     * before restoring each window's policy. A replay
     * that belongs to a take-back claim gets the refresh alone — the claim
     * acks and fences it itself. Empty for a grid tmux would reject.
     */
    fun clientSizeReplayCommands(
        columns: Int,
        rows: Int,
        sideChannel: Boolean,
        belongsToClaim: Boolean = false,
    ): List<String> {
        if (columns < 1 || rows < 1) return emptyList()
        NativeLibraries.ensureLoaded()
        val joined = try {
            NativeCoreBindings.tmuxClientSizeReplayCommands(columns, rows, sideChannel, belongsToClaim)
        } catch (rejected: IllegalArgumentException) {
            return emptyList()
        }
        return joined.split('\n').filter(String::isNotBlank)
    }

    /**
     * The shared core's S5′ gate of every backend operation kind code, for
     * the test that checks [SharedBackendCommand.authorityGate] against it.
     */
    val sessionAuthorityGates: Map<String, String> by lazy {
        NativeLibraries.ensureLoaded()
        val json = org.json.JSONObject(NativeCoreBindings.sessionAuthorityGates())
        json.keys().asSequence().associateWith(json::getString)
    }

    /**
     * The inline replay's `latest` fence alone (a targetless
     * `select-window`), for the fence a take-back claim sends itself. The
     * core's literal, so neither platform keeps a copy of it.
     */
    val clientSizeLatestFenceCommand: String by lazy {
        NativeLibraries.ensureLoaded()
        NativeCoreBindings.tmuxClientSizeLatestFenceCommand()
    }

    fun authorityVisibleClientOption(deviceId: String): String {
        require(deviceId.isNotBlank())
        NativeLibraries.ensureLoaded()
        val bytes = deviceId.encodeToByteArray()
        return NativeCoreBindings.tmuxAuthorityVisibleClientOption(
            bytes.toDirectBuffer(), bytes.size,
        )
    }

    private fun authorityCommands(op: String, ownerSessionId: Int? = null, stamp: String? = null, name: String? = null): List<String> {
        require(ownerSessionId == null || ownerSessionId >= 0)
        val request = sharedWindowJSON(buildMap {
            put("op", op)
            ownerSessionId?.let { put("ownerSessionID", "\$$it") }
            stamp?.let { put("stamp", it) }
            name?.let { put("name", it) }
        })
        NativeLibraries.ensureLoaded()
        val values = org.json.JSONArray(NativeCoreBindings.tmuxAuthorityCommands(request.toDirectBuffer(), request.size))
        return List(values.length()) { values.getString(it) }
    }

    fun authorityQueryCommand(ownerSessionId: Int? = null): String = authorityCommands("query", ownerSessionId).single()
    fun authorityWriteCommands(stamp: String, ownerSessionId: Int? = null): List<String> = authorityCommands("write", ownerSessionId, stamp)
    fun authorityOwnerResolutionCommands(name: String): List<String> = authorityCommands("ownerResolution", name = name)
    /** A read reply's stamp lines as `show-options -qv` gives them, or null when an owner read found no owner. */
    fun authorityQueryReplyLines(reply: List<String>, ownerSessionId: Int? = null): List<String>? {
        require(ownerSessionId == null || ownerSessionId >= 0)
        val request = sharedWindowJSON(buildMap {
            ownerSessionId?.let { put("ownerSessionID", "\$$it") }
            put("reply", reply)
        })
        NativeLibraries.ensureLoaded()
        val text = NativeCoreBindings.tmuxAuthorityQueryReply(request.toDirectBuffer(), request.size)
        if (text == "null") return null
        val values = org.json.JSONArray(text)
        return List(values.length()) { values.getString(it) }
    }
    /**
     * Whether an Agent Center tmux command only reads, and so may run while
     * another device holds the grid (S5′, D13); the core owns the verb list.
     */
    fun agentCommandIsReadOnly(command: String): Boolean {
        val bytes = command.encodeToByteArray()
        if (bytes.isEmpty()) return false
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxAgentCommandIsReadOnly(bytes.toDirectBuffer(), bytes.size) == 1
    }

    /** Reads and exact pane-targeted replies leave grid authority unchanged. */
    fun agentCommandIsAuthorityNeutral(command: String): Boolean {
        val bytes = command.encodeToByteArray()
        if (bytes.isEmpty()) return false
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.tmuxAgentCommandIsAuthorityNeutral(bytes.toDirectBuffer(), bytes.size) == 1
    }

    fun authorityResolveOwner(ownerReply: List<String>?, ownReply: List<String>?): Int? {
        val request = sharedWindowJSON(buildMap {
            ownerReply?.let { put("ownerReply", it) }
            ownReply?.let { put("ownReply", it) }
        })
        NativeLibraries.ensureLoaded()
        val id = NativeCoreBindings.tmuxAuthorityResolveOwner(request.toDirectBuffer(), request.size)
        return id.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt()
    }

    fun authorityStampValue(deviceId: String, displayName: String, generation: Long): String {
        require(deviceId.isNotBlank() && displayName.isNotBlank() && generation >= 0)
        NativeLibraries.ensureLoaded()
        val device = deviceId.encodeToByteArray()
        val display = displayName.encodeToByteArray()
        return NativeCoreBindings.tmuxAuthorityStampValue(
            device.toDirectBuffer(), device.size,
            display.toDirectBuffer(), display.size,
            generation,
        )
    }

    /**
     * The visible tmux client a mosh session runs. It attaches with
     * `ignore-size` so one device's SSP resize cannot yank the shared grid;
     * sizing runs through the `-CC` side channel instead.
     */
    fun moshVisibleClientCommand(
        sessionTarget: String,
        gridAuthorityDeviceId: String? = null,
        ignoresSize: Boolean = true,
    ): String {
        requireBridgeableTarget(sessionTarget)
        NativeLibraries.ensureLoaded()
        val target = sessionTarget.encodeToByteArray()
        val deviceId = gridAuthorityDeviceId?.encodeToByteArray()
        return NativeCoreBindings.moshVisibleTmuxClientCommand(
            target.toDirectBuffer(),
            target.size,
            deviceId?.toDirectBuffer(),
            deviceId?.size ?: 0,
            ignoresSize,
        )
    }

    /**
     * Tessera's private view of a user tmux session: a second session in the
     * same group, sharing its windows but carrying Tessera's own options, so
     * nothing Tessera prefers is ever written to the session the user asked
     * for.
     */
    fun moshViewSessionName(sessionTarget: String): String {
        requireBridgeableTarget(sessionTarget)
        NativeLibraries.ensureLoaded()
        val target = sessionTarget.encodeToByteArray()
        return NativeCoreBindings.moshTmuxViewSessionName(
            target.toDirectBuffer(),
            target.size,
        )
    }

    /**
     * The `-CC` control channel a mosh session opens beside its visible
     * client. Both join Tessera's own view of the session, so selecting a
     * window from the control channel moves the visible client with it.
     */
    fun moshControlChannelCommand(
        sessionTarget: String,
        preserveInitialGeometry: Boolean = false,
    ): String {
        requireBridgeableTarget(sessionTarget)
        NativeLibraries.ensureLoaded()
        val target = sessionTarget.encodeToByteArray()
        return NativeCoreBindings.moshTmuxControlChannelCommand(
            target.toDirectBuffer(),
            target.size,
            preserveInitialGeometry,
        )
    }

    /**
     * The `-CC` control-mode client. It is the device's sizing participant on
     * every form factor; `preserveInitialGeometry` is the ceded-observer state
     * only and must never be requested at attach time.
     */
    fun controlModeSessionCommand(
        sessionTarget: String,
        preserveInitialGeometry: Boolean = false,
    ): String {
        requireBridgeableTarget(sessionTarget)
        NativeLibraries.ensureLoaded()
        val target = sessionTarget.encodeToByteArray()
        return NativeCoreBindings.controlModeTmuxSessionCommand(
            target.toDirectBuffer(),
            target.size,
            preserveInitialGeometry,
        )
    }
}

/** The same deterministic auto-tmux target policy used by the Apple apps. */
object SharedAutomaticTmuxTarget {
    fun sessionName(username: String, hostname: String, port: Int): String {
        require(username.isNotBlank() && hostname.isNotBlank() && port in 1..65535)
        NativeLibraries.ensureLoaded()
        val hostKey = "$username@$hostname:$port".encodeToByteArray()
        return NativeCoreBindings.defaultTmuxSessionName(hostKey.toDirectBuffer(), hostKey.size)
    }
}

/** Shared tmux capture-pane parser and repaint assembler used by the Apple clients. */
object SharedTmuxRepaint {
    fun assemble(
        metadataLine: String,
        captureLines: List<String>,
        terminalIsInAltScreen: Boolean,
        clientRows: Int,
    ): ByteArray {
        require(metadataLine.isNotBlank())
        NativeLibraries.ensureLoaded()
        val metadata = metadataLine.encodeToByteArray()
        val capture = captureLines.joinToString("\n").encodeToByteArray()
        // Some JNI implementations do not expose an address for a zero-capacity
        // direct buffer. Keep the logical payload empty while supplying native code
        // a stable address so an empty tmux pane still repaints correctly.
        val captureStorage = if (capture.isEmpty()) byteArrayOf(0) else capture
        return NativeCoreBindings.assembleTmuxRepaint(
            metadata.toDirectBuffer(), metadata.size,
            captureStorage.toDirectBuffer(), capture.size,
            terminalIsInAltScreen, clientRows,
        )
    }
}

/**
 * JNI projection of the shared CrossDevicePairingRuntime.  Kotlin owns only
 * canonical ABI command bytes, QR/camera/socket adapters, and presentation;
 * pairing, encrypted records, replay rejection, and transaction ordering stay
 * inside TesseraCrossDeviceCore.
 */
class CrossDeviceRuntime private constructor(
    handle: Long,
    private val eventSink: NativeEventSink,
) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)

    fun sendCanonical(command: ByteArray): CoreCallResult {
        require(command.isNotEmpty() && command.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES) {
            "cross-device command must contain 1..${CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES} bytes"
        }
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        val buffer = command.toDirectBuffer()
        return NativeCoreBindings.sendCrossDeviceRuntime(handle, buffer, 0, command.size).toCoreCallResult()
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle == 0L) return
        NativeCoreBindings.destroyCrossDeviceRuntime(handle)
        eventSink.clear()
    }

    companion object {
        fun create(listener: CoreEventListener): CrossDeviceRuntime {
            val state = CoreBridge.inspectCrossDevice()
            check(state is CrossDeviceBridgeState.Ready) {
                "cross-device core unavailable: ${(state as CrossDeviceBridgeState.Failed).reason}"
            }
            val sink = NativeEventSink(listener)
            val handle = NativeCoreBindings.createCrossDeviceRuntime(sink)
            check(handle != 0L) { "shared core refused to create a cross-device runtime" }
            return CrossDeviceRuntime(handle, sink)
        }
    }
}

internal class NativeEventSink(listener: CoreEventListener) {
    @Volatile
    private var listener: CoreEventListener? = listener

    @Suppress("unused") // Called by tessera_core_jni.cpp.
    fun onEvent(buffer: ByteBuffer) {
        val copy = ByteArray(buffer.remaining())
        buffer.get(copy)
        listener?.onEvent(CoreEvent(copy))
    }

    fun clear() {
        listener = null
    }
}

internal object NativeLibraries {
    private val loaded: Unit by lazy {
        System.loadLibrary("TesseraCoreAndroid")
        System.loadLibrary("tessera_core_jni")
    }

    fun ensureLoaded() = loaded
}

internal object NativeCoreBindings {
    external fun agentIngestionReadStatus(request: java.nio.ByteBuffer, requestCount: Int): String
    external fun agentInitialLoadPageCount(): Int
    external fun agentProcessProofTimeoutMilliseconds(): Long
    external fun agentReadRetryDelayMilliseconds(consecutiveFailures: Int): Long
    external fun agentInitialLoadShouldPrefetch(completedPages: Int, flags: Int): Boolean

    external fun abiVersion(): Int

    external fun maxPayloadBytes(): Long

    external fun createRuntime(eventSink: NativeEventSink): Long

    external fun sendRuntime(
        handle: Long,
        payload: ByteBuffer,
        offset: Int,
        count: Int,
    ): Int

    external fun emitRuntime(
        handle: Long,
        payload: ByteBuffer,
        offset: Int,
        count: Int,
    ): Int

    external fun destroyRuntime(handle: Long)

    external fun createTmuxRuntime(eventSink: NativeEventSink): Long

    external fun feedTmuxRuntime(handle: Long, payload: ByteBuffer, offset: Int, count: Int): Int

    external fun feedTmuxRuntimeAt(handle: Long, payload: ByteBuffer, offset: Int, count: Int, nowMillis: Long): Int

    external fun attachTmuxRuntimeAuthoritySession(handle: Long, session: Long): Int

    external fun redeliverTmuxRuntimeAuthorityResult(handle: Long, nowMillis: Long): Int

    /** Returns a positive command-reply tag, -1 invalid input, or -2 stale handle. */
    external fun sendTmuxRuntimeCommand(
        handle: Long,
        command: ByteBuffer,
        count: Int,
    ): Long

    external fun queueTmuxRuntimeCommand(
        handle: Long,
        command: ByteBuffer,
        count: Int,
    ): Long

    /** Submits one canonical, byte-free RenderFact v1 JSON document. */
    external fun submitTmuxRenderFact(
        handle: Long,
        fact: ByteBuffer,
        count: Int,
    ): Int

    /**
     * Two-pass feed payload copy: null output queries the count without
     * consuming; a sufficient direct output copies and consumes the ref.
     */
    external fun takeTmuxRenderBytes(
        handle: Long,
        bytesRef: Long,
        output: ByteBuffer?,
        outputCapacity: Int,
    ): Int

    /** Bytes written; -1 means refused, -2 means a stale handle. */
    external fun projectTmuxAuthorityReleasing(
        handle: Long, authority: ByteBuffer, authorityCount: Int,
        output: ByteBuffer, outputCapacity: Int,
    ): Int

    /** 0, -1 for an undefined option bit, -2 for a stale handle. */
    external fun setTmuxRenderLedgerOptions(handle: Long, options: Int): Int

    external fun setTmuxProgramStatusEnabled(handle: Long, enabled: Boolean): Int
    external fun setTmuxSubscriptions(handle: Long, feeds: Int, authorityOwnerSessionId: Long): Int
    external fun copyTmuxProgramStatus(handle: Long, output: ByteBuffer?, outputCapacity: Int): Int
    external fun acknowledgeTmuxProgramStatus(handle: Long, paneId: Long, through: Long): Int

    external fun createProgramStatusMonitor(): Long
    external fun destroyProgramStatusMonitor(handle: Long)
    external fun setProgramStatusMonitorEnabled(handle: Long, enabled: Boolean): Int
    external fun feedProgramStatusMonitor(
        handle: Long, input: ByteBuffer?, count: Int,
        reply: ByteBuffer?, replyCapacity: Int, revisionOut: LongArray?,
    ): Int
    external fun copyProgramStatusMonitorSnapshot(handle: Long, output: ByteBuffer?, outputCapacity: Int): Int
    external fun acknowledgeProgramStatusMonitor(handle: Long, through: Long): Int
    external fun noteProgramStatusMonitorTransportLost(handle: Long): Int

    external fun resyncTmuxRuntimeSnapshot(handle: Long): Int

    external fun tmuxHydrationCommands(): String

    external fun tmuxWindowCommand(request: ByteBuffer, requestCount: Int): String

    external fun tmuxWindowReorderPlan(request: ByteBuffer, requestCount: Int): String

    external fun tmuxWindowCapabilities(request: ByteBuffer, requestCount: Int): String

    external fun tmuxSessionGroupMembers(request: ByteBuffer, requestCount: Int): String

    external fun tmuxSessionGroupRenumberCommands(request: ByteBuffer, requestCount: Int): String

    external fun tmuxActivePaneCommand(windowId: Int): String

    external fun tmuxSessionWindowTarget(sessionId: Int, windowId: Int, paneId: Int): String

    external fun tmuxClientSizeReplayCommands(
        columns: Int,
        rows: Int,
        sideChannel: Boolean,
        belongsToClaim: Boolean,
    ): String

    external fun tmuxWindowSizeReplayDecision(
        requestedColumns: Int,
        requestedRows: Int,
        observedColumns: Int,
        observedRows: Int,
        lastAttemptColumns: Int,
        lastAttemptRows: Int,
    ): Int

    external fun tmuxWindowSizeReplayCommands(windowId: Int, columns: Int, rows: Int): String

    external fun tmuxWindowSizeReplayConfirm(
        windowId: Int,
        columns: Int,
        rows: Int,
        reply: ByteBuffer,
        replyCount: Int,
    ): Int

    external fun tmuxWindowSizeReplaySizeQuery(windowId: Int): String

    external fun tmuxWindowSizeReplayReportedGeometry(windowId: Int, reply: ByteBuffer, replyCount: Int): Long

    external fun tmuxWindowSizeReplayProvesExclusiveOwnership(
        windowId: Int,
        controlIdentity: ByteBuffer,
        controlIdentityCount: Int,
        visibleIdentity: ByteBuffer,
        visibleIdentityCount: Int,
        inventory: ByteBuffer,
        inventoryCount: Int,
    ): Int

    external fun tmuxAuthorityCommands(request: ByteBuffer, requestCount: Int): String
    external fun tmuxAuthorityQueryReply(request: ByteBuffer, requestCount: Int): String
    external fun tmuxAuthorityResolveOwner(request: ByteBuffer, requestCount: Int): Long
    external fun tmuxAgentCommandIsReadOnly(command: ByteBuffer, commandCount: Int): Int
    external fun tmuxAgentCommandIsAuthorityNeutral(command: ByteBuffer, commandCount: Int): Int
    external fun tmuxClientSizeLatestFenceCommand(): String

    external fun sessionAuthorityGates(): String

    external fun tmuxClassifyLaunchFailure(
        exitStatus: Int,
        hasExitStatus: Boolean,
        output: ByteBuffer?,
        outputCount: Int,
    ): Int

    external fun tmuxPeerLabel(
        peerDisplayName: ByteBuffer?,
        peerDisplayNameCount: Int,
        selfDisplayName: ByteBuffer,
        selfDisplayNameCount: Int,
        knownDeviceNames: ByteBuffer?,
        knownDeviceNamesCount: Int,
    ): String

    external fun destroyTmuxRuntime(handle: Long)

    external fun tmuxAuthorityVisibleClientOption(deviceId: ByteBuffer, deviceIdCount: Int): String

    external fun tmuxAuthorityStampValue(
        deviceId: ByteBuffer,
        deviceIdCount: Int,
        displayName: ByteBuffer,
        displayNameCount: Int,
        generation: Long,
    ): String

    external fun createTmuxAuthorityLifecycleSeeded(initialGeneration: Long): Long
    external fun createTmuxAuthorityLifecycle(): Long

    external fun reduceTmuxAuthorityLifecycle(
        handle: Long,
        request: ByteBuffer,
        count: Int,
    ): ByteArray?

    external fun destroyTmuxAuthorityLifecycle(handle: Long)

    external fun createTmuxShowEdges(): Long

    external fun reduceTmuxShowEdges(
        handle: Long,
        request: ByteBuffer,
        count: Int,
    ): ByteArray?

    external fun destroyTmuxShowEdges(handle: Long)

    external fun moshVisibleTmuxClientCommand(
        sessionTarget: ByteBuffer,
        sessionTargetCount: Int,
        gridAuthorityDeviceId: ByteBuffer?,
        gridAuthorityDeviceIdCount: Int,
        ignoresSize: Boolean,
    ): String

    external fun moshTmuxViewSessionName(
        sessionTarget: ByteBuffer,
        sessionTargetCount: Int,
    ): String

    external fun moshTmuxControlChannelCommand(
        sessionTarget: ByteBuffer,
        sessionTargetCount: Int,
        preserveInitialGeometry: Boolean,
    ): String

    external fun controlModeTmuxSessionCommand(
        sessionTarget: ByteBuffer,
        sessionTargetCount: Int,
        preserveInitialGeometry: Boolean,
    ): String

    external fun compactTmuxCanvasProjection(
        windowColumns: Int,
        windowRows: Int,
        windowX: Int,
        windowY: Int,
        focusColumns: Int,
        focusRows: Int,
        focusX: Int,
        focusY: Int,
        cellWidth: Double,
        cellHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        output: DoubleArray,
    ): Int

    external fun stamplessTmuxPeerShouldRaise(
        participatesInAuthority: Boolean,
        windowSizePolicyKnown: Boolean,
        windowSizePolicyIsLatest: Boolean,
        rederiveInFlight: Boolean,
        alreadyPeer: Boolean,
        reclaimInFlight: Boolean,
        layoutIsForRenderedWindow: Boolean,
        layoutColumns: Int,
        layoutRows: Int,
        localColumns: Int,
        localRows: Int,
        secondsSinceLocalSizeReplay: Double,
    ): Int

    external fun compactTmuxClientSize(
        viewportColumns: Int,
        viewportRows: Int,
        layout: ByteBuffer?,
        layoutCount: Int,
        focusPaneId: Int,
        windowColumns: Int,
        windowRows: Int,
        focusColumns: Int,
        focusRows: Int,
    ): Long

    external fun compactTmuxReprojection(
        viewportColumns: Int,
        viewportRows: Int,
        lastColumns: Int,
        lastRows: Int,
        layout: ByteBuffer?,
        layoutCount: Int,
        focusPaneId: Int,
        windowColumns: Int,
        windowRows: Int,
        focusColumns: Int,
        focusRows: Int,
        /** Two words, read and replaced in place. */
        memo: LongArray,
    ): Int

    external fun defaultTmuxSessionName(hostKey: ByteBuffer, count: Int): String

    external fun assembleTmuxRepaint(
        metadata: ByteBuffer,
        metadataCount: Int,
        capture: ByteBuffer,
        captureCount: Int,
        terminalIsInAltScreen: Boolean,
        clientRows: Int,
    ): ByteArray

    external fun crossDeviceAbiVersion(): Int

    external fun crossDeviceMaxPayloadBytes(): Long

    external fun createCrossDeviceRuntime(eventSink: NativeEventSink): Long

    external fun sendCrossDeviceRuntime(
        handle: Long,
        payload: ByteBuffer,
        offset: Int,
        count: Int,
    ): Int

    external fun destroyCrossDeviceRuntime(handle: Long)

    external fun agentAbiVersion(): Int

    external fun agentMaxPayloadBytes(): Long

    external fun agentIntegrationAbiVersion(): Int

    external fun agentIntegrationMaxConfigBytes(): Long

    external fun agentIntegrationMaxInstallAttempts(): Int
    external fun agentIntegrationCheckPolicy(consecutiveFailures: Int): String

    external fun agentIntegrationStatusCommand(): String
    external fun agentHostDeploymentCommand(request: ByteBuffer, requestCount: Int): String

    external fun agentIntegrationCodexHooksReadCommand(): String

    external fun agentIntegrationClaudeSettingsReadCommand(): String

    external fun agentIntegrationKimiConfigReadCommand(): String

    external fun agentIntegrationShellStatusCommand(processIDs: ByteBuffer, processIDsCount: Int): String

    external fun agentIntegrationProcessDiscoveryCommand(scope: ByteBuffer, scopeCount: Int): String

    external fun agentIntegrationParseStatus(input: ByteBuffer, inputCount: Int): String

    external fun agentIntegrationClassifyInstallOutput(input: ByteBuffer, inputCount: Int): String

    external fun agentIntegrationParseShellStatus(input: ByteBuffer, inputCount: Int): String

    external fun agentIntegrationParseLifecycleEvent(input: ByteBuffer, inputCount: Int): String
    external fun agentProjectorDiagnostics(input: ByteBuffer, inputCount: Int): String

    external fun agentMarkdownParse(input: ByteBuffer?, inputCount: Int): String?
    external fun agentPageSearch(input: ByteBuffer, inputCount: Int): String

    external fun agentIntegrationParseConfigs(input: ByteBuffer, inputCount: Int): String

    external fun agentIntegrationParseProcessDiscovery(
        scope: ByteBuffer?,
        scopeCount: Int,
        input: ByteBuffer,
        inputCount: Int,
    ): String

    external fun agentIntegrationApplyCurrentShellCommand(): String

    external fun agentIntegrationPersistApplyCurrentShellCommand(): String

    external fun agentIntegrationInstallCommand(
        codexPresent: Boolean,
        codex: ByteBuffer?,
        codexCount: Int,
        claudePresent: Boolean,
        claude: ByteBuffer?,
        claudeCount: Int,
        kimiPresent: Boolean,
        kimi: ByteBuffer?,
        kimiCount: Int,
    ): String

    external fun agentIntegrationResolve(request: ByteBuffer, requestCount: Int): String

    external fun agentComposerMatches(request: ByteBuffer, requestCount: Int): Boolean
    external fun agentComposerAssess(request: ByteBuffer, requestCount: Int): Int
    external fun agentComposerInsertion(request: ByteBuffer, requestCount: Int): String

    external fun classifyAgentProviders(
        descriptors: ByteBuffer,
        descriptorCount: Int,
    ): String

    external fun createAgentRuntime(eventSink: NativeAgentEventSink): Long

    external fun sendAgentRuntime(
        handle: Long,
        payload: ByteBuffer,
        offset: Int,
        count: Int,
    ): Int

    /** Returns canonical response byte count, or -1 malformed / -2 stale. */
    external fun registerAgentPlatformProof(
        handle: Long,
        registration: ByteBuffer,
        registrationOffset: Int,
        registrationCount: Int,
        response: ByteBuffer,
        responseOffset: Int,
        responseCapacity: Int,
    ): Int

    /** Returns canonical response byte count, or -1 malformed / -2 stale. */
    external fun registerAgentPlatformBinding(
        handle: Long,
        registration: ByteBuffer,
        registrationOffset: Int,
        registrationCount: Int,
        response: ByteBuffer,
        responseOffset: Int,
        responseCapacity: Int,
    ): Int

    /** Compiled-attestation-only Tier-C conformance registration. */
    external fun registerAgentPlatformConformances(
        handle: Long,
        registration: ByteBuffer,
        registrationOffset: Int,
        registrationCount: Int,
    ): Int

    external fun registerAgentPlatformCandidate(
        handle: Long,
        registration: ByteBuffer,
        registrationOffset: Int,
        registrationCount: Int,
    ): Int

    external fun removeAgentPlatformCandidate(
        handle: Long,
        registration: ByteBuffer,
        registrationOffset: Int,
        registrationCount: Int,
    ): Int

    external fun destroyAgentRuntime(handle: Long)

    // MARK: - Stateless shared policy
    //
    // Everything below is a pure Core call: no handle, no runtime, no
    // callback. Direct input buffers are borrowed only for the duration of the
    // call. See the Shared*.kt facades for the typed wrappers; nothing outside
    // this module should call these directly.

    external fun inputEncodeAccessoryKey(
        id: ByteBuffer,
        idCount: Int,
        modifierBits: Int,
        applicationCursorMode: Boolean,
    ): ByteArray

    external fun inputApplySoftwareModifiers(
        input: ByteBuffer,
        inputCount: Int,
        modifierBits: Int,
    ): ByteArray

    external fun inputEncodeMouseEvent(request: ByteBuffer, requestCount: Int): ByteArray

    external fun inputScrollRoute(
        bufferIsAlternate: Boolean,
        mouseReporting: Boolean,
        mouseReportingImpliesAltScreen: Boolean,
    ): Int

    external fun inputAccessoryCatalog(): String

    external fun inputAccessoryBarOrder(request: ByteBuffer, requestCount: Int): String

    external fun inputRenderChord(request: ByteBuffer, requestCount: Int): String

    external fun inputModifierArmingTransition(request: ByteBuffer, requestCount: Int): String

    external fun sessionRestoreVerdict(request: ByteBuffer, requestCount: Int): String

    external fun sessionRestoreEvaluate(request: ByteBuffer, requestCount: Int): String

    external fun sessionRestoreWindowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpenedSeconds: Double,
        maxWindowSeconds: Double,
        hasUnansweredPrompt: Boolean,
    ): String

    external fun sessionRestoreChargeDelta(
        nowSeconds: Double,
        lastChargeAtSeconds: Double,
        hasLastChargeAt: Boolean,
        isPrompting: Boolean,
        maxTickSeconds: Double,
    ): Double

    external fun sessionRestorePersistMode(
        isActive: Boolean,
        hasPreservedSnapshots: Boolean,
        isWindowOpen: Boolean,
        hasCohortEntries: Boolean,
    ): String

    external fun sessionRestoreDocumentRules(request: ByteBuffer, requestCount: Int): String

    external fun sessionRestoreStartupAction(request: ByteBuffer, requestCount: Int): String

    external fun sessionRestoreEffectivePolicy(
        storedPolicy: ByteBuffer,
        storedPolicyCount: Int,
        usesCompactShell: Boolean,
    ): String

    external fun sessionRestorePersistPlan(request: ByteBuffer, requestCount: Int): String

    external fun sessionResizeNote(request: ByteBuffer, requestCount: Int): String

    external fun sessionResizeSettle(request: ByteBuffer, requestCount: Int): String

    external fun sessionResizeSettleSeconds(): Double

    external fun sessionRemoteProcessEnded(exitStatus: Int, hasExitStatus: Boolean): Int

    external fun sessionRetainsRestoreRecord(exitStatus: Int, hasExitStatus: Boolean): Int

    external fun sessionMoshRemoteProcessEnded(isShutdownCompletion: Boolean): Int

    external fun sessionShouldRetry(request: ByteBuffer, requestCount: Int): Int

    external fun sessionRetryDelaySeconds(attempt: Int): Double

    external fun sessionRetryMaxAttempts(): Int

    external fun moshParseConnectResponse(
        standardOutput: ByteBuffer?,
        standardOutputCount: Int,
        standardError: ByteBuffer?,
        standardErrorCount: Int,
    ): String

    external fun moshServerNewCommand(
        launchCommand: ByteBuffer?,
        launchCommandCount: Int,
    ): String

    external fun moshServerTerminationScript(pid: Int): String

    external fun moshServerLivenessScript(pid: Int): String

    external fun moshServerLivenessVerdict(output: ByteBuffer?, outputCount: Int): Int

    external fun moshServerLivenessGraceMilliseconds(): Long

    external fun moshServerLivenessNextProbeMilliseconds(
        outcome: Int,
        consecutiveHostFailures: Int,
        askedOwner: Int,
    ): Long

    external fun moshTranscriptSuggestsMissingServer(
        standardOutput: ByteBuffer?,
        standardOutputCount: Int,
        standardError: ByteBuffer?,
        standardErrorCount: Int,
    ): Int

    external fun moshDetachedServerPid(transcript: ByteBuffer, transcriptCount: Int): Int

    external fun moshNormalizedConnectKey(key: ByteBuffer, keyCount: Int): String

    external fun moshBootstrapTranscriptSummary(
        standardOutput: ByteBuffer?,
        standardOutputCount: Int,
        standardError: ByteBuffer?,
        standardErrorCount: Int,
    ): String

    external fun redactSensitive(
        text: ByteBuffer,
        textCount: Int,
        patterns: ByteBuffer?,
        patternsCount: Int,
    ): String

    external fun osDetectionProbeCommand(): String

    external fun osDetectionParse(probeOutput: ByteBuffer, probeOutputCount: Int): String

    /** Null when the probe output identifies no OS family. */
    external fun osDetectionParseFamily(probeOutput: ByteBuffer, probeOutputCount: Int): String?

    external fun trustCheck(request: ByteBuffer, requestCount: Int): String

    external fun trustNormalizeEndpoint(host: ByteBuffer, hostCount: Int, port: Int): String

    external fun trustSha256Fingerprint(blob: ByteBuffer, blobCount: Int, padded: Boolean): String

    external fun trustKnownHostsImportPlan(request: ByteBuffer, requestCount: Int): String

    /** Raw UTF-8: an empty pin store has a correct empty answer, which the
     * shared string builder would otherwise report as a failure. */
    external fun trustKnownHostsExport(records: ByteBuffer, recordsCount: Int): ByteArray

    external fun forwardingValidateRule(request: ByteBuffer, requestCount: Int): String

    external fun forwardingCapabilities(
        transport: Int,
        sshSideChannelAvailable: Boolean,
    ): String

    external fun forwardingRequiresRestart(request: ByteBuffer, requestCount: Int): Int

    external fun forwardingPortableLocalSubset(rules: ByteBuffer, rulesCount: Int): String

    external fun forwardingWebTarget(rule: ByteBuffer, ruleCount: Int): String

    external fun tmuxSessionNameValidate(name: ByteBuffer?, nameCount: Int): Int

    external fun tmuxTargetIdValidate(value: ByteBuffer?, valueCount: Int, kind: Int): Int

    external fun tmuxInlineHistoryShouldRequest(
        canDeepen: Boolean,
        requestInFlight: Boolean,
        rowsAboveOldest: Int,
        viewportRows: Int,
        crossedOldestRow: Boolean,
    ): Int

    external fun agentValidateBranch(branch: ByteBuffer?, branchCount: Int): Int

    external fun pairingQrDecodeOffer(text: ByteBuffer, textCount: Int): String
    external fun setupFlowProject(input: ByteBuffer, inputCount: Int): String

    external fun pairingQrEncodeOffer(offer: ByteBuffer, offerCount: Int): String

    external fun crossDeviceCanonicalizeCommand(command: ByteBuffer, commandCount: Int): ByteArray

    external fun continuationRouteIdentity(request: ByteBuffer, requestCount: Int): String

    external fun continuationDescriptorRouteIdentity(
        descriptor: ByteBuffer,
        descriptorCount: Int,
    ): String
}

internal fun ByteArray.toDirectBuffer(): ByteBuffer = ByteBuffer.allocateDirect(size).also { buffer ->
    buffer.put(this)
    buffer.flip()
}

internal fun Int.toCoreCallResult(): CoreCallResult = when (this) {
    0 -> CoreCallResult.Accepted
    -1 -> CoreCallResult.InvalidArguments
    -2 -> CoreCallResult.StaleHandle
    else -> error("unexpected shared-core result: $this")
}


data class SharedTmuxWindowMutationPlan(val mutationCommands: List<String>, val selectionRestoreCommands: List<String>)
