package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsForwardPlan
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedForwardDirection
import com.bambouville.tessera.core.bridge.SharedForwardEndpoint
import com.bambouville.tessera.core.bridge.SharedForwardRule
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.core.bridge.SharedForwardingPolicy
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.PortForwardDirection
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingStatus
import java.net.BindException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Tabs on one host and remote port share one temporary forward: the scheme
 * only changes the URL, and a second listener per tab would be waste. The
 * forward closes with the last tab using it.
 */
internal class ArtifactPageForwarder(
    private val hosts: ArtifactsLiveHosts,
    private val rules: PortForwardRuleStore,
    private val planForward: (Int, List<SharedForwardRule>) -> SharedArtifactsForwardPlan = SharedArtifacts::forwardPlan,
    private val webTarget: (SharedForwardRule) -> SharedForwardedWebTarget? = SharedForwardingPolicy::webTarget,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private data class Held(val isLive: () -> Boolean, val rule: SharedForwardRule, val lease: PortForwardingLease, val canKeep: Boolean)
    private data class Reused(val session: ArtifactLiveForwardingRegistry.Session, val rule: PortForwardRule, val bound: com.bambouville.tessera.forwarding.BoundForwardEndpoint)
    private data class Key(val hostId: String, val port: Int)
    private class Shared(val held: Held, first: String) {
        val tabs: MutableSet<String> = ConcurrentHashMap.newKeySet<String>().apply { add(first) }
    }
    private val mutex = Mutex()
    // Read without the mutex by canKeep on Main; written only under it.
    private val shared = ConcurrentHashMap<Key, Shared>()
    private val tabKeys = ConcurrentHashMap<String, Key>()
    private val reused = mutableMapOf<String, Reused>()

    /** The tabs sharing [tabId]'s temporary forward, including it; empty when it holds none. */
    fun sharingTabs(tabId: String): Set<String> = tabKeys[tabId]?.let { shared[it]?.tabs?.toSet() }.orEmpty()

    suspend fun load(tab: SharedArtifactTab): ArtifactContent = withContext(ioDispatcher) {
        mutex.withLock {
            val target = tab.target as? SharedArtifactsTarget.Page
            val key = target?.let { Key(tab.hostId, it.port) }
            // A tab that moved to another port or host lets go of its old forward.
            if (tabKeys[tab.id] != key) release(tab.id)
            if (target == null || key == null) return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
            val existing = shared[key]
            if (existing != null) {
                if (existing.held.isLive() && existing.held.lease.isOpen.value) {
                    existing.tabs += tab.id
                    tabKeys[tab.id] = key
                    reused.remove(tab.id)
                    return@withLock content(target, existing.held.rule, true, tab.title)
                }
                drop(key)
            }
            val sessions = hosts.forwarding(tab.hostId)
            if (sessions.isEmpty() && hosts.files(tab.hostId) == null) return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
            try {
                val hostRules = rules.observe(tab.hostId).first()
                val acquired = when (val plan = planForward(target.port, hostRules.map(PortForwardRule::artifactSharedRule))) {
                    is SharedArtifactsForwardPlan.Reuse -> {
                        val id = UUID.fromString(plan.ruleId)
                        val expected = hostRules.firstOrNull { it.id == id }
                            ?: return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
                        val running = sessions.asSequence().mapNotNull { session -> session.states.value[id]?.let { session to it } }.firstOrNull {
                            it.second.rule == expected && expected.target?.port == target.port &&
                                (it.second.status is PortForwardingStatus.Listening || it.second.status is PortForwardingStatus.Active)
                        }
                        if (running != null) {
                            val (session, state) = running
                            val bound = when (val status = state.status) {
                                is PortForwardingStatus.Listening -> status.bound
                                is PortForwardingStatus.Active -> status.bound
                                else -> return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
                            }
                            val rule = state.rule.artifactSharedRule().copy(bind = SharedForwardEndpoint(bound.host, bound.port))
                            reused[tab.id] = Reused(session, state.rule, bound)
                            return@withLock content(target, rule, false, state.rule.label.ifBlank { tab.title })
                        }
                        // Files attaches without saved rules; borrow its channel instead of starting the stopped rule.
                        if (hosts.files(tab.hostId) == null) return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
                        val fallback = planForward(target.port, emptyList()) as? SharedArtifactsForwardPlan.Ephemeral
                            ?: return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
                        acquireEphemeral(tab.hostId, fallback.rule, emptyList())
                    }
                    is SharedArtifactsForwardPlan.Ephemeral -> acquireEphemeral(tab.hostId, plan.rule, sessions)
                } ?: return@withLock ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
                reused.remove(tab.id)
                shared[key] = Shared(acquired, tab.id)
                tabKeys[tab.id] = key
                content(target, acquired.rule, true, tab.title)
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                ArtifactContent.Unavailable(ArtifactUnavailable.Failed(artifactFailureMessage(failure, R.string.artifacts_forward_page_failed, limit = 200)))
            }
        }
    }

    private suspend fun acquireEphemeral(
        hostId: String,
        planned: SharedForwardRule,
        sessions: List<ArtifactLiveForwardingRegistry.Session>,
    ): Held? {
        var failure: Exception? = null
        suspend fun acquire(canKeep: Boolean, isLive: () -> Boolean, start: suspend (PortForwardRule) -> PortForwardingLease?): Held? {
            if (!isLive()) return null
            return try {
                var rule = planned
                val lease = try { start(rule.artifactRule()) }
                catch (_: BindException) {
                    rule = rule.copy(bind = rule.bind.copy(port = 0))
                    start(rule.artifactRule())
                } ?: return null
                if (!isLive() || !lease.isOpen.value) { lease.close(); return null }
                Held(isLive, rule.copy(bind = SharedForwardEndpoint(lease.bound.host, lease.bound.port)), lease, canKeep)
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (error: Exception) { if (isLive()) failure = error; null }
        }
        for (session in sessions) {
            if (session.canAcquire) acquire(true, { session.isLive }, session::acquire)?.let { return it }
        }
        val files = hosts.files(hostId)
        if (files != null) acquire(false, { hosts.files(hostId) === files }, files::acquireForwardingLeaseOnLiveChannel)?.let { return it }
        failure?.let { throw it }
        return null
    }

    fun canKeep(tabId: String): Boolean = tabKeys[tabId]?.let(shared::get)?.held
        ?.let { it.canKeep && it.isLive() && it.lease.isOpen.value } == true

    /**
     * Saves [tab]'s temporary forward as a rule. Returns every tab that was
     * sharing it, which must reload through the saved rule; empty when nothing
     * was kept.
     */
    suspend fun keep(tab: SharedArtifactTab): Set<String> = withContext(ioDispatcher) {
        mutex.withLock {
            val key = tabKeys[tab.id] ?: return@withLock emptySet()
            val current = shared[key]?.takeIf { it.held.canKeep && it.held.isLive() && it.held.lease.isOpen.value } ?: return@withLock emptySet()
            val hostRules = rules.observe(tab.hostId).first()
            val rule = SharedArtifacts.keepAsRule(current.held.rule, tab.title, UUID.randomUUID().toString())
            if (SharedForwardingPolicy.validate(rule, hostRules.map(PortForwardRule::artifactSharedRule)) != null) {
                throw ArtifactFailureException(ArtifactMessage.Resource(R.string.artifacts_rule_conflict))
            }
            // The persistent manager must bind the same allocated port. Release
            // our temporary listener before the saved-rule observer starts it.
            val sharing = current.tabs.toSet()
            drop(key)
            rules.replace(tab.hostId, hostRules + rule.artifactRule())
            sharing
        }
    }

    suspend fun close(tabId: String) = withContext(ioDispatcher) { mutex.withLock { reused.remove(tabId); release(tabId) }; Unit }
    suspend fun sweep(): Set<String> = withContext(ioDispatcher) {
        mutex.withLock {
            val reusedChanged = reused.filterValues { saved ->
                val current = saved.session.states.value[saved.rule.id]
                val bound = when (val status = current?.status) {
                    is PortForwardingStatus.Listening -> status.bound
                    is PortForwardingStatus.Active -> status.bound
                    else -> null
                }
                !saved.session.isLive || current?.rule != saved.rule || bound != saved.bound
            }.keys.toSet()
            val dead = shared.filterValues { !it.held.isLive() || !it.held.lease.isOpen.value }.keys.toSet()
            val heldChanged = dead.flatMap { shared[it]?.tabs.orEmpty() }.toSet()
            dead.forEach(::drop)
            (heldChanged + reusedChanged).also { ids -> ids.forEach(reused::remove) }
        }
    }

    /** Under [mutex]: [tabId] stops using its forward, which closes with its last tab. */
    private fun release(tabId: String) {
        val key = tabKeys.remove(tabId) ?: return
        val entry = shared[key] ?: return
        entry.tabs -= tabId
        if (entry.tabs.isEmpty()) {
            shared.remove(key)
            entry.held.lease.close()
        }
    }

    /** Under [mutex]: forgets a forward for every tab using it. */
    private fun drop(key: Key) {
        val entry = shared.remove(key) ?: return
        entry.tabs.forEach { if (tabKeys[it] == key) tabKeys.remove(it) }
        entry.held.lease.close()
    }

    private fun content(target: SharedArtifactsTarget.Page, rule: SharedForwardRule, ephemeral: Boolean, label: String): ArtifactContent {
        val base = webTarget(rule) ?: return ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
        val url = base.url.replaceFirst("${base.scheme}:", "${target.scheme}:").trimEnd('/') + target.path
        return ArtifactContent.ForwardedPage(url, label, ephemeral)
    }
}

internal fun PortForwardRule.artifactSharedRule() = SharedForwardRule(id.toString(), enabled, autoStart, when (direction) {
    PortForwardDirection.LOCAL -> SharedForwardDirection.Local
    PortForwardDirection.REMOTE -> SharedForwardDirection.Remote
    PortForwardDirection.DYNAMIC -> SharedForwardDirection.Dynamic
}, SharedForwardEndpoint(bind.host, bind.port), target?.let { SharedForwardEndpoint(it.host, it.port) }, label)
internal fun SharedForwardRule.artifactRule() = PortForwardRule(UUID.fromString(id), enabled, autoStart, when (direction) {
    SharedForwardDirection.Local -> PortForwardDirection.LOCAL
    SharedForwardDirection.Remote -> PortForwardDirection.REMOTE
    SharedForwardDirection.Dynamic -> PortForwardDirection.DYNAMIC
}, PortForwardEndpoint(bind.host, bind.port), target?.let { PortForwardEndpoint(it.host, it.port) }, label)
