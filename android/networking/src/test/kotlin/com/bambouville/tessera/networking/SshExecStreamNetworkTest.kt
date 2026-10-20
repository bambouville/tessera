package com.bambouville.tessera.networking

import com.bambouville.tessera.agent.platform.AgentExecExitStatus
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentRemoteStreamDrain
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import net.schmizz.sshj.SSHClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in socket test against the disposable integration VPS, never the local Mac. */
class SshExecStreamNetworkTest {
    @Test(timeout = 30_000)
    fun transportOverflowCleanupDoesNotBlockCollectorDispatcher() = runBlocking {
        withFixture { owner ->
            Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { ui ->
                val longestGap = AtomicLong()
                val ready = CompletableDeferred<Unit>()
                val heartbeat = launch(ui) {
                    var previous = System.nanoTime()
                    ready.complete(Unit)
                    while (isActive) {
                        delay(10)
                        val now = System.nanoTime()
                        longestGap.accumulateAndGet((now - previous) / 1_000_000, ::maxOf)
                        previous = now
                    }
                }
                try {
                    ready.await()
                    val helper = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL,
                        maxStdoutBytes = 1024))
                    helper.writeStdin("trap '' TERM; dd if=/dev/zero bs=2048 count=1 2>/dev/null; sleep 3\n".encodeToByteArray())
                    helper.closeStdin()
                    val result = withContext(ui) { AgentRemoteStreamDrain.drain(Adapter(helper), 4096, 1500) }
                    assertTrue(result is AgentRemoteStreamDrain.Result.Failed)
                    withContext(ui) { delay(30) }
                    assertEquals("route-alive", owner.executeBoundedCommand("printf route-alive").standardOutput)
                } finally {
                    heartbeat.cancelAndJoin()
                }
                println("TESSERA_EXEC_COLLECTOR_HEARTBEAT maxGapMs=${longestGap.get()}")
                assertTrue("cleanup blocked collector dispatcher for ${longestGap.get()}ms", longestGap.get() < 200)
            }
        }
    }

    @Test(timeout = 60_000)
    fun completionRacingCancellationDoesNotSignalRetiredChannels() = runBlocking {
        withFixture { owner ->
            repeat(48) { index ->
                val helper = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
                val pause = listOf("0", "0.005", "0.015", "0.030")[index % 4]
                helper.writeStdin("sleep $pause; printf 'done'\n".encodeToByteArray())
                helper.closeStdin()
                when (val result = AgentRemoteStreamDrain.drain(Adapter(helper), 1024, 15)) {
                    is AgentRemoteStreamDrain.Result.Complete -> {
                        assertEquals("done", result.stdout.decodeToString())
                        assertEquals(0, result.exit.code)
                    }
                    AgentRemoteStreamDrain.Result.TimedOut -> Unit
                    is AgentRemoteStreamDrain.Result.Failed -> error(result.reason)
                }
                assertEquals("route-alive", owner.executeBoundedCommand("printf route-alive").standardOutput)
            }
            println("TESSERA_EXEC_CLOSE_RACE_SURVIVED iterations=48")
        }
    }

    @Test(timeout = 30_000)
    fun helperIgnoringTermDoesNotPinDeadlineOrRoute() = runBlocking {
        withFixture { owner ->
            val helper = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
            helper.writeStdin("trap '' TERM; printf 'ready\\n'; sleep 3\n".encodeToByteArray())
            helper.closeStdin()
            val started = System.nanoTime()
            val result = AgentRemoteStreamDrain.drain(Adapter(helper), 1024, 100)
            val elapsedMillis = (System.nanoTime() - started) / 1_000_000
            println("TESSERA_EXEC_IGNORED_TERM elapsedMs=$elapsedMillis result=${result.javaClass.simpleName}")
            assertTrue(result is AgentRemoteStreamDrain.Result.TimedOut)
            assertEquals("route-alive", owner.executeBoundedCommand("printf route-alive").standardOutput)
            assertTrue("TERM-ignoring helper cancellation took ${elapsedMillis}ms", elapsedMillis < 1500)
        }
    }

    @Test(timeout = 30_000)
    fun silentHelperDeadlinePreservesSiblingAndRoute() = runBlocking {
        withFixture { owner ->
            val sibling = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
            try {
                sibling.writeStdin("printf 'before\\n'; read reply; printf '%s\\n' \"\$reply\"\n".encodeToByteArray())
                val ready = CompletableDeferred<Unit>()
                val siblingResult = async(Dispatchers.IO) {
                    AgentRemoteStreamDrain.drain(Adapter(sibling) { ready.complete(Unit) }, 1024, 10_000)
                }
                withTimeout(5000) { ready.await() }
                val helper = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
                helper.writeStdin("sleep 3; printf 'late\\n'\n".encodeToByteArray())
                helper.closeStdin()
                val started = System.nanoTime()
                val result = AgentRemoteStreamDrain.drain(Adapter(helper), 1024, 100)
                val elapsedMillis = (System.nanoTime() - started) / 1_000_000
                println("TESSERA_EXEC_DEADLINE elapsedMs=$elapsedMillis result=${result.javaClass.simpleName}")
                assertTrue(result is AgentRemoteStreamDrain.Result.TimedOut)
                sibling.writeStdin("after\n".encodeToByteArray())
                sibling.closeStdin()
                val survived = siblingResult.await() as AgentRemoteStreamDrain.Result.Complete
                assertEquals("before\nafter\n", survived.stdout.decodeToString())
                assertEquals(0, survived.exit.code)
                assertEquals("route-alive", owner.executeBoundedCommand("printf route-alive").standardOutput)
                assertTrue("100ms deadline took ${elapsedMillis}ms with a silent remote child", elapsedMillis < 1500)
            } finally {
                sibling.cancel()
            }
        }
    }

    @Test(timeout = 60_000)
    fun cancellingOutputWhileSiblingRunsPreservesRoute() = runBlocking {
        withFixture { owner ->
            val sibling = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
            try {
                sibling.writeStdin("printf 'before\\n'; read reply; printf '%s\\n' \"\$reply\"\n".encodeToByteArray())
                val ready = CompletableDeferred<Unit>()
                val siblingResult = async(Dispatchers.IO) {
                    AgentRemoteStreamDrain.drain(Adapter(sibling) { ready.complete(Unit) }, 1024, 45_000)
                }
                withTimeout(5000) { ready.await() }
                repeat(24) { iteration ->
                    val helper = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL,
                        maxStdoutBytes = 4_194_304, maxStderrBytes = 16_384))
                    // Bounded synthetic output only; no files, persistent process, or user's pane.
                    helper.writeStdin("dd if=/dev/zero bs=32768 count=96 2>/dev/null; sleep 3\n".encodeToByteArray())
                    helper.closeStdin()
                    val started = System.nanoTime()
                    val result = AgentRemoteStreamDrain.drain(Adapter(helper), 4_194_304, 25)
                    val elapsedMillis = (System.nanoTime() - started) / 1_000_000
                    assertTrue(result is AgentRemoteStreamDrain.Result.TimedOut)
                    assertEquals("route-alive", owner.executeBoundedCommand("printf route-alive").standardOutput)
                    assertTrue("output cancellation took ${elapsedMillis}ms", elapsedMillis < 1500)
                    println("TESSERA_EXEC_CANCEL_SURVIVED iteration=$iteration elapsedMs=$elapsedMillis")
                }
                sibling.writeStdin("after\n".encodeToByteArray())
                sibling.closeStdin()
                val survived = siblingResult.await() as AgentRemoteStreamDrain.Result.Complete
                assertEquals("before\nafter\n", survived.stdout.decodeToString())
                assertEquals(0, survived.exit.code)
            } finally {
                sibling.cancel()
            }
        }
    }

    private suspend fun withFixture(block: suspend (SshRouteOwner) -> Unit) {
        assumeTrue("requires explicit disposable VPS fixture", System.getenv("TESSERA_EXEC_NETWORK_TEST") == "1")
        fun setting(name: String) = requireNotNull(System.getenv(name)) { "missing $name" }
        val host = setting("TESSERA_EXEC_TEST_HOST")
        require(host !in setOf("localhost", "127.0.0.1", "::1"))
        val client = SSHClient()
        client.connectTimeout = 5000
        client.timeout = 5000
        client.loadKnownHosts(File(setting("TESSERA_EXEC_TEST_KNOWN_HOSTS")))
        try {
            client.connect(host, setting("TESSERA_EXEC_TEST_PORT").toInt())
            client.authPassword(setting("TESSERA_EXEC_TEST_USER"), File(setting("TESSERA_EXEC_TEST_PASSWORD_FILE")).readText().trim())
            SshRouteOwner(client, listOf(client)).use { block(it) }
        } finally {
            client.close()
        }
    }

    private class Adapter(private val stream: SshExecStream, onOutput: () -> Unit = {}) : AgentRemoteExecStream {
        override val stdout: Flow<ByteArray> = stream.stdout().onEach { onOutput() }
        override val stderr: Flow<ByteArray> = stream.stderr()
        override suspend fun awaitExit() = AgentExecExitStatus(stream.awaitExit().code)
        override fun cancel() = stream.cancel()
        override fun close() = stream.close()
    }
}
