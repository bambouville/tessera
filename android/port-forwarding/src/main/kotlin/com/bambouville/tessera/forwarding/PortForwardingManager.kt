package com.bambouville.tessera.forwarding

import java.io.Closeable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class BoundForwardEndpoint(
    val host: String,
    val port: Int,
)

sealed interface PortForwardingFailure {
    data class Validation(val error: PortForwardRuleError) : PortForwardingFailure
    data class Unsupported(val reason: String) : PortForwardingFailure
    data class Transport(val reason: String) : PortForwardingFailure
}

sealed interface PortForwardingStatus {
    data object Idle : PortForwardingStatus
    data object Starting : PortForwardingStatus
    data class Listening(val bound: BoundForwardEndpoint) : PortForwardingStatus
    data class Active(val bound: BoundForwardEndpoint, val connectionCount: Int) : PortForwardingStatus
    data class Failed(val failure: PortForwardingFailure) : PortForwardingStatus
}

/**
 * Whether anything answers at a local rule's remote end. The listener on this
 * device being up ([PortForwardingStatus.Listening]) says nothing about that:
 * the server opens the target only when a direct-tcpip channel asks it to.
 *
 * Only ever other than [Unknown] while the rule is carrying; every stop,
 * restart, failure, target change, and detach puts it back, and so does a run
 * of looks that got no answer.
 */
enum class ForwardedServiceState {
    Unknown,
    Serving,
    NotServing,
}

/**
 * One direct-tcpip open's verdict on a rule's target, whether it came from a
 * probe or from a real forwarded connection.
 */
sealed interface ForwardedServiceProbe {
    /** The server connected to the target. */
    data object Serving : ForwardedServiceProbe

    /** `SSH_OPEN_CONNECT_FAILED`: nothing accepted the server's connect. */
    data object NotServing : ForwardedServiceProbe

    /**
     * `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED`: the server forbids forwarding,
     * so it can never tell us whether the target is up.
     */
    data object Prohibited : ForwardedServiceProbe

    /**
     * Timeout, transport loss, or any other refusal. It proves nothing about
     * the target, so one alone leaves the previous state standing, and
     * [PortForwardingManager.INCONCLUSIVE_LOOKS_BEFORE_UNKNOWN] in a row drop
     * it. [detail] is a class or reason name — never a message, which can
     * carry the target host.
     */
    data class Inconclusive(val detail: String) : ForwardedServiceProbe
}

data class PortForwardingState(
    val rule: PortForwardRule,
    val status: PortForwardingStatus,
    val service: ForwardedServiceState = ForwardedServiceState.Unknown,
    /**
     * The last direct-tcpip open for this rule was administratively
     * prohibited. [service] stays [ForwardedServiceState.Unknown] and can
     * never resolve, so presentation must not promise that it will.
     */
    val forwardingProhibited: Boolean = false,
)

/**
 * The shared model reports a reason rather than a sentence, so each platform
 * writes its own copy; this is Android's.
 */
private fun unavailableText(reason: ForwardingUnavailableReason): String = when (reason) {
    ForwardingUnavailableReason.MoshWithoutSshSideChannel -> "Mosh has no authenticated SSH side channel"
}

/**
 * A live forwarding primitive. Implementations must make [close] idempotent;
 * manager reconciliation can race with terminal disconnect and app teardown.
 */
interface PortForwardingLease : Closeable {
    val bound: BoundForwardEndpoint
    val activeConnectionCount: StateFlow<Int>
    val isOpen: StateFlow<Boolean>

    /**
     * Passive service evidence: the outcome of each real forwarded
     * connection's direct-tcpip open. Only a local forward has any; remote
     * binds are opened by the server and dynamic targets vary per request.
     */
    val serviceEvidence: Flow<ForwardedServiceProbe> get() = emptyFlow()
}

/**
 * The only transport-facing dependency of the domain manager. The session
 * controller supplies an instance after authentication, whether it is the
 * primary SSH transport or Mosh's side-channel SSH transport.
 */
interface PortForwardingRuntime : Closeable {
    val capabilities: ForwardingCapabilities

    suspend fun start(rule: PortForwardRule): PortForwardingLease

    /**
     * Opens a direct-tcpip channel to [target] and closes it at once. Must not
     * throw; a runtime that cannot probe answers inconclusively.
     */
    suspend fun probe(target: PortForwardEndpoint): ForwardedServiceProbe =
        ForwardedServiceProbe.Inconclusive("unsupported")
}

/**
 * The shared-core decisions the manager consults. Production goes over the
 * native bridge; JVM unit tests, which cannot load it, substitute their own.
 */
internal interface ForwardingRulePolicy {
    fun validate(rule: PortForwardRule, against: Collection<PortForwardRule>): PortForwardRuleError?
    fun requiresRestart(from: PortForwardRule, to: PortForwardRule): Boolean

    /**
     * Whether the manager tracks this rule's service state at all: probes it
     * while it is carrying without connections, and records what the user's
     * own connections say.
     *
     * Only local rules the shared `ForwardedWebPolicy` calls browsable over
     * plain `http`. A probe is a bare connect-and-close, repeated, and any
     * other service logs it as a broken client:
     *
     * - non-web services: postgres logs "incomplete startup packet" for every
     *   one, and MySQL counts each against `max_connect_errors` until it
     *   blocks a non-loopback client's host outright;
     * - `https` targets: with no TLS handshake, Go's net/http logs
     *   "http: TLS handshake error from …: EOF" per probe, straight into the
     *   dev-server output the user is watching in this very terminal.
     *
     * An unwatched rule records no passive evidence either: with nothing to
     * refresh it, a postgres connection from an hour ago would keep the
     * glyph green and hide whether the web dev server is actually up. Such a
     * rule counts as serving only while it is carrying connections.
     */
    fun watchesService(rule: PortForwardRule): Boolean

    object Shared : ForwardingRulePolicy {
        override fun validate(rule: PortForwardRule, against: Collection<PortForwardRule>) =
            PortForwardRuleValidator.validate(rule, against)

        override fun requiresRestart(from: PortForwardRule, to: PortForwardRule) = from.requiresRestart(to)

        override fun watchesService(rule: PortForwardRule) =
            rule.direction == PortForwardDirection.LOCAL && rule.browsableWebTarget()?.scheme == "http"
    }
}

/**
 * Lifecycle owner equivalent to the Apple PortForwarderManager:
 *
 * - attach starts enabled auto-start rules;
 * - reconcile removes, stops, restarts, or adds rules deterministically;
 * - detach closes listeners before its SSH connection is released.
 *
 * State is deliberately a `StateFlow`, making it safe for a phone compact UI,
 * the session top-bar indicator, and the shared-session forwarding event to
 * consume the same canonical snapshot.
 *
 * It also tracks whether each carrying, watched rule's remote end is serving
 * ([ForwardedServiceState]; see [ForwardingRulePolicy.watchesService]).
 * Evidence comes passively from every real forwarded connection and, while
 * someone is looking ([monitorServices], [probeServicesNow]), from probes.
 */
class PortForwardingManager internal constructor(
    private val scope: CoroutineScope,
    private val diagnostics: (String, Map<String, String>) -> Unit,
    private val policy: ForwardingRulePolicy,
    /** Monotonic milliseconds. */
    private val clock: () -> Long,
    private val monitorTickMillis: Long,
) : Closeable {
    /**
     * [diagnostics] receives forwarding events for the redacted local log.
     * Values carry ports, never a target host.
     */
    constructor(
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        diagnostics: (String, Map<String, String>) -> Unit = { _, _ -> },
    ) : this(
        scope = scope,
        diagnostics = diagnostics,
        policy = ForwardingRulePolicy.Shared,
        clock = { System.nanoTime() / NANOS_PER_MILLI },
        monitorTickMillis = SERVICE_MONITOR_TICK_MILLIS,
    )

    private val mutex = Mutex()
    private val entries = LinkedHashMap<UUID, ActiveEntry>()
    private var runtime: PortForwardingRuntime? = null
    private var configuredRules: Map<UUID, PortForwardRule> = emptyMap()
    private val mutableStates = MutableStateFlow<Map<UUID, PortForwardingState>>(emptyMap())

    /**
     * Rules with a probe out. Kept per rule rather than per entry, as on iOS:
     * a stop, restart, or target edit makes a fresh entry that is due at
     * once, and a probe outliving the old one must still hold the rule's one
     * slot. Added under [mutex]; cleared off it when the probe ends.
     */
    private val probesInFlight = ConcurrentHashMap.newKeySet<UUID>()

    /** Observations handled so far, applied or ignored; lets tests wait for one that changes nothing. */
    @Volatile private var observations = 0

    val states: StateFlow<Map<UUID, PortForwardingState>> = mutableStates.asStateFlow()

    internal fun observationCount(): Int = observations

    suspend fun attach(runtime: PortForwardingRuntime, rules: List<PortForwardRule>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            detachLocked(closeRuntime = true)
            this@PortForwardingManager.runtime = runtime
            configuredRules = rules.associateBy(PortForwardRule::id)
            publishAllIdleLocked()
            rules.filter { it.enabled && it.autoStart }.forEach { startLocked(it) }
        }
    }

    /**
     * Apply edits to an already-connected host. Like the Apple implementation,
     * an enabled newly-added rule starts immediately; `autoStart` only controls
     * initial connection attachment.
     */
    suspend fun reconcile(rules: List<PortForwardRule>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val next = rules.associateBy(PortForwardRule::id)
            entries.keys.filter { it !in next }.toList().forEach(::stopLocked)
            configuredRules = next

            rules.forEach { rule ->
                val active = entries[rule.id]
                when {
                    !rule.enabled -> {
                        if (active != null) stopLocked(rule.id)
                        updateStateLocked(rule, PortForwardingStatus.Idle)
                    }
                    active == null -> startLocked(rule)
                    policy.requiresRestart(active.rule, rule) -> {
                        stopLocked(rule.id)
                        startLocked(rule)
                    }
                    else -> {
                        // Preserve listener, activity, and service state while
                        // label or auto-start changes: the target is the same.
                        active.rule = rule
                        val watches = policy.watchesService(rule)
                        if (watches != active.watchesService) {
                            // Unreachable while the shared policy restarts on
                            // every field `watchesService` reads. Should that
                            // change, a rule that stops being watched is never
                            // probed and drops its passive evidence, so a kept
                            // answer would colour the glyph for good.
                            active.watchesService = watches
                            active.forgetService()
                        }
                        publishEntryLocked(active)
                    }
                }
            }
        }
    }

    suspend fun start(ruleId: UUID) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val rule = configuredRules[ruleId] ?: return@withLock
            if (!rule.enabled) {
                updateStateLocked(rule, PortForwardingStatus.Idle)
                return@withLock
            }
            if (entries[ruleId] == null) startLocked(rule)
        }
    }

    suspend fun stop(ruleId: UUID) = withContext(Dispatchers.IO) {
        mutex.withLock { stopLocked(ruleId) }
    }

    suspend fun reportTransportUnavailable(rules: List<PortForwardRule>, reason: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            detachLocked(closeRuntime = true)
            configuredRules = rules.associateBy(PortForwardRule::id)
            mutableStates.value = rules.associate { rule ->
                rule.id to PortForwardingState(
                    rule,
                    PortForwardingStatus.Failed(PortForwardingFailure.Transport(reason)),
                )
            }
        }
    }

    suspend fun detach() = withContext(Dispatchers.IO) {
        mutex.withLock { detachLocked(closeRuntime = true) }
    }

    /** Lifecycle teardown path used before synchronously closing the SSH carrier. */
    fun detachBlocking() = runBlocking { detach() }

    /**
     * Probes due rules every tick until cancelled. Call it only while someone
     * can see the result — the session on screen, or the forwarding panel
     * open — since every probe is traffic on the user's SSH connection.
     *
     * The loop itself never waits on the network: each probe runs on this
     * manager's scope and answers within the runtime's deadline, with at
     * most one in flight per rule.
     */
    suspend fun monitorServices(): Nothing = withContext(Dispatchers.IO) {
        // On IO like every other entry point: the mutex hands itself to its
        // first waiter, and a waiter on Main while `detachBlocking` holds Main
        // in runBlocking would never run to take it.
        //
        // Someone just started looking again: a target left unconfirmed while
        // nobody watched gets the brisk cadence back.
        mutex.withLock { entries.values.forEach { it.unconfirmedStreak = 0 } }
        probeDueServicesForever()
    }

    private suspend fun probeDueServicesForever(): Nothing {
        while (true) {
            launchServiceProbes(force = false)
            delay(monitorTickMillis)
        }
    }

    /**
     * Probes every eligible rule now, whatever its cadence says — the user
     * just opened the panel and is reading the answer. A rule with a probe
     * already in flight keeps that one.
     */
    suspend fun probeServicesNow() = withContext(Dispatchers.IO) {
        mutex.withLock { entries.values.forEach { it.unconfirmedStreak = 0 } }
        launchServiceProbes(force = true)
        Unit
    }

    override fun close() {
        detachBlocking()
        scope.cancel()
    }

    /** Launches every due probe and returns their jobs, which tests join. */
    internal suspend fun launchServiceProbes(force: Boolean): List<Job> = mutex.withLock {
        val currentRuntime = runtime ?: return@withLock emptyList()
        val now = clock()
        entries.values.filter { it.rule.id !in probesInFlight && it.isProbeDue(now, force) }.map { entry ->
            val ruleId = entry.rule.id
            val target = checkNotNull(entry.rule.target)
            probesInFlight += ruleId
            scope.launch {
                try {
                    val outcome = probeContained(currentRuntime, target)
                    mutex.withLock {
                        // A stop, restart, or detach replaced the entry while
                        // this probe was out: its answer is about a rule that
                        // no longer exists, possibly with another target.
                        if (entries[ruleId] === entry) {
                            observeLocked(entry, outcome, ObservationSource.Probe)
                        }
                    }
                } finally {
                    probesInFlight -= ruleId
                }
            }
        }
    }

    private suspend fun probeContained(
        runtime: PortForwardingRuntime,
        target: PortForwardEndpoint,
    ): ForwardedServiceProbe = try {
        runtime.probe(target)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        // An uncaught failure on this scope reaches the default handler,
        // which on Android ends the process.
        ForwardedServiceProbe.Inconclusive(error.javaClass.simpleName)
    }

    private suspend fun startLocked(rule: PortForwardRule) {
        val validation = policy.validate(rule, configuredRules.values)
        if (validation != null) {
            updateStateLocked(rule, PortForwardingStatus.Failed(PortForwardingFailure.Validation(validation)))
            return
        }
        val currentRuntime = runtime
        if (currentRuntime == null) {
            updateStateLocked(
                rule,
                PortForwardingStatus.Failed(PortForwardingFailure.Transport("SSH forwarding runtime is unavailable")),
            )
            return
        }
        if (!currentRuntime.capabilities.supports(rule.direction)) {
            updateStateLocked(
                rule,
                PortForwardingStatus.Failed(
                    PortForwardingFailure.Unsupported(
                        currentRuntime.capabilities.unavailableReason?.let(::unavailableText)
                            ?: "This transport does not support ${rule.direction}",
                    ),
                ),
            )
            return
        }

        updateStateLocked(rule, PortForwardingStatus.Starting)
        try {
            val lease = currentRuntime.start(rule)
            val entry = ActiveEntry(rule = rule, lease = lease, watchesService = policy.watchesService(rule))
            entries[rule.id] = entry
            updateActivityLocked(entry, lease.activeConnectionCount.value)
            entry.activityJob = scope.launch {
                lease.activeConnectionCount.collect { count ->
                    mutex.withLock {
                        val live = entries[rule.id] ?: return@withLock
                        if (live.lease === lease) updateActivityLocked(live, count)
                    }
                }
            }
            entry.evidenceJob = scope.launch {
                lease.serviceEvidence.collect { outcome ->
                    mutex.withLock {
                        val live = entries[rule.id] ?: return@withLock
                        if (live.lease === lease) observeLocked(live, outcome, ObservationSource.Passive)
                    }
                }
            }
            entry.lifecycleJob = scope.launch {
                lease.isOpen.collect { open ->
                    if (open) return@collect
                    mutex.withLock {
                        val live = entries[rule.id] ?: return@withLock
                        if (live.lease !== lease) return@withLock
                        entries.remove(rule.id)
                        live.activityJob?.cancel()
                        live.evidenceJob?.cancel()
                        updateStateLocked(
                            live.rule,
                            PortForwardingStatus.Failed(
                                PortForwardingFailure.Transport("Forwarding listener stopped unexpectedly"),
                            ),
                        )
                    }
                }
            }
        } catch (error: Throwable) {
            updateStateLocked(
                rule,
                PortForwardingStatus.Failed(
                    PortForwardingFailure.Transport(error.message ?: error.javaClass.simpleName),
                ),
            )
        }
    }

    private fun stopLocked(ruleId: UUID) {
        val entry = entries.remove(ruleId)
        entry?.activityJob?.cancel()
        entry?.evidenceJob?.cancel()
        entry?.lifecycleJob?.cancel()
        runCatching { entry?.lease?.close() }
        configuredRules[ruleId]?.let { updateStateLocked(it, PortForwardingStatus.Idle) }
    }

    private fun detachLocked(closeRuntime: Boolean) {
        entries.keys.toList().forEach(::stopLocked)
        if (closeRuntime) runCatching { runtime?.close() }
        runtime = null
        configuredRules = emptyMap()
        mutableStates.value = emptyMap()
    }

    private fun publishAllIdleLocked() {
        mutableStates.value = configuredRules.mapValues { (_, rule) ->
            PortForwardingState(rule, PortForwardingStatus.Idle)
        }
    }

    private fun updateActivityLocked(entry: ActiveEntry, count: Int) {
        entry.connectionCount = count
        publishEntryLocked(entry)
    }

    /**
     * Applies one open's verdict. Any observation, conclusive or not, restarts
     * the rule's cadence: a real connection is as fresh as a probe. Anything
     * but a serving answer lengthens the unconfirmed streak that backs the
     * cadence off, and a run of inconclusive ones forgets what was known
     * ([INCONCLUSIVE_LOOKS_BEFORE_UNKNOWN]).
     */
    private fun observeLocked(entry: ActiveEntry, outcome: ForwardedServiceProbe, source: ObservationSource) {
        observations += 1
        // Only watched rules are probed; this drops the passive evidence of
        // the rest (see ForwardingRulePolicy.watchesService).
        if (!entry.watchesService) return
        entry.lastObservedAt = clock()
        entry.unconfirmedStreak = if (outcome == ForwardedServiceProbe.Serving) 0 else entry.unconfirmedStreak + 1
        entry.inconclusiveStreak = if (outcome is ForwardedServiceProbe.Inconclusive) entry.inconclusiveStreak + 1 else 0
        val previous = entry.service
        val previousProhibited = entry.prohibited
        when (outcome) {
            ForwardedServiceProbe.Serving -> {
                entry.service = ForwardedServiceState.Serving
                entry.prohibited = false
            }
            ForwardedServiceProbe.NotServing -> {
                entry.service = ForwardedServiceState.NotServing
                entry.prohibited = false
            }
            ForwardedServiceProbe.Prohibited -> {
                entry.service = ForwardedServiceState.Unknown
                entry.prohibited = true
            }
            // `prohibited` stands: nothing here says the server relented.
            is ForwardedServiceProbe.Inconclusive ->
                if (entry.inconclusiveStreak >= INCONCLUSIVE_LOOKS_BEFORE_UNKNOWN) {
                    entry.service = ForwardedServiceState.Unknown
                }
        }
        val kind = outcome.diagnosticName()
        // Transitions and the first of a run of identical outcomes only: a
        // serving rule probed every 15 s must not fill the capped log.
        if (entry.service != previous || entry.prohibited != previousProhibited || kind != entry.lastOutcomeKind) {
            val target = entry.rule.target
            diagnostics(
                "forwarding_service",
                buildMap {
                    put("source", source.wireName)
                    put("outcome", kind)
                    put("state", entry.service.diagnosticName())
                    put("bind_port", entry.lease.bound.port.toString())
                    if (target != null) put("target_port", target.port.toString())
                    if (outcome is ForwardedServiceProbe.Inconclusive) put("detail", outcome.detail)
                },
            )
        }
        entry.lastOutcomeKind = kind
        publishEntryLocked(entry)
    }

    private fun publishEntryLocked(entry: ActiveEntry) {
        val status = if (entry.connectionCount > 0) {
            PortForwardingStatus.Active(entry.lease.bound, entry.connectionCount)
        } else {
            PortForwardingStatus.Listening(entry.lease.bound)
        }
        updateStateLocked(entry.rule, status, entry.service, entry.prohibited)
    }

    /**
     * The only writer of individual rule states. A state equal to the one
     * already published is not written at all, so observers — the top bar,
     * the panel, the shared-session forwarding event — see nothing when a
     * probe merely confirms what was known.
     */
    private fun updateStateLocked(
        rule: PortForwardRule,
        status: PortForwardingStatus,
        service: ForwardedServiceState = ForwardedServiceState.Unknown,
        prohibited: Boolean = false,
    ) {
        val next = PortForwardingState(rule, status, service, prohibited)
        val current = mutableStates.value
        if (current[rule.id] == next) return
        mutableStates.value = current.toMutableMap().apply { put(rule.id, next) }
    }

    private class ActiveEntry(
        var rule: PortForwardRule,
        val lease: PortForwardingLease,
        var watchesService: Boolean,
    ) {
        var activityJob: Job? = null
        var evidenceJob: Job? = null
        var lifecycleJob: Job? = null
        var connectionCount = 0
        var service = ForwardedServiceState.Unknown
        var prohibited = false
        var lastObservedAt: Long? = null
        var lastOutcomeKind: String? = null

        /**
         * Consecutive looks, probe or passive, that did not confirm a serving
         * target. A fresh entry — every stop, restart, failure, or target
         * change makes one — starts at zero.
         */
        var unconfirmedStreak = 0

        /** Consecutive looks, probe or passive, that got no answer at all. */
        var inconclusiveStreak = 0

        /** Back to what a fresh entry knows about its target: nothing. */
        fun forgetService() {
            service = ForwardedServiceState.Unknown
            prohibited = false
            unconfirmedStreak = 0
            inconclusiveStreak = 0
            lastObservedAt = null
            lastOutcomeKind = null
        }

        /**
         * Watched and listening without connections: live connections are
         * their own evidence, and a probe beside them would only add a
         * channel to a busy tunnel.
         */
        val probesServiceActively: Boolean
            get() = watchesService && connectionCount == 0 && rule.target != null

        /** The caller checks the rule's probe slot; this is the cadence alone. */
        fun isProbeDue(now: Long, force: Boolean): Boolean {
            if (!probesServiceActively) return false
            if (force) return true
            val last = lastObservedAt ?: return true
            val interval = when {
                prohibited -> PROHIBITED_PROBE_INTERVAL_MILLIS
                service == ForwardedServiceState.Serving -> SERVING_PROBE_INTERVAL_MILLIS
                // Every refused direct-tcpip connect is an error line in the
                // host's sshd log ("connect_to localhost port 3000: failed").
                // Brisk for about a minute while the user is likely starting
                // the service, then slow, rather than ~720 lines an hour.
                unconfirmedStreak < UNCONFIRMED_BRISK_LOOKS -> UNRESOLVED_PROBE_INTERVAL_MILLIS
                else -> UNRESOLVED_BACKOFF_PROBE_INTERVAL_MILLIS
            }
            return now - last >= interval
        }
    }

    private enum class ObservationSource(val wireName: String) {
        Probe("probe"),
        Passive("passive"),
    }

    internal companion object {
        const val SERVICE_MONITOR_TICK_MILLIS = 1_000L

        /** Unknown or not serving: the user is likely waiting for it to come up. */
        const val UNRESOLVED_PROBE_INTERVAL_MILLIS = 5_000L

        /** Unconfirmed looks at [UNRESOLVED_PROBE_INTERVAL_MILLIS] before backing off. */
        const val UNCONFIRMED_BRISK_LOOKS = 12
        const val UNRESOLVED_BACKOFF_PROBE_INTERVAL_MILLIS = 30_000L
        const val SERVING_PROBE_INTERVAL_MILLIS = 15_000L

        /** The server forbids forwarding; asking again is unlikely to help. */
        const val PROHIBITED_PROBE_INTERVAL_MILLIS = 60_000L

        /**
         * Inconclusive looks in a row before what was known is dropped. The
         * app keeps no SSH keepalive, so a transport that died quietly — mosh
         * keeps the terminal alive over it — or a target whose connect hangs
         * past the probe deadline answers every look inconclusively, and a
         * rule that kept its last answer would stay green on a tunnel that
         * can no longer carry a page. Two, not one, so a single slow answer
         * on a busy link does not flicker it. The same as iOS
         * `ForwardedServiceCadence.inconclusiveLooksBeforeUnknown`.
         */
        const val INCONCLUSIVE_LOOKS_BEFORE_UNKNOWN = 2

        private const val NANOS_PER_MILLI = 1_000_000L
    }
}

private fun ForwardedServiceProbe.diagnosticName(): String = when (this) {
    ForwardedServiceProbe.Serving -> "serving"
    ForwardedServiceProbe.NotServing -> "not_serving"
    ForwardedServiceProbe.Prohibited -> "prohibited"
    is ForwardedServiceProbe.Inconclusive -> "inconclusive"
}

private fun ForwardedServiceState.diagnosticName(): String = when (this) {
    ForwardedServiceState.Unknown -> "unknown"
    ForwardedServiceState.Serving -> "serving"
    ForwardedServiceState.NotServing -> "not_serving"
}
