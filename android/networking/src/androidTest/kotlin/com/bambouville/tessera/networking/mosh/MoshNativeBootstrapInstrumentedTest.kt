package com.bambouville.tessera.networking.mosh

import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedMoshBootstrapFailure
import com.bambouville.tessera.core.bridge.SharedMoshConnectResult
import com.bambouville.tessera.core.bridge.SharedMoshGrammar
import com.bambouville.tessera.core.bridge.SharedMoshServerLiveness
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.NextProbe
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.Outcome
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import java.net.InetAddress
import java.util.Properties
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The two ways a Mosh host that works from every shell the user can see still
 * failed from this app, proven on the real native client and a real host:
 *
 * 1. the vendored client only dials a numeric UDP target, so a host saved by
 *    DNS name must be resolved by the shared core before `start()`;
 * 2. the SSH exec channel runs a non-login shell, so `mosh-server` on a
 *    login-only PATH (Homebrew, Nix, `~/.local/bin`) must be reached through
 *    the login shell by the shared bootstrap command itself.
 */
@RunWith(AndroidJUnit4::class)
class MoshNativeBootstrapInstrumentedTest {
    @Test
    fun sharedServerLivenessMatchesSwiftGrammar() {
        assertEquals(
            "sh -c 'pid=4321; " +
                "if ! kill -0 \"\$pid\" 2>/dev/null; then echo TESSERA_MOSH_SERVER=gone; exit 0; fi; " +
                "c=\$(ps -p \"\$pid\" -o comm= 2>/dev/null); " +
                "case \"\$c\" in " +
                "*mosh-server*) echo TESSERA_MOSH_SERVER=alive;; " +
                "*[![:space:]]*) echo TESSERA_MOSH_SERVER=gone;; " +
                "*) echo TESSERA_MOSH_SERVER=unknown;; esac'",
            SharedMoshGrammar.serverLivenessScript(4321),
        )
        assertEquals(SharedMoshServerLiveness.GONE, SharedMoshGrammar.serverLiveness("TESSERA_MOSH_SERVER=gone\n"))
    }

    @Test
    fun sharedServerLivenessTimingMatchesSwiftPolicy() {
        assertEquals(3_000L, SharedMoshServerLivenessPolicy.graceMillis())
        assertEquals(
            listOf(2_000L, 4_000L, 8_000L, 15_000L, 15_000L, 15_000L, 15_000L, 30_000L, 30_000L, 60_000L, 60_000L)
                .map { NextProbe.After(it) },
            (1..11).map { SharedMoshServerLivenessPolicy.nextProbe(Outcome.HOST_UNREACHABLE, it, false) },
        )
        assertEquals(NextProbe.After(60_000), SharedMoshServerLivenessPolicy.nextProbe(Outcome.ALIVE, 0, false))
        assertEquals(NextProbe.After(60_000), SharedMoshServerLivenessPolicy.nextProbe(Outcome.UNKNOWN, 0, false))
        assertEquals(NextProbe.None, SharedMoshServerLivenessPolicy.nextProbe(Outcome.GONE, 0, false))
        // After an owner-authorization challenge: a slow timer for an unreachable host, a wake otherwise.
        assertEquals(NextProbe.After(60_000), SharedMoshServerLivenessPolicy.nextProbe(Outcome.HOST_UNREACHABLE, 1, true))
        assertEquals(NextProbe.OnWake, SharedMoshServerLivenessPolicy.nextProbe(Outcome.ALIVE, 0, true))
        assertEquals(NextProbe.OnWake, SharedMoshServerLivenessPolicy.nextProbe(Outcome.UNKNOWN, 0, true))
        assertEquals(NextProbe.None, SharedMoshServerLivenessPolicy.nextProbe(Outcome.GONE, 0, true))
    }

    @Test
    fun nativeClientResolvesAHostNameAndRejectsAnUnresolvableOne() {
        assumeTrue("native Mosh is required for this lane", JniMoshNativeClientFactory.isAvailable)
        val key = "qiXpjXIk6M8/nWtBn9s6rQ".encodeToByteArray()

        val resolved = JniMoshNativeClientFactory.create("localhost", 60_001, key.copyOf()) { }
        try {
            resolved.resize(80, 24)
            resolved.start()
            assertFalse("nothing listens on localhost:60001", resolved.connected)
        } finally {
            resolved.close()
        }

        val unresolvable = JniMoshNativeClientFactory.create("tessera-no-such-host.invalid", 60_001, key.copyOf()) { }
        val failure = try {
            unresolvable.start()
            null
        } catch (expected: IllegalStateException) {
            expected
        } finally {
            unresolvable.close()
        }
        assertNotNull("an unresolvable name must fail start(), not dial nothing", failure)
        assertTrue(failure!!.message.orEmpty(), failure.message.orEmpty().contains("Could not resolve the mosh host"))
        Log.i(TAG, "TESSERA_ANDROID_MOSH_TARGET_OK resolvedName=1 unresolvableRejected=1 sharedCore=1")
    }

    @Test
    fun bootstrapReachesMoshServerOnALoginOnlyPathAndConnects(): Unit = runBlocking {
        assumeTrue("native Mosh is required for this lane", JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val backend = AndroidSshBackend()
        val request = SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "mosh-bootstrap",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        )
        val passwordProvider = SshPasswordProvider { fixture.password.toCharArray() }
        val hostKeyPolicy = SshHostKeyPolicy { true }

        // First prove the trap is real on this host: with the exec channel's
        // PATH reduced to a directory holding only `sh`, the bare invocation
        // fails exactly the way a login-only PATH does.
        val bare = backend.executeRouteCommand(
            request = request,
            commandText = onLoginOnlyPath("mosh-server new"),
            passwordProvider = passwordProvider,
            hostKeyPolicy = hostKeyPolicy,
        )
        val bareOutcome = SharedMoshGrammar.parseConnectResponse(bare.standardOutput, bare.standardError)
        assertEquals(
            "hiding PATH must reproduce the login-only failure; stdout=${bare.standardOutput} stderr=${bare.standardError}",
            SharedMoshConnectResult.Failure(SharedMoshBootstrapFailure.MissingServer),
            bareOutcome,
        )

        // Then the shared command, byte for byte what the app sends, on the
        // same reduced PATH: the probe misses, the login shell restores PATH,
        // mosh-server starts.
        val bootstrapper = MoshBootstrapper { bootstrapRequest ->
            val transcript = backend.executeRouteCommand(
                request = bootstrapRequest.route,
                commandText = onLoginOnlyPath(SharedMoshGrammar.serverNewCommand(bootstrapRequest.launchCommand)),
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
            )
            when (val outcome = SharedMoshGrammar.parseConnectResponse(transcript.standardOutput, transcript.standardError)) {
                is SharedMoshConnectResult.Failure -> error(
                    "login-shell fallback did not start mosh-server (${outcome.reason}); " +
                        "stdout=${transcript.standardOutput} stderr=${transcript.standardError}",
                )
                is SharedMoshConnectResult.Success -> MoshBootstrapResult(
                    host = bootstrapRequest.udpHost,
                    udpPort = outcome.credentials.udpPort,
                    base64Key = outcome.credentials.base64Key.encodeToByteArray(),
                    serverPid = outcome.credentials.serverProcessId,
                )
            }
        }

        // Dial the fixture by DNS name when a public wildcard resolver is
        // reachable from this device, so the numeric-target resolution is
        // proven against a live server too; otherwise by address.
        val dnsName = "${fixture.stableHost}.nip.io"
        val dnsTarget = runCatching { InetAddress.getByName(dnsName).hostAddress == fixture.stableHost }.getOrDefault(false)

        val transport = AndroidMoshTransport(bootstrapper)
        val reader = CoroutineScope(Dispatchers.IO).launch { transport.output.collect { } }
        var serverPid: Int? = null
        try {
            transport.connect(
                MoshConnectRequest(
                    bootstrap = MoshBootstrapRequest(route = request, udpHost = if (dnsTarget) dnsName else fixture.stableHost),
                    columns = 100,
                    rows = 30,
                ),
            )
            serverPid = transport.bootstrapServerPid
            withTimeout(30_000) {
                while (transport.connectivity.value.let { it.state != MoshConnectionState.CONNECTED || !it.transportReachable }) {
                    delay(50)
                }
            }
            Log.i(TAG, "TESSERA_ANDROID_MOSH_BOOTSTRAP_OK loginShellFallback=1 dnsTarget=${if (dnsTarget) 1 else 0} sharedCore=1")
        } finally {
            reader.cancel()
            transport.close()
            // Reap only the server this test's own banner named.
            serverPid?.takeIf { it > 1 }?.let { pid ->
                runCatching {
                    backend.executeRouteCommand(
                        request = request,
                        commandText = SharedMoshGrammar.serverTerminationScript(pid),
                        passwordProvider = passwordProvider,
                        hostKeyPolicy = hostKeyPolicy,
                    )
                }
            }
        }
    }

    /**
     * mosh-server exports the TERM its shell — and, on mosh+tmux, the visible
     * tmux client — sees from its `-c` flag alone. The app used to omit it,
     * so every mosh session ran as 8-colour `xterm` and tmux squashed orange
     * to red and the greys of autosuggestions to black on the way here.
     * Proven live, byte for byte what the app sends: the shell reads
     * xterm-256color, and the visible client the app attaches is RGB.
     */
    @Test
    fun moshShellIs256ColourAndTheVisibleTmuxClientIsTruecolor(): Unit = runBlocking {
        assumeTrue("native Mosh is required for this lane", JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val backend = AndroidSshBackend()
        val request = SshRouteRequest(
            listOf(
                SshRouteHop(
                    id = "mosh-term",
                    endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                    username = fixture.user,
                    authentication = SshAuthentication.Password,
                ),
            ),
        )
        val passwordProvider = SshPasswordProvider { fixture.password.toCharArray() }
        val hostKeyPolicy = SshHostKeyPolicy { true }
        val exec: suspend (String) -> String = { command ->
            backend.executeRouteCommand(
                request = request,
                commandText = command,
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
            ).standardOutput
        }

        val termMarker = "TESSERA_MOSH_TERM"
        val termScreen = connectThroughTheAppCommand(
            backend, request, passwordProvider, hostKeyPolicy,
            udpHost = fixture.stableHost,
            launchCommand = "sh -c 'printf \"\\n$termMarker=%s\\n\" \"\$TERM\"; sleep 8'",
        ) { capture -> awaitText(capture, "$termMarker=xterm") }
        assertTrue(termScreen, termScreen.contains("$termMarker=xterm-256color"))

        // The gate's run token, not a random name: when this process dies
        // before its finally, run-native-ssh-gate.sh can still prove the
        // session and its mosh-server are this run's and reap them.
        val session = "tessera-rgb-" + (fixture.token ?: java.util.UUID.randomUUID().toString().take(8))
        val viewSession = SharedTmuxCommands.moshViewSessionName(session)
        try {
            val client = connectThroughTheAppCommand(
                backend, request, passwordProvider, hostKeyPolicy,
                udpHost = fixture.stableHost,
                launchCommand = SharedTmuxCommands.moshVisibleClientCommand(session),
            ) {
                withTimeout(20_000) {
                    var listed = ""
                    while (!listed.contains("|")) {
                        delay(250)
                        // Tessera's visible client attaches to its own view of
                        // the session, never to the session itself.
                        listed = exec("tmux list-clients -t '$viewSession' -F '#{client_termname}|#{client_termfeatures}' 2>/dev/null")
                    }
                    listed
                }
            }
            assertTrue(client, client.contains("xterm-256color|"))
            assertTrue(client, client.contains("RGB"))
        } finally {
            runCatching { exec("tmux kill-session -t '$session' 2>/dev/null") }
        }
        Log.i(TAG, "TESSERA_ANDROID_MOSH_TERM_OK term=xterm-256color tmuxClientRGB=1 sharedCore=1")
    }

    /**
     * Bootstraps with the app's own command, connects the native client, and
     * runs [whileConnected] against the rendered output; always closes the
     * client and reaps only the server this bootstrap's banner named.
     */
    private suspend fun <T> connectThroughTheAppCommand(
        backend: AndroidSshBackend,
        request: SshRouteRequest,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        udpHost: String,
        launchCommand: String,
        whileConnected: suspend (StringBuilder) -> T,
    ): T {
        val bootstrapper = MoshBootstrapper { bootstrapRequest ->
            val transcript = backend.executeRouteCommand(
                request = bootstrapRequest.route,
                commandText = SharedMoshGrammar.serverNewCommand(bootstrapRequest.launchCommand),
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
            )
            when (val outcome = SharedMoshGrammar.parseConnectResponse(transcript.standardOutput, transcript.standardError)) {
                is SharedMoshConnectResult.Failure -> error(
                    "bootstrap failed (${outcome.reason}); stdout=${transcript.standardOutput} stderr=${transcript.standardError}",
                )
                is SharedMoshConnectResult.Success -> MoshBootstrapResult(
                    host = bootstrapRequest.udpHost,
                    udpPort = outcome.credentials.udpPort,
                    base64Key = outcome.credentials.base64Key.encodeToByteArray(),
                    serverPid = outcome.credentials.serverProcessId,
                )
            }
        }
        val capture = StringBuilder()
        val transport = AndroidMoshTransport(bootstrapper)
        val reader = CoroutineScope(Dispatchers.IO).launch {
            transport.output.collect { chunk ->
                synchronized(capture) { capture.append(chunk.bytes.decodeToString()) }
            }
        }
        var serverPid: Int? = null
        try {
            transport.connect(
                MoshConnectRequest(
                    bootstrap = MoshBootstrapRequest(route = request, udpHost = udpHost, launchCommand = launchCommand),
                    columns = 100,
                    rows = 30,
                ),
            )
            serverPid = transport.bootstrapServerPid
            withTimeout(30_000) {
                while (transport.connectivity.value.let { it.state != MoshConnectionState.CONNECTED || !it.transportReachable }) {
                    delay(50)
                }
            }
            return whileConnected(capture)
        } finally {
            reader.cancel()
            transport.close()
            serverPid?.takeIf { it > 1 }?.let { pid ->
                runCatching {
                    backend.executeRouteCommand(
                        request = request,
                        commandText = SharedMoshGrammar.serverTerminationScript(pid),
                        passwordProvider = passwordProvider,
                        hostKeyPolicy = hostKeyPolicy,
                    )
                }
            }
        }
    }

    private suspend fun awaitText(capture: StringBuilder, token: String): String = withTimeout(20_000) {
        var value = synchronized(capture) { capture.toString() }
        while (!value.contains(token)) {
            delay(100)
            value = synchronized(capture) { capture.toString() }
        }
        value
    }

    /**
     * Runs [command] the way a host with a login-only `mosh-server` would:
     * the exec channel's PATH is reduced to a scratch directory holding only
     * `sh`, and HOME is a scratch directory whose `.profile` /
     * `.bash_profile` / `.zprofile` prepend `/usr/bin` again — the mechanism
     * Homebrew's `.zprofile`, Nix's `nix.sh` and Ubuntu's `~/.local/bin`
     * clause all use. The fallback execs the *real* `$SHELL -l`, which reads
     * that profile. (Linux login shells extend PATH rather than reset it, so
     * hiding `/usr/bin` cannot be undone by the fixture's own profile.)
     */
    private fun onLoginOnlyPath(command: String): String =
        "tessera_bin=\$(mktemp -d) && tessera_home=\$(mktemp -d) && ln -s /bin/sh \"\$tessera_bin/sh\" && " +
            "printf 'PATH=\"/usr/bin:/bin:\$PATH\"; export PATH\\n' > \"\$tessera_home/.profile\" && " +
            "cp \"\$tessera_home/.profile\" \"\$tessera_home/.bash_profile\" && " +
            "cp \"\$tessera_home/.profile\" \"\$tessera_home/.zprofile\" && " +
            "PATH=\"\$tessera_bin\" && HOME=\"\$tessera_home\" && export PATH HOME && " +
            "$command; tessera_status=\$?; /bin/rm -rf \"\$tessera_bin\" \"\$tessera_home\"; exit \$tessera_status"

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
            port = required("port").toInt(),
            user = required("user"),
            password = String(Base64.decode(required("passwordBase64"), Base64.DEFAULT)),
            token = properties.getProperty("token")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,64}")) },
        )
    }

    private data class Fixture(
        val stableHost: String,
        val port: Int,
        val user: String,
        val password: String,
        val token: String?,
    )

    private companion object {
        const val TAG = "TesseraNativeSsh"
        const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties"
    }
}
