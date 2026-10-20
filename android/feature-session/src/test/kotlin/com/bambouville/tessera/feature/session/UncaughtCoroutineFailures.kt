package com.bambouville.tessera.feature.session

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement
import java.util.Collections
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * Fails a test when a coroutine it started failed where nothing was
 * awaiting it.
 *
 * Production gives a controller [LiveSessionStore.scope]: a supervisor
 * with no handler, so on a device such a failure crashes the app. A
 * fixture scope used to be `CoroutineScope(dispatcher)`. Its plain job
 * printed the first failure to stderr and then cancelled the scope, so
 * every later launch (Main's drain of a callback's batch, a bell, a
 * restore save) was silently dropped. A test asserting on that later work
 * could pass for the wrong reason.
 *
 * [scope] is the production shape, with this rule's handler, so siblings
 * keep running. Scopes a fixture cannot build, such as
 * [LiveSessionStore.scope], reach the rule through
 * [UncaughtCoroutineFailureCollector], the JVM-wide handler
 * kotlinx.coroutines loads for failures in scopes with none. Each failure
 * is attached to the test's verdict.
 */
class UncaughtCoroutineFailures : TestRule {
    private val failures = Collections.synchronizedList(mutableListOf<Throwable>())

    val handler = CoroutineExceptionHandler { _, failure -> failures += failure }

    /** A supervisor scope on [dispatcher] whose child failures fail the test. */
    fun scope(dispatcher: CoroutineDispatcher): CoroutineScope = CoroutineScope(SupervisorJob() + dispatcher + handler)

    internal fun record(failure: Throwable) {
        failures += failure
    }

    override fun apply(base: Statement, description: Description): Statement = object : Statement() {
        override fun evaluate() {
            failures.clear()
            UncaughtCoroutineFailureCollector.active = this@UncaughtCoroutineFailures
            var verdict: Throwable? = null
            try {
                base.evaluate()
            } catch (failure: Throwable) {
                verdict = failure
            } finally {
                UncaughtCoroutineFailureCollector.active = null
            }
            val uncaught = synchronized(failures) { failures.toList() }
            if (uncaught.isNotEmpty()) {
                val report = verdict ?: AssertionError(
                    "${uncaught.size} coroutine(s) failed uncaught during ${description.methodName}; first: ${uncaught.first()}",
                )
                uncaught.forEach { if (it !== report) report.addSuppressed(it) }
                throw report
            }
            verdict?.let { throw it }
        }
    }
}

/**
 * Registered in `META-INF/services/kotlinx.coroutines.CoroutineExceptionHandler`
 * and loaded once per JVM. It reports to the rule of the test that is
 * running, if any. It returns normally, so the failure is also printed.
 */
class UncaughtCoroutineFailureCollector :
    AbstractCoroutineContextElement(CoroutineExceptionHandler), CoroutineExceptionHandler {
    override fun handleException(context: CoroutineContext, exception: Throwable) {
        active?.record(exception)
    }

    internal companion object {
        @Volatile var active: UncaughtCoroutineFailures? = null
    }
}
