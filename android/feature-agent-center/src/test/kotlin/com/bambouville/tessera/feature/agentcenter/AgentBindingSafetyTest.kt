package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentBindingSafetyTest {
    @Test fun ingestionDiagnosticsNeverExportExceptionTextOrUnrecognizedServerCodes() {
        assertEquals("sourceMissing", AgentIngestionDiagnostics.code("sourceMissing"))
        // The store's own failure codes ride beside codexTitleUnavailable as its reason.
        for (reason in listOf("opencodeDatabaseUnavailable", "opencodeInvalidSchema", "codexMetadataSchemaUnsupported", "sourceChanged")) {
            assertEquals(reason, AgentIngestionDiagnostics.code(reason))
        }
        for (code in listOf("windowStale", "windowBusy", "windowAckStale", "windowAckConflict", "segmentSourceChanged",
            "windowAnchorExpired", "windowAckExpired", "subscriptionAckExpired", "canonicalReadFailed", "hookOverflow",
            "projectionInactive", "projectionRouteChanged", "projectionOwnerChanged")) {
            assertEquals(code, AgentIngestionDiagnostics.failure(IllegalStateException(code))["code"])
        }
        for (privateValue in listOf("/Users/private/session.jsonl", "api-key-secret", "prompt text", "inventedCode")) {
            val fields = AgentIngestionDiagnostics.failure(IllegalStateException(privateValue))
            assertEquals("unclassified", fields["code"])
            assertFalse(fields.values.any { it.contains(privateValue) })
        }
    }
    @Test fun threadOwnerRetainsStructuredContextSeparatelyFromLookupKey() {
        for (transport in listOf("ssh", "sshTmux", "mosh", "moshTmux")) {
            val binding = JSONObject().put("liveSessionID", "carrier").put("carrierGeneration", 1)
                .put("transport", transport).put("agentPID", 123)
                .put("incarnation", JSONObject().put("rawValue", "proved-incarnation"))
                .put("capabilities", 31)
            val owner = AgentCenterPresenter.ThreadOwner(AgentSessionKey("carrier", 1), "{}",
                binding.toString(), "token")
            assertEquals(binding.tokenKey(), owner.canonicalBinding)
            assertNotEquals(owner.canonicalBinding, owner.coreBindingJSON)
            val context = JSONObject(owner.coreBindingJSON)
            assertEquals(123, context.getInt("agentPID"))
            assertEquals("proved-incarnation", context.getJSONObject("incarnation").getString("rawValue"))
        }
    }

    @Test fun swiftSnapshotResolvesAndroidTokenWithoutWeakeningAuthority() {
        for (transport in listOf("ssh", "sshTmux", "mosh", "moshTmux")) {
            val issued = JSONObject()
                .put("liveSessionID", "20e2b41f-1e9e-49c1-a0e5-b80de7d33a73")
                .put("carrierGeneration", 9)
                .put("incarnation", JSONObject().put("rawValue", "incarnation-A"))
                .put("transport", transport)
                .put("tmuxSession", "CaseSensitive")
                .put("windowID", "@7").put("paneID", "%22")
                .put("agentPID", 123).put("capabilities", 31)
            val snapshot = JSONObject(issued.toString()).put("liveSessionID", issued.getString("liveSessionID").uppercase())
            val tokens = mapOf(issued.tokenKey() to "issued-proof")
            assertEquals("issued-proof", tokens[snapshot.tokenKey()])
            assertTrue(issued.sameCoreBinding(snapshot))
            val hostID = "2c0f0101-1e67-45be-a031-8ebc7c345680"
            val nativeLease = JSONObject().put("threadID", JSONObject().put("hostID", hostID)).put("binding", issued)
            val coreLease = JSONObject().put("threadID", JSONObject().put("hostID", hostID.uppercase())).put("binding", snapshot)
            val nativeRoute = nativeLease.endpointBindingOrNull()!!
            val coreRoute = coreLease.endpointBindingOrNull()!!
            assertEquals(nativeRoute, coreRoute)
            // The registry uses exact AgentSessionKey equality, not JSON text.
            assertEquals(nativeRoute, mapOf(nativeRoute.key to nativeRoute)[coreRoute.key])
            for ((field, replacement) in listOf(
                "liveSessionID" to "other", "carrierGeneration" to 10,
                "incarnation" to JSONObject().put("rawValue", "incarnation-B"),
                "transport" to "other", "tmuxSession" to "casesensitive",
                "windowID" to "@8", "paneID" to "%23", "agentPID" to 124, "capabilities" to 1,
            )) {
                assertNull(tokens[JSONObject(snapshot.toString()).put(field, replacement).tokenKey()])
            }
        }
    }

    @Test fun canonicalizationNeverFoldsOpaqueRouteIdentity() {
        assertNotEquals("Carrier-A".canonicalAgentUUID(), "carrier-a".canonicalAgentUUID())
        assertEquals("not-a-uuid", "not-a-uuid".canonicalAgentUUID())
    }

    @Test fun leaseReconstructionKeepsTheExactTmuxAddress() {
        val lease = JSONObject()
            .put("threadID", JSONObject().put("hostID", "2c0f0101-1e67-45be-a031-8ebc7c345680"))
            .put("binding", JSONObject()
                .put("liveSessionID", "20e2b41f-1e9e-49c1-a0e5-b80de7d33a73")
                .put("carrierGeneration", 9)
                .put("transport", "sshTmux")
                .put("tmuxSession", "main")
                .put("windowID", "@7")
                .put("paneID", "%22"))

        val leased = lease.endpointBindingOrNull()

        assertEquals(
            AgentEndpointBinding(
                AgentSessionKey("20e2b41f-1e9e-49c1-a0e5-b80de7d33a73", 9),
                "2c0f0101-1e67-45be-a031-8ebc7c345680",
                AgentEndpointTransport.SSH_TMUX,
                "main", "@7", "%22",
            ),
            leased,
        )
        assertNotEquals(leased, leased!!.copy(paneID = "%23"))
    }

    @Test fun malformedLeaseCannotResolveARegistryEndpoint() {
        assertNull(JSONObject().put("binding", JSONObject()).endpointBindingOrNull())
    }

    @Test fun allFourTransportLeasesReconstructTheirExactEndpointKinds() {
        val expected = mapOf(
            "ssh" to AgentEndpointTransport.SSH,
            "sshTmux" to AgentEndpointTransport.SSH_TMUX,
            "mosh" to AgentEndpointTransport.MOSH,
            "moshTmux" to AgentEndpointTransport.MOSH_TMUX,
        )
        expected.forEach { (wire, transport) ->
            val lease = JSONObject()
                .put("threadID", JSONObject().put("hostID", "host"))
                .put("binding", JSONObject().put("liveSessionID", "carrier").put("carrierGeneration", 1).put("transport", wire))
            assertEquals(transport, lease.endpointBindingOrNull()?.transport)
        }
    }

    @Test fun unknownTransportCannotResolveARegistryEndpoint() {
        assertNull(JSONObject()
            .put("threadID", JSONObject().put("hostID", "host"))
            .put("binding", JSONObject().put("liveSessionID", "carrier").put("carrierGeneration", 1).put("transport", "other"))
            .endpointBindingOrNull())
    }

    @Test fun allFourTransportBindingsRemainExactForLaunchActionAndFocusRoutes() {
        val mapping = mapOf(
            AgentEndpointTransport.SSH to "ssh",
            AgentEndpointTransport.SSH_TMUX to "sshTmux",
            AgentEndpointTransport.MOSH to "mosh",
            AgentEndpointTransport.MOSH_TMUX to "moshTmux",
        )
        mapping.forEach { (transport, wire) ->
            val tmux = transport == AgentEndpointTransport.SSH_TMUX || transport == AgentEndpointTransport.MOSH_TMUX
            val binding = AgentEndpointBinding(
                AgentSessionKey("carrier", 1), "host", transport,
                tmuxSession = if (tmux) "main" else null,
                windowID = if (tmux) "@1" else null,
                paneID = if (tmux) "%2" else null,
            )
            val request = AgentLaunchRequest(
                kind = AgentLaunchKind.Spawn, task = "x", name = null, providerID = "claude",
                target = AgentLaunchTarget("carrier", 1, "host", wire, "host", binding.tmuxSession, binding.windowID, binding.paneID, listOf("/repo")),
                directory = "/repo", placement = AgentLaunchPlacement.NewWindow, isolation = AgentLaunchIsolation.CurrentWorktree,
            )
            // The same parser backs focus/action-plan reconstruction, while a
            // launch separately compares the exact transport before forwarding.
            assertTrue(request.matchesEndpointBinding(binding))
        }
    }

}
