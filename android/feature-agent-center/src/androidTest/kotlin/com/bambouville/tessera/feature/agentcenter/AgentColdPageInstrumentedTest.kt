package com.bambouville.tessera.feature.agentcenter

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.view.Choreographer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.design.TesseraTheme
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Test APK only: finite corpus via authenticated adb-reversed Unix streams.
 * No user host, provider process control, or action authority. The external
 * runner may back the Unix adapter with its owned authenticated SSH fixture.
 * Clock calibration precedes cold-helper startup; a visible-tail callback plus
 * two real Choreographer ticks is a paint candidate, not compositor evidence.
 */
@RunWith(AndroidJUnit4::class)
class AgentColdPageInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    @Test fun privateColdPage() {
        val supplied = InstrumentationRegistry.getArguments().getString("tesseraColdPage")
        assumeNotNull(supplied) // Not part of unconfigured aggregate test runs.
        val encoded = checkNotNull(supplied)
        require(encoded.length <= 8192)
        val config = JSONObject(String(Base64.getDecoder().decode(encoded), Charsets.UTF_8))
        assertNull("fixture must not shrink the transcript with a platform action bar", compose.activity.actionBar)
        require(config.getString("provider") in setOf("codex", "claude"))
        require(config.getString("socket").matches(Regex("tessera-paint-[a-f0-9]{32}")))
        require(config.getString("token").matches(Regex("[a-f0-9]{64}")))
        require(config.getInt("expectedInventory") in 1..16384)
        require(config.getString("expectedInventorySHA256").matches(Regex("[a-f0-9]{64}")))
        if (config.getBoolean("landscape")) require(compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE)
        val measuredActivity = compose.activity
        val fixture = Fixture(config)
        try {
            compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
                AgentDetailPane(fixture.detail, "", {}, {}, {}, { _, _ -> }, fixture::visible,
                    {}, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding())
            } } }
            compose.waitForIdle()
            fixture.start()
            compose.waitUntil(60_000) { fixture.complete || fixture.failure != null }
            assertNull("content-free fixture stage: ${fixture.stage}", fixture.failure)
            assertTrue(fixture.complete)
            compose.waitForIdle()
            // A retained fixture can safely redraw after recreation, but its
            // earlier Choreographer callback cannot time the new composition.
            // Reject that trial rather than publishing a misleading latency.
            assertSame("activity recreated during cold-page measurement", measuredActivity, compose.activity)
            val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            fixture.capturedPixels()
            File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "cold-page.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
            assertSame("activity recreated during cold-page capture", measuredActivity, compose.activity)
        } finally { fixture.close() }
    }

    @OptIn(CoordinatorOnlyAgentRouteAuthority::class)
    private class Fixture(private val config: JSONObject) : AutoCloseable {
        private val runtime = SharedAgentRuntime.create()
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        private val endpoint = UnixEndpoint(config)
        private var connection: AgentIngestionConnection? = null
        private val tokens = mutableMapOf<String, String>()
        private val result = JSONObject()
        private var visibleStarted = false
        private var paintDone = false
        private var inventoryDone = false
        private var frameCallback: Choreographer.FrameCallback? = null
        private var choreographer: Choreographer? = null
        var detail by mutableStateOf<AgentThreadDetail?>(null); private set
        @Volatile var complete = false; private set
        @Volatile var failure: String? = null; private set
        @Volatile var stage = "initialize"; private set

        private fun command(kind: String, fields: JSONObject = JSONObject()) {
            check(runtime.sendCanonical(fields.put("v", 1).put("kind", kind).toString().encodeToByteArray()) == CoreCallResult.Accepted)
        }
        private fun id(provider: String, session: String) = JSONObject().put("hostID", endpoint.binding.value.hostID)
            .put("providerID", JSONObject().put("rawValue", provider)).put("providerSessionID", session)

        private fun bind(thread: JSONObject, modified: Long? = null): String = tokens.getOrPut(thread.toString()) {
            val binding = JSONObject().put("liveSessionID", endpoint.key.liveSessionID).put("carrierGeneration", 1)
                .put("incarnation", JSONObject().put("rawValue", "private-cold-page"))
                .put("transport", "ssh").put("capabilities", 1)
            fun registration() = JSONObject().put("threadID", thread).put("hostID", endpoint.binding.value.hostID)
                .put("binding", binding).put("sourceIdentity", "private-cold-page").put("validatedDirectories", JSONArray())
            val proof = checkNotNull(runtime.issuePlatformRouteProof(registration().put("processIDs", JSONArray())))
            val mode = if (modified != null) "inventoryObservation" else "observeOnly"
            val token = checkNotNull(runtime.exchangePlatformRouteProof(registration().put("mode", mode).put("proofHandle", proof)))
            command("bind", JSONObject().put("threadID", thread).put("bindingToken", token).putOpt("inventoryModified", modified))
            token
        }

        fun start() { scope.launch {
            try {
                val generation = runtime.snapshot.value?.runtimeGeneration ?: 0
                command("configure", JSONObject().put("metadata", JSONArray()))
                withTimeout(5000) { runtime.snapshot.first { it != null && it.runtimeGeneration > generation } }
                if (!config.optBoolean("coldApp")) delay(500) // Resident baseline only, not the launch-inclusive lane.
                stage = "connect"
                val conn = AgentIngestionConnection.open(endpoint, scope); connection = conn
                result.put("appBaselineRSSBytes", endpoint.baselineRSS).put("helloNS", System.nanoTime())
                if (config.getBoolean("inventoryBeforeBootstrap")) inventory(conn)
                stage = "resolve"
                val resolved = conn.request(JSONObject().put("kind", "resolve").put("provider", config.getString("provider"))
                    .put("transcriptRef", config.getString("transcript"))).end
                val handle = resolved.getString("thread")
                val thread = id(config.getString("provider"), resolved.getString("sessionID"))
                val token = bind(thread)
                command("select", JSONObject().put("threadID", thread))
                stage = "bootstrap"
                val page = conn.request(JSONObject().put("kind", "window.read").put("thread", handle)
                    .put("operation", "bootstrap").put("windowVersion", 0).put("limit", 100))
                val before = runtime.snapshot.value?.runtimeGeneration ?: 0
                command("projection", JSONObject().put("threadID", thread).put("bindingToken", token)
                    .put("ingestionEpoch", conn.epoch).put("ingestionThread", handle)
                    .put("ingestionRequestID", page.end.getString("id"))
                    .put("ingestionWire", Base64.getEncoder().encodeToString(checkNotNull(page.wire))))
                val snapshot = withTimeout(10000) { runtime.snapshot.first {
                    it != null && it.runtimeGeneration > before && it.kind == SharedAgentSnapshotKind.Projection
                } }!!
                val next = checkNotNull(AgentPresentation.detail(snapshot))
                check(next.live.isNotEmpty() && next.window?.atLiveHead == true)
                val rawThread = snapshot.payload.fields["thread"] as SharedAgentValue.ObjectValue
                val window = (rawThread.fields["ingestionWindow"] as SharedAgentValue.ObjectValue).toJson()
                val messages = (rawThread.fields["messages"] as SharedAgentValue.ArrayValue).values.size
                check(messages > 0)
                result.put("modelNS", System.nanoTime()).put("messages", messages).put("renderedBlocks", next.live.size)
                    .put("hostPeakRSSBytes", page.end.getLong("hostPeakRSSBytes")).put("bytesRead", page.end.getLong("bytesRead"))
                detail = next
                conn.acknowledgeWindow(page, window)
                if (!config.getBoolean("inventoryBeforeBootstrap")) inventory(conn)
                finishIfReady()
            } catch (error: Throwable) {
                failure = error.javaClass.simpleName
                result.put("error", "native_cold_page_failed").put("stage", stage).put("failureType", failure)
                publish()
            }
        } }

        private suspend fun inventory(conn: AgentIngestionConnection) {
            stage = "inventory"
            val sources = sortedSetOf<String>(); val cursors = mutableSetOf<String>()
            var cursor: String? = null
            do {
                val page = conn.request(JSONObject().put("kind", "inventory").put("limit", 500).putOpt("cursor", cursor))
                for (row in page.inventory) {
                    check(sources.add(row.getString("transcriptRef")))
                    check(sources.size <= config.getInt("expectedInventory"))
                    bind(id(row.getString("provider"), row.getString("sessionID")), row.getLong("modified"))
                }
                command("filter")
                cursor = if (page.end.getBoolean("hasMore")) page.end.getString("cursor").also { check(cursors.add(it)) } else null
            } while (cursor != null)
            val digest = MessageDigest.getInstance("SHA-256").digest(sources.joinToString("\n").toByteArray()).joinToString("") { "%02x".format(it) }
            check(sources.size == config.getInt("expectedInventory") && digest == config.getString("expectedInventorySHA256"))
            // A unique, empty-result metadata search is a correlated FIFO
            // barrier. An earlier bind/filter snapshot cannot satisfy it.
            // This extra test-only barrier is included in inventory timing.
            val nonce = "private-inventory-barrier-" + UUID.randomUUID().toString()
            val generation = runtime.snapshot.value?.runtimeGeneration ?: 0
            command("search", JSONObject().put("query", nonce))
            withTimeout(10000) { runtime.snapshot.first {
                // This is the only Search command in this fresh runtime.
                // SearchSnapshot deliberately does not echo its query.
                it != null && it.runtimeGeneration > generation && it.kind == SharedAgentSnapshotKind.Search &&
                    ((it.payload.fields["search"] as? SharedAgentValue.ObjectValue)?.fields?.get("results")
                        as? SharedAgentValue.ArrayValue)?.values?.isEmpty() == true
            } }
            result.put("inventoryCount", sources.size).put("inventoryNS", System.nanoTime())
                .put("appAfterInventoryRSSBytes", memory("VmRSS")).put("appAfterInventoryLifetimePeakRSSBytes", memory("VmHWM"))
            inventoryDone = true
        }

        fun visible(record: String) {
            if (visibleStarted || record.isEmpty() || detail?.window?.atLiveHead != true) return
            visibleStarted = true
            result.put("visibleLayoutNS", System.nanoTime())
            var ticks = 0
            val callback = object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (++ticks < 2) { Choreographer.getInstance().postFrameCallback(this); return }
                    result.put("paintNS", System.nanoTime()).put("appPaintRSSBytes", memory("VmRSS"))
                        .put("appLifetimePeakRSSBytes", memory("VmHWM"))
                    frameCallback = null
                    paintDone = true; finishIfReady()
                }
            }
            frameCallback = callback; choreographer = Choreographer.getInstance()
            choreographer!!.postFrameCallback(callback)
        }
        private fun finishIfReady() {
            if (paintDone && inventoryDone) { publish(); complete = true }
        }
        private fun publish() {
            val root = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
            val pending = File(root, "cold-page.pending")
            pending.writeText(result.toString())
            check(pending.renameTo(File(root, "cold-page.json")))
        }
        fun capturedPixels() {
            result.put("capturedPixelsNS", System.nanoTime())
            publish()
        }
        override fun close() {
            frameCallback?.let { pending -> android.os.Handler(android.os.Looper.getMainLooper()).post {
                choreographer?.removeFrameCallback(pending)
            } }
            endpoint.close(); connection?.close(); scope.cancel(); runtime.close()
        }
    }

    private class UnixEndpoint(private val config: JSONObject) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "A11CE000-0000-4000-8000-000000000001", AgentEndpointTransport.SSH))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames = emptyFlow<AgentLifecycleFrame>()
        private val socket = LocalSocket()
        private val closed = AtomicBoolean()
        var baselineRSS = 0L; private set
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> = withContext(Dispatchers.IO) {
            check(request.executable == "tessera-agent-host" && isCurrentRoute(binding))
            socket.connect(LocalSocketAddress(config.getString("socket"), LocalSocketAddress.Namespace.ABSTRACT))
            socket.soTimeout = 20000 // LocalSocket creates its descriptor lazily during connect.
            val input = DataInputStream(socket.inputStream); val output = DataOutputStream(socket.outputStream)
            output.write(config.getString("token").toByteArray(Charsets.US_ASCII)); output.flush()
            // Five host/device round trips establish an offset INTERVAL, not
            // an assumption that Android and macOS monotonic epochs match.
            repeat(5) {
                val nonce = input.readLong()
                val received = System.nanoTime()
                output.writeLong(nonce); output.writeLong(received); output.writeLong(System.nanoTime()); output.flush()
            }
            baselineRSS = memory("VmRSS")
            output.writeLong(baselineRSS); output.flush()
            check(input.readUnsignedByte() == 1) // Host starts the fresh helper before releasing hello.
            output.write(request.stdin); output.flush()
            val stream = object : AgentRemoteExecStream {
                override val stdout: Flow<ByteArray> = flow {
                    val buffer = ByteArray(65536)
                    while (!closed.get()) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        emit(buffer.copyOf(count))
                    }
                }.flowOn(Dispatchers.IO)
                // A quiet stderr channel stays open for the duplex stream's
                // lifetime. EOF means process termination to the real client.
                override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
                override suspend fun awaitExit(): AgentExecExitStatus { while (!closed.get()) delay(20); return AgentExecExitStatus(0) }
                override suspend fun send(bytes: ByteArray) = withContext(Dispatchers.IO) { output.write(bytes); output.flush() }
                override fun cancel() = this@UnixEndpoint.close()
                override fun close() = cancel()
            }
            AgentEndpointResult.Success(stream)
        }
        override fun close() { if (closed.compareAndSet(false, true)) socket.close() }
        private fun unavailable() = AgentEndpointResult.Unavailable("private read-only fixture")
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> = unavailable()
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> = unavailable()
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

    companion object {
        private fun memory(name: String): Long {
            val line = File("/proc/self/status").useLines { lines -> lines.first { it.startsWith("$name:") } }
            val match = Regex("^${name}:\\s+(\\d+) kB$").matchEntire(line.trim()) ?: error("missing memory measurement")
            return match.groupValues[1].toLong().times(1024).also { check(it > 0) }
        }
    }
}
