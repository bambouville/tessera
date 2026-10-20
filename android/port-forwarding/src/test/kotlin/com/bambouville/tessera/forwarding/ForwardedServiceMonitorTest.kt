package com.bambouville.tessera.forwarding

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The service-liveness state machine and its probe cadence, driven by a fake
 * runtime and a fake monotonic clock. The shared-core policy the manager
 * normally consults over JNI is replaced by [FakePolicy].
 */
class ForwardedServiceMonitorTest {
    private val clock = AtomicLong(0)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val logged = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
    private val runtime = FakeRuntime()

    @After fun tearDown() {
        scope.cancel()
    }

    @Test fun aNewlyCarryingWebRuleIsProbedAtOnceThenEveryFiveSecondsWhileUnconfirmed() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }

        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
        assertEquals(1, manager.tick())
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))
        assertTrue(manager.status(rule) is PortForwardingStatus.Listening)

        clock.set(4_999)
        assertEquals(0, manager.tick())
        clock.set(5_000)
        assertEquals(1, manager.tick())
        assertEquals(listOf(rule.target, rule.target), runtime.probes.toList())
    }

    @Test fun aServingTargetIsReprobedEveryFifteenSeconds() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Serving }

        assertEquals(1, manager.tick())
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        clock.set(14_999)
        assertEquals(0, manager.tick())
        clock.set(15_000)
        assertEquals(1, manager.tick())
    }

    @Test fun prohibitedForwardingIsUnknownFlaggedAndBacksOffToAMinute() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Serving }
        manager.tick()
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        clock.set(15_000)
        runtime.answer = { ForwardedServiceProbe.Prohibited }
        assertEquals(1, manager.tick())
        val state = manager.states.value.getValue(rule.id)
        assertEquals(ForwardedServiceState.Unknown, state.service)
        assertTrue(state.forwardingProhibited)

        clock.set(15_000 + 59_999)
        assertEquals(0, manager.tick())
        clock.set(15_000 + 60_000)
        assertEquals(1, manager.tick())
    }

    @Test fun serviceStateFollowsAnswersAndAnInconclusiveOneKeepsThePrevious() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)

        runtime.answer = { ForwardedServiceProbe.Serving }
        manager.tick(force = true)
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        runtime.answer = { ForwardedServiceProbe.NotServing }
        manager.tick(force = true)
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))

        runtime.answer = { ForwardedServiceProbe.Inconclusive("ConnectionException") }
        manager.tick(force = true)
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))

        runtime.answer = { ForwardedServiceProbe.Serving }
        manager.tick(force = true)
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        // A runtime that throws is contained as inconclusive, not a crash.
        runtime.answer = { throw IllegalStateException("transport lost to web.internal") }
        manager.tick(force = true)
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        val outcomes = logged.filter { it.first == "forwarding_service" }.map { it.second.getValue("outcome") }
        assertEquals(listOf("serving", "not_serving", "inconclusive", "serving", "inconclusive"), outcomes)
        val inconclusive = logged.map { it.second }.filter { it["outcome"] == "inconclusive" }
        assertEquals(listOf("ConnectionException", "IllegalStateException"), inconclusive.map { it["detail"] })
        // Ports only: the target host never reaches the diagnostics log.
        assertTrue(logged.all { (_, values) -> values.values.none { "web.internal" in it } })
        assertEquals("3000", logged.first().second["target_port"])
    }

    /**
     * There is no SSH keepalive: a transport that died quietly under mosh,
     * or a target whose connect hangs past the deadline, answers every look
     * inconclusively. One such look keeps what was known; two in a row,
     * probe or passive, forget it.
     */
    @Test fun twoInconclusiveLooksInARowForgetAServingTarget() = runBlocking {
        val rule = webRule()
        val rules = listOf(rule)
        val manager = attached(rule)
        manager.look(ForwardedServiceProbe.Serving)

        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        assertEquals(1, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)

        runtime.lease(rule).passive(ForwardedServiceProbe.Inconclusive("TransportException"))
        manager.awaitService(rule, ForwardedServiceState.Unknown)
        assertFalse(manager.states.value.getValue(rule.id).isServing())
        assertEquals(0, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)
        val forgotten = logged.last { it.first == "forwarding_service" }.second
        assertEquals("inconclusive", forgotten["outcome"])
        assertEquals("unknown", forgotten["state"])
    }

    @Test fun twoInconclusiveLooksInARowForgetARefusedTargetButNotAProhibition() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        manager.look(ForwardedServiceProbe.NotServing)

        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))

        // A prohibition is the server's, and nothing inconclusive says it relented.
        manager.look(ForwardedServiceProbe.Prohibited)
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertTrue(manager.states.value.getValue(rule.id).forwardingProhibited)
    }

    @Test fun aConclusiveAnswerBetweenInconclusiveLooksRestartsTheCount() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)

        manager.look(ForwardedServiceProbe.Serving)
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        manager.look(ForwardedServiceProbe.Serving)
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        manager.look(ForwardedServiceProbe.NotServing)
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))
        manager.look(ForwardedServiceProbe.Inconclusive("timeout"))
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
    }

    /**
     * Non-web and https rules are unwatched: never probed, and their real
     * connections store nothing either, since nothing would ever refresh it.
     * They serve only while they carry connections.
     */
    @Test fun anUnwatchedRuleIsNeverProbedAndKeepsNoServiceState() = runBlocking {
        val postgres = rule(bindPort = 15_432, targetPort = 5_432)
        val https = rule(bindPort = 18_443, targetPort = 443)
        val rules = listOf(postgres, https)
        val manager = attached(postgres, https)
        runtime.answer = { ForwardedServiceProbe.Serving }

        assertEquals(0, manager.tick(force = true))
        manager.probeServicesNow()
        assertTrue(runtime.probes.isEmpty())

        runtime.lease(postgres).passive(ForwardedServiceProbe.NotServing)
        runtime.lease(https).passive(ForwardedServiceProbe.Serving)
        runtime.lease(postgres).passive(ForwardedServiceProbe.Serving)
        manager.awaitObservations(3)
        assertEquals(ForwardedServiceState.Unknown, manager.service(postgres))
        assertEquals(ForwardedServiceState.Unknown, manager.service(https))
        assertTrue(logged.none { it.first == "forwarding_service" })
        assertEquals(0, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)

        // Carrying a connection is serving, for exactly as long as it lasts.
        runtime.lease(postgres).count.value = 1
        manager.states.awaitValue { it[postgres.id]?.status is PortForwardingStatus.Active }
        assertEquals(1, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)
        runtime.lease(postgres).passive(ForwardedServiceProbe.Serving)
        manager.awaitObservations(4)

        runtime.lease(postgres).count.value = 0
        manager.states.awaitValue { it[postgres.id]?.status is PortForwardingStatus.Listening }
        assertEquals(ForwardedServiceState.Unknown, manager.service(postgres))
        assertEquals(0, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)
        assertTrue(runtime.probes.isEmpty())
    }

    @Test fun aWatchedRuleRemembersWhatItsConnectionsFound() = runBlocking {
        val rule = webRule()
        val rules = listOf(rule)
        val manager = attached(rule)

        runtime.lease(rule).count.value = 1
        manager.states.awaitValue { it[rule.id]?.status is PortForwardingStatus.Active }
        runtime.lease(rule).passive(ForwardedServiceProbe.Serving)
        manager.awaitService(rule, ForwardedServiceState.Serving)

        runtime.lease(rule).count.value = 0
        manager.states.awaitValue { it[rule.id]?.status is PortForwardingStatus.Listening }
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        assertEquals(1, ForwardingChromePresentation.of(rules, manager.states.value, panelOpen = false).servingCount)
    }

    @Test fun anActiveRuleIsNotProbedItsConnectionsAreTheEvidence() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        val lease = runtime.lease(rule)

        lease.count.value = 1
        manager.states.awaitValue { it[rule.id]?.status is PortForwardingStatus.Active }
        assertEquals(0, manager.tick(force = true))

        lease.count.value = 0
        manager.states.awaitValue { it[rule.id]?.status is PortForwardingStatus.Listening }
        assertEquals(1, manager.tick())
    }

    @Test fun atMostOneProbeIsInFlightPerRule() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        val gate = CompletableDeferred<ForwardedServiceProbe>()
        runtime.answer = { gate.await() }

        val first = manager.launchServiceProbes(force = true)
        assertEquals(1, first.size)
        assertEquals(0, manager.launchServiceProbes(force = true).size)
        clock.set(3_600_000)
        assertEquals(0, manager.launchServiceProbes(force = false).size)

        gate.complete(ForwardedServiceProbe.Serving)
        first.joinAll()
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        runtime.answer = { ForwardedServiceProbe.Serving }
        assertEquals(1, manager.tick(force = true))
        assertEquals(2, runtime.probes.size)
    }

    /**
     * The one slot is the rule's, not the entry's: a stop and start, or a
     * target edit, makes a fresh entry that is due at once, and a probe still
     * out from the old one must keep a second from joining it.
     */
    @Test fun aProbeOutlivingItsEntryStillHoldsTheRulesOneSlot() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        val gate = CompletableDeferred<ForwardedServiceProbe>()
        runtime.answer = { gate.await() }

        val first = manager.launchServiceProbes(force = true)
        assertEquals(1, first.size)
        manager.stop(rule.id)
        manager.start(rule.id)
        assertTrue(manager.status(rule) is PortForwardingStatus.Listening)
        assertEquals(0, manager.launchServiceProbes(force = true).size)
        manager.reconcile(listOf(rule.copy(target = PortForwardEndpoint("web.internal", 3_001))))
        assertEquals(0, manager.launchServiceProbes(force = true).size)
        assertEquals(1, runtime.probes.size)

        gate.complete(ForwardedServiceProbe.Serving)
        first.joinAll()
        // Its answer was about the rule as it was, and lands nowhere.
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
        runtime.answer = { ForwardedServiceProbe.Serving }
        assertEquals(1, manager.tick(force = true))
        assertEquals(PortForwardEndpoint("web.internal", 3_001), runtime.probes.last())
    }

    @Test fun stopRestartFailureAndTargetChangeResetToUnknown() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Serving }

        manager.tick()
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        manager.stop(rule.id)
        assertEquals(PortForwardingStatus.Idle, manager.status(rule))
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))

        manager.start(rule.id)
        assertTrue(manager.status(rule) is PortForwardingStatus.Listening)
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
        // Newly carrying again: due at once, whatever the old clock said.
        assertEquals(1, manager.tick())
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        // A probe out while the target changes answers for the old target.
        val gate = CompletableDeferred<ForwardedServiceProbe>()
        runtime.answer = { gate.await() }
        val stale = manager.launchServiceProbes(force = true)
        val moved = rule.copy(target = PortForwardEndpoint("web.internal", 3_001))
        manager.reconcile(listOf(moved))
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
        gate.complete(ForwardedServiceProbe.Serving)
        stale.joinAll()
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
        assertEquals(moved, manager.states.value.getValue(rule.id).rule)

        runtime.answer = { ForwardedServiceProbe.Serving }
        assertEquals(1, manager.tick())
        assertEquals(PortForwardEndpoint("web.internal", 3_001), runtime.probes.last())
        assertEquals(ForwardedServiceState.Serving, manager.service(rule))

        // The listener dying under the rule: failed, and no longer serving.
        runtime.lease(rule).open.value = false
        manager.states.awaitValue { it[rule.id]?.status is PortForwardingStatus.Failed }
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))

        manager.detach()
        assertTrue(manager.states.value.isEmpty())
    }

    @Test fun aLabelEditKeepsTheServiceState() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Serving }
        manager.tick()

        manager.reconcile(listOf(rule.copy(label = "renamed")))

        assertEquals(ForwardedServiceState.Serving, manager.service(rule))
        assertEquals("renamed", manager.states.value.getValue(rule.id).rule.label)
    }

    @Test fun passiveEvidenceCountsAsAProbeForCadence() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }
        assertEquals(1, manager.tick())

        clock.set(3_000)
        runtime.lease(rule).passive(ForwardedServiceProbe.NotServing)
        manager.awaitObservations(2)

        clock.set(5_000)
        assertEquals(0, manager.tick())
        clock.set(8_000)
        assertEquals(1, manager.tick())

        clock.set(9_000)
        runtime.lease(rule).passive(ForwardedServiceProbe.Serving)
        manager.awaitService(rule, ForwardedServiceState.Serving)
        clock.set(9_000 + 14_999)
        assertEquals(0, manager.tick())
    }

    @Test fun anAnswerThatChangesNothingWritesNoNewStateMap() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Serving }
        manager.tick()
        val published = manager.states.value
        val logLines = logged.size

        clock.set(15_000)
        assertEquals(1, manager.tick())
        runtime.lease(rule).passive(ForwardedServiceProbe.Serving)
        manager.awaitObservations(3)

        assertSame(published, manager.states.value)
        assertEquals(logLines, logged.size)

        runtime.answer = { ForwardedServiceProbe.NotServing }
        manager.tick(force = true)
        assertNotSame(published, manager.states.value)
    }

    @Test fun anUnconfirmedTargetBacksOffToThirtySecondsAfterTwelveLooks() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }

        val last = manager.lookTwelveTimesAtFiveSeconds()

        clock.set(last + 5_000)
        assertEquals(0, manager.tick())
        clock.set(last + 29_999)
        assertEquals(0, manager.tick())
        clock.set(last + 30_000)
        assertEquals(1, manager.tick())
        assertEquals(13, runtime.probes.size)
    }

    @Test fun inconclusiveLooksCountTowardsTheBackoffToo() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.Inconclusive("ConnectionException") }

        val last = manager.lookTwelveTimesAtFiveSeconds()

        clock.set(last + 5_000)
        assertEquals(0, manager.tick())
        assertEquals(ForwardedServiceState.Unknown, manager.service(rule))
    }

    @Test fun startingToMonitorAgainRestoresTheBriskCadence() = runBlocking {
        val rule = webRule()
        val manager = attached(rule, tickMillis = 3_600_000)
        runtime.answer = { ForwardedServiceProbe.NotServing }
        val last = manager.lookTwelveTimesAtFiveSeconds()
        clock.set(last + 5_000)
        assertEquals(0, manager.tick())

        // One iteration, then the monitor sleeps for the long tick.
        val monitor = launch { manager.monitorServices() }
        runtime.awaitProbes(13)
        monitor.cancelAndJoin()
        assertEquals(13, runtime.probes.size)
    }

    @Test fun probingNowIgnoresCadenceAndRestoresTheBriskCadence() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }
        val last = manager.lookTwelveTimesAtFiveSeconds()

        clock.set(last + 1_000)
        manager.probeServicesNow()
        runtime.awaitProbes(13)
        manager.awaitObservations(13)

        // One unconfirmed look since the reset: brisk again.
        clock.set(last + 6_000)
        assertEquals(1, manager.tick())
    }

    @Test fun aServingAnswerResetsTheBackoff() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }
        val last = manager.lookTwelveTimesAtFiveSeconds()

        clock.set(last + 5_000)
        runtime.lease(rule).passive(ForwardedServiceProbe.Serving)
        manager.awaitService(rule, ForwardedServiceState.Serving)

        clock.set(last + 20_000)
        assertEquals(1, manager.tick())
        assertEquals(ForwardedServiceState.NotServing, manager.service(rule))
        // Without the reset this would be the 14th unconfirmed look, due 30 s on.
        clock.set(last + 25_000)
        assertEquals(1, manager.tick())
    }

    @Test fun passiveRefusalsLengthenTheStreakLikeProbes() = runBlocking {
        val rule = webRule()
        val manager = attached(rule)
        runtime.answer = { ForwardedServiceProbe.NotServing }
        assertEquals(1, manager.tick())
        repeat(11) { index ->
            clock.set((index + 1) * 1_000L)
            runtime.lease(rule).passive(ForwardedServiceProbe.NotServing)
            manager.awaitObservations(index + 2)
        }
        val last = 11_000L

        clock.set(last + 5_000)
        assertEquals(0, manager.tick())
        clock.set(last + 30_000)
        assertEquals(1, manager.tick())
    }

    @Test fun monitoringProbesUntilCancelled() = runBlocking {
        val rule = webRule()
        val manager = attached(rule, tickMillis = 10)
        runtime.answer = { ForwardedServiceProbe.Serving }

        val monitor = launch(Dispatchers.Default) { manager.monitorServices() }
        runtime.awaitProbes(1)
        manager.awaitService(rule, ForwardedServiceState.Serving)
        monitor.cancelAndJoin()
        val probed = runtime.probes.size

        clock.set(3_600_000)
        delay(100)
        assertEquals(probed, runtime.probes.size)
    }

    @Test fun nothingIsProbedWithoutARuntime() = runBlocking {
        val manager = manager()
        assertEquals(0, manager.launchServiceProbes(force = true).size)
        assertTrue(manager.states.value.isEmpty())
    }

    // region fixtures

    private fun manager(tickMillis: Long = 1_000) = PortForwardingManager(
        scope = scope,
        diagnostics = { code, values -> logged += code to values },
        policy = FakePolicy,
        clock = clock::get,
        monitorTickMillis = tickMillis,
    )

    private suspend fun attached(vararg rules: PortForwardRule, tickMillis: Long = 1_000): PortForwardingManager {
        val manager = manager(tickMillis)
        manager.attach(runtime, rules.toList())
        rules.forEach { rule ->
            assertTrue(manager.states.value.getValue(rule.id).status is PortForwardingStatus.Listening)
        }
        return manager
    }

    private suspend fun PortForwardingManager.tick(force: Boolean = false): Int {
        val jobs = launchServiceProbes(force)
        jobs.joinAll()
        return jobs.size
    }

    /** One forced probe that answers [outcome]. */
    private suspend fun PortForwardingManager.look(outcome: ForwardedServiceProbe) {
        runtime.answer = { outcome }
        assertEquals(1, tick(force = true))
    }

    /** Twelve unconfirmed probes 5 s apart from now; returns the last one's time. */
    private suspend fun PortForwardingManager.lookTwelveTimesAtFiveSeconds(): Long {
        val start = clock.get()
        repeat(12) { index ->
            clock.set(start + index * 5_000L)
            assertEquals("look ${index + 1}", 1, tick())
        }
        assertEquals(12, runtime.probes.size)
        return clock.get()
    }

    private fun PortForwardingManager.service(rule: PortForwardRule) =
        states.value.getValue(rule.id).service

    private fun PortForwardingManager.status(rule: PortForwardRule) =
        states.value.getValue(rule.id).status

    private suspend fun PortForwardingManager.awaitService(rule: PortForwardRule, service: ForwardedServiceState) {
        states.awaitValue { it[rule.id]?.service == service }
    }

    /** Waits until the manager has applied [count] observations in total. */
    private suspend fun PortForwardingManager.awaitObservations(count: Int) {
        withTimeout(5_000) {
            while (observationCount() < count) delay(5)
        }
    }

    private suspend fun <T> StateFlow<T>.awaitValue(predicate: (T) -> Boolean) {
        withTimeout(5_000) { first(predicate) }
    }

    private suspend fun FakeRuntime.awaitProbes(count: Int) {
        withTimeout(5_000) {
            while (probes.size < count) delay(5)
        }
    }

    private fun webRule() = rule(bindPort = 18_080, targetPort = 3_000)

    private fun rule(bindPort: Int, targetPort: Int) = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint("127.0.0.1", bindPort),
        target = PortForwardEndpoint("web.internal", targetPort),
    )

    /**
     * Stands in for the shared-core policy: only restart-relevant fields
     * restart, and only plain-http local targets are watched.
     */
    private object FakePolicy : ForwardingRulePolicy {
        override fun validate(rule: PortForwardRule, against: Collection<PortForwardRule>): PortForwardRuleError? = null

        override fun requiresRestart(from: PortForwardRule, to: PortForwardRule) =
            from.direction != to.direction || from.bind != to.bind || from.target != to.target

        override fun watchesService(rule: PortForwardRule) =
            rule.direction == PortForwardDirection.LOCAL && rule.target?.port !in setOf(443, 5_432)
    }

    private class FakeRuntime : PortForwardingRuntime {
        override val capabilities = ForwardingCapabilities(local = true, remote = true, dynamic = true)
        private val leases = ConcurrentHashMap<UUID, FakeLease>()
        val probes = CopyOnWriteArrayList<PortForwardEndpoint>()

        @Volatile var answer: suspend (PortForwardEndpoint) -> ForwardedServiceProbe = {
            ForwardedServiceProbe.Inconclusive("unset")
        }

        fun lease(rule: PortForwardRule): FakeLease = leases.getValue(rule.id)

        override suspend fun start(rule: PortForwardRule): PortForwardingLease =
            FakeLease(BoundForwardEndpoint(rule.bind.host, rule.bind.port)).also { leases[rule.id] = it }

        override suspend fun probe(target: PortForwardEndpoint): ForwardedServiceProbe {
            probes += target
            return answer(target)
        }

        override fun close() = Unit
    }

    private class FakeLease(override val bound: BoundForwardEndpoint) : PortForwardingLease {
        val count = MutableStateFlow(0)
        val open = MutableStateFlow(true)
        private val evidence = MutableSharedFlow<ForwardedServiceProbe>(extraBufferCapacity = 16)

        override val activeConnectionCount: StateFlow<Int> = count
        override val isOpen: StateFlow<Boolean> = open
        override val serviceEvidence: Flow<ForwardedServiceProbe> = evidence

        /** Reports one real connection's open outcome, once the manager listens. */
        suspend fun passive(outcome: ForwardedServiceProbe) {
            withTimeout(5_000) { evidence.subscriptionCount.first { it > 0 } }
            evidence.emit(outcome)
        }

        override fun close() {
            open.value = false
        }
    }

    // endregion
}
