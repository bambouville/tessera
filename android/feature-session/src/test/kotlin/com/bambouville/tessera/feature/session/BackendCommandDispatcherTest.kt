package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedBackendCommand
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class BackendCommandDispatcherTest {
    /** The controller's scope is a supervisor, and a command that fails in it would crash the app. */
    @get:Rule
    val coroutineFailures = UncaughtCoroutineFailures()

    /**
     * The autocorrect scramble, in miniature. Gboard revising "something"
     * emits four DELs and nine characters about 2 ms apart; each one used to
     * become its own coroutine, and the transport's dispatcher hop then let
     * them overtake each other, so the pty echoed "smehtiong". A lane that
     * only holds under a single-threaded dispatcher would not have caught it,
     * so this runs on the multi-threaded default pool and makes every command
     * suspend where a real transport does.
     */
    @Test
    fun anAutocorrectRevisionReachesTheTransportInSubmissionOrder() {
        repeat(20) {
            val scope = coroutineFailures.scope(Dispatchers.Default)
            val performed = Collections.synchronizedList(mutableListOf<Int>())
            val done = CountDownLatch(REVISION.size)
            val dispatcher = BackendCommandDispatcher(scope) { command ->
                // Every transport hops threads before it writes a byte.
                yield()
                delay(1)
                performed += (command as SharedBackendCommand.SendInput).bytes.single().toInt()
                done.countDown()
            }

            REVISION.forEach { byte ->
                dispatcher.dispatch(SharedBackendCommand.SendInput(byteArrayOf(byte.toByte())))
            }

            assertTrue(done.await(10, TimeUnit.SECONDS))
            assertEquals(REVISION, performed.toList())
            scope.cancel()
        }
    }

    /** A stalled connect must not hold the keystrokes that follow it. */
    @Test
    fun aStalledCommandOutsideTheLaneDoesNotWedgeTyping() {
        val scope = coroutineFailures.scope(Dispatchers.Default)
        val entered = CountDownLatch(1)
        val typed = CountDownLatch(1)
        val dispatcher = BackendCommandDispatcher(scope) { command ->
            when (command) {
                is SharedBackendCommand.SendInput -> typed.countDown()
                else -> {
                    entered.countDown()
                    delay(Long.MAX_VALUE)
                }
            }
        }

        dispatcher.dispatch(SharedBackendCommand.Disconnect)
        assertTrue(entered.await(10, TimeUnit.SECONDS))
        dispatcher.dispatch(SharedBackendCommand.SendInput(byteArrayOf('a'.code.toByte())))

        assertTrue(typed.await(10, TimeUnit.SECONDS))
        scope.cancel()
    }

    @Test
    fun onlyTheByteCarryingCommandsTakeTheOrderedLane() {
        assertTrue(SharedBackendCommand.SendInput(byteArrayOf(1)).carriesOrderedInput())
        assertTrue(SharedBackendCommand.SendTmuxPaneInput("%1", byteArrayOf(1), null).carriesOrderedInput())
        assertTrue(
            SharedBackendCommand.SendTmuxPaneKey(
                paneId = "%1",
                key = com.bambouville.tessera.core.bridge.SharedTmuxPaneKey.ENTER,
                receipt = null,
            ).carriesOrderedInput(),
        )
        assertFalse(SharedBackendCommand.Disconnect.carriesOrderedInput())
        assertFalse(SharedBackendCommand.Resize(80, 24).carriesOrderedInput())
        assertFalse(SharedBackendCommand.RequestFullRepaint.carriesOrderedInput())
    }

    private companion object {
        /** Four DELs, then "omething ". */
        val REVISION: List<Int> = List(4) { 0x7F } + "omething ".map(Char::code)
    }
}
