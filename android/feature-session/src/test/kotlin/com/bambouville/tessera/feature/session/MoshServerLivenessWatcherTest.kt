package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.NextProbe
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.Outcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MoshServerLivenessWatcherTest {
    private val watching = MoshServerLivenessWatcher.Conditions(true, false, true, 4321)

    @Test
    fun `only all four conditions admit a watch`() = runTest {
        val fixture = Fixture(this)
        for (connected in listOf(false, true)) {
            for (reachable in listOf(false, true)) {
                for (foreground in listOf(false, true)) {
                    for (pid in listOf(null, -1, 0, 4321)) {
                        fixture.watcher.update(MoshServerLivenessWatcher.Conditions(connected, reachable, foreground, pid))
                        runCurrent()
                        val shouldStart = connected && !reachable && foreground && pid == 4321
                        assertEquals(if (shouldStart) 1 else 0, fixture.events.count { it.first.endsWith("watch_start") })
                        fixture.watcher.stop("test")
                        fixture.events.clear()
                    }
                }
            }
        }
        assertEquals(0, fixture.probes)
    }

    @Test
    fun `the probe's own credential screen does not end the watch it is answering`() = runTest {
        val answer = CompletableDeferred<MoshServerLivenessWatcher.ProbeResult>()
        val fixture = Fixture(this, probe = { answer.await() })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        assertEquals(1, fixture.probes)
        // The credential activity stops ours while the challenge is up.
        fixture.watcher.update(watching.copy(appForeground = false, ownerPromptPending = true))
        runCurrent()
        assertEquals(0, fixture.events.count { it.first.endsWith("watch_stop") })
        answer.complete(MoshServerLivenessWatcher.ProbeResult(Outcome.GONE, neededOwnerAuthorization = true))
        runCurrent()
        assertEquals("the approved probe must still deliver its verdict", listOf(4321), fixture.gone)
        // An ordinary trip to the background, with no prompt of ours up, still ends it.
        val other = Fixture(this)
        other.watcher.update(watching)
        other.watcher.update(watching.copy(appForeground = false))
        runCurrent()
        assertEquals("conditions", other.events.single { it.first.endsWith("watch_stop") }.second["reason"])
    }

    @Test
    fun `injected grace elapses before first probe`() = runTest {
        val fixture = Fixture(this)
        fixture.watcher.update(watching)
        runCurrent()
        assertEquals(listOf(GRACE), fixture.sleeps)
        advanceTimeBy(GRACE - 1)
        runCurrent()
        assertEquals(0, fixture.probes)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(1, fixture.probes)
        assertEquals(listOf(4321), fixture.pids)
    }

    @Test
    fun `host failure ladder comes entirely from injected policy`() = runTest {
        val delays = listOf(17L, 29L, 43L, 61L, 61L)
        val calls = mutableListOf<Pair<Outcome, Int>>()
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE) }, policy = timed { outcome, failures ->
            calls += outcome to failures
            delays[minOf(failures - 1, delays.lastIndex)]
        })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        for (delay in delays.take(4)) {
            advanceTimeBy(delay)
            runCurrent()
        }
        assertEquals((1..5).map { Outcome.HOST_UNREACHABLE to it }, calls)
        assertEquals(listOf(GRACE) + delays, fixture.sleeps)
        assertEquals(0, fixture.gone.size)
    }

    @Test
    fun `alive and unknown recheck without ending attempt and reset failure run`() = runTest {
        val outcomes = ArrayDeque(listOf(Outcome.HOST_UNREACHABLE, Outcome.ALIVE, Outcome.UNKNOWN, Outcome.HOST_UNREACHABLE))
        val calls = mutableListOf<Pair<Outcome, Int>>()
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(outcomes.removeFirst()) }, policy = timed { outcome, failures ->
            calls += outcome to failures
            if (outcome == Outcome.HOST_UNREACHABLE) 71 else 113
        })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        for (wait in listOf(71L, 113L, 113L)) {
            advanceTimeBy(wait)
            runCurrent()
        }
        assertEquals(listOf(Outcome.HOST_UNREACHABLE to 1, Outcome.ALIVE to 0, Outcome.UNKNOWN to 0, Outcome.HOST_UNREACHABLE to 1), calls)
        assertEquals(listOf(GRACE, 71L, 113L, 113L, 71L), fixture.sleeps)
        assertTrue(fixture.gone.isEmpty())
    }

    @Test
    fun `owner authorized alive waits for a wake instead of a timer`() = runTest { assertOwnerAwaitsWake(Outcome.ALIVE) }

    @Test
    fun `owner cancelled unknown waits for a wake instead of a timer`() = runTest { assertOwnerAwaitsWake(Outcome.UNKNOWN) }

    @Test
    fun `the probe's owner authorization reaches the shared policy`() = runTest {
        val answers = ArrayDeque(listOf(
            MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE),
            MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE, neededOwnerAuthorization = true),
            MoshServerLivenessWatcher.ProbeResult(Outcome.ALIVE),
        ))
        val calls = mutableListOf<Triple<Outcome, Int, Boolean>>()
        val fixture = Fixture(this, probe = { answers.removeFirst() }, policy = { outcome, failures, askedOwner ->
            calls += Triple(outcome, failures, askedOwner)
            if (calls.size < 3) NextProbe.After(RECHECK) else NextProbe.None
        })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE + RECHECK * 2)
        runCurrent()
        assertEquals(
            listOf(
                Triple(Outcome.HOST_UNREACHABLE, 1, false),
                Triple(Outcome.HOST_UNREACHABLE, 2, true),
                Triple(Outcome.ALIVE, 0, false),
            ),
            calls,
        )
        assertEquals("settled", fixture.events.last { it.first.endsWith("watch_stop") }.second["reason"])
    }

    @Test
    fun `deadline cancels pending owner authorization as unknown`() = runTest {
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult.timedOut(true, true) })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE + 100_000)
        runCurrent()
        assertEquals(1, fixture.probes)
        assertEquals("UNKNOWN", fixture.events.single { it.first.endsWith("_probe") }.second["outcome"])
        assertTrue(fixture.gone.isEmpty())
    }

    @Test
    fun `SSH deadline after owner approval remains host unreachable`() {
        assertEquals(MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE, true),
            MoshServerLivenessWatcher.ProbeResult.timedOut(true, false))
        assertEquals(MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE),
            MoshServerLivenessWatcher.ProbeResult.timedOut(false, false))
    }

    private suspend fun TestScope.assertOwnerAwaitsWake(outcome: Outcome) {
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(outcome, neededOwnerAuthorization = true) })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        fixture.watcher.update(watching) // duplicate connectivity must not rearm a stopped episode
        advanceTimeBy(100_000)
        runCurrent()
        assertEquals(1, fixture.probes)
        assertEquals(listOf(GRACE), fixture.sleeps)
        assertTrue(fixture.gone.isEmpty())
        assertEquals("on-wake", fixture.events.single { it.first.endsWith("_probe") }.second["next_delay_ms"])
        assertEquals("awaiting-wake", fixture.events.single { it.first.endsWith("watch_stop") }.second["reason"])
        // Returning to the foreground is this platform's wake: a fresh episode, grace first.
        fixture.watcher.update(watching.copy(appForeground = false))
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        assertEquals(2, fixture.probes)
    }

    @Test
    fun `host failure after owner authorization rechecks only on the slower shared timer`() = runTest {
        assertOwnerRechecksSlowly(MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE, true))
    }

    @Test
    fun `deadline after owner approval rechecks only on the slower shared timer`() = runTest {
        assertOwnerRechecksSlowly(MoshServerLivenessWatcher.ProbeResult.timedOut(true, false))
    }

    private suspend fun TestScope.assertOwnerRechecksSlowly(answer: MoshServerLivenessWatcher.ProbeResult) {
        val fixture = Fixture(this, probe = { answer })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        advanceTimeBy(OWNER_RECHECK - 1)
        runCurrent()
        assertEquals(1, fixture.probes)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(2, fixture.probes)
        assertEquals(listOf(GRACE, OWNER_RECHECK, OWNER_RECHECK), fixture.sleeps)
        val probe = fixture.events.first { it.first.endsWith("_probe") }.second
        assertEquals("HOST_UNREACHABLE", probe["outcome"])
        assertEquals("$OWNER_RECHECK", probe["next_delay_ms"])
        assertTrue(fixture.gone.isEmpty())
        assertEquals(0, fixture.events.count { it.first.endsWith("watch_stop") })
    }

    @Test
    fun `host failure before owner authorization still follows shared backoff`() = runTest {
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE) })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE + RECHECK)
        runCurrent()
        assertEquals(2, fixture.probes)
        assertTrue(fixture.gone.isEmpty())
    }

    @Test
    fun `gone fires exactly once despite duplicate connectivity`() = runTest {
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(Outcome.GONE) })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        repeat(3) { fixture.watcher.update(watching) }
        advanceTimeBy(100_000)
        runCurrent()
        assertEquals(listOf(4321), fixture.gone)
        assertEquals(1, fixture.probes)
        assertEquals(listOf(GRACE), fixture.sleeps)
    }

    @Test
    fun `owner authorized gone still ends the attempt exactly once`() = runTest {
        val fixture = Fixture(this, probe = { MoshServerLivenessWatcher.ProbeResult(Outcome.GONE, true) })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        fixture.watcher.update(watching)
        advanceTimeBy(100_000)
        runCurrent()
        assertEquals(listOf(4321), fixture.gone)
        assertEquals(1, fixture.probes)
        assertEquals(listOf(GRACE), fixture.sleeps)
    }

    @Test
    fun `every false condition cancels grace and next episode restarts it`() = runTest {
        for (condition in listOf(
            watching.copy(connectedEmitted = false), watching.copy(transportReachable = true),
            watching.copy(appForeground = false), watching.copy(serverPid = null), watching.copy(serverPid = 0),
        )) {
            val fixture = Fixture(this)
            fixture.watcher.update(watching)
            runCurrent()
            advanceTimeBy(GRACE - 1)
            fixture.watcher.update(condition)
            advanceTimeBy(1_000)
            runCurrent()
            assertEquals(0, fixture.probes)
            fixture.watcher.update(watching)
            runCurrent()
            advanceTimeBy(GRACE - 1)
            runCurrent()
            assertEquals(0, fixture.probes)
            advanceTimeBy(1)
            runCurrent()
            assertEquals(1, fixture.probes)
            fixture.watcher.stop("test")
        }
    }

    @Test
    fun `condition loss cancels backoff and resumes with grace`() = runTest {
        val fixture = Fixture(this)
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        fixture.watcher.update(watching.copy(transportReachable = true))
        advanceTimeBy(RECHECK * 2)
        runCurrent()
        assertEquals(1, fixture.probes)
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        assertEquals(2, fixture.probes)
        assertEquals(listOf(GRACE, RECHECK, GRACE, RECHECK), fixture.sleeps)
    }

    @Test
    fun `late gone after cancellation is discarded while replacement runs`() = runTest {
        val answer = CompletableDeferred<Unit>()
        var count = 0
        val fixture = Fixture(this, probe = {
            if (++count == 1) {
                withContext(NonCancellable) { answer.await() }
                MoshServerLivenessWatcher.ProbeResult(Outcome.GONE)
            } else MoshServerLivenessWatcher.ProbeResult(Outcome.ALIVE)
        })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        fixture.watcher.update(watching.copy(appForeground = false))
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        answer.complete(Unit)
        runCurrent()
        assertEquals(2, fixture.probes)
        assertTrue(fixture.gone.isEmpty())
        assertEquals(1, fixture.events.count { it.first.endsWith("_probe") })
    }

    @Test
    fun `changing pid cancels old episode and probes new pid after grace`() = runTest {
        val fixture = Fixture(this)
        fixture.watcher.update(watching)
        runCurrent()
        advanceTimeBy(GRACE - 1)
        fixture.watcher.update(watching.copy(serverPid = 9876))
        advanceTimeBy(GRACE)
        runCurrent()
        assertEquals(listOf(9876), fixture.pids)
    }

    @Test
    fun `explicit teardown discards an uncooperative late answer`() = runTest {
        val answer = CompletableDeferred<Unit>()
        val fixture = Fixture(this, probe = {
            withContext(NonCancellable) { answer.await() }
            MoshServerLivenessWatcher.ProbeResult(Outcome.GONE)
        })
        fixture.watcher.update(watching)
        advanceTimeBy(GRACE)
        runCurrent()
        fixture.watcher.stop("teardown")
        answer.complete(Unit)
        runCurrent()
        assertTrue(fixture.gone.isEmpty())
        assertEquals(0, fixture.events.count { it.first.endsWith("_probe") })
    }

    @Test
    fun `probe deadline gives up after its budget when nobody is prompted`() = runTest {
        val work = CompletableDeferred<String>()
        val answer = backgroundScope.async { awaitProbeDeadline(work, budgetMillis = 12_000, ownerPrompting = { false }) }
        advanceTimeBy(11_999)
        runCurrent()
        assertFalse(answer.isCompleted)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(answer.isCompleted)
        assertNull(answer.await())
    }

    @Test
    fun `probe deadline does not run while the owner is being asked`() = runTest {
        val work = CompletableDeferred<String>()
        var prompting = false
        val answer = backgroundScope.async {
            awaitProbeDeadline(work, budgetMillis = 12_000, ownerPrompting = { prompting })
        }
        advanceTimeBy(4_000)
        runCurrent()
        prompting = true
        advanceTimeBy(60_000)
        runCurrent()
        assertFalse("a slow Face ID answer must not spend the probe's deadline", answer.isCompleted)
        prompting = false
        advanceTimeBy(7_000)
        runCurrent()
        assertFalse(answer.isCompleted)
        work.complete("TESSERA_MOSH_SERVER=alive")
        runCurrent()
        assertEquals("TESSERA_MOSH_SERVER=alive", answer.await())
    }

    @Test
    fun `probe deadline returns an early answer at once`() = runTest {
        val work = CompletableDeferred<String>()
        val answer = backgroundScope.async { awaitProbeDeadline(work, budgetMillis = 12_000, ownerPrompting = { false }) }
        advanceTimeBy(100)
        work.complete("gone")
        runCurrent()
        assertEquals("gone", answer.await())
        assertEquals(100L, testScheduler.currentTime)
    }

    @Test
    fun `cancelled blocking worker keeps probe slot until it actually returns`() = runTest {
        val slot = MoshServerLivenessProbeSlot()
        val unblock = CompletableDeferred<Unit>()
        assertTrue(slot.reserve())
        val worker = backgroundScope.launch { withContext(NonCancellable) { unblock.await() } }
        slot.releaseAfter(worker) { null }
        runCurrent()
        worker.cancel()
        runCurrent()
        assertFalse(slot.reserve())
        unblock.complete(Unit)
        runCurrent()
        assertTrue(slot.reserve())
    }

    @Test
    fun `completed probe retains slot until asynchronous route cleanup finishes`() = runTest {
        val slot = MoshServerLivenessProbeSlot()
        val cleanup = CompletableDeferred<Unit>()
        assertTrue(slot.reserve())
        val worker = backgroundScope.launch { }
        slot.releaseAfter(worker) { cleanup }
        runCurrent()
        assertTrue(worker.isCompleted)
        assertFalse(slot.reserve())
        cleanup.complete(Unit)
        assertTrue(slot.reserve())
    }

    @Test
    fun `cancellation before IO dispatch releases probe slot`() = runTest {
        val slot = MoshServerLivenessProbeSlot()
        assertTrue(slot.reserve())
        val worker = backgroundScope.launch(start = CoroutineStart.LAZY) { error("must not execute") }
        slot.releaseAfter(worker) { null }
        worker.cancel()
        assertTrue(slot.reserve())
    }

    private class Fixture(
        testScope: TestScope,
        probe: suspend (Int) -> MoshServerLivenessWatcher.ProbeResult = { MoshServerLivenessWatcher.ProbeResult(Outcome.ALIVE) },
        policy: (Outcome, Int, Boolean) -> NextProbe = ::sharedShapedPolicy,
    ) {
        var probes = 0
        val pids = mutableListOf<Int>()
        val gone = mutableListOf<Int>()
        val sleeps = mutableListOf<Long>()
        val events = mutableListOf<Pair<String, Map<String, String>>>()
        val watcher = MoshServerLivenessWatcher(
            scope = testScope.backgroundScope,
            probe = { pid -> ++probes; pids += pid; probe(pid) },
            graceMillis = { GRACE }, nextProbe = policy,
            onServerGone = gone::add, record = { event, fields -> events += event to fields },
            sleep = { sleeps += it; delay(it) }, clockMillis = { testScope.testScheduler.currentTime },
            dispatcher = StandardTestDispatcher(testScope.testScheduler),
        )
    }

    private companion object {
        const val GRACE = 137L
        const val RECHECK = 503L
        const val OWNER_RECHECK = 1_009L

        /** The shape of the shared `nextProbe` with test-sized delays. */
        fun sharedShapedPolicy(outcome: Outcome, failures: Int, askedOwner: Boolean): NextProbe = when {
            outcome == Outcome.GONE -> NextProbe.None
            !askedOwner -> NextProbe.After(RECHECK)
            outcome == Outcome.HOST_UNREACHABLE -> NextProbe.After(OWNER_RECHECK)
            else -> NextProbe.OnWake
        }

        /** A timer-only policy for tests about the delays themselves. */
        fun timed(delayMillis: (Outcome, Int) -> Long?): (Outcome, Int, Boolean) -> NextProbe = { outcome, failures, _ ->
            delayMillis(outcome, failures)?.let { NextProbe.After(it) } ?: NextProbe.None
        }
    }
}
