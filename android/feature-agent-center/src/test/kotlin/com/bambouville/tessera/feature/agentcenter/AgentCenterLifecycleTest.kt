package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/** Production presenter, coordinator and host JNI Core; no Android storage or host connections. */
class AgentCenterLifecycleTest {
    @Test fun paneProvidersRequireMatchingSnapshotCurrentRegistrationAndEnabledCenter() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val rig = Rig(transport)
            try {
                rig.endpoint.live("%75", 7, "claude")
                rig.frame("A", 7)
                val key = rig.endpoint.key
                val expected = mapOf(key to mapOf(75 to "claude"))
                withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it == expected } }
                val owners = rig.owners().toMap()
                val details = rig.presenter.state.value.projectedDetails
                assertEquals(expected, rig.providers(details, owners))
                assertTrue(rig.providers(details, owners, enabled = false).isEmpty())
                assertTrue(rig.providers(emptyMap(), owners).isEmpty())
                assertTrue(rig.providers(details, emptyMap()).isEmpty())
                val threadKey = rig.endpoint.threadKey("A")
                val owner = owners.getValue(threadKey)
                val stale = JSONObject(owner.coreBindingJSON).put("agentPID", 999).toString()
                assertTrue(rig.providers(details, mapOf(threadKey to owner.copy(coreBindingJSON = stale))).isEmpty())
                val wrongGeneration = owner.copy(endpointKey = key.copy(carrierGeneration = 2))
                assertTrue(rig.providers(details, mapOf(threadKey to wrongGeneration)).isEmpty())
                // The same key and route on a replacement endpoint is a different registration.
                val replacement = object : AgentSessionEndpoint by rig.endpoint {}
                assertTrue(rig.providers(details, mapOf(threadKey to owner.copy(endpoint = replacement))).isEmpty())
                rig.onPresenter { it.setEnabled(false) }
                assertTrue(rig.presenter.paneAgentProviders.value.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun paneProvidersSuppressDifferentProvidersButKeepSameProviderThreadsAndExactSessionKeys() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it.isNotEmpty() } }
            val key = rig.endpoint.threadKey("A")
            val detail = rig.presenter.state.value.projectedDetails.getValue(key)
            val owner = rig.owner("A")!!
            val sameOwners = linkedMapOf(key to owner, "same" to owner)
            val sameDetails = linkedMapOf(key to detail, "same" to detail)
            assertEquals(mapOf(rig.endpoint.key to mapOf(75 to "claude")), rig.providers(sameDetails, sameOwners))
            val codexID = JSONObject(owner.threadID).put("providerID", JSONObject().put("rawValue", "codex"))
            val ambiguousOwners = sameOwners + ("codex" to owner.copy(threadID = codexID.toString())) + ("last" to owner)
            val ambiguousDetails = sameDetails + ("codex" to detail.copy(row = detail.row.copy(providerID = "codex"))) + ("last" to detail)
            assertTrue(rig.providers(ambiguousDetails, ambiguousOwners).isEmpty())
            // A pane on another live session/carrier cannot consume this entry.
            val providers = rig.providers(sameDetails, sameOwners)
            assertNull(providers[rig.endpoint.key.copy(liveSessionID = "another-session")])
            assertNull(providers[rig.endpoint.key.copy(carrierGeneration = 2)])
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            withTimeout(8_000) { rig.presenter.paneAgentProviders.first { it.isEmpty() } }
            assertTrue(rig.presenter.paneAgentProviders.value.isEmpty())
        } finally { rig.close() }
    }

    @Test fun refusedEndAndBlankExitRetireOnlyTheAbsentFieldOwner() = runBlocking {
        val rig = Rig()
        try {
            val endpoint = rig.endpoint
            endpoint.live("%75", 95076, "claude")
            rig.frame("A", 95076)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("A") }
            endpoint.live("%75", 2, "claude")
            endpoint.occupancy = AgentEndpointResult.Failed("pending-field-observation")
            rig.forgetProofMemo()
            rig.frame("A", 95076, event = "SessionEnd")
            rig.frame("", null, event = "WrapperExit")
            rig.frame("B", 2)
            rig.await { it.threads.map { row -> row.providerSessionID }.toSet() == setOf("A", "B") }
            endpoint.occupancy = null
            rig.sweep()
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") }
            assertNull(rig.owner("A"))
            assertFalse(rig.sources().containsKey(endpoint.threadKey("A")))
            assertNotNull(rig.owner("B"))
            val refusals = rig.logs.filter { it.first == "agent_lifecycle_refused" }.map { it.second["detail"].orEmpty() }
            assertTrue("$refusals", refusals.any { "proof_exit_1" in it })
            assertTrue("$refusals", refusals.any { "blank-session-id" in it })
            assertEquals(1, rig.logs.count { it.first == "agent_route_retired" && it.second["pid"] == "95076" })
            assertTrue(rig.logs.filter { it.first == "agent_route_retired" }.all { entry -> entry.second.values.none { '@' in it } })
        } finally { rig.close() }
    }

    @Test fun incompleteOrUnavailableOccupancyKeepsOwnersUntilACompletePaneList() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val owner = rig.owner("A")!!
            for (observation in listOf<AgentEndpointResult<AgentOccupancySnapshot>>(
                AgentEndpointResult.Success(AgentOccupancySnapshot(listOf(AgentOccupancyPane("%75", true, false, emptyList())))),
                AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList())),
                AgentEndpointResult.Failed("timeout"))) {
                rig.endpoint.occupancy = observation
                rig.sweep(); rig.drain()
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
            }
            rig.endpoint.occupancy = AgentEndpointResult.Success(AgentOccupancySnapshot(emptyList(), allPaneIDs = emptyList()))
            rig.sweep()
            rig.await { it.threads.isEmpty() && it.selectedThreadKey == null }
            assertNull(rig.owner("A"))
        } finally { rig.close() }
    }

    @Test fun rawOccupancyRetiresTheMissingProviderWithoutATmuxPane() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val rig = Rig(transport)
            try {
                rig.endpoint.live(null, 7, "claude")
                rig.frame("A", 7, pane = null)
                rig.await { it.threads.size == 1 }
                rig.endpoint.live(null, 7, "codex")
                rig.sweep()
                rig.await { it.threads.isEmpty() }
                assertNull(rig.owner("A"))
            } finally { rig.close() }
        }
    }

    @Test fun occupancyReadBeforeANewOwnerIsInstalledCannotRetireThatOwner(): Unit = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.endpoint.occupancyGate = entered to release
            val reading = async { rig.sweep() }
            withTimeout(8_000) { entered.await() }
            rig.endpoint.live("%75", 8, "claude")
            rig.frame("B", 8)
            rig.await { it.threads.map { row -> row.providerSessionID }.toSet() == setOf("A", "B") }
            release.complete(Unit)
            assertNull(reading.await())
            assertNotNull(rig.owner("B"))
            rig.sweep()
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") }
        } finally { rig.close() }
    }

    @Test fun provedBlankCodexRootRetiresItsRootAndChildAndSelection() = runBlocking {
        val rig = Rig(provider = "codex")
        try {
            rig.endpoint.live("%75", 7, "codex")
            rig.frame("root", 7)
            rig.await { it.threads.size == 1 }
            rig.frame("child", 7, event = "PermissionRequest", child = "worker")
            rig.await { it.threads.size == 2 }
            rig.onPresenter { it.select(rig.endpoint.threadKey("root")) }
            rig.frame("", 7)
            rig.await { it.threads.isEmpty() && it.selectedThreadKey == null && it.detail == null }
            assertNull(rig.owner("root")); assertNull(rig.owner("child"))
            assertTrue(rig.sources().isEmpty())
        } finally { rig.close() }
    }

    @Test fun blankClaudeAndUnprovedCodexDoNotClearLiveOwners() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                rig.frame("root", 7)
                rig.await { it.threads.size == 1 }
                val owner = rig.owner("root")!!
                rig.frame("", if (provider == "claude") 7 else null)
                rig.drain()
                assertEquals(owner.bindingToken, rig.owner("root")?.bindingToken)
                assertEquals(listOf("root"), rig.presenter.state.value.threads.map { it.providerSessionID })
            } finally { rig.close() }
        }
    }

    @Test fun unlocatableSuccessorRetiresThePredecessorWithoutCreatingARow() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                rig.frame("A", 7)
                rig.await { it.threads.size == 1 }
                rig.onPresenter { it.select(rig.endpoint.threadKey("A")) }
                rig.frame("B", 7, locatable = false)
                rig.await { it.threads.isEmpty() && it.selectedThreadKey == null }
                assertNull(rig.owner("A")); assertNull(rig.owner("B"))
                assertTrue(rig.logs.any { it.first == "agent_conversation_cleared" && it.second["detail"].orEmpty().contains("successor=unlocatable") })
                assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("v9-no-transcript") })
            } finally { rig.close() }
        }
    }

    @Test fun lateOrSameConversationWithoutALocatorKeepsTheHeldRoot() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                rig.endpoint.live("%75", 7, provider)
                val started = System.nanoTime()
                rig.frame("A", 7, timestampNs = started)
                rig.await { it.threads.size == 1 }
                val owner = rig.owner("A")!!
                // The same conversation briefly without a locator is not a successor.
                rig.frame("A", 7, event = "UserPromptSubmit", locatable = false)
                // A replayed frame older than A's tenure cannot end it: the clear
                // carries its source timestamp and Core spares newer tenures.
                rig.frame("B", 7, locatable = false, timestampNs = started - 1_000_000)
                rig.drain()
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
                // Another process in the pane is not this root's successor.
                rig.frame("C", 8, locatable = false)
                rig.drain()
                assertEquals(listOf("A"), rig.presenter.state.value.threads.map { it.providerSessionID })
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
            } finally { rig.close() }
        }
    }

    @Test fun delayedRetirementOfAnOlderProofKeepsTheNewOwnerAndSource() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val old = rig.owner("A")!!
            rig.holdRetirements = true
            rig.endpoint.capabilities.value = AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true)
            rig.forgetProofMemo()
            rig.frame("A", 7)
            rig.await { it.threads.singleOrNull()?.providerSessionID == "A" && rig.owner("A")?.bindingToken != old.bindingToken }
            val newer = rig.owner("A")!!
            assertTrue(rig.heldRetirements.any { it.retirements.any { retired -> retired.bindingToken == old.bindingToken } })
            rig.releaseRetirements()
            assertEquals(newer.bindingToken, rig.owner("A")?.bindingToken)
            assertEquals(newer.endpointKey, rig.owner("A")?.endpointKey)
            assertTrue(rig.sources().containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun blankKimiWithoutConformanceStillTriggersAnOccupancySweep() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.endpoint.live("%75", null, "claude")
            rig.frame("", 7, providerOverride = "kimi")
            rig.await { it.threads.isEmpty() }
            assertNull(rig.owner("A"))
            assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("blank-session-id") })
        } finally { rig.close() }
    }

    @Test fun capabilityChangeRetiresThePreviousConversationAndFollowsItsSuccessor() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.onPresenter { it.select(rig.endpoint.threadKey("A")) }
            rig.endpoint.capabilities.value = AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true)
            rig.frame("B", 7)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") && it.selectedThreadKey == rig.endpoint.threadKey("B") }
            assertNull(rig.owner("A"))
            assertFalse(rig.sources().containsKey(rig.endpoint.threadKey("A")))
            assertFalse(rig.presenter.state.value.projectedDetails.containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun resumeKeepsALivePaneOwnerAndTransfersAfterItsProcessDisappears() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.live("%76", 8, "claude")
            rig.frame("B", 7)
            rig.await { it.threads.size == 1 }
            val old = rig.owner("B")!!
            rig.frame("B", 8, pane = "%76")
            rig.drain()
            assertEquals(old.bindingToken, rig.owner("B")?.bindingToken)
            assertEquals("%75", rig.owner("B")?.endpointBinding?.paneID)
            assertNull(rig.presenter.state.value.notice)
            assertTrue(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("bind_liveElsewhere") })
            rig.endpoint.live("%75", null, "claude")
            rig.frame("B", 8, pane = "%76")
            rig.await { it.threads.singleOrNull()?.providerSessionID == "B" && rig.owner("B")?.endpointBinding?.paneID == "%76" }
            assertNotEquals(old.bindingToken, rig.owner("B")?.bindingToken)
        } finally { rig.close() }
    }

    // O2: lifecycle recovery is independent of selection and of the old retry budget.
    @Test(timeout = 40_000) fun sameSourceLifecycleRenewsPendingAndExhaustedFirstReadBudgets() = runBlocking {
        for (exhausted in listOf(false, true)) {
            val rig = Rig(nativeReads = true)
            try {
                val key = rig.endpoint.threadKey("A")
                rig.endpoint.live("%75", 7, "claude")
                rig.endpoint.missingSources.add("A")
                // Neutral child hooks do not advance Core's summary sequence.
                // Acceptance must still correlate to their exact source.
                rig.frame("A", 7, event = if (exhausted) "SubagentStart" else "SessionStart")
                // The failed read can land before the snapshot publishes its detail.
                val failed = rig.await { it.ingestionReadStatuses[key]?.code == "sourceMissing" && it.projectedDetails[key] != null }
                val detail = requireNotNull(failed.projectedDetails[key])
                assertNull(agentVisibleReadStatus(failed.ingestionReadStatuses[key], transcriptShown = false,
                    hasLiveBinding = (detail.binding?.number("agentPID")?.toIntOrNull() ?: -1) > 1,
                    hasTranscriptMessages = detail.hasTranscriptMessages))
                if (exhausted) withTimeout(22_000) {
                    while (rig.endpoint.resolves.count { it == "A" } < 6 || rig.retryJobs().containsKey(key)) delay(20)
                }
                val owner = requireNotNull(rig.owner("A"))
                val reads = rig.endpoint.resolves.count { it == "A" }
                rig.frame("A", 7, event = if (exhausted) "SubagentStop" else "UserPromptSubmit")
                // Leave the source missing for the renewed immediate read, so
                // success subsequently requires a freshly armed bounded ladder.
                withTimeout(4_000) { while (rig.endpoint.resolves.count { it == "A" } <= reads ||
                    !rig.retryJobs().containsKey(key)) delay(10) }
                assertEquals(owner.bindingToken, rig.owner("A")?.bindingToken)
                rig.endpoint.missingSources.remove("A")
                rig.await { it.projectedDetails[key]?.live?.isNotEmpty() == true && it.ingestionReadStatuses[key] == null }
                assertEquals(reads + 2, rig.endpoint.resolves.count { it == "A" })
            } finally { rig.close() }
        }
    }

    @Test fun sameSourceLifecyclePreservesOtherManualFirstReadFailures() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            val key = rig.endpoint.threadKey("A")
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.resolveFailureCodes["A"] = "sourceNotAuthorized"
            rig.frame("A", 7)
            val failed = rig.await { it.ingestionReadStatuses[key]?.code == "sourceNotAuthorized" }
            val status = failed.ingestionReadStatuses[key]
            rig.endpoint.resolveFailureCodes.remove("A")
            rig.frame("A", 7, event = "UserPromptSubmit")
            rig.drain()
            assertEquals(status, rig.presenter.state.value.ingestionReadStatuses[key])
            assertEquals(1, rig.endpoint.resolves.count { it == "A" })
            assertFalse(rig.retryJobs().containsKey(key))
        } finally { rig.close() }
    }

    @Test fun sourceMissingFirstReadRecoversWhileAnotherThreadIsSelected() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.live("%76", 8, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.frame("C", 8, pane = "%76")
            rig.onPresenter { it.select(rig.endpoint.threadKey("C")) }
            rig.await { it.detail?.row?.providerSessionID == "C" && it.detail?.live?.isNotEmpty() == true }
            rig.endpoint.missingSources.remove("A")
            // The page lands before the bootstrap read returns and clears its status.
            rig.await { it.projectedDetails[rig.endpoint.threadKey("A")]?.live?.isNotEmpty() == true &&
                it.ingestionReadStatuses[rig.endpoint.threadKey("A")] == null }
            assertTrue(rig.endpoint.resolves.count { it == "A" } >= 2)
            assertEquals(rig.endpoint.threadKey("C"), rig.presenter.state.value.selectedThreadKey)
            assertNull(rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")])
        } finally { rig.close() }
    }

    @Test fun movingTheSamePaneToAnotherWindowRefreshesItsOwner() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            val before = rig.owner("A")!!
            rig.endpoint.binding.value = rig.endpoint.binding.value.copy(windowID = "@2")
            rig.frame("A", 7)
            rig.await { it.threads.singleOrNull()?.providerSessionID == "A" && rig.owner("A")?.endpointBinding?.windowID == "@2" }
            assertNotEquals(before.bindingToken, rig.owner("A")?.bindingToken)
            assertFalse(rig.logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("bind_liveElsewhere") })
        } finally { rig.close() }
    }

    @Test fun ownerRetirementCancelsFirstReadRecovery() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.frame("B", 7)
            rig.await { it.threads.map { row -> row.providerSessionID } == listOf("B") && rig.owner("A") == null }
            val reads = rig.endpoint.resolves.count { it == "A" }
            delay(800)
            assertEquals(reads, rig.endpoint.resolves.count { it == "A" })
            assertFalse(rig.retryJobs().containsKey(rig.endpoint.threadKey("A")))
        } finally { rig.close() }
    }

    @Test fun sourceMissingOnTheFirstPageRecoversAfterResolveSucceeded() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingPages.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            rig.endpoint.missingPages.remove("A")
            rig.await { it.projectedDetails[rig.endpoint.threadKey("A")]?.live?.isNotEmpty() == true &&
                it.ingestionReadStatuses[rig.endpoint.threadKey("A")] == null }
            assertEquals(listOf("A"), rig.endpoint.resolves.toList())
            assertTrue(rig.endpoint.pageReads.count { it == "A" } >= 2)
            assertNull(rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")])
        } finally { rig.close() }
    }

    @Test fun acceptedEndSchedulesOccupancyAfterTheProcessExits() = runBlocking {
        val rig = Rig()
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.frame("A", 7)
            rig.await { it.threads.size == 1 }
            rig.frame("A", 7, event = "SessionEnd")
            withTimeout(8_000) { while (rig.events.none { event ->
                event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.obj("thread")?.bool("conversationEnded") == true
            }) delay(10) }
            rig.endpoint.live("%75", null, "claude")
            rig.await { it.threads.isEmpty() }
            assertNull(rig.owner("A"))
        } finally { rig.close() }
    }

    @Test(timeout = 30_000) fun missingFirstReadExhaustsItsBudgetAndKeepsManualRetryStatus() = runBlocking {
        val rig = Rig(nativeReads = true)
        try {
            rig.endpoint.live("%75", 7, "claude")
            rig.endpoint.missingSources.add("A")
            rig.frame("A", 7)
            rig.await { it.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.code == "sourceMissing" }
            withTimeout(22_000) { while (rig.endpoint.resolves.count { it == "A" } < 6 || rig.retryJobs().isNotEmpty()) delay(20) }
            assertEquals(6, rig.endpoint.resolves.count { it == "A" })
            assertEquals("manual", rig.presenter.state.value.ingestionReadStatuses[rig.endpoint.threadKey("A")]?.recovery)
            delay(600)
            assertEquals(6, rig.endpoint.resolves.count { it == "A" })
        } finally { rig.close() }
    }

    private class Rig(transport: AgentEndpointTransport = AgentEndpointTransport.SSH_TMUX,
        provider: String = "claude", nativeReads: Boolean = false) {
        private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val registry = LiveAgentSessionRegistry()
        private val coordinator = AndroidAgentSessionCoordinator(registry)
        private val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val endpoint = Endpoint(transport, provider, nativeReads)
        private val registrations = mutableListOf(registry.register(endpoint))
        val logs = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
        val events = CopyOnWriteArrayList<SharedAgentRuntimeEvent>()
        val presenter = AgentCenterPresenter(coordinator, metadata(), unusedPreferences(), scope, integration,
            diagnostics = { event, fields -> logs.add(event to fields) })
        private val runtime = coordinator.runtime()
        @Volatile var holdRetirements = false
        val heldRetirements = CopyOnWriteArrayList<SharedAgentRuntimeEvent.RoutesRetired>()
        init {
            field("runtime").set(presenter, runtime)
            field("enabled").setBoolean(presenter, true)
            scope.launch { runtime.events.collect { event ->
                events.add(event)
                if (holdRetirements && event is SharedAgentRuntimeEvent.RoutesRetired) heldRetirements.add(event)
                else presenter.consume(event)
            } }
        }
        suspend fun frame(session: String, pid: Int?, event: String = "SessionStart", pane: String? = this.endpoint.binding.value.paneID,
            child: String? = null, endpoint: Endpoint = this.endpoint, providerOverride: String? = null,
            locatable: Boolean = true, timestampNs: Long = System.nanoTime()) = withContext(dispatcher) {
            val source = "/fixture/$session"
            val transcriptRef = Base64.getUrlEncoder().withoutPadding().encodeToString(source.encodeToByteArray())
            endpoint.sources[transcriptRef] = session
            presenter.consumeLifecycle(endpoint, AgentLifecycleFrame(endpoint.binding.value.copy(paneID = pane), JSONObject()
                .put("version", 9).put("provider", providerOverride ?: endpoint.provider).put("event", event)
                .put("state", when (event) {
                    "PermissionRequest" -> "waitingForInput"
                    "SessionEnd", "WrapperExit", "StopFailure" -> "unavailable"
                    "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop" -> "working"
                    else -> "idle"
                })
                .put("timestampNs", "$timestampNs").put("sessionId", session).putOpt("agentPid", pid).putOpt("agentId", child)
                .put("transcriptRef", if (locatable) transcriptRef else "")
                .toString().encodeToByteArray()))
            Unit
        }
        suspend fun onPresenter(action: (AgentCenterPresenter) -> Unit) = withContext(dispatcher) { action(presenter) }
        suspend fun sweep() = withContext(dispatcher) { presenter.reconcileEndpointOccupancy(endpoint) }
        suspend fun drain() {
            withContext(dispatcher) { runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "filter")
                .put("grouping", "host").toString().encodeToByteArray()) }
            delay(100)
        }
        suspend fun await(predicate: (AgentCenterUiState) -> Boolean): AgentCenterUiState =
            withTimeoutOrNull(8_000) { presenter.state.first(predicate) }
                ?: throw AssertionError("timed out; state=${presenter.state.value.threads.map { it.providerSessionID }} " +
                    "statuses=${presenter.state.value.ingestionReadStatuses} resolves=${endpoint.resolves} logs=${logs.takeLast(30)}")
        fun providers(
            details: Map<String, AgentThreadDetail>,
            owners: Map<String, AgentCenterPresenter.ThreadOwner>,
            enabled: Boolean = true,
        ) = derivePaneAgentProviders(enabled, details, owners, coordinator.directory)
        fun owner(session: String): AgentCenterPresenter.ThreadOwner? = owners()[endpoint.threadKey(session)]
        @Suppress("UNCHECKED_CAST") fun owners() = field("threadOwners").get(presenter) as Map<String, AgentCenterPresenter.ThreadOwner>
        @Suppress("UNCHECKED_CAST") fun sources() = field("projectionSources").get(presenter) as Map<String, *>
        @Suppress("UNCHECKED_CAST") fun retryJobs() = field("firstProjectionRetryJobs").get(presenter) as Map<String, Job>
        fun forgetProofMemo() {
            val memo = coordinator.javaClass.getDeclaredField("issuedRoutes").also { it.isAccessible = true }.get(coordinator)
            memo.javaClass.getDeclaredMethod("clear").also { it.isAccessible = true }.invoke(memo)
        }
        suspend fun releaseRetirements() = withContext(dispatcher) {
            holdRetirements = false
            heldRetirements.toList().forEach { presenter.consume(it) }; heldRetirements.clear()
        }
        suspend fun close() {
            withContext(NonCancellable + dispatcher) { presenter.close(); integration.close(); coordinator.close() }
            registrations.forEach { it.close() }; endpoint.close(); scope.cancel(); dispatcher.close()
        }
        private fun field(name: String) = AgentCenterPresenter::class.java.getDeclaredField(name).also { it.isAccessible = true }
    }

    private class Endpoint(transport: AgentEndpointTransport, val provider: String, private val nativeReads: Boolean = false,
        host: String = UUID.randomUUID().toString()) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        private val tmux = transport.name.endsWith("TMUX")
        override val binding = MutableStateFlow(AgentEndpointBinding(key, host, transport,
            tmuxSession = if (tmux) "fixture" else null, windowID = if (tmux) "@1" else null, paneID = if (tmux) "%75" else null))
        override val ingestionBinding get() = binding.value.copy(windowID = null, paneID = null)
        override fun isCurrentIngestion(candidate: AgentEndpointBinding) = candidate.sameRouteAs(ingestionBinding)
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = candidate.copy(windowID = null, paneID = null).sameRouteAs(ingestionBinding)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true,
            freshTerminalObservation = true, verifiedInput = true, semanticKeys = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()
        private val processes = java.util.concurrent.ConcurrentHashMap<String, List<AgentOccupancyProcess>>()
        @Volatile var occupancy: AgentEndpointResult<AgentOccupancySnapshot>? = null
        @Volatile var occupancyGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        val sources = java.util.concurrent.ConcurrentHashMap<String, String>()
        val missingSources = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val resolveFailureCodes = java.util.concurrent.ConcurrentHashMap<String, String>()
        val missingPages = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val resolves = CopyOnWriteArrayList<String>()
        val pageReads = CopyOnWriteArrayList<String>()
        private val streams = CopyOnWriteArrayList<HostStream>()
        fun live(pane: String?, pid: Int?, provider: String) { processes[pane ?: "raw"] = pid?.let {
            listOf(AgentOccupancyProcess(it, AgentProofProvider.fromWire(provider)!!)) } ?: emptyList() }
        fun threadKey(session: String) = canonicalAgentThreadKey(binding.value.hostID, provider, session)
        override suspend fun observeOccupancy(bindings: List<AgentEndpointBinding>): AgentEndpointResult<AgentOccupancySnapshot> {
            val observed = occupancy ?: AgentEndpointResult.Success(AgentOccupancySnapshot(bindings.map { route ->
                AgentOccupancyPane(route.paneID, true, true, processes[route.paneID ?: "raw"].orEmpty())
            }, processes.keys.toList().takeIf { tmux }))
            occupancyGate?.let { (entered, release) ->
                occupancyGate = null; entered.complete(Unit); release.await()
            }
            return observed
        }
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> =
            if (processes[binding.paneID ?: "raw"].orEmpty().any { it.pid == claimedPID && it.provider == provider })
                AgentEndpointResult.Success(AgentProcessProof(setOf(claimedPID), provider, "fixture-$claimedPID"))
            else AgentEndpointResult.Failed("proof_exit_1")
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> =
            if (nativeReads) AgentEndpointResult.Success(HostStream().also(streams::add)) else unavailable()
        private inner class HostStream : AgentRemoteExecStream {
            private val frames = Channel<ByteArray>(Channel.UNLIMITED)
            private fun emit(value: JSONObject) { frames.trySend(AgentIngestionConnection.frame(value)) }
            private fun envelope(kind: String, id: String, handle: String = "") = JSONObject().put("kind", kind).put("id", id)
                .put("serviceEpoch", "lifecycle_epoch").put("thread", handle)
            init { emit(envelope("hello", "hello").put("v", 3).put("contextScope", "0000000000000001")
                .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions", "read.progress.v1")))) }
            override val stdout = frames.receiveAsFlow()
            override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
            override suspend fun awaitExit(): AgentExecExitStatus { awaitCancellation() }
            override suspend fun send(bytes: ByteArray) {
                val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
                val id = request.getString("id")
                val handle = request.optString("thread")
                when (request.getString("kind")) {
                    "resolve" -> {
                        val session = sources[request.getString("transcriptRef")]!!
                        resolves.add(session)
                        val failureCode = resolveFailureCodes[session] ?: "sourceMissing".takeIf { session in missingSources }
                        if (failureCode != null) emit(envelope("error", id).put("code", failureCode).put("status", JSONObject()
                            .put("v", 1).put("state", "failed").put("domain", "source").put("recovery", "manual").put("code", failureCode)))
                        else emit(envelope("resolved", id, "handle_$session").put("provider", provider).put("sessionID", session))
                    }
                    "inventory" -> { emit(envelope("inventory.begin", id)); emit(envelope("inventory.end", id).put("hasMore", false)) }
                    "window.read" -> {
                        val session = handle.removePrefix("handle_")
                        pageReads.add(session)
                        if (session in missingPages) {
                            emit(envelope("error", id, handle).put("code", "sourceMissing").put("status", JSONObject()
                                .put("v", 1).put("state", "failed").put("domain", "source").put("recovery", "manual").put("code", "sourceMissing")))
                            return
                        }
                        emit(envelope("page.begin", id, handle).put("sourceIdentity", "jsonl:$handle").put("operation", "bootstrap"))
                        emit(envelope("page.record", id, handle).put("recordID", "record_$handle").put("revision", 1).put("order", 1)
                            .put("record", JSONObject().put("type", "message").put("role", "assistant").put("blocks", JSONArray()
                                .put(JSONObject().put("type", "text").put("text", "Ready $handle")))))
                        emit(envelope("page.end", id, handle).put("records", 1).put("hasOlder", false).put("hasNewer", false)
                            .put("liveCursor", "live_$handle").put("sourceEnd", 100).put("backend", "jsonl").put("window", JSONObject()
                                .put("lane", "bootstrap").put("version", request.optLong("windowVersion") + 1).put("segmentID", "segment_$id")
                                .put("before", "before_$handle").put("after", "after_$handle").put("hasOlder", false).put("hasNewer", false)))
                    }
                    "window.ack" -> emit(envelope("window.acked", id, handle))
                    "summary" -> emit(envelope("summary", id, handle).put("revision", "1").put("modified", 1).put("records", JSONArray()))
                    "subscribe" -> emit(envelope("subscribed", id, handle))
                    else -> emit(envelope("ack", id, handle))
                }
            }
            override fun cancel() { frames.close() }
            override fun close() = cancel()
        }
        override fun close() { streams.forEach { it.close() } }
        private fun unavailable() = AgentEndpointResult.Unavailable("synthetic lifecycle fixture")
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> = unavailable()
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> = unavailable()
        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> = unavailable()
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
    }

    private companion object {
        fun metadata(): AndroidAgentMetadataRepository {
            val dao = Class.forName("com.bambouville.tessera.data.AgentMetadataDao")
            val empty = Proxy.newProxyInstance(dao.classLoader, arrayOf(dao)) { _, method, _ ->
                when (method.name) { "threads", "repairThreadKeys" -> emptyList<Any>(); "thread" -> null; else -> Unit }
            }
            return AndroidAgentMetadataRepository::class.java.getDeclaredConstructor(dao).also { it.isAccessible = true }
                .newInstance(empty)
        }
        // These tests attach only the runtime; no view-preference method is used.
        fun unusedPreferences(): AndroidAgentCenterViewPreferences {
            val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").also { it.isAccessible = true }.get(null) as Unsafe
            return unsafe.allocateInstance(AndroidAgentCenterViewPreferences::class.java) as AndroidAgentCenterViewPreferences
        }
    }
}
