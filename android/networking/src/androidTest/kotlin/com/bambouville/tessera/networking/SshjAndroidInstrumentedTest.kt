package com.bambouville.tessera.networking

import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySession
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityActiveWindow
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRuntime
import com.bambouville.tessera.core.bridge.SharedTmuxSubscriptions
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxEvent
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxLaunch
import com.bambouville.tessera.core.bridge.SharedTmuxLaunchFailure
import com.bambouville.tessera.core.bridge.SharedTmuxCommandSubmission
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.KeyPair
import java.security.KeyStore
import java.security.PrivateKey
import java.util.Collections
import java.util.Properties
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.PTYMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SshjAndroidInstrumentedTest {
    @Test
    fun interactiveClientsDoNotExpireIdleTransportReads() {
        SshjClientFactory { true }.create().use { client ->
            assertEquals(0, client.timeout)
        }
    }

    @Test
    fun ed25519EcdsaAndRsaHostKeysWorkDirectAndThroughJump(): Unit = runBlocking {
        val fixture = readFixture()
        val algorithms = linkedMapOf(
            "ssh-ed25519" to "ssh-ed25519",
            "ecdsa-sha2-nistp256" to "ecdsa-sha2-nistp256",
            "rsa-sha2-512" to "ssh-rsa",
        )

        for ((negotiatedAlgorithm, canonicalAlgorithm) in algorithms) {
            val observations = mutableListOf<SshHostKeyObservation>()
            val factory = SshjClientFactory(
                hostKeyPolicy = { observation -> observations += observation; true },
                preferredHostKeyAlgorithms = listOf(negotiatedAlgorithm),
            )
            withPasswordClient(factory, fixture.stableHost, fixture) { direct ->
                assertEquals("direct-$negotiatedAlgorithm", execChecked(direct, "printf direct-$negotiatedAlgorithm"))
                direct.newDirectConnection(fixture.chaosHost, fixture.port).use { tunnel ->
                    factory.create().use { jumped ->
                        jumped.connectVia(tunnel)
                        jumped.authPassword(fixture.user, fixture.password)
                        assertEquals(
                            "jump-$negotiatedAlgorithm",
                            execChecked(jumped, "printf jump-$negotiatedAlgorithm"),
                        )
                    }
                }
            }
            assertEquals(2, observations.size)
            assertTrue(observations.all { it.algorithm == canonicalAlgorithm })
            assertTrue(observations.all { it.canonicalKeyBlob.isNotEmpty() })
        }
        Log.i(
            "TesseraNativeSsh",
            "TESSERA_ANDROID_HOST_KEYS_OK ed25519=1 ecdsa=1 rsa=1 direct=1 jump=1",
        )
    }

    @Test
    fun remoteFilesSideChannelBrowsesMutatesAndTransfers(): Unit = runBlocking {
        val fixture = readFixture()
        val route = SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "files",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        )
        val passwordProvider = SshPasswordProvider { fixture.password.toCharArray() }
        val connection = AndroidSshBackend().connectFiles(
            route,
            passwordProvider,
            SshHostKeyPolicy { true },
        )
        val home = connection.realPath(".")
        val directory = "$home/tessera-files-${fixture.token}"
        val source = "TESSERA_ANDROID_FILES_OK ${fixture.token}".encodeToByteArray()
        try {
            connection.createDirectory(directory)
            connection.upload(ByteArrayInputStream(source), "$directory/source.txt", source.size.toLong()) { _, _ -> }
            assertTrue(connection.list(directory).any { it.name == "source.txt" && it.size == source.size.toLong() })
            connection.rename("$directory/source.txt", "$directory/renamed.txt")
            connection.setPermissions("$directory/renamed.txt", 0x180)
            val destination = ByteArrayOutputStream()
            connection.download("$directory/renamed.txt", destination) { _, _ -> }
            assertTrue(source.contentEquals(destination.toByteArray()))
            connection.removeFile("$directory/renamed.txt")
            connection.removeDirectory(directory)
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_FILES_OK browse=1 upload=1 download=1 mutate=1")
        } finally {
            runCatching { connection.removeFile("$directory/source.txt") }
            runCatching { connection.removeFile("$directory/renamed.txt") }
            runCatching { connection.removeDirectory(directory) }
            connection.close()
        }
    }

    /**
     * Round-trips a multi-megabyte file whose length is not a multiple of any
     * request size. Byte equality proves pipelined requests land at the right
     * offsets; the log line records throughput beside the stop-and-wait
     * ceiling (one 32 KiB request per round trip) for the same link.
     */
    @Test
    fun remoteFilesPipelineLargeTransfers(): Unit = runBlocking {
        val fixture = readFixture()
        val connection = connectFiles(fixture)
        val home = connection.realPath(".")
        val directory = "$home/tessera-files-pipeline-${fixture.token}"
        val remotePath = "$directory/payload.bin"
        val size = 24 * 1024 * 1024 + 12_345
        val source = pseudoRandomBytes(size)
        try {
            val roundTrips = (0 until 5).map {
                val start = System.nanoTime()
                connection.realPath(".")
                (System.nanoTime() - start) / 1e9
            }.sorted()
            connection.createDirectory(directory)

            val uploadProgress = mutableListOf<Pair<Long, Long?>>()
            val uploadStart = System.nanoTime()
            connection.upload(ByteArrayInputStream(source), remotePath, size.toLong()) { done, total ->
                uploadProgress += done to total
            }
            val uploadSeconds = (System.nanoTime() - uploadStart) / 1e9
            assertEquals(size.toLong(), connection.stat(remotePath).size)

            val downloadProgress = mutableListOf<Pair<Long, Long?>>()
            val destination = ByteArrayOutputStream(size)
            val downloadStart = System.nanoTime()
            connection.download(remotePath, destination) { done, total -> downloadProgress += done to total }
            val downloadSeconds = (System.nanoTime() - downloadStart) / 1e9
            assertTrue("downloaded bytes differ", source.contentEquals(destination.toByteArray()))

            for ((name, log) in listOf("upload" to uploadProgress, "download" to downloadProgress)) {
                val values = log.map { it.first }
                assertEquals("$name progress must end at the file size", size.toLong(), values.last())
                assertEquals("$name progress must not go backwards", values.sorted(), values)
                assertTrue("$name progress total", log.all { it.second == size.toLong() })
                assertTrue(
                    "$name progress must report before the end",
                    values.any { it > 0 && it < size.toLong() },
                )
            }

            val megabytes = size / 1_000_000.0
            val roundTrip = roundTrips[roundTrips.size / 2]
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_FILES_PIPELINE bytes=$size " +
                    "rtt_ms=${"%.1f".format(roundTrip * 1000)} " +
                    "upload_MBps=${"%.2f".format(megabytes / uploadSeconds)} " +
                    "download_MBps=${"%.2f".format(megabytes / downloadSeconds)} " +
                    "stop_and_wait_upload_ceiling_MBps=${"%.2f".format(0.032 / roundTrip)}",
            )
        } finally {
            runCatching { connection.removeFile(remotePath) }
            runCatching { connection.removeDirectory(directory) }
            connection.close()
        }
    }

    /**
     * Browsing shares the SFTP channel with a running transfer, so a listing
     * waits behind whatever the transfer has queued. Through a 10 Mbit/s
     * relay a fixed 2 MiB queue holds each of the listing's requests for
     * 1.6 s, until the transfer ends; the adaptive window keeps the whole
     * listing near a second. On a fast link it passes trivially.
     */
    @Test
    fun remoteFilesListPromptlyDuringTransfers(): Unit = runBlocking {
        val fixture = readFixture()
        val connection = connectFiles(fixture)
        val home = connection.realPath(".")
        val directory = "$home/tessera-files-responsive-${fixture.token}"
        val remotePath = "$directory/payload.bin"
        val size = 16 * 1024 * 1024
        val source = pseudoRandomBytes(size)
        try {
            connection.createDirectory(directory)
            val idleListing = (0 until 3).map {
                val start = System.nanoTime()
                connection.list(directory)
                (System.nanoTime() - start) / 1e9
            }.sorted()[1]

            val uploaded = AtomicLong()
            val upload = async {
                connection.upload(ByteArrayInputStream(source), remotePath, size.toLong()) { done, _ ->
                    uploaded.set(done)
                }
            }
            val duringUpload = timeListing(connection, directory, uploaded, size)
            upload.await()

            val downloaded = AtomicLong()
            val destination = ByteArrayOutputStream(size)
            val download = async {
                connection.download(remotePath, destination) { done, _ -> downloaded.set(done) }
            }
            val duringDownload = timeListing(connection, directory, downloaded, size)
            download.await()
            assertTrue("downloaded bytes differ", source.contentEquals(destination.toByteArray()))

            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_FILES_RESPONSIVE " +
                    "idle_list_ms=${"%.0f".format(idleListing * 1000)} " +
                    "upload_list_ms=${"%.0f".format(duringUpload.first * 1000)} " +
                    "upload_overlapped=${if (duringUpload.second) 1 else 0} " +
                    "download_list_ms=${"%.0f".format(duringDownload.first * 1000)} " +
                    "download_overlapped=${if (duringDownload.second) 1 else 0}",
            )
            for ((name, listing) in listOf("upload" to duringUpload, "download" to duringDownload)) {
                assertTrue("listing waited behind the $name's queue: ${listing.first} s", listing.first < 4.0)
            }
        } finally {
            runCatching { connection.removeFile(remotePath) }
            runCatching { connection.removeDirectory(directory) }
            connection.close()
        }
    }

    /**
     * Lists [directory] once the transfer has 2 MB behind it, so its window
     * has adapted. The flag says the transfer was still running when the
     * listing returned.
     */
    private suspend fun timeListing(
        connection: SshFileConnection,
        directory: String,
        progress: AtomicLong,
        size: Int,
    ): Pair<Double, Boolean> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(120)
        while (progress.get() < 2_000_000 && System.nanoTime() < deadline) delay(20)
        val start = System.nanoTime()
        connection.list(directory)
        return (System.nanoTime() - start) / 1e9 to (progress.get() < size)
    }

    private suspend fun connectFiles(fixture: Fixture): SshFileConnection = AndroidSshBackend().connectFiles(
        SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "files",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        ),
        SshPasswordProvider { fixture.password.toCharArray() },
        SshHostKeyPolicy { true },
    )

    /** xorshift64 bytes: incompressible and position-dependent. */
    private fun pseudoRandomBytes(size: Int): ByteArray = ByteArray(size).also { bytes ->
        var state = -0x61c8864680b583ebL
        for (index in bytes.indices) {
            state = state xor (state shl 13)
            state = state xor (state ushr 7)
            state = state xor (state shl 17)
            bytes[index] = state.toByte()
        }
    }

    /**
     * The reporter's crash-on-connect was a macOS host whose sshd shell cannot
     * see Homebrew's tmux: the control channel exited 127 without ever emitting
     * a control frame, and the session went to Terminated. This is that host,
     * as a fixture — the `tessera-notmux` account has no tmux on its PATH.
     *
     * Asserted here is the seam the degrade decision rests on: control mode
     * never engaged, and the *shared* classifier — reached over the real JNI
     * bridge, not a Kotlin reimplementation — calls it `UNAVAILABLE`.
     */
    @Test
    fun tmuxLaunchOnAHostWithoutTmuxClassifiesAsUnavailable(): Unit = runBlocking {
        val fixture = readFixture()
        val target = "tessera-${fixture.token}".replace(Regex("[^A-Za-z0-9_.:-]"), "-").take(80)
        val connection = AndroidSshBackend().connectTmux(
            request = SshRouteRequest(
                listOf(
                    SshRouteHop(
                        id = "tmux-missing",
                        endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                        username = fixture.notmuxUser,
                        authentication = SshAuthentication.Password,
                    ),
                ),
            ),
            sessionTarget = target,
            passwordProvider = SshPasswordProvider { fixture.password.toCharArray() },
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        try {
            val output = StringBuilder()
            var engaged = false
            withContext(Dispatchers.IO) {
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val count = connection.standardOutput.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        val text = String(buffer, 0, count, Charsets.UTF_8)
                        output.append(text)
                        if (text.contains("\u001bP1000p") || text.contains("%begin")) engaged = true
                    }
                }
                val errors = ByteArray(16 * 1024)
                while (true) {
                    val count = connection.standardError.read(errors)
                    if (count < 0) break
                    if (count > 0) output.append(String(errors, 0, count, Charsets.UTF_8))
                }
            }
            val exitStatus = connection.awaitRemoteExitStatus()
            assertFalse("control mode must never engage on a host without tmux", engaged)
            val failure = SharedTmuxLaunch.classifyFailure(exitStatus, output.toString())
            assertEquals(
                "shared classifier verdict for $exitStatus / ${output.toString().take(120)}",
                SharedTmuxLaunchFailure.UNAVAILABLE,
                failure,
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_TMUX_DEGRADE_OK notEngaged=1 classified=unavailable sharedCore=1",
            )
        } finally {
            connection.close()
        }
    }

    @Test
    fun tmuxControlModeUsesSharedTopologyRuntime(): Unit = runBlocking {
        val fixture = readFixture()
        val target = "tessera-${fixture.token}".replace(Regex("[^A-Za-z0-9_.:-]"), "-").take(80)
        val events = Channel<SharedTmuxSnapshot>(Channel.UNLIMITED)
        val parser = SharedTmuxRuntime.create { event -> events.trySend(event.snapshot) }
        val connection = AndroidSshBackend().connectTmux(
            request = SshRouteRequest(
                listOf(
                    SshRouteHop(
                        id = "tmux",
                        endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                        username = fixture.user,
                        authentication = SshAuthentication.Password,
                    ),
                ),
            ),
            sessionTarget = target,
            passwordProvider = SshPasswordProvider { fixture.password.toCharArray() },
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        val reader = launch(Dispatchers.IO) {
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = connection.standardOutput.read(buffer)
                if (count < 0) break
                if (count > 0) parser.feed(buffer.copyOf(count))
            }
        }
        try {
            val attached = events.awaitSnapshot { it.sessionName == target && it.windows.isNotEmpty() }
            // Product startup immediately projects the terminal geometry through refresh-client;
            // tmux answers with the authoritative layout carrying pane IDs.
            connection.sendControl("refresh-client -C 90,30")
            events.awaitSnapshot { it.activePaneId != null }
            connection.sendControl("new-window -n android-second")
            connection.sendControl("refresh-client -C 91,31")
            val second = events.awaitSnapshot { it.windows.size >= 2 && it.activePaneId != null }
            val pane = requireNotNull(second.activePaneId)
            connection.sendControl("split-window -h -t %$pane")
            val split = events.awaitSnapshot { (it.activeWindow?.panes?.size ?: 0) >= 2 }
            assertEquals(target, attached.sessionName)
            assertTrue(split.activeWindow!!.panes.size >= 2)
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_TMUX_OK attach=1 create=1 split=1 sharedCore=1")
        } finally {
            runCatching { connection.sendControl("kill-session -t $target") }
            connection.close()
            reader.cancel()
            parser.close()
            withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
                runCatching { execChecked(client, "tmux kill-session -t '$target' 2>/dev/null || true") }
            }
        }
    }

    /**
     * Live proof of the take-back contest and the window label, against a real
     * tmux server. A second device is simulated by writing `@tessera_authority`
     * from a plain ssh side channel, which is exactly what a peer's claim does.
     *
     * Both behaviours regressed because a client cannot tell "a peer holds the
     * grid" from "a peer just took it" by looking at authority state, and
     * because tmux never announces a pane title change.
     */
    @Test
    fun tmuxTakeBackContestAndWindowLabelFollowLiveServerState(): Unit = runBlocking {
        val fixture = readFixture()
        val target = "tessera-authority-${fixture.token}"
            .replace(Regex("[^A-Za-z0-9_.:-]"), "-")
            .take(80)
        val route = SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "tmux-authority",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        )
        val password = SshPasswordProvider { fixture.password.toCharArray() }
        withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
            execChecked(
                client,
                "tmux kill-session -t '$target' 2>/dev/null || true; " +
                    "tmux new-session -d -x 120 -y 40 -s '$target'; " +
                    "tmux rename-window -t '$target' shell",
            )
        }

        val events = Channel<SharedTmuxEvent>(Channel.UNLIMITED)
        // The shared session classifies the raw stamp edges, as the adapter's does;
        // reduced on the reader before each event is queued, so an awaited event's
        // edges are already classified. Its clock stands still: no deadline may
        // fire while the server is slow, and its reads are never answered.
        val authority = SharedTmuxAuthoritySession.create(initialGeneration = 0)
        authority.attached(0, "android-authority-device")
        val classified = Collections.synchronizedList(mutableListOf<SharedTmuxGridAuthoritySnapshot>())
        val parser = SharedTmuxRuntime.create { event ->
            if (event.authorityStamps.isNotEmpty()) {
                authority.stampsObserved(0, event.authorityStamps).effects
                    .filterIsInstance<SharedTmuxAuthoritySessionEffect.AuthorityChanged>()
                    .forEach { classified += it.authority }
            }
            events.trySend(event)
        }
        val connection = AndroidSshBackend().connectTmux(
            request = route,
            sessionTarget = target,
            preserveInitialGeometry = false,
            passwordProvider = password,
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        val reader = launchTmuxReader(connection, parser)
        fun confirmFence(generation: Long, windowId: Int) {
            if (authority.state.claim?.targetGrid == null) {
                authority.claimAdvertisedGeometry(0, generation, 120, 40)
            }
            val targetGrid = requireNotNull(authority.state.claim?.targetGrid)
            authority.claimFenceSent(0, generation, windowId)
            val fenceId = requireNotNull(authority.state.claimFence).id
            authority.claimFenceAcknowledged(0, fenceId)
            authority.windowSizePolicyReplied(0, windowId, "latest", fenceId)
            authority.windowFacts(0, true, SharedTmuxAuthorityActiveWindow(windowId, targetGrid, true))
            authority.confirmClaimFence(0)
            assertEquals(generation, authority.state.claim?.generation)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, authority.state.claim?.phase)
        }
        suspend fun sendCorrelatedControl(command: String) {
            assertTrue(
                "shared tmux FIFO rejected test command: $command",
                parser.sendCommand(command) is SharedTmuxCommandSubmission.Accepted,
            )
            connection.sendControl(command)
        }
        // Stand in for a second device claiming the grid. The read-back keeps a
        // subscription that never fires distinguishable from a write that never
        // landed. tmux evaluates subscriptions on its client loop, so the
        // control client is nudged afterwards — in the product a session is
        // never this idle, but a fixture with no output is.
        suspend fun plantStamp(value: String) {
            withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
                execChecked(client, "tmux set-option -t '$target' @tessera_authority '$value'")
                val readBack = execChecked(
                    client,
                    "tmux show-options -v -t '$target' @tessera_authority",
                ).trim()
                assertEquals("the peer stamp must be on the server", value, readBack)
            }
            // tmux evaluates subscriptions on its client loop. A fixture
            // session with no output is far quieter than any real one, so give
            // the server something to process before waiting on a push.
            sendCorrelatedControl("refresh-client")
            withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
                runCatching { execChecked(client, "tmux display-message -t '$target' -p '#{session_id}'") }
            }
        }
        try {
            SharedTmuxCommands.hydrationCommands().forEach { sendCorrelatedControl(it) }
            sendCorrelatedControl("refresh-client -C 120,40")
            // The list-windows reply can land before the active-window reply,
            // and activePaneId then falls back to the first window's pane while
            // activeWindowId is still null. The fence below needs tmux's own
            // answer for the active window.
            val attached = events.awaitEvent("attach") {
                it.snapshot.sessionName == target && it.snapshot.activePaneId != null &&
                    it.snapshot.isActiveWindowAuthoritative && it.snapshot.activeWindowId != null
            }
            // Production anchors the session-level feeds on one window, which
            // tmux reports with a `-` pane field.
            val windowId = requireNotNull(attached.snapshot.activeWindowId)
            sendCorrelatedControl("refresh-client -B 'tessera-authority:@$windowId:#{@tessera_authority}'")
            assertEquals(CoreCallResult.Accepted, parser.setSubscriptions(SharedTmuxSubscriptions(paneMetadata = true)))
            val subscriptions = events.awaitEvent("pane metadata subscription") { it.subscriptionCommands.isNotEmpty() }
            subscriptions.subscriptionCommands.forEach { sendCorrelatedControl(it) }

            // A peer takes the grid.
            plantStamp("v1 peer-ipad 7 iPad")
            events.awaitEvent("peer stamp") { it.hasForeignAuthorityStamp() }
            val peer = SharedTmuxGridAuthoritySnapshot.Peer("peer-ipad", "iPad", 7)
            assertEquals(listOf(peer), classified.toList())

            // Take the grid back in the session, as the adapter does, as far as
            // the stamp write, which re-arms the session's raw memo.
            authority.adoptShown(0)
            val claim = authority.requestTakeBack(0).effects
                .filterIsInstance<SharedTmuxAuthoritySessionEffect.BeginClaim>().single()
            confirmFence(claim.generation, requireNotNull(attached.snapshot.activeWindowId))
            assertTrue(
                authority.repaintSucceeded(0, claim.generation).effects
                    .contains(SharedTmuxAuthoritySessionEffect.CommitAuthorityStamp(claim.generation)),
            )

            // The regression: a take-back replays geometry and re-arms the
            // subscription, which makes tmux refire the standing stamp, now in
            // a read of its own that the runtime reports. That replay must NOT
            // read as a second takeover, or every reclaim aborts before it can
            // settle.
            sendCorrelatedControl("refresh-client -C 100,36")
            sendCorrelatedControl("refresh-client -B 'tessera-authority:@$windowId:#{@tessera_authority}'")
            events.awaitEvent("standing stamp replay") { "v1 peer-ipad 7 iPad" in it.authorityStamps }
            assertEquals("an unchanged stamp replay must not read as a new takeover", listOf(peer), classified.toList())
            assertEquals("the replay must not end the claim", claim.generation, authority.state.claim?.generation)

            // A genuine re-claim by the peer carries a new generation, and must
            // still fold a claim back.
            plantStamp("v1 peer-ipad 8 iPad")
            val restamped = events.awaitEvent("peer re-stamp") { event ->
                Log.i(
                    "TesseraNativeSsh",
                    "authority-probe arrived=${event.hasForeignAuthorityStamp()} " +
                        "classified=${classified.size}",
                )
                "v1 peer-ipad 8 iPad" in event.authorityStamps
            }
            assertEquals("shell", restamped.snapshot.activeWindow?.name)
            assertEquals(
                "the replay never classified; the re-stamp did, once",
                listOf(peer, SharedTmuxGridAuthoritySnapshot.Peer("peer-ipad", "iPad", 8)),
                classified.toList(),
            )
            assertNull("a newer peer stamp folds the claim back", authority.state.claim)

            // The window label follows the live pane title, which tmux never
            // announces — only the subscription reports it. `select-pane -T`
            // sets `#{pane_title}` server-side, which is what an OSC 2 from the
            // remote shell does, without depending on a shell being ready.
            sendCorrelatedControl("select-pane -T 'vim README'")
            val retitled = events.awaitEvent("pane title label") {
                it.snapshot.activeWindow?.displayName == "vim README"
            }
            assertEquals(
                "the raw tmux window name must be untouched by a pane title",
                "shell",
                retitled.snapshot.activeWindow?.name,
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_TMUX_AUTHORITY_OK stampReplayInert=1 restampDetected=1 " +
                    "paneTitleLabel=1 sharedCore=1",
            )
        } finally {
            runCatching { connection.sendControl("kill-session -t $target") }
            connection.close()
            reader.cancel()
            parser.close()
            authority.close()
            withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
                runCatching { execChecked(client, "tmux kill-session -t '$target' 2>/dev/null || true") }
            }
        }
    }

    @Test
    fun compactTmuxProjectionPreservesSplitAcrossLargerReattach(): Unit = runBlocking {
        val fixture = readFixture()
        val target = "tessera-geometry-${fixture.token}"
            .replace(Regex("[^A-Za-z0-9_.:-]"), "-")
            .take(80)
        val route = SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "tmux-geometry",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        )
        val password = SshPasswordProvider { fixture.password.toCharArray() }
        withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
            execChecked(
                client,
                "tmux kill-session -t '$target' 2>/dev/null || true; " +
                    "tmux new-session -d -x 160 -y 50 -s '$target'; " +
                    "tmux split-window -h -t '$target'",
            )
        }

        val phoneEvents = Channel<SharedTmuxSnapshot>(Channel.UNLIMITED)
        val phoneParser = SharedTmuxRuntime.create { event ->
            phoneEvents.trySend(event.snapshot)
        }
        val phone = AndroidSshBackend().connectTmux(
            request = route,
            sessionTarget = target,
            preserveInitialGeometry = true,
            passwordProvider = password,
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        val phoneReader = launchTmuxReader(phone, phoneParser)
        var tablet: SshTmuxConnection? = null
        var tabletParser: SharedTmuxRuntime? = null
        var tabletReader: kotlinx.coroutines.Job? = null
        try {
            hydrateTmux(phone)
            val inherited = phoneEvents.awaitSnapshot("inherited split") {
                it.sessionName == target && it.activeWindow?.panes?.size == 2
            }
            val inheritedWindow = requireNotNull(inherited.activeWindow)
            val inheritedLayout = requireNotNull(inheritedWindow.layout)
            val inheritedSize = inheritedLayout.gridSize()
            val paneIds = inheritedWindow.panes.map { it.id }.toSet()
            assertEquals(160, inheritedSize.columns)
            assertTrue(inheritedSize.rows >= 48)

            // Capability check for the ceded-observer state only: a client
            // that has yielded the grid adopts the complete canvas while
            // remaining ignore-size, and cannot resize the shared layout.
            // Product attaches do NOT request this — a compact client is a
            // sizing participant that advertises its projected canvas.
            phone.sendControl("refresh-client -C ${inheritedSize.columns},${inheritedSize.rows}")
            assertEquals(inheritedSize, inherited.activeWindow!!.layout!!.gridSize())
            assertEquals(paneIds, inherited.activeWindow!!.panes.map { it.id }.toSet())

            val tabletEvents = Channel<SharedTmuxSnapshot>(Channel.UNLIMITED)
            tabletParser = SharedTmuxRuntime.create { event ->
                tabletEvents.trySend(event.snapshot)
            }
            tablet = AndroidSshBackend().connectTmux(
                request = route,
                sessionTarget = target,
                preserveInitialGeometry = false,
                passwordProvider = password,
                hostKeyPolicy = SshHostKeyPolicy { true },
            )
            tabletReader = launchTmuxReader(tablet, tabletParser)
            tablet.sendControl("refresh-client -C 160,50")
            hydrateTmux(tablet)
            val restored = tabletEvents.awaitSnapshot("larger reattach") {
                it.activeWindow?.layout?.gridSize() == inheritedSize
            }
            assertEquals(paneIds, restored.activeWindow!!.panes.map { it.id }.toSet())
            assertTrue(restored.activeWindow!!.layout is SharedTmuxLayoutNode.Split)
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_TMUX_GEOMETRY_OK geometryNeutral=1 splitPreserved=1 largerReattach=1 sharedCore=1",
            )
        } finally {
            runCatching { phone.sendControl("kill-session -t $target") }
            tablet?.close()
            tabletReader?.cancel()
            tabletParser?.close()
            phone.close()
            phoneReader.cancel()
            phoneParser.close()
            withPasswordClient(SshjClientFactory { true }, fixture.stableHost, fixture) { client ->
                runCatching { execChecked(client, "tmux kill-session -t '$target' 2>/dev/null || true") }
            }
        }
    }

    @Test
    fun passwordBackendStreamsInteractivePty() {
        runBlocking {
            val fixture = readFixture()
            val observations = mutableListOf<SshHostKeyObservation>()
            val password = fixture.password.toCharArray()
            val connection = AndroidSshBackend().connectPassword(
                request = SshPasswordRequest(
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    password = password,
                    initialColumns = 80,
                    initialRows = 24,
                ),
                hostKeyPolicy = SshHostKeyPolicy { observation ->
                    observations += observation
                    true
                },
            )
            try {
                assertTrue("product adapter did not wipe the password", password.all { it == '\u0000' })
                connection.resize(132, 43)
                connection.write("stty size; printf TESSERA_PRODUCT_PTY_OK; exit\n".encodeToByteArray())
                val output = withContext(Dispatchers.IO) {
                    connection.standardOutput.bufferedReader().readText()
                }
                assertTrue(output.contains("43 132"))
                assertTrue(output.contains("TESSERA_PRODUCT_PTY_OK"))
                assertTrue(observations.single().canonicalKeyBlob.isNotEmpty())
                Log.i(
                    "TesseraNativeSsh",
                    "TESSERA_ANDROID_SSH_BACKEND_OK password=1 passwordWiped=1 " +
                        "pty=1 resize=1 hostKey=1",
                )
            } finally {
                connection.close()
            }
        }
    }

    @Test
    fun keystoreP256SupportsDirectPtyResizeAndOrderedJump() {
        val fixture = readFixture()
        val store = AndroidKeystoreCredentialStore()
        val token = fixture.token
        val alias = "tessera-native-ssh-$token"
        val marker = "tessera-phase-a-$token"
        val credential = store.generateP256(
            alias = alias,
            ownerAuthenticationRequired = false,
        )
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val privateKey = keyStore.getKey(alias, null) as PrivateKey
        val publicKey = keyStore.getCertificate(alias).publicKey
        val keyPair = KeyPair(publicKey, privateKey)
        val authorizedKey = "ecdsa-sha2-nistp256 " +
            Base64.encodeToString(credential.publicKeyBlob, Base64.NO_WRAP) + " $marker"
        val observations = mutableListOf<SshHostKeyObservation>()
        val factory = SshjClientFactory { observation ->
            observations += observation
            true // Experiment only: product trust UI/persistence remains above this boundary.
        }
        val installedHosts = mutableListOf<String>()

        assertFalse("Android Keystore private key became exportable", privateKey.encoded != null)
        try {
            for (host in listOf(fixture.stableHost, fixture.chaosHost)) {
                withPasswordClient(factory, host, fixture) { client ->
                    execChecked(client, installKeyCommand(authorizedKey))
                }
                installedHosts += host
            }

            factory.create().use { direct ->
                direct.connect(fixture.stableHost, fixture.port)
                direct.authPublickey(fixture.user, direct.loadKeys(keyPair))
                assertEquals("TESSERA_SSHJ_EXEC_OK", execChecked(direct, "printf TESSERA_SSHJ_EXEC_OK"))
                assertTrue("resized PTY did not report 43x132", ptyResize(direct).contains("43 132"))

                direct.newDirectConnection(fixture.chaosHost, fixture.port).use { tunnel ->
                    factory.create().use { jumped ->
                        jumped.connectVia(tunnel)
                        jumped.authPublickey(fixture.user, jumped.loadKeys(keyPair))
                        assertEquals(
                            "TESSERA_SSHJ_JUMP_OK",
                            execChecked(jumped, "printf TESSERA_SSHJ_JUMP_OK"),
                        )
                    }
                }
            }

            assertTrue("direct and jump host keys were not observed", observations.size >= 2)
            assertTrue(observations.all { it.canonicalKeyBlob.isNotEmpty() })
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_SSHJ_ANDROID_OK direct=1 exec=1 pty=1 resize=1 jump=1 " +
                    "hostKeys=${observations.size} exportable=false",
            )
        } finally {
            val cleanupFailures = mutableListOf<Throwable>()
            for (host in installedHosts.asReversed()) {
                try {
                    withPasswordClient(factory, host, fixture) { client ->
                        execChecked(client, removeKeyCommand(marker))
                    }
                } catch (error: Throwable) {
                    cleanupFailures += error
                }
            }
            store.delete(alias)
            if (cleanupFailures.isNotEmpty()) {
                throw AssertionError("failed to remove temporary fixture keys", cleanupFailures.first())
            }
        }
    }

    private fun withPasswordClient(
        factory: SshjClientFactory,
        host: String,
        fixture: Fixture,
        action: (SSHClient) -> Unit,
    ) {
        factory.create().use { client ->
            client.connect(host, fixture.port)
            client.authPassword(fixture.user, fixture.password)
            action(client)
        }
    }

    private fun execChecked(client: SSHClient, command: String): String =
        client.startSession().use { session ->
            session.exec(command).use { process ->
                val output = process.inputStream.bufferedReader().readText().trim()
                val error = process.errorStream.bufferedReader().readText().trim()
                process.join(20, TimeUnit.SECONDS)
                check(process.exitStatus == 0) {
                    "remote command failed (${process.exitStatus}): $error"
                }
                output
            }
        }

    private fun ptyResize(client: SSHClient): String =
        client.startSession().use { session ->
            session.allocatePTY("xterm-256color", 80, 24, 0, 0, emptyMap<PTYMode, Int>())
            session.startShell().use { shell ->
                shell.changeWindowDimensions(132, 43, 0, 0)
                shell.outputStream.write("stty size; printf TESSERA_PTY_DONE; exit\n".encodeToByteArray())
                shell.outputStream.flush()
                val output = shell.inputStream.bufferedReader().readText()
                shell.join(20, TimeUnit.SECONDS)
                check(output.contains("TESSERA_PTY_DONE")) { "PTY shell did not finish cleanly" }
                output
            }
        }

    private fun installKeyCommand(line: String): String =
        "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; " +
            "grep -Fqx '$line' ~/.ssh/authorized_keys || printf '%s\\n' '$line' >> ~/.ssh/authorized_keys"

    private fun removeKeyCommand(marker: String): String =
        "if [ -f ~/.ssh/authorized_keys ]; then " +
            "grep -v '$marker$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tessera-tmp || true; " +
            "mv ~/.ssh/authorized_keys.tessera-tmp ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; fi"

    private fun readFixture(): Fixture {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val descriptor = automation.executeShellCommand("cat $FIXTURE_PATH")
        val properties = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            Properties().apply { load(input) }
        }
        fun required(name: String): String =
            properties.getProperty(name)?.takeIf { it.isNotBlank() }
                ?: error("missing native SSH fixture property: $name")
        return Fixture(
            stableHost = required("stableHost"),
            chaosHost = required("chaosHost"),
            port = required("port").toInt(),
            user = required("user"),
            notmuxUser = required("notmuxUser"),
            password = String(Base64.decode(required("passwordBase64"), Base64.DEFAULT)),
            token = required("token"),
        )
    }

    private data class Fixture(
        val stableHost: String,
        val chaosHost: String,
        val port: Int,
        val user: String,
        val notmuxUser: String,
        val password: String,
        val token: String,
    )

    /**
     * A timeout here has to name *why*. The gate only dumps logcat after the
     * Gradle task returns, so a failing assertion is the one channel that
     * reaches the run log: "no events at all" (the server pushed nothing) and
     * "events but no arrival" (the stamp edge was lost crossing the ABI) are
     * different bugs and must not look alike.
     */
    private fun SharedTmuxEvent.hasForeignAuthorityStamp(): Boolean = authorityStamps.any { raw ->
        val parts = raw.trim().split(Regex("\\s+"), limit = 4)
        parts.size == 4 && parts[0] == "v1" && parts[2].toLongOrNull() != null && parts[1] != "android-authority-device"
    }

    private suspend fun Channel<SharedTmuxEvent>.awaitEvent(
        label: String,
        predicate: (SharedTmuxEvent) -> Boolean,
    ): SharedTmuxEvent {
        var seen = 0
        var arrivals = 0
        var lastAuthority: String? = null
        return try {
            withTimeout(20_000L) {
                while (true) {
                    val value = receive()
                    seen += 1
                    if (value.hasForeignAuthorityStamp()) arrivals += 1
                    lastAuthority = value.snapshot.authority.toString()
                    if (predicate(value)) return@withTimeout value
                }
                error("unreachable")
            }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError(
                "timed out waiting for $label " +
                    "(events=$seen arrivals=$arrivals authority=$lastAuthority)",
                failure,
            )
        }
    }

    private suspend fun Channel<SharedTmuxSnapshot>.awaitSnapshot(
        label: String = "tmux state",
        predicate: (SharedTmuxSnapshot) -> Boolean,
    ): SharedTmuxSnapshot {
        var last: SharedTmuxSnapshot? = null
        return try {
            withTimeout(20_000L) {
                while (true) {
                    val value = receive()
                    last = value
                    if (predicate(value)) return@withTimeout value
                }
                error("unreachable")
            }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("timed out waiting for $label; last snapshot=$last", failure)
        }
    }

    private fun CoroutineScope.launchTmuxReader(
        connection: SshTmuxConnection,
        parser: SharedTmuxRuntime,
    ): Job = launch(Dispatchers.IO) {
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val count = connection.standardOutput.read(buffer)
            if (count < 0) break
            if (count > 0) parser.feed(buffer.copyOf(count))
        }
    }

    private suspend fun hydrateTmux(connection: SshTmuxConnection) {
        SharedTmuxCommands.hydrationCommands().forEach { connection.sendControl(it) }
    }

    private fun SharedTmuxLayoutNode.gridSize(): SharedTmuxGridSize = when (this) {
        is SharedTmuxLayoutNode.Leaf -> SharedTmuxGridSize(width, height)
        is SharedTmuxLayoutNode.Split -> SharedTmuxGridSize(width, height)
    }

    private fun SharedTmuxLayoutNode.findPane(paneId: Int?): SharedTmuxLayoutNode.Leaf? = when (this) {
        is SharedTmuxLayoutNode.Leaf -> takeIf { paneId == null || it.paneId == paneId }
        is SharedTmuxLayoutNode.Split -> children.firstNotNullOfOrNull { it.findPane(paneId) }
    }

    companion object {
        private const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties"
    }
}
