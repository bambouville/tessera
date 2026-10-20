package com.bambouville.tessera.feature.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.Description
import org.junit.runners.model.Statement

/** The fixture rule that makes a fixture's lost coroutine failures fail its test. */
class UncaughtCoroutineFailuresTest {
    private val scheduler = TestCoroutineScheduler()

    /** [body] as a test under a fresh rule; the rule's verdict, or null if it passed. */
    private fun verdict(body: (UncaughtCoroutineFailures) -> Unit): Throwable? {
        val rule = UncaughtCoroutineFailures()
        val statement = rule.apply(
            object : Statement() {
                override fun evaluate() = body(rule)
            },
            Description.createTestDescription(javaClass, "probe"),
        )
        return runCatching { statement.evaluate() }.exceptionOrNull()
    }

    @Test
    fun aFixtureScopesChildFailureFailsTheTestAndItsSiblingsStillRun() {
        val ran = mutableListOf<String>()
        val boom = IllegalStateException("drain failed")
        val verdict = verdict { rule ->
            val scope = rule.scope(StandardTestDispatcher(scheduler))
            scope.launch { throw boom }
            scope.launch { ran += "the later drain" }
            scheduler.runCurrent()
        }
        assertEquals("a supervisor, as production's scope is", listOf("the later drain"), ran)
        assertTrue(verdict.toString(), verdict is AssertionError)
        assertSame(boom, verdict!!.suppressed.single())
    }

    @Test
    fun aHandlerlessScopeTheFixtureDidNotBuildStillFailsTheTest() {
        // LiveSessionStore.scope's shape: a supervisor with no handler.
        val boom = IllegalStateException("store work failed")
        val verdict = verdict {
            val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
            scope.launch { throw boom }
            scheduler.runCurrent()
            scope.cancel()
        }
        assertSame("reported through the JVM-wide collector", boom, verdict?.suppressed?.single())
    }

    @Test
    fun aTestThatFailsKeepsItsOwnVerdictWithTheCoroutineFailureAttached() {
        val boom = IllegalStateException("drain failed")
        val verdict = verdict { rule ->
            rule.scope(StandardTestDispatcher(scheduler)).launch { throw boom }
            scheduler.runCurrent()
            fail("the assertion's own message")
        }
        assertEquals("the assertion's own message", verdict?.message)
        assertSame(boom, verdict!!.suppressed.single())
    }

    @Test
    fun aCleanTestPassesAndLeavesNoCollectorBehind() {
        assertNull(verdict { rule -> rule.scope(StandardTestDispatcher(scheduler)).launch { }; scheduler.runCurrent() })
        assertNull(UncaughtCoroutineFailureCollector.active)
    }
}
