package com.bambouville.tessera.feature.session

import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentRemoteStreamDrain
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshExecRequest
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRemoteOperation
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import java.io.File
import java.util.Properties
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** The production Android crypto, route, and Agent stream adapter over a real VPS socket. */
class AgentExecCancellationInstrumentedTest {
    @Test(timeout = 90_000)
    fun deadlinesFailuresAndParentCancellationPreserveEstablishedSibling(): Unit = runBlocking(Dispatchers.IO) {
        val path = InstrumentationRegistry.getArguments().getString("tesseraExecCancellationFixture")
        assumeTrue("requires the opt-in disposable VPS runner", path != null)
        val fixture = Properties().apply { File(requireNotNull(path)).inputStream().use(::load) }
        val host = fixture.getProperty("host")
        require(host !in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2"))
        val keys = fixture.getProperty("hostKeyBlobs").split(',').toSet()
        val route = AndroidSshBackend().openRoute(
            SshRouteRequest(listOf(SshRouteHop("exec-cancellation", SshEndpoint(host, fixture.getProperty("port").toInt()),
                fixture.getProperty("user"), SshAuthentication.Password))),
            SshPasswordProvider { Base64.decode(fixture.getProperty("passwordBase64"), Base64.DEFAULT).decodeToString().toCharArray() },
            SshHostKeyPolicy { Base64.encodeToString(it.canonicalKeyBlob, Base64.NO_WRAP) in keys },
        )
        route.use {
            val sibling = route.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
            val siblingClosed = AtomicInteger()
            val siblingAdapter = SshAgentRemoteExecStream(sibling) { siblingClosed.incrementAndGet() }
            try {
                sibling.writeStdin("printf 'before\\n'; read reply; printf '%s\\n' \"\$reply\"\n".encodeToByteArray())
                val ready = CompletableDeferred<Unit>()
                val observedSibling = object : AgentRemoteExecStream by siblingAdapter {
                    override val stdout = siblingAdapter.stdout.onEach { ready.complete(Unit) }
                }
                val siblingResult = async { AgentRemoteStreamDrain.drain(observedSibling, 1024, 60_000) }
                withTimeout(5000) { ready.await() }

                val scripts = listOf(
                    "sleep 3; printf 'late\\n'\n",
                    "trap '' TERM; sleep 3; printf 'late\\n'\n",
                    "dd if=/dev/zero bs=32768 count=96 2>/dev/null; sleep 3\n",
                )
                scripts.forEachIndexed { index, script ->
                    val helper = route.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL,
                        maxStdoutBytes = 4_194_304, maxStderrBytes = 16_384))
                    val closed = AtomicInteger()
                    val adapter = SshAgentRemoteExecStream(helper) { closed.incrementAndGet() }
                    helper.writeStdin(script.encodeToByteArray())
                    helper.closeStdin()
                    val started = System.nanoTime()
                    val result = AgentRemoteStreamDrain.drain(adapter, 4_194_304, 100)
                    val elapsedMillis = (System.nanoTime() - started) / 1_000_000
                    assertTrue("case $index", result is AgentRemoteStreamDrain.Result.TimedOut)
                    assertTrue("case $index took ${elapsedMillis}ms", elapsedMillis < 1500)
                    assertEquals(1, closed.get())
                    assertEquals(0, siblingClosed.get())
                    assertEquals("route-alive", route.executeBoundedCommand("printf route-alive").standardOutput)
                    Log.i("TesseraExecCancel", "TESSERA_ANDROID_EXEC_DEADLINE case=$index elapsedMs=$elapsedMillis")
                }

                val overflow = route.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
                overflow.writeStdin("dd if=/dev/zero bs=2048 count=1 2>/dev/null; sleep 3\n".encodeToByteArray())
                overflow.closeStdin()
                assertEquals(AgentRemoteStreamDrain.Result.Failed("stdout_too_large"),
                    AgentRemoteStreamDrain.drain(SshAgentRemoteExecStream(overflow), 1024, 1500))

                val cancelled = route.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
                cancelled.writeStdin("printf 'ready\\n'; sleep 3\n".encodeToByteArray())
                cancelled.closeStdin()
                val parentReady = CompletableDeferred<Unit>()
                val cancelledAdapter = SshAgentRemoteExecStream(cancelled)
                val observed = object : AgentRemoteExecStream by cancelledAdapter {
                    override val stdout = cancelledAdapter.stdout.onEach { parentReady.complete(Unit) }
                }
                val task = async { AgentRemoteStreamDrain.drain(observed, 1024, 30_000) }
                withTimeout(5000) { parentReady.await() }
                val started = System.nanoTime()
                task.cancelAndJoin()
                assertTrue((System.nanoTime() - started) / 1_000_000 < 1500)
                assertTrue(task.isCancelled)

                sibling.writeStdin("after\n".encodeToByteArray())
                sibling.closeStdin()
                val survived = siblingResult.await() as AgentRemoteStreamDrain.Result.Complete
                assertEquals("before\nafter\n", survived.stdout.decodeToString())
                assertEquals(0, survived.exit.code)
                assertEquals(1, siblingClosed.get())
                assertEquals("route-alive", route.executeBoundedCommand("printf route-alive").standardOutput)
                Log.i("TesseraExecCancel", "TESSERA_ANDROID_EXEC_CANCELLATION_OK deadline=1 ignoresTerm=1 output=1 overflow=1 parentCancel=1 sibling=1 route=1")
            } finally {
                siblingAdapter.cancel()
            }
        }
    }
}
