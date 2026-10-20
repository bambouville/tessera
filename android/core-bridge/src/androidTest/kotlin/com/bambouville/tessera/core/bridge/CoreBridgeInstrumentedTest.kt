package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CoreBridgeInstrumentedTest {
    @Test fun readRecoveryPolicyComesFromPackagedCore() {
        assertEquals(6_000L, SharedAgentReadRecoveryPolicy.processProofTimeoutMilliseconds)
        for (state in listOf("preparing", "verifying", "retryable", "sourceChanged", "unsupported", "resourceLimited", "failed")) {
            val progress = state in setOf("preparing", "verifying")
            val status = checkNotNull(SharedAgentReadStatus.decode(org.json.JSONObject().put("v", 1).put("state", state)
                .put("domain", "source").put("recovery", if (progress) "continue" else "manual").put("code", "readPending")))
            assertEquals(!progress, status.survivesReaderClosure)
        }
    }
    @Test
    fun integrationTimingPolicyComesFromPackagedSwiftCore() {
        assertEquals(30_000L, SharedAgentIntegrationCheckPolicy.freshnessMillis(SharedAgentIntegrationInstallation.Current))
        assertEquals(5_000L, SharedAgentIntegrationCheckPolicy.freshnessMillis(SharedAgentIntegrationInstallation.Missing))
        assertEquals(5_000L, SharedAgentIntegrationCheckPolicy.freshnessMillis(SharedAgentIntegrationInstallation.Outdated))
        assertEquals(listOf(2_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L),
            (0..6).map(SharedAgentIntegrationCheckPolicy::retryDelayMillis))
        assertEquals(30_000L, SharedAgentIntegrationCheckPolicy.retryDelayMillis(Int.MAX_VALUE))
        assertEquals(2_000L, SharedAgentIntegrationCheckPolicy.activityThrottleMillis)
        assertEquals(5_000L, SharedAgentIntegrationCheckPolicy.warningPresentationDelayMillis)
    }

    @Test
    fun loadsPackagedSwiftCoreAndReadsContract() {
        assertEquals(
            CoreBridgeState.Ready(
                CoreRuntimeInfo(
                    abiVersion = CoreBridge.EXPECTED_ABI_VERSION,
                    maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
                ),
            ),
            CoreBridge.inspect(),
        )
    }

    @Test
    fun sharedCommandRoundTripsOrdinaryUtf8IncludingEmoji() {
        val target = "unicode-\uD83E\uDD8A"
        val command = SharedTmuxCommands.controlModeSessionCommand(target)

        assertTrue(command.contains(target))
    }

    @Test
    fun integrationInstallRoundTripsUnicodeProviderConfigurations() {
        val marker = "Crème-東京-\uD83E\uDD8A"
        val command = SharedAgentIntegrationCommands.installCommand(
            codex = AgentIntegrationConfigSnapshot.Present("""{"tesseraUnicode":"$marker"}"""),
            claude = AgentIntegrationConfigSnapshot.Present("""{"tesseraUnicode":"$marker"}"""),
            kimi = AgentIntegrationConfigSnapshot.Present("tessera_unicode = \"$marker\"\n"),
        )

        assertTrue(command.contains(marker))
    }

    @Test
    fun integrationDecisionUsesSharedReducerAndReconcilesFreshAction() {
        val decision = SharedAgentIntegrationDecisions.resolve(
            SharedAgentIntegrationObservation(
                installation = SharedAgentIntegrationInstallation.Missing,
                foreground = SharedAgentIntegrationForeground.Shell,
                shellIntegrationActive = false,
                agentIntegrationActive = false,
            ),
            requestedAction = SharedAgentIntegrationDecisionAction.InstallOnly,
        )

        assertEquals(SharedAgentIntegrationDecisionKind.NotInstalled, decision.kind)
        assertEquals(SharedAgentIntegrationDecisionAction.InstallAndApply, decision.primaryAction)
        assertEquals(SharedAgentIntegrationDecisionAction.InstallAndApply, decision.effectiveAction)
        assertTrue(decision.showsWarning)
    }

    @Test
    fun newerHostIntegrationRequiresAnAppUpdateAndRefusesInstall() {
        val decision = SharedAgentIntegrationDecisions.resolve(
            SharedAgentIntegrationObservation(
                installation = SharedAgentIntegrationInstallation.RequiresAppUpdate,
                foreground = SharedAgentIntegrationForeground.Shell,
                shellIntegrationActive = null,
                agentIntegrationActive = false,
            ),
            requestedAction = SharedAgentIntegrationDecisionAction.InstallOnly,
        )

        assertEquals(SharedAgentIntegrationDecisionKind.AppUpdateRequired, decision.kind)
        assertEquals(null, decision.primaryAction)
        assertEquals(null, decision.secondaryAction)
        assertEquals(null, decision.effectiveAction)
        assertTrue(decision.showsWarning)
    }

    @Test
    fun integrationLifecycleSchemaIsParsedBySharedCore() {
        val event = SharedAgentIntegrationParsing.lifecycleHookEvent(
            """{"version":9,"provider":"kimi","event":"PermissionRequest","state":"waitingForInput","reason":"permission","timestampNs":"184467440","sessionId":"session-1","agentPid":42,"transcriptRef":"session_abc"}"""
                .encodeToByteArray(),
        )

        assertEquals("kimi", event.providerID)
        assertEquals("PermissionRequest", event.event)
        assertEquals("waitingForInput", event.status)
        assertEquals(42, event.agentPID)
    }

    /**
     * Both mosh clients join Tessera's own view of the session, so the option
     * that hides the status line — a tmux *session* option — cannot reach the
     * session the user asked for, or the terminal they have open elsewhere.
     */
    @Test
    fun moshClientsJoinTesseraSViewRatherThanTheUsersSession() {
        assertEquals("main-tessera-view", SharedTmuxCommands.moshViewSessionName("main"))
        assertEquals(
            "tessera-abc12345-view",
            SharedTmuxCommands.moshViewSessionName("tessera-abc12345"),
        )

        val visible = SharedTmuxCommands.moshVisibleClientCommand("main")
        assertTrue(visible.contains("main-tessera-view"))
        assertFalse(visible.contains("-t '\\''main'\\'' status"))

        val control = SharedTmuxCommands.moshControlChannelCommand("main")
        assertTrue(control.contains("attach-session -t 'main-tessera-view'"))
        assertFalse(control.contains("new-session"))
    }

    @Test
    fun sharedCommandRejectsEmbeddedNulBeforeShellEncoding() {
        try {
            SharedTmuxCommands.controlModeSessionCommand("bad\u0000target")
            fail("NUL must not reach a shell command")
        } catch (_: IllegalArgumentException) {
            // The UTF-16 bridge can preserve NUL, but a shell argument cannot.
        }
    }

    /**
     * The scroll route the Termux view asks for is the shared
     * `TerminalScrollRouting` table: the screen decides, and mouse reporting
     * stands in for the alternate screen only when the session says so.
     */
    @Test
    fun sharedScrollRoutingIsTheScreenRuleNotMouseTrackingAlone() {
        assertEquals(SharedScrollRoute.LocalScrollback, SharedScrollRouting.route(false, false, false))
        assertEquals(SharedScrollRoute.LocalScrollback, SharedScrollRouting.route(false, true, false))
        assertEquals(SharedScrollRoute.LocalScrollback, SharedScrollRouting.route(false, false, true))
        assertEquals(SharedScrollRoute.MouseWheel, SharedScrollRouting.route(false, true, true))
        assertEquals(SharedScrollRoute.ArrowKeys, SharedScrollRouting.route(true, false, false))
        assertEquals(SharedScrollRoute.MouseWheel, SharedScrollRouting.route(true, true, false))
        assertEquals(SharedScrollRoute.ArrowKeys, SharedScrollRouting.route(true, false, true))
        assertEquals(SharedScrollRoute.MouseWheel, SharedScrollRouting.route(true, true, true))
    }
}
