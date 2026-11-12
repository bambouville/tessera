package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsForwardPlan
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingState
import com.bambouville.tessera.forwarding.PortForwardingStatus
import java.io.IOException
import java.io.OutputStream
import java.net.BindException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The policy is injected; these lifecycle tests run without JNI or a remote host. */
class ArtifactPageForwarderFilesTest {
    private class Rules(initial: List<PortForwardRule> = emptyList()) : PortForwardRuleStore {
        val value = MutableStateFlow(initial)
        var replacements = 0
        override fun observe(hostId: String) = value
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) { replacements += 1; value.value = rules }
        override suspend fun delete(hostId: String) { value.value = emptyList() }
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        var closes = 0
        override fun close() { closes += 1; isOpen.value = false }
    }
    private class Slot(var currentOrNull: Lease? = null) {
        var connectionAttempts = 0
        fun connected(): Nothing { connectionAttempts += 1; error("artifacts must never connect Files") }
    }
    private class Files(val slot: Slot) : ArtifactLiveFiles {
        override val hasLiveArtifactChannel: Boolean get() = slot.currentOrNull != null
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        val acquired = mutableListOf<PortForwardRule>()
        var onAcquire: suspend (PortForwardRule) -> Unit = {}
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? {
            val held = slot.currentOrNull ?: return null
            acquired += rule
            onAcquire(rule)
            return held
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? = error("a page must not read a file")
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? = error("a page must not stat a file")
        override suspend fun probeOnLiveChannel(command: String): String? = error("a page must not probe Files")
    }
    private fun tab(host: String) = SharedArtifactTab("tab", host, "dev", SharedArtifactsTarget.Page("https", 5173, "/app?q=1#view"),
        SharedArtifactsKind.Pages, "dev app", "terminalLink", "mosh-session", 1, 1, false, null, false, null)
    private val planned = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 5173), target = PortForwardEndpoint("127.0.0.1", 5173))
    private val expected = ArtifactContent.ForwardedPage("https://127.0.0.1:45555/app?q=1#view", "dev app", true)
    private val unavailable = ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
    private fun forwarder(plan: SharedArtifactsForwardPlan = SharedArtifactsForwardPlan.Ephemeral(planned.artifactSharedRule()), rules: List<PortForwardRule> = emptyList(), ruleStore: Rules = Rules(rules)) =
        ArtifactPageForwarder(ArtifactsLiveHosts(), ruleStore, planForward = { _, _ -> plan }, webTarget = {
            SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}")
        })

    @Test fun moshUsesAnAlreadyHeldFilesChannelAndClosingTheTabReleasesIt() = runBlocking {
        val host = UUID.randomUUID().toString()
        val lease = Lease()
        val files = Files(Slot(lease))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(listOf(planned), files.acquired)
            assertFalse(forwarder.canKeep("tab"))
            forwarder.close("tab"); forwarder.close("tab")
            assertEquals(1, lease.closes)
            assertFalse(forwarder.canKeep("tab"))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun keepingAFilesLeaseCannotSaveARuleOrReleaseThePagesListener() = runBlocking {
        val host = UUID.randomUUID().toString()
        val lease = Lease()
        val files = Files(Slot(lease))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val rules = Rules()
        val forwarder = forwarder(ruleStore = rules)
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertFalse(forwarder.canKeep("tab"))
            forwarder.keep(tab(host))
            assertEquals(0, rules.replacements)
            assertTrue(rules.value.value.isEmpty())
            assertTrue(lease.isOpen.value)
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun aReusePlanCannotPublishARunningRuleThatAlreadyTargetsAnotherPort() = runBlocking {
        val host = UUID.randomUUID().toString()
        val edited = planned.copy(target = PortForwardEndpoint("127.0.0.1", 6000))
        val states = MutableStateFlow(mapOf(planned.id to PortForwardingState(edited, PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 45555)))))
        val registration = ArtifactLiveForwardingRegistry.register(host, UUID.randomUUID().toString(), states) { true }
        val plan = SharedArtifactsForwardPlan.Reuse(planned.id.toString(), SharedForwardedWebTarget("http", "127.0.0.1", 5173, "http://127.0.0.1:5173"))
        val forwarder = forwarder(plan, listOf(planned))
        try {
            assertEquals(unavailable, forwarder.load(tab(host)))
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun editingAReusedRulesRemotePortDropsItsPageAndReplansTheOriginalPort() = runBlocking {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val rules = Rules(listOf(planned))
        val states = MutableStateFlow(mapOf(planned.id to PortForwardingState(planned, PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 45555)))))
        val acquired = mutableListOf<PortForwardRule>()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { acquired += it; Lease() })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, states) { true }
        val forwarder = ArtifactPageForwarder(ArtifactsLiveHosts(), rules, planForward = { port, current ->
            val reuse = current.firstOrNull { it.target?.port == port }
            if (reuse == null) SharedArtifactsForwardPlan.Ephemeral(planned.artifactSharedRule())
            else SharedArtifactsForwardPlan.Reuse(reuse.id, SharedForwardedWebTarget("http", "127.0.0.1", 45555, "http://127.0.0.1:45555"))
        }, webTarget = { SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}") })
        try {
            assertFalse((forwarder.load(tab(host)) as ArtifactContent.ForwardedPage).isEphemeral)
            val edited = planned.copy(target = PortForwardEndpoint("127.0.0.1", 6000))
            rules.value.value = listOf(edited)
            states.value = mapOf(edited.id to PortForwardingState(edited, PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 45555))))
            assertEquals(setOf("tab"), forwarder.sweep())
            assertTrue((forwarder.load(tab(host)) as ArtifactContent.ForwardedPage).isEphemeral)
            assertEquals(5173, acquired.single().target?.port)
        } finally { forwarder.close("tab"); registration.close(); provider.close() }
    }

    @Test fun noHeldFilesChannelYieldsNoForwardingAndNeverConnects() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files(Slot())
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(unavailable, forwarder.load(tab(host)))
            assertTrue(files.acquired.isEmpty())
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun aFilesChannelOpenedElsewhereCanThenSupplyThePageWithoutAConnectionAttempt() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files(Slot())
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(unavailable, forwarder.load(tab(host)))
            files.slot.currentOrNull = Lease()
            ArtifactLiveFilesRegistry.changed()
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun registryRemovalReleasesTheFilesLeaseEvenWhenItsChannelStillReportsLive() = runBlocking {
        val host = UUID.randomUUID().toString()
        val lease = Lease()
        val files = Files(Slot(lease))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            val revision = ArtifactLiveFilesRegistry.revision.value
            registration.close()
            assertTrue(ArtifactLiveFilesRegistry.revision.value > revision)
            assertEquals(setOf("tab"), forwarder.sweep())
            assertEquals(1, lease.closes)
            assertEquals(unavailable, forwarder.load(tab(host)))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun lossOfTheHeldChannelReleasesTheLeaseWithoutReconnecting() = runBlocking {
        val host = UUID.randomUUID().toString()
        val lease = Lease()
        val files = Files(Slot(lease))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            files.slot.currentOrNull = null
            ArtifactLiveFilesRegistry.changed()
            assertEquals(setOf("tab"), forwarder.sweep())
            assertFalse(lease.isOpen.value)
            assertEquals(unavailable, forwarder.load(tab(host)))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun aFilesCapabilityRemovedDuringAcquisitionCannotPublishItsLease() = runBlocking {
        val host = UUID.randomUUID().toString()
        val lease = Lease()
        val files = Files(Slot(lease))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        files.onAcquire = { registration.close() }
        try {
            assertEquals(unavailable, forwarder.load(tab(host)))
            assertEquals(1, lease.closes)
            assertFalse(forwarder.canKeep("tab"))
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun filesDisconnectionDuringAcquisitionShowsNoForwarding() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files(Slot(Lease()))
        files.onAcquire = { files.slot.currentOrNull = null; throw IOException("files connection closed") }
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(unavailable, forwarder.load(tab(host)))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun aSessionAcquirerWinsBeforeFiles() = runBlocking {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val sessionLease = Lease()
        val filesLease = Lease()
        val files = Files(Slot(filesLease))
        val filesRegistration = ArtifactLiveFilesRegistry.register(host, session, files, sessionLive = { true })
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { sessionLease })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, MutableStateFlow(emptyMap<UUID, PortForwardingState>())) { true }
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertTrue(files.acquired.isEmpty())
            forwarder.close("tab")
            assertFalse(sessionLease.isOpen.value)
            assertTrue(filesLease.isOpen.value)
        } finally { forwarder.close("tab"); registration.close(); provider.close(); filesRegistration.close() }
    }

    @Test fun unavailableSessionAcquirersFallBackToFiles() = runBlocking {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val files = Files(Slot(Lease()))
        val filesRegistration = ArtifactLiveFilesRegistry.register(host, session, files, sessionLive = { true })
        var sessionAttempts = 0
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { sessionAttempts += 1; null })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, MutableStateFlow(emptyMap<UUID, PortForwardingState>())) { true }
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(1, sessionAttempts)
            assertEquals(1, files.acquired.size)
        } finally { forwarder.close("tab"); registration.close(); provider.close(); filesRegistration.close() }
    }

    @Test fun aStoppedSavedRuleUsesAnEphemeralFilesLeaseWithoutStartingATerminalForward() = runBlocking {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val files = Files(Slot(Lease()))
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        var terminalAttempts = 0
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { terminalAttempts += 1; Lease() })
        val forwarding = ArtifactLiveForwardingRegistry.register(host, session,
            MutableStateFlow(mapOf(planned.id to PortForwardingState(planned, PortForwardingStatus.Idle)))) { true }
        val plan = SharedArtifactsForwardPlan.Reuse(planned.id.toString(), SharedForwardedWebTarget("http", "127.0.0.1", 5173, "http://127.0.0.1:5173"))
        val ephemeral = planned.copy(id = UUID(0, 0), autoStart = false)
        val rules = Rules(listOf(planned))
        val forwarder = ArtifactPageForwarder(ArtifactsLiveHosts(), rules, planForward = { port, current ->
            assertEquals(5173, port)
            if (current.isEmpty()) SharedArtifactsForwardPlan.Ephemeral(ephemeral.artifactSharedRule()) else plan
        }, webTarget = { SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}") })
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(listOf(ephemeral), files.acquired)
            assertEquals(0, terminalAttempts)
            assertEquals(listOf(planned), rules.value.value)
            assertEquals(0, rules.replacements)
            assertFalse(forwarder.canKeep("tab"))
            assertEquals(0, files.slot.connectionAttempts)
        } finally { forwarder.close("tab"); forwarding.close(); provider.close(); registration.close() }
    }

    @Test fun filesBindCollisionsRetryWithAnAllocatedPort() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files(Slot(Lease()))
        files.onAcquire = { if (it.bind.port != 0) throw BindException("in use") }
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val forwarder = forwarder()
        try {
            assertEquals(expected, forwarder.load(tab(host)))
            assertEquals(listOf(5173, 0), files.acquired.map { it.bind.port })
        } finally { forwarder.close("tab"); registration.close() }
    }

    @Test fun cancellingASessionAcquisitionDoesNotFallThroughToFiles() = runBlocking {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val files = Files(Slot(Lease()))
        val filesRegistration = ArtifactLiveFilesRegistry.register(host, session, files, sessionLive = { true })
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { throw CancellationException("session closed") })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, MutableStateFlow(emptyMap<UUID, PortForwardingState>())) { true }
        val forwarder = forwarder()
        try {
            assertTrue(runCatching { forwarder.load(tab(host)) }.exceptionOrNull() is CancellationException)
            assertTrue(files.acquired.isEmpty())
        } finally { forwarder.close("tab"); registration.close(); provider.close(); filesRegistration.close() }
    }
}
