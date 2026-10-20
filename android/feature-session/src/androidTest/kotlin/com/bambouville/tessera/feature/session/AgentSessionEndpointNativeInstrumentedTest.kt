package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentExecRequest
import com.bambouville.tessera.agent.platform.AgentIntegrationCommand
import com.bambouville.tessera.agent.platform.AgentIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryCommands
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryScope
import com.bambouville.tessera.agent.platform.AgentProofProvider
import com.bambouville.tessera.agent.platform.AgentSemanticKey
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentShellActivationCommand
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.agent.platform.AgentTmuxPlacement
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.SshExecRequest
import com.bambouville.tessera.networking.SshRemoteOperation
import com.bambouville.tessera.networking.SshTmuxConnection
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import com.bambouville.tessera.networking.mosh.AndroidSshMoshBootstrapper
import com.bambouville.tessera.networking.mosh.JniMoshNativeClientFactory
import com.bambouville.tessera.networking.mosh.MoshBootstrapRequest
import com.bambouville.tessera.networking.mosh.MoshConnectRequest
import com.bambouville.tessera.networking.mosh.MoshConnectionState
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.Properties
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Disposable-AVD proof for the Android endpoint, using the exact production
 * v9 helpers installed through the production endpoint onto a clean fixture account.
 */
@RunWith(AndroidJUnit4::class)
class AgentSessionEndpointNativeInstrumentedTest {
    @Test fun realSshAndTmuxEndpointsProjectActNavigateAndReceiveLaunchReceipt(): Unit = runBlocking {
        val fixture = readFixture()
        val route = AndroidSshBackend().openRoute(
            request = SshRouteRequest(listOf(SshRouteHop(
                id = "agent-native", endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                username = fixture.user, authentication = SshAuthentication.Password,
            ))),
            passwordProvider = SshPasswordProvider { fixture.password.toCharArray() },
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        val raw = route.openTerminal(100, 30, routeMarker = UUID.randomUUID().toString())
        val rawCapture = StringBuilder()
        val rawReader = kotlinx.coroutines.CoroutineScope(Dispatchers.IO).launch {
            val buffer = ByteArray(4096)
            while (true) {
                val count = raw.standardOutput.read(buffer)
                if (count <= 0) break
                synchronized(rawCapture) { rawCapture.append(buffer.decodeToString(0, count)) }
            }
        }
        try {
            val rawBinding = AgentEndpointBinding(
                AgentSessionKey(UUID.randomUUID().toString(), 1), "fixture-host", AgentEndpointTransport.SSH,
            )
            val rawEndpoint = SshAgentSessionEndpoint(
                key = rawBinding.key,
                hostID = rawBinding.hostID,
                transport = AgentEndpointTransport.SSH,
                route = route,
                routeMarker = raw.routeMarker,
                rawWriter = raw::write,
                hostAsset = ::packagedHostAsset,
            )
            raw.write("printf '__TESSERA_AGENT_PID:%s__\\n' \"\$\$\"\n".encodeToByteArray())
            val shellPID = awaitMatch(rawCapture, Regex("__TESSERA_AGENT_PID:([0-9]+)__"))
                .groupValues[1].toInt()
            assertTrue(raw.routeMarker != null)
            // A forged OSC can name any shell descendant. Route ancestry is
            // necessary but insufficient: only the exact provider executable
            // may upgrade an Agent Center route.
            assertTrue(rawEndpoint.proveProcess(rawBinding, shellPID, AgentProofProvider.CLAUDE) is AgentEndpointResult.Failed)
            assertTrue(!rawEndpoint.capabilities.value.verifiedInput)
            assertTrue(!rawEndpoint.capabilities.value.semanticKeys)

            when (val initialStatus =
                (rawEndpoint.probeIntegration(rawBinding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value
            ) {
                AgentIntegrationStatus.Missing -> installIntegration(rawEndpoint, rawBinding)
                // Instrumentation method order is intentionally unspecified;
                // the real-Mosh method may have already performed the same
                // product-owned installation after the gate's clean preflight.
                AgentIntegrationStatus.Current -> Unit
                is AgentIntegrationStatus.Outdated -> error("clean fixture began with outdated integration: $initialStatus")
                is AgentIntegrationStatus.RequiresAppUpdate ->
                    error("clean fixture began with a newer app's integration: $initialStatus")
            }
            assertEquals(
                AgentIntegrationStatus.Current,
                (rawEndpoint.probeIntegration(rawBinding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value,
            )
            executeFixtureShell(
                route,
                // Version-agnostic downgrade: any real installation is newer than v1.
                "sed 's/^TESSERA_AGENT_INTEGRATION_VERSION=[0-9][0-9]*${'$'}/TESSERA_AGENT_INTEGRATION_VERSION=1/' \"${'$'}HOME/.config/tessera/agent-lifecycle-hook.sh\" > \"${'$'}HOME/.config/tessera/agent-lifecycle-hook.sh.test\" && chmod 700 \"${'$'}HOME/.config/tessera/agent-lifecycle-hook.sh.test\" && mv \"${'$'}HOME/.config/tessera/agent-lifecycle-hook.sh.test\" \"${'$'}HOME/.config/tessera/agent-lifecycle-hook.sh\"\n",
            )
            assertTrue(
                (rawEndpoint.probeIntegration(rawBinding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value
                    is AgentIntegrationStatus.Outdated,
            )
            installIntegration(rawEndpoint, rawBinding)
            assertEquals(
                AgentIntegrationStatus.Current,
                (rawEndpoint.probeIntegration(rawBinding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value,
            )
            val discoveryScope = (rawEndpoint.processDiscoveryScope(rawBinding) as AgentEndpointResult.Success).value
            val discovered = (rawEndpoint.discoverProcesses(
                rawBinding,
                AgentProcessDiscoveryCommands.command(discoveryScope),
            ) as AgentEndpointResult.Success).value.processes
            assertTrue(discovered.any { it.processID == shellPID && it.foreground })
            assertTrue(rawEndpoint.activateCurrentShell(
                rawBinding,
                discovered.filter { it.foreground && it.executable.substringAfterLast('/') in setOf("bash", "zsh") }
                    .mapTo(linkedSetOf()) { it.processID },
                AgentShellActivationCommand.persistAndApplyFromSharedCore(),
            ) is AgentEndpointResult.Success)

            val projectionRequest = JSONObject().put("v", 1).put("kind", "project").put("provider", "claude")
                .put("transcriptRef", fixture.transcriptRef).put("limitBytes", 262_144).put("limitRecords", 100)
                .toString().plus("\n").encodeToByteArray()
            val stream = (rawEndpoint.execute(rawBinding, AgentExecRequest("tessera-agent-project", projectionRequest)) as AgentEndpointResult.Success).value
            // The production presenter drains both SSH pipes concurrently;
            // preserve that property in the native proof so helper diagnostics
            // cannot leave a child blocked on a full stderr pipe.
            val projection = coroutineScope {
                val stdout = async { stream.stdout.toByteArrayBounded() }
                val stderr = async { stream.stderr.toByteArrayBounded() }
                val exit = async { stream.awaitExit() }
                val output = stdout.await()
                stderr.await()
                check(exit.await().code == 0)
                output
            }
            stream.close()
            assertTrue(projection.decodeToString().contains("\"kind\":\"record\""))

            assertTrue(rawEndpoint.sendInput(rawBinding, "printf TESSERA_AGENT_RAW_ACTION".encodeToByteArray()) is AgentEndpointResult.Success)
            assertTrue(rawEndpoint.sendSemanticKey(rawBinding, AgentSemanticKey.RETURN) is AgentEndpointResult.Success)
            assertTrue(awaitText(rawCapture, "TESSERA_AGENT_RAW_ACTION").contains("TESSERA_AGENT_RAW_ACTION"))

            route.openTmux(fixture.tmuxSession).use { tmux ->
                val control = LiveTmuxControl(tmux)
                // A newly attached -CC client can emit its initial attach
                // response before the first command response. Consume only a
                // syntactically exact pane address, never an arbitrary line.
                var addressLine: String? = null
                repeat(3) {
                    addressLine = control.send("display-message -p '#{window_id}\t#{pane_id}'").lines
                        .firstOrNull { it.matches(Regex("@[0-9]+\\t%[0-9]+")) } ?: addressLine
                    if (addressLine != null) return@repeat
                }
                val address = requireNotNull(addressLine).split('\t')
                val window = address[0]
                val pane = address[1]
                val tmuxBinding = AgentEndpointBinding(
                    AgentSessionKey(UUID.randomUUID().toString(), 2), "fixture-host", AgentEndpointTransport.SSH_TMUX,
                    fixture.tmuxSession, window, pane,
                )
                val endpoint = SshAgentSessionEndpoint(
                    key = tmuxBinding.key, hostID = tmuxBinding.hostID, transport = AgentEndpointTransport.SSH_TMUX,
                    route = route, tmuxSession = fixture.tmuxSession,
                    tmuxControl = TmuxAgentControlPort(control::send),
                    hostAsset = ::packagedHostAsset,
                )
                endpoint.updateActiveTmuxTarget(window.removePrefix("@").toInt(), pane.removePrefix("%").toInt())
                val panePID = control.send("display-message -p -t $pane '#{pane_pid}'").lines
                    .firstNotNullOfOrNull(String::trim)?.toIntOrNull() ?: error("missing pane PID")
                assertTrue(endpoint.proveProcess(tmuxBinding, panePID, AgentProofProvider.CLAUDE) is AgentEndpointResult.Failed)
                assertTrue(endpoint.focus(tmuxBinding) is AgentEndpointResult.Success)
                assertTrue((endpoint.inspect(tmuxBinding) as AgentEndpointResult.Success).value.authoritative)
                assertEquals(
                    fixture.directory,
                    ((endpoint.validatedDirectories(tmuxBinding) as AgentEndpointResult.Success).value.single()),
                )
                val launchID = UUID.randomUUID().toString()
                val receipt = endpoint.launchTmux(
                    tmuxBinding, AgentTmuxPlacement.NewWindow("native-agent"), launchID,
                    JSONObject().put("v", 1).put("requestID", launchID).put("kind", "spawn")
                        .put("provider", "claude").put("task", "native gate").put("directory", fixture.directory)
                        .put("isolation", JSONObject().put("kind", "current")).toString().encodeToByteArray(),
                )
                val launchReceipt = when (receipt) {
                    is AgentEndpointResult.Success -> receipt.value
                    else -> error("production helper did not acknowledge the spawn: $receipt")
                }
                assertEquals(launchID, launchReceipt.requestID)
                assertTrue(launchReceipt.windowID.matches(Regex("@[0-9]+")))
                assertTrue(launchReceipt.paneID.matches(Regex("%[0-9]+")))

            }
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_AGENT_CENTER_SSH_OK install=1 update=1 projection=1 rawAction=1 tmuxFocus=1 spawn=1 transports=2")
        } finally {
            rawReader.cancel(); raw.close(); route.close()
        }
    }

    /**
     * This lane intentionally uses the production native UDP client, rather
     * than relabelling an SSH route as Mosh. The authenticated SSH route below
     * is the documented data/control side channel; visible terminal bytes must
     * nevertheless come from the mosh-server started by [AndroidMoshTransport].
     */
    @Test fun realMoshAndMoshTmuxEndpointsUseBootstrapRootAndControlSideChannel(): Unit = runBlocking {
        assumeTrue("native Mosh is required for this focused runtime lane", JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val backend = AndroidSshBackend()
        val request = SshRouteRequest(listOf(SshRouteHop(
            id = "agent-native-mosh", endpoint = SshEndpoint(fixture.stableHost, fixture.port),
            username = fixture.user, authentication = SshAuthentication.Password,
        )))
        val passwordProvider = SshPasswordProvider { fixture.password.toCharArray() }
        val hostKeyPolicy = SshHostKeyPolicy { true }
        val bootstrapper = AndroidSshMoshBootstrapper(backend, passwordProvider, hostKeyPolicy)

        val rawRoute = backend.openRoute(request, passwordProvider, hostKeyPolicy)
        val rawTransport = AndroidMoshTransport(bootstrapper)
        val rawCapture = StringBuilder()
        val rawReader = CoroutineScope(Dispatchers.IO).launch {
            rawTransport.output.collect { chunk ->
                synchronized(rawCapture) { rawCapture.append(chunk.bytes.decodeToString()) }
            }
        }
        var rawServerPID: Int? = null
        try {
            rawTransport.connect(MoshConnectRequest(
                bootstrap = MoshBootstrapRequest(route = request, udpHost = fixture.stableHost),
                columns = 100,
                rows = 30,
            ))
            awaitMoshReachable(rawTransport)
            Log.i("TesseraNativeSsh", "agent_mosh_phase=raw_connected")
            val bootstrapServerPID = requireNotNull(rawTransport.bootstrapServerPid) {
                "mosh bootstrap did not report server PID"
            }
            rawServerPID = bootstrapServerPID
            val rawBinding = AgentEndpointBinding(
                AgentSessionKey(UUID.randomUUID().toString(), 3), "fixture-host", AgentEndpointTransport.MOSH,
            )
            val rawEndpoint = SshAgentSessionEndpoint(
                key = rawBinding.key,
                hostID = rawBinding.hostID,
                transport = AgentEndpointTransport.MOSH,
                route = rawRoute,
                rawWriter = rawTransport::send,
                processRootPID = { rawTransport.bootstrapServerPid },
                hostAsset = ::packagedHostAsset,
            )
            assertEquals(
                AgentProcessDiscoveryScope.RootProcess(bootstrapServerPID),
                (rawEndpoint.processDiscoveryScope(rawBinding) as AgentEndpointResult.Success).value,
            )
            ensureIntegrationCurrent(rawEndpoint, rawBinding)
            val discovered = (rawEndpoint.discoverProcesses(
                rawBinding,
                AgentProcessDiscoveryCommands.command(AgentProcessDiscoveryScope.RootProcess(bootstrapServerPID)),
            ) as AgentEndpointResult.Success).value.processes
            assertTrue(discovered.any { it.executable.substringAfterLast('/') in setOf("bash", "zsh") })
            Log.i("TesseraNativeSsh", "agent_mosh_phase=raw_shell_discovered")
            val rawActionPath = "${fixture.directory}/mosh-raw-action"
            assertTrue(rawEndpoint.sendInput(
                rawBinding,
                "printf TESSERA_AGENT_MOSH_RAW_ACTION > '$rawActionPath'".encodeToByteArray(),
            ) is AgentEndpointResult.Success)
            assertTrue(rawEndpoint.sendSemanticKey(rawBinding, AgentSemanticKey.RETURN) is AgentEndpointResult.Success)
            awaitFixtureFile(rawRoute, rawActionPath)
            Log.i("TesseraNativeSsh", "agent_mosh_phase=raw_action")
        } finally {
            rawReader.cancel()
            rawTransport.close()
            rawRoute.close()
            rawServerPID?.let { terminateMoshServer(backend, request, passwordProvider, hostKeyPolicy, it) }
        }

        val tmuxRoute = backend.openRoute(request, passwordProvider, hostKeyPolicy)
        val tmuxTransport = AndroidMoshTransport(bootstrapper)
        val tmuxCapture = StringBuilder()
        val visibleClientDeviceID = "agent-${UUID.randomUUID()}"
        val tmuxReader = CoroutineScope(Dispatchers.IO).launch {
            tmuxTransport.output.collect { chunk ->
                synchronized(tmuxCapture) { tmuxCapture.append(chunk.bytes.decodeToString()) }
            }
        }
        var tmuxServerPID: Int? = null
        try {
            tmuxTransport.connect(MoshConnectRequest(
                bootstrap = MoshBootstrapRequest(
                    route = request,
                    udpHost = fixture.stableHost,
                    launchCommand = SharedTmuxCommands.moshVisibleClientCommand(
                        fixture.tmuxSession,
                        visibleClientDeviceID,
                    ),
                ),
                columns = 100,
                rows = 30,
            ))
            awaitMoshReachable(tmuxTransport)
            Log.i("TesseraNativeSsh", "agent_mosh_phase=tmux_connected")
            tmuxServerPID = requireNotNull(tmuxTransport.bootstrapServerPid) { "mosh tmux bootstrap did not report server PID" }
            // Mosh's side channel joins Tessera's view of the session, the
            // one its visible client attaches to; the user's session is left
            // untouched, so every session-scoped probe below names the view.
            val moshViewSession = SharedTmuxCommands.moshViewSessionName(fixture.tmuxSession)
            tmuxRoute.openTmux(fixture.tmuxSession, moshViewSession = true).use { tmux ->
                val control = LiveTmuxControl(tmux)
                val (originalWindow, originalPane) = tmuxPaneAddress(control)
                // A window-only mirror can hide a wrong active pane. Create a
                // real sibling here, leave the existing pane selected, then
                // let the production focus path select this exact %pane.
                val focusAddress = control.send(
                    "split-window -d -t $originalPane -c '${fixture.directory}' -P -F '#{window_id}\t#{pane_id}'",
                ).lines.firstOrNull { it.matches(Regex("@[0-9]+\\t%[0-9]+")) }
                    ?: error("missing sibling focus pane")
                val (window, pane) = focusAddress.split('\t')
                assertEquals("sibling pane must remain in the visible window", originalWindow, window)
                assertTrue("fixture split must create a distinct sibling pane", pane != originalPane)
                val panePID = control.send("display-message -p -t $pane '#{pane_pid}'").lines
                    .firstNotNullOfOrNull(String::trim)?.toIntOrNull() ?: error("missing tmux pane PID")
                val binding = AgentEndpointBinding(
                    AgentSessionKey(UUID.randomUUID().toString(), 4), "fixture-host", AgentEndpointTransport.MOSH_TMUX,
                    fixture.tmuxSession, window, pane,
                )
                val endpoint = SshAgentSessionEndpoint(
                    key = binding.key,
                    hostID = binding.hostID,
                    transport = AgentEndpointTransport.MOSH_TMUX,
                    route = tmuxRoute,
                    tmuxSession = fixture.tmuxSession,
                    hostAsset = ::packagedHostAsset,
                    tmuxControl = TmuxAgentControlPort(
                        directResponder = control::send,
                        directWindowSelector = { target ->
                            mirrorVisibleTmuxClient(
                                control = control,
                                session = moshViewSession,
                                deviceID = visibleClientDeviceID,
                                target = target,
                            )
                        },
                        directPaneSelector = { target, preservingWindowZoom ->
                            mirrorVisibleTmuxClient(
                                control = control,
                                session = moshViewSession,
                                deviceID = visibleClientDeviceID,
                                target = target,
                                preservingWindowZoom = preservingWindowZoom,
                            )
                        },
                    ),
                )
                endpoint.updateActiveTmuxTarget(window.removePrefix("@").toInt(), pane.removePrefix("%").toInt())
                ensureIntegrationCurrent(endpoint, binding)
                assertTrue((endpoint.inspect(binding) as AgentEndpointResult.Success).value.authoritative)
                assertTrue(endpoint.focus(binding) is AgentEndpointResult.Success)
                assertEquals(
                    "Agent focus must move the stamped Mosh painter to the exact pane, not only the -CC client",
                    "$window|$pane",
                    visibleTmuxClientTarget(
                        control,
                        moshViewSession,
                        visibleClientDeviceID,
                    ),
                )
                assertEquals(
                    AgentProcessDiscoveryScope.RootProcess(panePID),
                    (endpoint.processDiscoveryScope(binding) as AgentEndpointResult.Success).value,
                )
                val processes = (endpoint.discoverProcesses(
                    binding,
                    AgentProcessDiscoveryCommands.command(AgentProcessDiscoveryScope.RootProcess(panePID)),
                ) as AgentEndpointResult.Success).value.processes
                assertTrue(processes.any { it.processID == panePID })
                assertTrue(endpoint.sendInput(binding, "printf TESSERA_AGENT_MOSH_TMUX_SIDE_CHANNEL".encodeToByteArray()) is AgentEndpointResult.Success)
                assertTrue(endpoint.sendSemanticKey(binding, AgentSemanticKey.RETURN) is AgentEndpointResult.Success)
                awaitTmuxText(control, pane, "TESSERA_AGENT_MOSH_TMUX_SIDE_CHANNEL")
                assertTrue(awaitText(tmuxCapture, "TESSERA_AGENT_MOSH_TMUX_SIDE_CHANNEL")
                    .contains("TESSERA_AGENT_MOSH_TMUX_SIDE_CHANNEL"))
            }
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_AGENT_CENTER_MOSH_OK rawUdp=1 bootstrapRoot=1 tmuxUdp=1 tmuxSideChannel=1 tmuxVisiblePaneFocus=1 transports=2")
        } finally {
            tmuxReader.cancel()
            tmuxTransport.close()
            tmuxRoute.close()
            tmuxServerPID?.let { terminateMoshServer(backend, request, passwordProvider, hostKeyPolicy, it) }
        }
    }

    private class LiveTmuxControl(connection: SshTmuxConnection) {
        private val reader = BufferedReader(InputStreamReader(connection.standardOutput))
        private val sendControl = connection::sendControl
        private val incoming = Channel<String>(Channel.UNLIMITED)
        private val lock = Mutex()

        init {
            CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
                try {
                    while (true) incoming.send(reader.readLine() ?: break)
                } finally {
                    incoming.close()
                }
            }
        }

        private var aligned = false

        suspend fun send(command: String): AgentTmuxControlAck = withTimeout(20_000) {
            lock.withLock {
                if (!aligned) {
                    // The attach reply usually shares its line with the -CC
                    // DCS and is skipped, but it can arrive on a line of its
                    // own and pair every later command with the previous
                    // reply. Discard every block before a marker's reply.
                    val marker = "TESSERA_ALIGN_${UUID.randomUUID().toString().replace("-", "")}"
                    sendControl("display-message -p '$marker'")
                    while (true) {
                        val block = readBlock() ?: return@withLock AgentTmuxControlAck(false, emptyList())
                        if (marker in block.lines) break
                    }
                    aligned = true
                }
                sendControl(command)
                readBlock() ?: AgentTmuxControlAck(false, emptyList())
            }
        }

        private suspend fun readBlock(): AgentTmuxControlAck? {
            val lines = mutableListOf<String>(); var begun = false
            repeat(200) {
                val line = incoming.receiveCatching().getOrNull() ?: return null
                when {
                    line.startsWith("%begin") -> begun = true
                    begun && line.startsWith("%end") -> return AgentTmuxControlAck(true, lines)
                    begun && line.startsWith("%error") -> return AgentTmuxControlAck(false, lines)
                    begun && !line.startsWith("%") -> lines += line
                }
            }
            return AgentTmuxControlAck(false, emptyList())
        }
    }

    private suspend fun awaitText(capture: StringBuilder, token: String): String = withTimeout(20_000) {
        while (true) {
            val value = synchronized(capture) { capture.toString() }
            if (value.contains(token)) return@withTimeout value
            kotlinx.coroutines.delay(50)
        }
        error("unreachable")
    }

    private suspend fun awaitMatch(capture: StringBuilder, pattern: Regex): MatchResult = withTimeout(20_000) {
        while (true) {
            val match = synchronized(capture) { pattern.find(capture.toString()) }
            if (match != null) return@withTimeout match
            kotlinx.coroutines.delay(50)
        }
        error("unreachable")
    }

    private suspend fun awaitMoshReachable(transport: AndroidMoshTransport) = withTimeout(30_000) {
        while (transport.connectivity.value.let {
                it.state != MoshConnectionState.CONNECTED || !it.transportReachable
            }
        ) kotlinx.coroutines.delay(50)
    }

    private suspend fun awaitFixtureFile(
        route: com.bambouville.tessera.networking.SshRouteOwner,
        path: String,
    ) = withTimeout(20_000) {
        while (true) {
            if (runCatching { executeFixtureShell(route, "test -f '$path'\n") }.isSuccess) return@withTimeout
            kotlinx.coroutines.delay(100)
        }
    }

    private suspend fun awaitTmuxText(control: LiveTmuxControl, pane: String, token: String) = withTimeout(20_000) {
        while (true) {
            val capture = control.send("capture-pane -p -t $pane").lines.joinToString("\n")
            if (capture.contains(token)) return@withTimeout
            kotlinx.coroutines.delay(100)
        }
    }

    private suspend fun tmuxPaneAddress(control: LiveTmuxControl): Pair<String, String> {
        var addressLine: String? = null
        repeat(3) {
            addressLine = control.send("display-message -p '#{window_id}\t#{pane_id}'").lines
                .firstOrNull { it.matches(Regex("@[0-9]+\\t%[0-9]+")) } ?: addressLine
            if (addressLine != null) return@repeat
        }
        val address = requireNotNull(addressLine).split('\t')
        return address[0] to address[1]
    }

    private suspend fun mirrorVisibleTmuxClient(
        control: LiveTmuxControl,
        session: String,
        deviceID: String,
        target: String,
        preservingWindowZoom: Boolean = false,
    ): AgentTmuxControlAck {
        val isWindowTarget = TmuxVisibleClientSelection.windowId(target) != null
        val isPaneTarget = TmuxVisibleClientSelection.paneId(target) != null
        if (!isWindowTarget && !isPaneTarget) {
            return AgentTmuxControlAck(false, emptyList())
        }
        val quotedSession = TmuxVisibleClientSelection.quotedArgument(session)
            ?: return AgentTmuxControlAck(false, emptyList())
        val selected = when {
            isWindowTarget -> control.send("select-window -t $target")
            preservingWindowZoom -> control.send("select-pane -Z -t $target")
            else -> control.send("select-pane -t $target")
        }
        if (!selected.success) return selected
        val selectedAddress = tmuxPaneAddress(control)
        if (isPaneTarget && selectedAddress.second != target) {
            return AgentTmuxControlAck(false, emptyList())
        }
        val option = SharedTmuxCommands.authorityVisibleClientOption(deviceID)
        val stamped = TmuxVisibleClientSelection.singleStampedIdentity(
            control.send("show-options -qv -t $quotedSession $option").lines,
        ) ?: return AgentTmuxControlAck(false, emptyList())
        val clients = control.send(
            "list-clients -t $quotedSession -F '#{client_name}|#{client_pid}|#{client_created}'",
        )
        if (!clients.success || !TmuxVisibleClientSelection.isExactlyAttached(stamped.first, clients.lines)) {
            return AgentTmuxControlAck(false, emptyList())
        }
        val quotedClient = TmuxVisibleClientSelection.quotedArgument(stamped.second.name)
            ?: return AgentTmuxControlAck(false, emptyList())
        val qualifiedTarget = TmuxVisibleClientSelection.qualifiedTarget(
            session,
            TmuxVisibleClientSelection.windowId(selectedAddress.first) ?: return AgentTmuxControlAck(false, emptyList()),
            if (isPaneTarget) TmuxVisibleClientSelection.paneId(target) else null,
        ) ?: return AgentTmuxControlAck(false, emptyList())
        val switched = if (isPaneTarget) {
            val zoomFlag = if (preservingWindowZoom) "-Z " else ""
            control.send("switch-client ${zoomFlag}-c $quotedClient -t $qualifiedTarget")
        } else {
            control.send("switch-client -c $quotedClient -t $qualifiedTarget")
        }
        if (!switched.success) return switched
        if (isPaneTarget) {
            val expectedTarget = "${selectedAddress.first}|$target"
            if (tmuxPaneAddress(control).second != target ||
                visibleTmuxClientTarget(control, session, deviceID) != expectedTarget
            ) {
                return AgentTmuxControlAck(false, emptyList())
            }
        }
        return switched
    }

    private suspend fun visibleTmuxClientTarget(
        control: LiveTmuxControl,
        session: String,
        deviceID: String,
    ): String? {
        val quotedSession = TmuxVisibleClientSelection.quotedArgument(session) ?: return null
        val option = SharedTmuxCommands.authorityVisibleClientOption(deviceID)
        val stamp = TmuxVisibleClientSelection.singleStampedIdentity(
            control.send("show-options -qv -t $quotedSession $option").lines,
        )?.first ?: return null
        val attached = control.send(
            "list-clients -t $quotedSession -F '#{client_name}|#{client_pid}|#{client_created}'",
        )
        if (!attached.success || !TmuxVisibleClientSelection.isExactlyAttached(stamp, attached.lines)) return null
        val matches = control.send(
            "list-clients -t $quotedSession -F '#{client_name}|#{client_pid}|#{client_created}|#{window_id}|#{pane_id}'",
        )
        if (!matches.success) return null
        val clientTarget = matches.lines.singleOrNull { line ->
            val fields = line.split('|')
            fields.size == 5 && fields.take(3).joinToString("|") == stamp &&
                TmuxVisibleClientSelection.windowId(fields[3]) != null &&
                TmuxVisibleClientSelection.paneId(fields[4]) != null
        } ?: return null
        return clientTarget.substringAfter("$stamp|")
    }

    private suspend fun ensureIntegrationCurrent(endpoint: SshAgentSessionEndpoint, binding: AgentEndpointBinding) {
        when (val status = (endpoint.probeIntegration(binding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value) {
            AgentIntegrationStatus.Current -> Unit
            AgentIntegrationStatus.Missing,
            is AgentIntegrationStatus.Outdated -> installIntegration(endpoint, binding)
            // Installing would be refused; a newer app owns this fixture host.
            is AgentIntegrationStatus.RequiresAppUpdate ->
                error("fixture host carries a newer app's integration: $status")
        }
        assertEquals(
            AgentIntegrationStatus.Current,
            (endpoint.probeIntegration(binding, AgentIntegrationCommand.probeFromSharedCore()) as AgentEndpointResult.Success).value,
        )
    }

    private suspend fun terminateMoshServer(
        backend: AndroidSshBackend,
        request: SshRouteRequest,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        serverPID: Int,
    ) {
        if (serverPID <= 1) return
        // The bootstrap parser admitted this numeric PID from this test's own
        // mosh-server banner. Reap only that process on the disposable fixture.
        runCatching {
            backend.executeRouteCommand(
                request = request,
                commandText = "kill $serverPID",
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
            )
        }
    }

    private suspend fun kotlinx.coroutines.flow.Flow<ByteArray>.toByteArrayBounded(): ByteArray {
        val output = ArrayList<Byte>()
        collect { chunk ->
            check(output.size + chunk.size <= 262_144)
            chunk.forEach(output::add)
        }
        return output.toByteArray()
    }

    private suspend fun installIntegration(endpoint: SshAgentSessionEndpoint, binding: AgentEndpointBinding) {
        val snapshotsResult = endpoint.readIntegrationConfigs(
            binding,
            AgentIntegrationCommand.readConfigsFromSharedCore(),
        )
        assertTrue("production config snapshot read failed: $snapshotsResult", snapshotsResult is AgentEndpointResult.Success)
        val snapshots = (snapshotsResult as AgentEndpointResult.Success).value
        val installed = endpoint.installIntegration(
            binding,
            AgentIntegrationCommand.installFromSharedCore(snapshots.codex, snapshots.claude, snapshots.kimi),
        )
        assertTrue("production integration install failed: $installed", installed is AgentEndpointResult.Success)
        assertEquals(
            SharedAgentIntegrationInstallOutcome.Completed,
            (installed as AgentEndpointResult.Success).value,
        )
    }

    /** The same packaged artifacts and size bound used by SshSessionScreen. */
    private fun packagedHostAsset(name: String): ByteArray {
        require(name == "manifest.json" || name in listOf(
            "darwin-arm64", "darwin-x86_64", "linux-aarch64", "linux-x86_64",
        ).map { "tessera-agent-host-$it" })
        return InstrumentationRegistry.getInstrumentation().targetContext.assets.open(name).use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(65_536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                check(output.size() + count <= 16 * 1024 * 1024)
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private suspend fun executeFixtureShell(route: com.bambouville.tessera.networking.SshRouteOwner, script: String) {
        val stream = route.execute(SshExecRequest(
            SshRemoteOperation.AGENT_INTEGRATION_SHELL,
            maxStdinBytes = script.encodeToByteArray().size,
        ))
        try {
            stream.writeStdin(script.encodeToByteArray())
            stream.closeStdin()
            coroutineScope {
                val stdout = async { stream.stdout().toByteArrayBounded() }
                val stderr = async { stream.stderr().toByteArrayBounded() }
                val exit = async { stream.awaitExit() }
                stdout.await(); stderr.await()
                check(exit.await().code == 0)
            }
        } finally {
            stream.close()
        }
    }

    private fun readFixture(): Fixture {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cat $FIXTURE_PATH")
        val properties = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { Properties().apply { load(it) } }
        fun value(name: String) = properties.getProperty(name)?.takeIf(String::isNotBlank) ?: error("missing $name")
        return Fixture(value("stableHost"), value("port").toInt(), value("user"),
            String(Base64.decode(value("passwordBase64"), Base64.DEFAULT)), value("agentTranscriptRef"),
            value("agentDirectory"), value("agentTmuxSession"))
    }

    private data class Fixture(val stableHost: String, val port: Int, val user: String, val password: String,
        val transcriptRef: String, val directory: String, val tmuxSession: String)

    private companion object { const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties" }
}
