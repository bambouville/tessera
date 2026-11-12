package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingState
import com.bambouville.tessera.forwarding.PortForwardingStatus
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

class ArtifactPageForwarderNativeTest {
    @Before fun requireNativeCore() { assumeTrue(CoreBridge.inspect() is CoreBridgeState.Ready) }
    private class Rules(initial: List<PortForwardRule> = emptyList()) : PortForwardRuleStore {
        val value = MutableStateFlow(initial)
        override fun observe(hostId: String) = value
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) { value.value = rules }
        override suspend fun delete(hostId: String) { value.value = emptyList() }
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        override fun close() { isOpen.value = false }
    }
    private fun tab(host: String) = SharedArtifactTab("tab", host, "dev", SharedArtifactsTarget.Page("http", 5173, "/app?q=1#view"),
        SharedArtifactsKind.Pages, "dev app", "quickOpen", null, 1, 1, false, null, false, null)
    private fun hosts() = ArtifactsLiveHosts(findFiles = { null }, findContext = { null })

    @Test fun ephemeralUsesTheBoundPortAndKeepSavesItBeforeSessionRulesTakeOver() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val states = MutableStateFlow(emptyMap<UUID, PortForwardingState>())
        val lease = Lease()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { lease })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, states) { true }
        val rules = Rules()
        val forwarder = ArtifactPageForwarder(hosts(), rules)
        try {
            assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:45555/app?q=1#view", "dev app", true), forwarder.load(tab(id)))
            assertTrue(forwarder.canKeep("tab"))
            forwarder.keep(tab(id))
            assertFalse(lease.isOpen.value)
            val kept = rules.value.value.single()
            assertEquals(45_555, kept.bind.port)
            assertTrue(kept.enabled && kept.autoStart)
            assertEquals("dev app", kept.label)
            assertFalse(forwarder.canKeep("tab"))
        } finally { forwarder.close("tab"); registration.close(); provider.close() }
    }

    @Test fun sessionEndReleasesTheTemporaryLeaseAndMoshWithoutACarrierDoesNotAcquire() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        var live = true
        var acquired = 0
        val lease = Lease()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { live }, { acquired += 1; lease })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, MutableStateFlow(emptyMap())) { true }
        val forwarder = ArtifactPageForwarder(hosts(), Rules())
        try {
            assertTrue(forwarder.load(tab(id)) is ArtifactContent.ForwardedPage)
            live = false
            assertEquals(setOf("tab"), forwarder.sweep())
            assertFalse(lease.isOpen.value)
            assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding), forwarder.load(tab(id)))
            assertEquals(1, acquired)
        } finally { forwarder.close("tab"); registration.close(); provider.close() }
    }

    @Test fun reuseUsesTheRunningRulesActualLocalEndpoint() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 8080), target = PortForwardEndpoint("127.0.0.1", 5173), label = "saved")
        val states = MutableStateFlow(mapOf(rule.id to PortForwardingState(rule, PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 8081)))))
        val registration = ArtifactLiveForwardingRegistry.register(id, session, states) { true }
        val forwarder = ArtifactPageForwarder(hosts(), Rules(listOf(rule)))
        try {
            assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:8081/app?q=1#view", "saved", false), forwarder.load(tab(id)))
        } finally { registration.close() }
    }

    private fun shared(host: String, id: String, scheme: String = "http", port: Int = 5173, path: String = "/") =
        tab(host).copy(id = id, target = SharedArtifactsTarget.Page(scheme, port, path))

    @Test fun tabsOnOnePortShareOneTemporaryForwardUntilTheLastCloses() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val leases = mutableListOf<Lease>()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { Lease().also { leases += it } })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, MutableStateFlow(emptyMap())) { true }
        val forwarder = ArtifactPageForwarder(hosts(), Rules())
        try {
            assertEquals("http://127.0.0.1:45555/", (forwarder.load(shared(id, "a")) as ArtifactContent.ForwardedPage).url)
            // The scheme only changes the URL; the port's forward is the same.
            assertEquals("https://127.0.0.1:45555/laptop.html",
                (forwarder.load(shared(id, "b", "https", path = "/laptop.html")) as ArtifactContent.ForwardedPage).url)
            assertEquals(1, leases.size)
            assertEquals(setOf("a", "b"), forwarder.sharingTabs("a"))
            assertTrue(forwarder.canKeep("b"))
            forwarder.close("a")
            assertTrue(leases.single().isOpen.value)
            assertEquals(setOf("b"), forwarder.sharingTabs("b"))
            assertTrue(forwarder.sharingTabs("a").isEmpty())
            forwarder.close("b")
            assertFalse(leases.single().isOpen.value)
            // A later tab on the port starts a fresh forward.
            forwarder.load(shared(id, "c"))
            assertEquals(2, leases.size)
        } finally { forwarder.close("c"); registration.close(); provider.close() }
    }

    @Test fun keepingASharedForwardHandsEverySharingTabToTheSavedRule() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val lease = Lease()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { lease })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, MutableStateFlow(emptyMap())) { true }
        val rules = Rules()
        val forwarder = ArtifactPageForwarder(hosts(), rules)
        try {
            forwarder.load(shared(id, "a"))
            forwarder.load(shared(id, "b", path = "/laptop.html"))
            assertEquals(setOf("a", "b"), forwarder.keep(shared(id, "a")))
            assertFalse(lease.isOpen.value)
            assertEquals(1, rules.value.value.size)
            assertFalse(forwarder.canKeep("a"))
            assertFalse(forwarder.canKeep("b"))
            assertTrue(forwarder.sharingTabs("b").isEmpty())
            assertTrue("nothing left to keep", forwarder.keep(shared(id, "b")).isEmpty())
        } finally { forwarder.close("a"); forwarder.close("b"); registration.close(); provider.close() }
    }

    @Test fun aSessionEndSweepsEveryTabSharingItsForward() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        var live = true
        val lease = Lease()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { live }, { lease })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, MutableStateFlow(emptyMap())) { true }
        val forwarder = ArtifactPageForwarder(hosts(), Rules())
        try {
            forwarder.load(shared(id, "a"))
            forwarder.load(shared(id, "b", path = "/laptop.html"))
            live = false
            assertEquals(setOf("a", "b"), forwarder.sweep())
            assertFalse(lease.isOpen.value)
            assertTrue(forwarder.sweep().isEmpty())
        } finally { forwarder.close("a"); forwarder.close("b"); registration.close(); provider.close() }
    }

    @Test fun aTabMovingToAnotherPortLetsGoOfItsShareOfTheOldForward() = runBlocking {
        val id = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val leases = mutableListOf<Lease>()
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { Lease().also { leases += it } })
        val registration = ArtifactLiveForwardingRegistry.register(id, session, MutableStateFlow(emptyMap())) { true }
        val forwarder = ArtifactPageForwarder(hosts(), Rules())
        try {
            forwarder.load(shared(id, "a"))
            forwarder.load(shared(id, "b"))
            forwarder.load(shared(id, "a", port = 3000))
            assertEquals(2, leases.size)
            assertEquals(setOf("b"), forwarder.sharingTabs("b"))
            assertTrue(leases[0].isOpen.value)
            forwarder.close("b")
            assertFalse(leases[0].isOpen.value)
            assertTrue(leases[1].isOpen.value)
        } finally { forwarder.close("a"); forwarder.close("b"); registration.close(); provider.close() }
    }
}
