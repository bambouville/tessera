package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentRuntime
import com.bambouville.tessera.core.bridge.CoordinatorOnlyAgentRouteAuthority
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedAgentProcessDescriptor
import com.bambouville.tessera.core.bridge.SharedAgentProviderClassification
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Application/session-coordinator-owned registry of live endpoints. It holds
 * endpoint adapters only; endpoints must never retain a terminal View.
 */
interface AgentSessionDirectory {
    val sessions: StateFlow<List<AgentEndpointBinding>>
    fun resolve(key: AgentSessionKey): AgentSessionEndpoint?
}

interface AgentSessionLifecycleCapabilities {
    fun supportsLifecycle(binding: AgentEndpointBinding, provider: AgentProofProvider): Boolean
}

class LiveAgentSessionRegistry : AutoCloseable, AgentSessionDirectory {
    private val lock = Any()
    private val endpoints = linkedMapOf<AgentSessionKey, AgentSessionEndpoint>()
    private val mutableSessions = MutableStateFlow<List<AgentEndpointBinding>>(emptyList())
    override val sessions: StateFlow<List<AgentEndpointBinding>> = mutableSessions.asStateFlow()

    fun register(endpoint: AgentSessionEndpoint): AgentSessionRegistration {
        synchronized(lock) {
            check(endpoints[endpoint.key] == null) { "Agent endpoint already registered" }
            endpoints[endpoint.key] = endpoint
            publishLocked()
        }
        return AgentSessionRegistration(this, endpoint.key)
    }

    override fun resolve(key: AgentSessionKey): AgentSessionEndpoint? = synchronized(lock) { endpoints[key] }

    /** Publishes a binding update without allowing adapters to mutate registry keys. */
    fun refresh(key: AgentSessionKey) {
        synchronized(lock) {
            if (endpoints.containsKey(key)) publishLocked()
        }
    }

    fun unregister(key: AgentSessionKey) {
        val endpoint = synchronized(lock) {
            endpoints.remove(key).also { publishLocked() }
        }
        endpoint?.close()
    }

    /** Invalidates every old carrier generation before controllers are disposed. */
    override fun close() {
        val detached = synchronized(lock) {
            endpoints.values.toList().also {
                endpoints.clear()
                publishLocked()
            }
        }
        detached.forEach { it.close() }
    }

    private fun publishLocked() {
        mutableSessions.value = endpoints.values.map { it.binding.value }
    }
}

class AgentSessionRegistration internal constructor(
    private val registry: LiveAgentSessionRegistry,
    private val key: AgentSessionKey,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    override fun close() {
        if (closed.compareAndSet(false, true)) registry.unregister(key)
    }
}

/**
 * The application/session coordinator owns this for the lifetime of its live
 * controller set. It deliberately does not create a native runtime until a
 * future Agent presenter explicitly asks for one.
 */
class AndroidAgentSessionCoordinator(
    private val registry: LiveAgentSessionRegistry,
) : AutoCloseable, AgentSessionLifecycleCapabilities {
    /** Read-only facade: presentation code cannot register a self-attesting endpoint. */
    val directory: AgentSessionDirectory = object : AgentSessionDirectory {
        override val sessions: StateFlow<List<AgentEndpointBinding>> get() = registry.sessions
        override fun resolve(key: AgentSessionKey): AgentSessionEndpoint? = registry.resolve(key)
    }
    private var runtime: SharedAgentRuntime? = null
    private var tierCConformances: Map<AgentSessionKey, Pair<AgentEndpointBinding, Set<AgentTierCProvider>>> = emptyMap()
    private val issuedRoutes = IssuedRouteMemo()

    @Synchronized
    fun runtime(): SharedAgentRuntime = runtime ?: SharedAgentRuntime.create().also { runtime = it }

    /**
     * The coordinator is the sole Android caller of native Tier-C capability
     * registration. A provider reaches this only after the separate bounded
     * remote-data inventory gate has completed successfully.
     */
    @OptIn(CoordinatorOnlyAgentRouteAuthority::class)
    @Synchronized
    fun registerTierCConformances(
        conformances: Map<AgentEndpointBinding, Set<AgentTierCProvider>>,
    ): Boolean {
        val current = runtime ?: return false
        if (conformances.keys.any { registry.resolve(it.key)?.binding?.value != it }) return false
        val exact = conformances.entries.associate { (binding, providers) ->
            binding.key to (binding to providers)
        }
        val providers = exact.values.flatMapTo(linkedSetOf()) { it.second }
        if (!current.registerPlatformConformingProviders(providers.mapTo(linkedSetOf()) { it.providerID })) return false
        tierCConformances = exact
        return true
    }

    @Synchronized
    override fun supportsLifecycle(binding: AgentEndpointBinding, provider: AgentProofProvider): Boolean =
        when (provider) {
            AgentProofProvider.CLAUDE, AgentProofProvider.CODEX -> true
            AgentProofProvider.KIMI -> supportsTierC(binding, AgentTierCProvider.Kimi)
        }

    @Synchronized
    private fun supportsTierC(binding: AgentEndpointBinding, provider: AgentTierCProvider): Boolean =
        registry.resolve(binding.key)?.isCurrentRoute(binding) == true &&
            tierCConformances[binding.key]?.let { (exact, providers) ->
                exact.sameRouteAs(binding) && provider in providers
            } == true

    /**
     * The only presentation-facing authority issuance path.  It intentionally
     * resolves the endpoint from the app-owned registry rather than accepting
     * a caller-supplied endpoint or proof. The feature layer receives only the
     * read-only directory facade, so it cannot register a self-attesting route.
     */
    /** Host inventory is observational. This path cannot accept a PID or
     * upgrade a host-wide carrier into pane action authority. */
    suspend fun issueIngestionBinding(threadID: org.json.JSONObject, key: AgentSessionKey): AgentEndpointResult<AgentIssuedBinding> {
        val current = synchronized(this) { runtime }
            ?: return AgentEndpointResult.Unavailable("Agent runtime unavailable")
        val endpoint = registry.resolve(key) ?: return AgentEndpointResult.StaleBinding
        val issued = AgentRouteBindingAuthority(current).issue(endpoint, threadID, endpoint.ingestionBinding,
            claimedPID = null, hostObservation = true)
        if (issued is AgentEndpointResult.Success) issuedRoutes.retireOthers(IssuedRouteMemo.threadIdentity(threadID), issued.value)
        return issued
    }

    suspend fun issueRouteBinding(
        threadID: org.json.JSONObject,
        binding: AgentEndpointBinding,
        claimedPID: Int?,
        providerID: String,
    ): AgentEndpointResult<AgentIssuedBinding> {
        val current = synchronized(this) { runtime }
            ?: return AgentEndpointResult.Unavailable("Agent runtime unavailable")
        val endpoint = registry.resolve(binding.key) ?: return AgentEndpointResult.StaleBinding
        if (!endpoint.isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
        AgentTierCProvider.fromWire(providerID)?.let { provider ->
            if (!supportsTierC(binding, provider)) return AgentEndpointResult.StaleBinding
        }
        // A hook provider emits several frames for one tool call, and every one
        // of them asks for authority over the same pane, PID and thread. Issuing
        // it again costs a tmux round trip for the pane process, a second for its
        // directory and a fresh SSH exec channel for the proof, all on the
        // carrier the reader is typing through; a busy agent turned that into a
        // steady stream of channel opens behind the terminal. The coordinator
        // already refuses to repeat this work on its own integration path (see
        // `trustedLifecycleProcesses`); this is the same rule for the
        // presentation path, bounded in time rather than by binding identity so
        // an agent that exits cannot stay actionable on a remembered proof.
        val cacheKey = IssuedRouteKey(binding, IssuedRouteMemo.threadIdentity(threadID), providerID, claimedPID)
        issuedRoutes.remembered(cacheKey)?.let { return AgentEndpointResult.Success(it) }
        val issued = AgentRouteBindingAuthority(current).issue(endpoint, threadID, binding, claimedPID)
        if (issued is AgentEndpointResult.Success) {
            issuedRoutes.retireOthers(cacheKey.threadIdentity, issued.value)
            issuedRoutes.remember(cacheKey, issued.value)
        }
        return issued
    }

    /**
     * Turns a fresh route-scoped process fact into an observe-only Tier-A row.
     * Provider identity is classified by native Core and the candidate receives
     * no action token, even though its process binding remains fresh enough to
     * reject a forged or cross-route PID.
     */
    @OptIn(CoordinatorOnlyAgentRouteAuthority::class)
    fun registerTierACandidate(
        binding: AgentEndpointBinding,
        process: AgentDiscoveredProcess,
        allProcessIDs: Set<Int>,
        liveTail: String,
        knownCandidates: Map<String, AgentTierACandidateRegistration> = emptyMap(),
    ): AgentTierACandidateRegistration? {
        val current = synchronized(this) { runtime } ?: return null
        val endpoint = registry.resolve(binding.key) ?: return null
        if (endpoint.binding.value != binding || process.processID !in allProcessIDs) return null
        val providerID = runCatching {
            SharedAgentProviderClassification.classify(
                listOf(SharedAgentProcessDescriptor(process.executable)),
            ).singleOrNull()
        }.getOrNull() ?: return null
        val sourceIdentity = "android:${binding.key.liveSessionID}:${binding.key.carrierGeneration}:${binding.paneID ?: "raw"}:$providerID:${process.processID}"
        // Exact equality matters: different PID sets can have the same hash,
        // and stale process evidence can hide an unidentified terminal.
        val registrationState = AgentTierACandidateRegistration(providerID, sourceIdentity, liveTail, allProcessIDs.toSet())
        if (knownCandidates[sourceIdentity] == registrationState) return registrationState
        val candidateBinding = binding.candidateCoreBinding(process.processID)
        val id = JSONObject()
            .put("hostID", binding.hostID)
            .put("providerID", JSONObject().put("rawValue", providerID))
            .put("sourceIdentity", sourceIdentity)
        val registration = JSONObject()
            .put("id", id)
            .put("fallback", JSONObject()
                .put("status", "working")
                .put("location", binding.paneID ?: binding.transport.name.lowercase())
                .put("integrationAvailable", false)
                .put("liveTail", liveTail.takeLast(16_384))
                .put("binding", candidateBinding))
            .put("providerName", "Agent")
            .put("title", "Live agent")
            .put("hostDisplayLabel", binding.hostDisplayLabel)
            .put("processIDs", JSONArray(allProcessIDs.sorted()))
        return registrationState.takeIf {
            current.registerPlatformCandidate(registration) == CoreCallResult.Accepted
        }
    }

    @OptIn(CoordinatorOnlyAgentRouteAuthority::class)
    fun removeTierACandidate(binding: AgentEndpointBinding, providerID: String, sourceIdentity: String) {
        val current = synchronized(this) { runtime } ?: return
        current.removePlatformCandidate(JSONObject().put("id", JSONObject()
            .put("hostID", binding.hostID)
            .put("providerID", JSONObject().put("rawValue", providerID))
            .put("sourceIdentity", sourceIdentity)))
    }

    @Synchronized
    fun resetRuntime() {
        runtime?.close()
        runtime = null
        tierCConformances = emptyMap()
        issuedRoutes.clear()
    }

    @Synchronized
    override fun close() {
        registry.close()
        runtime?.close()
        runtime = null
        tierCConformances = emptyMap()
        issuedRoutes.clear()
    }
}

internal data class IssuedRouteKey(
    val binding: AgentEndpointBinding,
    val threadIdentity: String,
    val providerID: String,
    val claimedPID: Int?,
)

/**
 * Remembers an issuance long enough that the several lifecycle frames one tool
 * call produces cost one proof between them, and no longer. Freshness is the
 * whole point of the proof, so this expires on a clock rather than living until
 * the binding changes: an agent that exits must stop being actionable while a
 * reader is still looking at its row.
 */
internal class IssuedRouteMemo(
    private val freshNanos: Long = DEFAULT_FRESH_NANOS,
    private val capacity: Int = DEFAULT_CAPACITY,
    private val clock: () -> Long = System::nanoTime,
) {
    private class Entry(val value: AgentIssuedBinding, val freshUntilNanos: Long)

    private val entries = ConcurrentHashMap<IssuedRouteKey, Entry>()

    fun remembered(key: IssuedRouteKey): AgentIssuedBinding? =
        entries[key]?.takeIf { it.freshUntilNanos > clock() }?.value

    fun remember(key: IssuedRouteKey, value: AgentIssuedBinding) {
        val now = clock()
        if (entries.size >= capacity) entries.entries.removeAll { it.value.freshUntilNanos <= now }
        if (entries.size < capacity) entries[key] = Entry(value, now + freshNanos)
    }

    /**
     * Core keeps one live token per thread, so a fresh issuance retires every
     * other token remembered for it. Handing one back later would install an
     * owner whose every command Core refuses as stale.
     */
    fun retireOthers(threadIdentity: String, live: AgentIssuedBinding) {
        entries.entries.removeAll { it.key.threadIdentity == threadIdentity && it.value.value.bindingToken != live.bindingToken }
    }

    fun clear() = entries.clear()

    companion object {
        /**
         * Long enough to absorb the frames of one tool call, short enough that a
         * pane whose agent has gone is re-proven before a reader can act on it.
         */
        const val DEFAULT_FRESH_NANOS = 10_000_000_000L
        const val DEFAULT_CAPACITY = 64

        /**
         * The identity Core cross-checks the lifecycle envelope against,
         * flattened so two threads sharing one pane can never share a
         * remembered issuance.
         */
        fun threadIdentity(threadID: JSONObject): String = listOf(
            threadID.optString("hostID"),
            threadID.optJSONObject("providerID")?.optString("rawValue").orEmpty(),
            threadID.optString("providerSessionID"),
        ).joinToString("\u0000")
    }
}

data class AgentTierACandidateRegistration(
    val providerID: String,
    val sourceIdentity: String,
    val liveTail: String,
    val processIDs: Set<Int>,
)
