package com.bambouville.tessera.forwarding

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.Modifier
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.design.LocalTesseraTokens
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A listening rule's row says whether anything serves behind the tunnel.
 *
 * On a device, so the rows consult the real shared-core `ForwardedWebPolicy`:
 * which rules the manager probes — and so which may say "checking…" — is its
 * answer, not a fixture's. Three rules per case keep every row on screen; the
 * list is lazy, and an off-screen row has no node to assert on.
 *
 * Host-free: nothing here opens an SSH session.
 */
@RunWith(AndroidJUnit4::class)
class PortForwardingServiceStatusInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun aRecoveredAttachmentReplacesTheRuntimeFailureWithAListeningRow() = runBlocking {
        val preview = rule(port = 18_001, target = 8_001).copy(label = "preview")
        val manager = PortForwardingManager()
        try {
            manager.reportTransportUnavailable(listOf(preview), "SSH forwarding runtime is unavailable")
            compose.setContent {
                val states by manager.states.collectAsState()
                TesseraTheme(darkTheme = true) {
                    Surface(modifier = Modifier.fillMaxSize(), color = LocalTesseraTokens.current.bg) {
                        PortForwardingPanel(rules = listOf(preview), states = states, onRulesChanged = {},
                            modifier = Modifier.safeDrawingPadding())
                    }
                }
            }
            awaitTag("tunnel-status-18001")
            compose.onNodeWithTag("tunnel-status-18001").assertTextEquals("SSH forwarding runtime is unavailable")
            capture("runtime-unavailable")

            // Lifecycle runs against the real JNI policy on Android; only
            // SSH's listener primitive is a host-free fixture here.
            manager.attach(object : PortForwardingRuntime {
                override val capabilities = ForwardingCapabilities.forTransport(ForwardingTransport.Ssh)
                override suspend fun start(rule: PortForwardRule): PortForwardingLease = object : PortForwardingLease {
                    override val bound = BoundForwardEndpoint(rule.bind.host, rule.bind.port)
                    override val activeConnectionCount: StateFlow<Int> = MutableStateFlow(0)
                    override val isOpen = MutableStateFlow(true)
                    override fun close() { isOpen.value = false }
                }
                override fun close() = Unit
            }, listOf(preview))

            compose.waitForIdle()
            compose.onNodeWithTag("tunnel-status-18001").assertTextEquals("listening · checking…")
            compose.onNodeWithTag("tunnel-open-18001").assertIsDisplayed()
            capture("runtime-restored")
        } finally {
            manager.close()
        }
    }

    @Test fun aListeningRowSaysWhetherAnythingServesBehindIt() {
        val serving = rule(port = 18_080, target = 3_000)
        val refused = rule(port = 18_081, target = 3_001)
        val checking = rule(port = 18_082, target = 3_002)
        var probeRequests = 0

        compose.setContent {
            TesseraTheme {
                PortForwardingPanel(
                    rules = listOf(serving, refused, checking),
                    states = mapOf(
                        serving.id to state(serving, ForwardedServiceState.Serving),
                        refused.id to state(refused, ForwardedServiceState.NotServing),
                        checking.id to state(checking, ForwardedServiceState.Unknown),
                    ),
                    onRulesChanged = {},
                    onProbeServices = { probeRequests += 1 },
                )
            }
        }
        awaitTag("tunnel-status-18082")

        compose.onNodeWithTag("tunnel-status-18080").assertTextEquals("serving · 0 active")
        compose.onNodeWithTag("tunnel-status-18081")
            .assertTextEquals("listening · nothing serving on remote port 3001")
        compose.onNodeWithTag("tunnel-status-18082").assertTextEquals("listening · checking…")

        // Nothing serving is no reason to withhold the page: it may be up by
        // the time the user taps.
        compose.onNodeWithTag("tunnel-open-18080").assertIsDisplayed()
        compose.onNodeWithTag("tunnel-open-18081").assertIsDisplayed()

        // Opening the panel asks for fresh answers, once.
        compose.runOnIdle { assertEquals(1, probeRequests) }
    }

    @Test fun aRowThatWouldNeverResolveKeepsThePlainListeningLine() {
        val prohibited = rule(port = 18_083, target = 3_003)
        // Never probed: https targets log a TLS error per bare connect, and
        // postgres an incomplete startup packet.
        val https = rule(port = 18_443, target = 443)
        val postgres = rule(port = 15_432, target = 5_432)

        compose.setContent {
            TesseraTheme {
                PortForwardingPanel(
                    rules = listOf(prohibited, https, postgres),
                    states = mapOf(
                        prohibited.id to state(prohibited, ForwardedServiceState.Unknown, prohibited = true),
                        https.id to state(https, ForwardedServiceState.Unknown),
                        postgres.id to state(postgres, ForwardedServiceState.Unknown),
                    ),
                    onRulesChanged = {},
                )
            }
        }
        awaitTag("tunnel-status-15432")

        compose.onNodeWithTag("tunnel-status-18083").assertTextEquals("listening · 0 active")
        compose.onNodeWithTag("tunnel-status-18443").assertTextEquals("listening · 0 active")
        compose.onNodeWithTag("tunnel-status-15432").assertTextEquals("listening · 0 active")
    }

    /** Waits for a tag without requiring a root to exist yet. */
    private fun awaitTag(tag: String) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun shell(command: String): ByteArray = automation.executeShellCommand(command).let { descriptor ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
        }
        // Gradle uninstalls library test packages before the gate's EXIT trap.
        // Shell-owned pictures survive that uninstall and can be exported.
        val path = "/sdcard/Pictures/tessera-forwarding/$name.png"
        shell("mkdir -p /sdcard/Pictures/tessera-forwarding")
        shell("screencap -p $path")
        check(shell("head -c 8 $path").contentEquals(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)))
    }

    private fun state(rule: PortForwardRule, service: ForwardedServiceState, prohibited: Boolean = false) =
        PortForwardingState(
            rule = rule,
            status = PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", rule.bind.port)),
            service = service,
            forwardingProhibited = prohibited,
        )

    private fun rule(port: Int, target: Int) = PortForwardRule(
        id = UUID.randomUUID(),
        direction = PortForwardDirection.LOCAL,
        bind = PortForwardEndpoint("127.0.0.1", port),
        target = PortForwardEndpoint("localhost", target),
    )
}
