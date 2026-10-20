package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentIntegrationDecision
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationCheckPolicy
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationDecisionAction
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationDecisionKind
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationDecisions
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallFailure
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationObservation
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationParsing
import com.bambouville.tessera.core.bridge.SharedAgentProcessDescriptor
import com.bambouville.tessera.core.bridge.SharedAgentProviderClassification
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Session-owned lifecycle-integration state. Agent Center consumes the resulting
 * lifecycle/projector data, but it does not own host detection or repair UI. */
enum class AgentSessionIntegrationKind {
    Checking,
    Ready,
    Missing,
    Outdated,
    InactiveShell,
    InsideAgent,
    AwayFromShell,
    UnsupportedShell,
    BusyProgram,
    ManualCheckRequired,
    Repairing,
    Unavailable,

    /** The host integration came from a newer Tessera; only an app update helps. */
    AppUpdateRequired,
}

enum class AgentSessionIntegrationAction {
    InstallAndApply,
    InstallOnly,
    Apply,
    PersistAndApply,
    Check,
    Retry,
}

enum class AgentSessionIntegrationForeground {
    Shell,
    UnsupportedShell,
    Agent,
    Other,
}

data class AgentSessionIntegrationStatus(
    val kind: AgentSessionIntegrationKind,
    val sessionKey: AgentSessionKey,
    val detail: String? = null,
    val primaryAction: AgentSessionIntegrationAction? = null,
    val secondaryAction: AgentSessionIntegrationAction? = null,
    val showsWarning: Boolean,
    val foreground: AgentSessionIntegrationForeground? = null,
    val agentRequiresLifecycleHook: Boolean? = null,
) {

    fun supports(action: AgentSessionIntegrationAction): Boolean =
        action == primaryAction || action == secondaryAction
}

data class AgentSessionIntegrationActionRequest(
    val binding: AgentEndpointBinding,
    val action: AgentSessionIntegrationAction,
) {
    val sessionKey: AgentSessionKey get() = binding.key
}

sealed interface AgentSessionIntegrationEvent {
    data class Installed(
        val sessionKey: AgentSessionKey,
        val binding: AgentEndpointBinding,
    ) : AgentSessionIntegrationEvent
}

/**
 * Watches every live endpoint independently and publishes exact-session status.
 * No state is collapsed across hosts or panes: a terminal reads only the entry
 * matching its own live-session lease.
 */
class AgentSessionIntegrationCoordinator(
    private val directory: AgentSessionDirectory,
    private val scope: CoroutineScope,
    private val lifecycleCapabilities: AgentSessionLifecycleCapabilities = object : AgentSessionLifecycleCapabilities {
        override fun supportsLifecycle(binding: AgentEndpointBinding, provider: AgentProofProvider): Boolean =
            provider == AgentProofProvider.CLAUDE || provider == AgentProofProvider.CODEX
    },
) : AutoCloseable {
    private data class IntegrationCheckState(
        val binding: AgentEndpointBinding,
        val mutex: Mutex = Mutex(),
        var installation: AgentIntegrationStatus? = null,
        var installationCheckedAtNanos: Long = 0,
        var consecutiveFailures: Int = 0,
    )

    private val checkStates = ConcurrentHashMap<AgentSessionKey, IntegrationCheckState>()
    private val bindings = ConcurrentHashMap<AgentSessionKey, AgentEndpointBinding>()
    private val monitorJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private val lifecycleJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private val actionJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private data class TrustedLifecycleProcess(
        val claimedPID: Int,
        val provider: AgentProofProvider,
        val processStart: String,
    )

    private val trustedLifecycleProcesses =
        ConcurrentHashMap<AgentSessionKey, Map<Int, TrustedLifecycleProcess>>()
    private val statusValues = ConcurrentHashMap<AgentSessionKey, AgentSessionIntegrationStatus>()
    private val mutableStatuses = MutableStateFlow<Map<AgentSessionKey, AgentSessionIntegrationStatus>>(emptyMap())
    val statuses: StateFlow<Map<AgentSessionKey, AgentSessionIntegrationStatus>> = mutableStatuses.asStateFlow()
    private val mutableEvents = MutableSharedFlow<AgentSessionIntegrationEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<AgentSessionIntegrationEvent> = mutableEvents.asSharedFlow()
    @Volatile private var enabled = false
    @Volatile private var applicationForeground = true
    @Volatile private var latestBindings: List<AgentEndpointBinding> = emptyList()

    private val directoryObserver = scope.launch {
        directory.sessions.collect { current ->
            latestBindings = current
            reconcile(current)
        }
    }

    fun setEnabled(value: Boolean) {
        if (enabled == value) return
        enabled = value
        if (value) reconcile(latestBindings) else clearSessionState()
    }

    fun setApplicationForeground(value: Boolean) {
        if (applicationForeground == value) return
        applicationForeground = value
        if (!value) {
            monitorJobs.values.forEach(Job::cancel)
            lifecycleJobs.values.forEach(Job::cancel)
            actionJobs.values.forEach(Job::cancel)
            monitorJobs.clear()
            lifecycleJobs.clear()
            actionJobs.clear()
        } else if (enabled) {
            bindings.values.forEach { binding ->
                directory.resolve(binding.key)?.let { endpoint ->
                    startMonitoring(endpoint, binding)
                }
            }
        }
    }

    fun requestAction(request: AgentSessionIntegrationActionRequest) {
        val key = request.sessionKey
        val binding = bindings[key] ?: return
        if (binding != request.binding) return
        val status = statusValues[key] ?: return
        if (!status.supports(request.action)) return
        val endpoint = directory.resolve(key) ?: return
        if (!bindingIsCurrent(endpoint, binding)) return
        val checkState = checkStates[key] ?: return
        val actionJob = scope.launch(start = CoroutineStart.LAZY) {
            try {
                checkState.mutex.withLock {
                    if (!bindingIsCurrent(endpoint, binding)) return@withLock
                    // Actions must always re-probe host installation, even when a
                    // background status check recently cached the same host.
                    checkState.installation = null
                    if (request.action == AgentSessionIntegrationAction.Retry ||
                        request.action == AgentSessionIntegrationAction.Check
                    ) {
                        refreshIntegration(endpoint, binding)
                        return@withLock
                    }
                    val inspection = inspectIntegration(
                        endpoint,
                        binding,
                        requestedAction = request.action.sharedAction,
                    ) ?: return@withLock
                    val effective = inspection.decision.effectiveAction ?: run {
                        setDecision(
                            binding,
                            inspection.decision,
                            foreground = inspection.foreground,
                            agentRequiresLifecycleHook = inspection.agentRequiresLifecycleHook,
                        )
                        return@withLock
                    }
                    when (effective) {
                        SharedAgentIntegrationDecisionAction.InstallAndApply ->
                            installIntegration(endpoint, binding, applyAfterInstall = true)
                        SharedAgentIntegrationDecisionAction.InstallOnly ->
                            installIntegration(endpoint, binding, applyAfterInstall = false)
                        SharedAgentIntegrationDecisionAction.Apply ->
                            activateIntegrationInCurrentShell(endpoint, binding, persist = false)
                        SharedAgentIntegrationDecisionAction.PersistAndApply ->
                            activateIntegrationInCurrentShell(endpoint, binding, persist = true)
                        SharedAgentIntegrationDecisionAction.Check,
                        SharedAgentIntegrationDecisionAction.Retry,
                        -> refreshIntegration(endpoint, binding)
                    }
                }
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The host integration check failed.")
            } finally {
                coroutineContext[Job]?.let { completed -> actionJobs.remove(key, completed) }
            }
        }
        val accepted = synchronized(actionJobs) {
            val existing = actionJobs[key]
            if (existing != null && !existing.isCompleted) false
            else {
                actionJobs[key] = actionJob
                actionJob.start()
                true
            }
        }
        if (!accepted) actionJob.cancel()
    }

    private fun reconcile(current: List<AgentEndpointBinding>) {
        if (!enabled) return
        val live = current.mapTo(linkedSetOf()) { it.key }
        bindings.keys.filterNot(live::contains).forEach { key ->
            monitorJobs.remove(key)?.cancel()
            lifecycleJobs.remove(key)?.cancel()
            actionJobs.remove(key)?.cancel()
            bindings.remove(key)
            checkStates.remove(key)
            trustedLifecycleProcesses.remove(key)
            statusValues.remove(key)
        }
        current.forEach { binding ->
            val previous = bindings.put(binding.key, binding)
            if (previous != binding) {
                monitorJobs.remove(binding.key)?.cancel()
                lifecycleJobs.remove(binding.key)?.cancel()
                actionJobs.remove(binding.key)?.cancel()
                // Foreground PID and process-start identity are re-proved on
                // every check. Changing only the visible tmux pane does not
                // invalidate that route's lifecycle evidence.
                if (previous == null || previous.hostID != binding.hostID ||
                    previous.transport != binding.transport ||
                    previous.tmuxSession != binding.tmuxSession
                ) trustedLifecycleProcesses.remove(binding.key)
                checkStates[binding.key] = IntegrationCheckState(binding)
                // A tmux window or pane change keeps the session's last result
                // until the recheck lands, as on iOS: otherwise every switch
                // blinks the warning off and restarts its presentation hold.
                // Actions re-inspect the current terminal before they mutate.
                if (previous == null || statusValues[binding.key] == null) {
                    setStatus(binding, AgentSessionIntegrationKind.Checking)
                }
                directory.resolve(binding.key)?.let { endpoint ->
                    startMonitoring(endpoint, binding)
                }
            }
        }
        publishStatuses()
    }

    private fun startMonitoring(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding) {
        if (!applicationForeground) return
        monitorJobs[binding.key] = scope.launch { monitorIntegration(endpoint, binding) }
        lifecycleJobs[binding.key] = scope.launch {
            endpoint.retainedLifecycleFrame(binding)?.let { frame ->
                acceptTrustedLifecycleFrame(endpoint, binding, frame)
            }
            endpoint.lifecycleFrames.collect { frame -> acceptTrustedLifecycleFrame(endpoint, binding, frame) }
        }
    }

    private suspend fun acceptTrustedLifecycleFrame(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        frame: AgentLifecycleFrame,
    ) {
        // A frame is trusted per route, not per visible pane: the session's
        // integration status is one fact for the whole host, and the agent
        // that proves it is usually running in a window this client is not
        // painting. Only its own route may be proven, so prove that one.
        if (!bindingIsCurrent(endpoint, binding) ||
            frame.binding.key != binding.key ||
            !endpoint.isCurrentRoute(frame.binding)
        ) return
        val wire = runCatching {
            com.bambouville.tessera.core.bridge.SharedAgentIntegrationParsing.lifecycleHookEvent(frame.payload)
        }.getOrNull() ?: return
        val provider = AgentProofProvider.fromWire(wire.providerID) ?: return
        if (!lifecycleCapabilities.supportsLifecycle(binding, provider)) return
        val claimedPID = wire.agentPID ?: return
        // Hook providers can emit several events for one tool call. Once this
        // exact PID/provider is trusted, the periodic monitor below continues
        // to re-prove its process-start identity; repeating the full proof and
        // integration refresh for every OSC only creates redundant SSH work.
        if (trustedLifecycleProcesses[binding.key]?.get(claimedPID)?.provider == provider) return
        val checkState = checkStates[binding.key] ?: return
        checkState.mutex.withLock {
            if (!checkIsCurrent(endpoint, binding)) return@withLock
            val proof = endpoint.proveProcess(frame.binding, claimedPID, provider)
            if (!checkIsCurrent(endpoint, binding)) return
            val proven = (proof as? AgentEndpointResult.Success)?.value ?: return
            if (proven.provider != provider || claimedPID !in proven.processIDs) return
            trustedLifecycleProcesses.compute(binding.key) { _, current ->
                current.orEmpty() + (claimedPID to TrustedLifecycleProcess(
                    claimedPID = claimedPID,
                    provider = provider,
                    processStart = proven.processStart,
                ))
            }
            refreshIntegration(endpoint, binding)
        }
    }

    private suspend fun monitorIntegration(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding) {
        val checkState = checkStates[binding.key] ?: return
        while (bindingIsCurrent(endpoint, binding)) {
            checkState.mutex.withLock {
                if (!checkIsCurrent(endpoint, binding)) return@withLock
                try {
                    refreshIntegration(endpoint, binding)
                } catch (failure: Throwable) {
                    if (failure is CancellationException) throw failure
                    setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
                }
                checkState.consecutiveFailures = if (statusValues[binding.key]?.kind == AgentSessionIntegrationKind.Unavailable) {
                    checkState.consecutiveFailures.coerceAtMost(Int.MAX_VALUE - 1) + 1
                } else 0
            }
            val nextDelay = runCatching {
                SharedAgentIntegrationCheckPolicy.retryDelayMillis(checkState.consecutiveFailures)
            }.getOrElse { return } // A missing Core ABI cannot safely schedule or classify checks.
            delay(nextDelay)
        }
    }

    private suspend fun refreshIntegration(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding) {
        val inspection = inspectIntegration(endpoint, binding) ?: return
        currentCoroutineContext().ensureActive()
        setDecision(
            binding,
            inspection.decision,
            inspection.detail,
            inspection.foreground,
            inspection.agentRequiresLifecycleHook,
        )
    }

    private data class IntegrationInspection(
        val decision: SharedAgentIntegrationDecision,
        val shellProcessIDs: Set<Int>,
        val detail: String?,
        val foreground: SharedAgentIntegrationForeground,
        val agentRequiresLifecycleHook: Boolean?,
    )

    private suspend fun inspectIntegration(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        requestedAction: SharedAgentIntegrationDecisionAction? = null,
    ): IntegrationInspection? {
        if (!checkIsCurrent(endpoint, binding)) return null
        val probeCommand = runCatching { AgentIntegrationCommand.probeFromSharedCore() }.getOrElse {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
            return null
        }
        val checkState = checkStates[binding.key] ?: return null
        val cached = checkState.installation
        val cachedAgeMillis = (System.nanoTime() - checkState.installationCheckedAtNanos) / 1_000_000
        val installation = if (requestedAction == null && cached != null &&
            cachedAgeMillis >= 0 && cachedAgeMillis < SharedAgentIntegrationCheckPolicy.freshnessMillis(cached.sharedInstallation)
        ) AgentEndpointResult.Success(cached)
        else endpoint.probeIntegration(binding, probeCommand).also { result ->
            if (result is AgentEndpointResult.Success && bindingIsCurrent(endpoint, binding)) {
                checkState.installation = result.value
                checkState.installationCheckedAtNanos = System.nanoTime()
            }
        }
        if (!checkIsCurrent(endpoint, binding)) return null
        val installationValue = when (installation) {
            is AgentEndpointResult.Success -> installation.value
            AgentEndpointResult.StaleBinding -> return null
            is AgentEndpointResult.Unavailable -> {
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, installation.reason.take(256))
                return null
            }
            is AgentEndpointResult.Failed -> {
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The host integration probe failed.")
                return null
            }
        }
        val discovery = discoverProcesses(endpoint, binding) ?: run {
            setStatus(
                binding,
                AgentSessionIntegrationKind.Unavailable,
                "The terminal process state could not be verified.",
            )
            return null
        }
        if (!checkIsCurrent(endpoint, binding)) return null
        val shellIDs = discovery.foregroundShellProcessIDs
        val foreground = discovery.foreground
        var shellActive: Boolean? = false
        if (installationValue == AgentIntegrationStatus.Current && foreground == SharedAgentIntegrationForeground.Shell) {
            val command = runCatching {
                AgentIntegrationCommand.currentShellFromSharedCore(shellIDs)
            }.getOrElse {
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
                return null
            }
            shellActive = when (val shell = endpoint.inspectCurrentShell(binding, command)) {
                is AgentEndpointResult.Success -> shell.value.active
                AgentEndpointResult.StaleBinding -> return null
                else -> null
            }
        }
        val lifecycleProcessIDs = runCatching {
            lifecycleCapableForegroundProcessIDs(
                binding,
                discovery,
                lifecycleCapabilities,
            )
        }.getOrElse {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
            return null
        }
        val agentIntegrationActive = hasFreshTrustedForegroundAgent(
            endpoint,
            binding,
            lifecycleProcessIDs,
        )
        if (!checkIsCurrent(endpoint, binding)) return null
        val observation = SharedAgentIntegrationObservation(
            installation = installationValue.sharedInstallation,
            foreground = foreground,
            shellIntegrationActive = shellActive,
            agentIntegrationActive = agentIntegrationActive,
            agentRequiresLifecycleHook = if (foreground == SharedAgentIntegrationForeground.Agent) {
                lifecycleProcessIDs.isNotEmpty()
            } else null,
        )
        val decision = runCatching {
            SharedAgentIntegrationDecisions.resolve(observation, requestedAction)
        }.getOrElse {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
            return null
        }
        return IntegrationInspection(
            decision = decision,
            shellProcessIDs = shellIDs,
            detail = when (installationValue) {
                is AgentIntegrationStatus.Outdated -> installationValue.version?.let {
                    "Host integration v$it is out of date."
                }
                is AgentIntegrationStatus.RequiresAppUpdate -> installationValue.version?.let {
                    "Host integration v$it was installed by a newer Tessera."
                } ?: "The host integration was installed by a newer Tessera."
                AgentIntegrationStatus.Missing,
                AgentIntegrationStatus.Current,
                -> null
            },
            foreground = foreground,
            agentRequiresLifecycleHook = if (foreground == SharedAgentIntegrationForeground.Agent) {
                lifecycleProcessIDs.isNotEmpty()
            } else null,
        )
    }

    private suspend fun installIntegration(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        applyAfterInstall: Boolean,
    ) {
        if (!checkIsCurrent(endpoint, binding)) return
        setStatus(binding, AgentSessionIntegrationKind.Repairing)
        // Core owns the retry budget and the race-versus-failure decision. This
        // loop must never invent either: reporting every failure as a settings
        // race is what hid a broken installer behind "retry when they are idle"
        // for a full release.
        val attempts = runCatching { SharedAgentIntegrationParsing.maximumInstallAttempts() }
            .getOrDefault(0)
        if (attempts <= 0) {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
            return
        }
        repeat(attempts) {
            val readCommand = runCatching { AgentIntegrationCommand.readConfigsFromSharedCore() }.getOrElse {
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
                return
            }
            val snapshots = endpoint.readIntegrationConfigs(binding, readCommand)
            if (!checkIsCurrent(endpoint, binding)) return
            val values = (snapshots as? AgentEndpointResult.Success)?.value
            if (values == null) {
                if (snapshots is AgentEndpointResult.StaleBinding) return
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "Provider settings could not be read safely.")
                return
            }
            val installCommand = runCatching {
                AgentIntegrationCommand.installFromSharedCore(values.codex, values.claude, values.kimi)
            }.getOrElse {
                setStatus(binding, AgentSessionIntegrationKind.Unavailable, "Provider settings exceed the safe installation limit.")
                return
            }
            val result = endpoint.installIntegration(binding, installCommand)
            if (!checkIsCurrent(endpoint, binding)) return
            if (result is AgentEndpointResult.StaleBinding) return
            when (val outcome = (result as? AgentEndpointResult.Success)?.value) {
                // Only a compare-and-swap race earns another attempt.
                SharedAgentIntegrationInstallOutcome.ConfigurationRace -> return@repeat
                is SharedAgentIntegrationInstallOutcome.Failed -> {
                    if (outcome.reason == SharedAgentIntegrationInstallFailure.NewerInstalled) {
                        // Another device running a newer Tessera won the host
                        // between probe and install. Retrying can never help.
                        // Re-read the host: a newer integration that admits this
                        // app is ready, one that does not requires an update.
                        checkStates[binding.key]?.installation = null
                        refreshIntegration(endpoint, binding)
                        return
                    }
                    setStatus(binding, AgentSessionIntegrationKind.Unavailable, outcome.reason.failureDetail)
                    return
                }
                // The route never delivered a classifiable install frame. Carry
                // the transport's own bounded code rather than inventing one.
                null -> {
                    val detail = when (result) {
                        is AgentEndpointResult.Unavailable -> result.reason
                        is AgentEndpointResult.Failed -> result.code
                        else -> null
                    }
                    setStatus(
                        binding,
                        AgentSessionIntegrationKind.Unavailable,
                        if (detail == null) {
                            "Could not verify Agent Center integration."
                        } else {
                            "Could not verify Agent Center integration: ${detail.take(160)}"
                        },
                    )
                    return
                }
                SharedAgentIntegrationInstallOutcome.Completed -> Unit
            }
            val discovery = discoverProcesses(endpoint, binding) ?: run {
                setStatus(
                    binding,
                    AgentSessionIntegrationKind.Unavailable,
                    "The terminal process state could not be verified.",
                )
                return
            }
            val shellIDs = discovery.foregroundShellProcessIDs
            if (applyAfterInstall) {
                if (shellIDs.isEmpty()) {
                    mutableEvents.tryEmit(AgentSessionIntegrationEvent.Installed(binding.key, binding))
                    setStatus(
                        binding,
                        AgentSessionIntegrationKind.Unavailable,
                        "Integration was installed, but the foreground shell changed before activation.",
                    )
                    return
                }
                val activation = runCatching {
                    endpoint.activateCurrentShell(
                        binding,
                        shellIDs,
                        AgentShellActivationCommand.applyFromSharedCore(),
                    )
                }.getOrElse {
                    AgentEndpointResult.Failed("shell_activation_failed")
                }
                if (!checkIsCurrent(endpoint, binding)) return
                when (activation) {
                    is AgentEndpointResult.Success -> Unit
                    AgentEndpointResult.StaleBinding -> return
                    is AgentEndpointResult.Unavailable -> {
                        mutableEvents.tryEmit(AgentSessionIntegrationEvent.Installed(binding.key, binding))
                        setStatus(
                            binding,
                            AgentSessionIntegrationKind.Unavailable,
                            "Integration was installed, but could not be enabled here: ${activation.reason.take(160)}",
                        )
                        return
                    }
                    is AgentEndpointResult.Failed -> {
                        mutableEvents.tryEmit(AgentSessionIntegrationEvent.Installed(binding.key, binding))
                        setStatus(
                            binding,
                            AgentSessionIntegrationKind.Unavailable,
                            "Integration was installed, but the foreground shell changed before activation.",
                        )
                        return
                    }
                }
            }
            mutableEvents.tryEmit(AgentSessionIntegrationEvent.Installed(binding.key, binding))
            checkStates[binding.key]?.installation = null
            delay(150)
            refreshIntegration(endpoint, binding)
            return
        }
        // Reached only by exhausting the budget on genuine races.
        setStatus(
            binding,
            AgentSessionIntegrationKind.Unavailable,
            "Provider settings changed during installation. Retry when they are idle.",
        )
    }

    private suspend fun activateIntegrationInCurrentShell(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        persist: Boolean,
    ) {
        val discovery = discoverProcesses(endpoint, binding) ?: run {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The terminal process state could not be verified.")
            return
        }
        val processIDs = discovery.foregroundShellProcessIDs
        if (processIDs.isEmpty()) {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The current shell could not be verified.")
            return
        }
        setStatus(binding, AgentSessionIntegrationKind.Repairing)
        val command = runCatching {
            if (persist) AgentShellActivationCommand.persistAndApplyFromSharedCore()
            else AgentShellActivationCommand.applyFromSharedCore()
        }.getOrElse {
            setStatus(binding, AgentSessionIntegrationKind.Unavailable, "The shared Agent integration is unavailable.")
            return
        }
        val result = endpoint.activateCurrentShell(binding, processIDs, command)
        if (!checkIsCurrent(endpoint, binding)) return
        when (result) {
            is AgentEndpointResult.Success -> {
                delay(150)
                refreshIntegration(endpoint, binding)
            }
            AgentEndpointResult.StaleBinding -> Unit
            is AgentEndpointResult.Unavailable -> setStatus(
                binding,
                AgentSessionIntegrationKind.Unavailable,
                result.reason.take(256),
            )
            is AgentEndpointResult.Failed -> setStatus(
                binding,
                AgentSessionIntegrationKind.Unavailable,
                "The foreground shell changed before activation.",
            )
        }
    }

    private suspend fun discoverProcesses(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
    ): AgentProcessDiscoverySnapshot? {
        val scopeResult = endpoint.processDiscoveryScope(binding)
        if (!checkIsCurrent(endpoint, binding)) return null
        val discoveryScope = (scopeResult as? AgentEndpointResult.Success)?.value ?: return null
        val result = endpoint.discoverProcesses(binding, AgentProcessDiscoveryCommands.command(discoveryScope))
        currentCoroutineContext().ensureActive()
        if (!checkIsCurrent(endpoint, binding)) return null
        return (result as? AgentEndpointResult.Success)?.value
    }

    /**
     * A lifecycle PID is only a candidate. Re-prove the exact provider and
     * kernel/process start identity whenever that PID is foreground so PID
     * reuse cannot turn an unhooked process into a ready integration.
     */
    private suspend fun hasFreshTrustedForegroundAgent(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        foregroundLifecycleProviderProcessIDs: Set<Int>,
    ): Boolean {
        val trusted = trustedLifecycleProcesses[binding.key].orEmpty()
        var active = false
        trusted.values.filter { it.claimedPID in foregroundLifecycleProviderProcessIDs }.forEach { candidate ->
            val refreshed = endpoint.proveProcess(binding, candidate.claimedPID, candidate.provider)
            currentCoroutineContext().ensureActive()
            if (!checkIsCurrent(endpoint, binding)) return false
            when (refreshed) {
                is AgentEndpointResult.Success -> {
                    val proof = refreshed.value
                    if (proof.matchesProcessIdentity(
                            candidate.claimedPID,
                            candidate.provider,
                            candidate.processStart,
                        )
                    ) {
                        active = true
                    } else {
                        trustedLifecycleProcesses.computeIfPresent(binding.key) { _, current ->
                            current - candidate.claimedPID
                        }
                    }
                }
                is AgentEndpointResult.Failed -> trustedLifecycleProcesses.computeIfPresent(binding.key) { _, current ->
                    current - candidate.claimedPID
                }
                AgentEndpointResult.StaleBinding,
                is AgentEndpointResult.Unavailable,
                -> Unit
            }
        }
        return active
    }

    private suspend fun checkIsCurrent(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding): Boolean {
        currentCoroutineContext().ensureActive()
        return bindingIsCurrent(endpoint, binding)
    }

    private fun bindingIsCurrent(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding): Boolean =
        enabled && applicationForeground && endpoint.binding.value == binding && bindings[binding.key] == binding

    private fun setStatus(
        binding: AgentEndpointBinding,
        kind: AgentSessionIntegrationKind,
        detail: String? = null,
        primaryAction: AgentSessionIntegrationAction? = null,
        secondaryAction: AgentSessionIntegrationAction? = null,
        showsWarning: Boolean = kind !in setOf(
            AgentSessionIntegrationKind.Checking,
            AgentSessionIntegrationKind.Ready,
            AgentSessionIntegrationKind.BusyProgram,
        ),
        foreground: AgentSessionIntegrationForeground? = null,
        agentRequiresLifecycleHook: Boolean? = null,
    ) {
        if (!enabled || bindings[binding.key] != binding ||
            (!applicationForeground && kind != AgentSessionIntegrationKind.Checking)
        ) return
        val key = binding.key
        val resolvedPrimaryAction = primaryAction ?: when (kind) {
            AgentSessionIntegrationKind.Unavailable -> AgentSessionIntegrationAction.Retry
            AgentSessionIntegrationKind.ManualCheckRequired -> AgentSessionIntegrationAction.Check
            else -> null
        }
        statusValues[key] = AgentSessionIntegrationStatus(
            kind,
            key,
            detail,
            resolvedPrimaryAction,
            secondaryAction,
            showsWarning,
            foreground,
            agentRequiresLifecycleHook,
        )
        publishStatuses()
    }

    private fun setDecision(
        binding: AgentEndpointBinding,
        decision: SharedAgentIntegrationDecision,
        detail: String? = null,
        foreground: SharedAgentIntegrationForeground? = null,
        agentRequiresLifecycleHook: Boolean? = null,
    ) = setStatus(
        binding = binding,
        kind = decision.kind.sessionKind,
        detail = detail,
        primaryAction = decision.primaryAction?.sessionAction,
        secondaryAction = decision.secondaryAction?.sessionAction,
        showsWarning = decision.showsWarning,
        foreground = foreground?.sessionForeground,
        agentRequiresLifecycleHook = agentRequiresLifecycleHook,
    )

    private fun publishStatuses() {
        mutableStatuses.value = statusValues.toMap()
    }

    private fun clearSessionState() {
        monitorJobs.values.forEach(Job::cancel)
        lifecycleJobs.values.forEach(Job::cancel)
        actionJobs.values.forEach(Job::cancel)
        monitorJobs.clear()
        lifecycleJobs.clear()
        actionJobs.clear()
        bindings.clear()
        checkStates.clear()
        trustedLifecycleProcesses.clear()
        statusValues.clear()
        publishStatuses()
    }

    override fun close() {
        enabled = false
        directoryObserver.cancel()
        clearSessionState()
    }


}

internal fun lifecycleCapableForegroundProcessIDs(
    binding: AgentEndpointBinding,
    discovery: AgentProcessDiscoverySnapshot,
    capabilities: AgentSessionLifecycleCapabilities,
    providerClassification: (AgentDiscoveredProcess) -> Set<AgentProofProvider> = ::sharedLifecycleProviders,
): Set<Int> = discovery.processes.asSequence()
    .filter { it.processID in discovery.foregroundLifecycleProviderProcessIDs }
    .filter { process ->
        providerClassification(process).any { capabilities.supportsLifecycle(binding, it) }
    }
    .mapTo(linkedSetOf()) { it.processID }

private fun sharedLifecycleProviders(process: AgentDiscoveredProcess): Set<AgentProofProvider> =
    SharedAgentProviderClassification.classify(
        listOf(SharedAgentProcessDescriptor(process.executable)),
    ).mapNotNullTo(linkedSetOf()) { AgentProofProvider.fromWire(it) }

internal val AgentIntegrationStatus.sharedInstallation: SharedAgentIntegrationInstallation
    get() = when (this) {
        AgentIntegrationStatus.Missing -> SharedAgentIntegrationInstallation.Missing
        AgentIntegrationStatus.Current -> SharedAgentIntegrationInstallation.Current
        is AgentIntegrationStatus.Outdated -> SharedAgentIntegrationInstallation.Outdated
        is AgentIntegrationStatus.RequiresAppUpdate -> SharedAgentIntegrationInstallation.RequiresAppUpdate
    }

/** User-facing detail for Core's bounded install-failure vocabulary. */
internal val SharedAgentIntegrationInstallFailure.failureDetail: String
    get() = when (this) {
        SharedAgentIntegrationInstallFailure.NotVerified ->
            "The host did not confirm the Agent integration was installed."
        SharedAgentIntegrationInstallFailure.NotCurrent ->
            "The Agent integration was written, but the host still reports it out of date."
        SharedAgentIntegrationInstallFailure.NewerInstalled ->
            "This host has a newer Agent Center integration from a newer Tessera. Update this app instead."
    }

private val AgentSessionIntegrationAction.sharedAction: SharedAgentIntegrationDecisionAction
    get() = when (this) {
        AgentSessionIntegrationAction.InstallAndApply -> SharedAgentIntegrationDecisionAction.InstallAndApply
        AgentSessionIntegrationAction.InstallOnly -> SharedAgentIntegrationDecisionAction.InstallOnly
        AgentSessionIntegrationAction.Apply -> SharedAgentIntegrationDecisionAction.Apply
        AgentSessionIntegrationAction.PersistAndApply -> SharedAgentIntegrationDecisionAction.PersistAndApply
        AgentSessionIntegrationAction.Check -> SharedAgentIntegrationDecisionAction.Check
        AgentSessionIntegrationAction.Retry -> SharedAgentIntegrationDecisionAction.Retry
    }

private val SharedAgentIntegrationDecisionAction.sessionAction: AgentSessionIntegrationAction
    get() = when (this) {
        SharedAgentIntegrationDecisionAction.InstallAndApply -> AgentSessionIntegrationAction.InstallAndApply
        SharedAgentIntegrationDecisionAction.InstallOnly -> AgentSessionIntegrationAction.InstallOnly
        SharedAgentIntegrationDecisionAction.Apply -> AgentSessionIntegrationAction.Apply
        SharedAgentIntegrationDecisionAction.PersistAndApply -> AgentSessionIntegrationAction.PersistAndApply
        SharedAgentIntegrationDecisionAction.Check -> AgentSessionIntegrationAction.Check
        SharedAgentIntegrationDecisionAction.Retry -> AgentSessionIntegrationAction.Retry
    }

internal val SharedAgentIntegrationDecisionKind.sessionKind: AgentSessionIntegrationKind
    get() = when (this) {
        SharedAgentIntegrationDecisionKind.Checking -> AgentSessionIntegrationKind.Checking
        SharedAgentIntegrationDecisionKind.Ready -> AgentSessionIntegrationKind.Ready
        SharedAgentIntegrationDecisionKind.NotInstalled -> AgentSessionIntegrationKind.Missing
        SharedAgentIntegrationDecisionKind.Outdated -> AgentSessionIntegrationKind.Outdated
        SharedAgentIntegrationDecisionKind.InactiveShell -> AgentSessionIntegrationKind.InactiveShell
        SharedAgentIntegrationDecisionKind.InsideAgent -> AgentSessionIntegrationKind.InsideAgent
        SharedAgentIntegrationDecisionKind.AwayFromShell -> AgentSessionIntegrationKind.AwayFromShell
        SharedAgentIntegrationDecisionKind.UnsupportedShell -> AgentSessionIntegrationKind.UnsupportedShell
        SharedAgentIntegrationDecisionKind.BusyProgram -> AgentSessionIntegrationKind.BusyProgram
        SharedAgentIntegrationDecisionKind.ManualCheckRequired -> AgentSessionIntegrationKind.ManualCheckRequired
        SharedAgentIntegrationDecisionKind.Repairing -> AgentSessionIntegrationKind.Repairing
        SharedAgentIntegrationDecisionKind.Unavailable -> AgentSessionIntegrationKind.Unavailable
        SharedAgentIntegrationDecisionKind.AppUpdateRequired -> AgentSessionIntegrationKind.AppUpdateRequired
    }

private val SharedAgentIntegrationForeground.sessionForeground: AgentSessionIntegrationForeground
    get() = when (this) {
        SharedAgentIntegrationForeground.Shell -> AgentSessionIntegrationForeground.Shell
        SharedAgentIntegrationForeground.UnsupportedShell -> AgentSessionIntegrationForeground.UnsupportedShell
        SharedAgentIntegrationForeground.Agent -> AgentSessionIntegrationForeground.Agent
        SharedAgentIntegrationForeground.Other -> AgentSessionIntegrationForeground.Other
    }
