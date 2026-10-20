package com.bambouville.tessera.core.bridge

import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.nio.ByteBuffer
import java.util.Collections
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CoreRuntimeInstrumentedTest {
    @Test
    fun routesTmuxSnapshotVectorThroughSharedRuntime() {
        val events = Collections.synchronizedList(mutableListOf<JSONObject>())
        val callbackLatch = CountDownLatch(4)
        CoreRuntime.create { event ->
            events += JSONObject(event.bytes.decodeToString())
            callbackLatch.countDown()
        }.use { runtime ->
            val requestID = "11111111-1111-4111-8111-111111111111"
            assertEquals(
                CoreCallResult.Accepted,
                runtime.send(
                    """{"v":4,"kind":"connect","requestID":"$requestID","hostID":"22222222-2222-4222-8222-222222222222","policyGeneration":1}"""
                        .encodeToByteArray(),
                ),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emit(
                    """{"version":1,"kind":"transportConnected","attemptID":"$requestID","policyGeneration":1}"""
                        .encodeToByteArray(),
                ),
            )

            val vectorBytes = InstrumentationRegistry.getInstrumentation()
                .context.assets.open("tmux/basic-topology.snapshot.json").use { it.readBytes() }
            val encodedVector = Base64.encodeToString(vectorBytes, Base64.NO_WRAP)
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emit(
                    """{"version":1,"kind":"tmuxSnapshotChanged","generation":1,"payload":"$encodedVector"}"""
                        .encodeToByteArray(),
                ),
            )

            assertTrue("shared runtime callbacks timed out", callbackLatch.await(10, TimeUnit.SECONDS))
            val snapshotEvent = synchronized(events) {
                events.firstOrNull { it.getString("kind") == "tmuxSnapshotChanged" }
            }
            assertNotNull("tmux vector did not cross the runtime", snapshotEvent)
            val outputSnapshot = JSONObject(
                Base64.decode(snapshotEvent!!.getString("payload"), Base64.DEFAULT).decodeToString(),
            )
            val expectedSnapshot = JSONObject(vectorBytes.decodeToString())
            assertEquals(
                expectedSnapshot.getJSONObject("sessionID").getLong("rawValue"),
                outputSnapshot.getJSONObject("sessionID").getLong("rawValue"),
            )
            assertEquals(
                expectedSnapshot.getJSONObject("activeWindowID").getLong("rawValue"),
                outputSnapshot.getJSONObject("activeWindowID").getLong("rawValue"),
            )
            assertEquals(expectedSnapshot.getJSONArray("windows").length(), outputSnapshot.getJSONArray("windows").length())
            assertEquals("logs", outputSnapshot.getJSONArray("windows").getJSONObject(1).getString("name"))
        }
    }

    @Test
    fun directBuffersSustainCoarseBatchThroughputWithoutOverlappingCallbacks() {
        val iterations = 128
        val bytesPerBatch = 64 * 1024
        val callbackLatch = CountDownLatch(iterations)
        val inCallback = AtomicBoolean(false)
        val overlap = AtomicBoolean(false)
        val callbackCount = AtomicInteger()
        CoreRuntime.create { event ->
            if (!inCallback.compareAndSet(false, true)) overlap.set(true)
            assertTrue(event.bytes.isNotEmpty())
            callbackCount.incrementAndGet()
            inCallback.set(false)
            callbackLatch.countDown()
        }.use { runtime ->
            val payload = ByteBuffer.allocateDirect(bytesPerBatch)
            repeat(bytesPerBatch) { payload.put('x'.code.toByte()) }
            payload.flip()
            val started = System.nanoTime()
            repeat(iterations) {
                assertEquals(CoreCallResult.Accepted, runtime.send(payload))
            }
            assertTrue("direct-buffer callbacks timed out", callbackLatch.await(30, TimeUnit.SECONDS))
            val elapsedSeconds = (System.nanoTime() - started) / 1_000_000_000.0
            val mebibytesPerSecond = iterations * bytesPerBatch / elapsedSeconds / (1024.0 * 1024.0)
            val callsPerSecond = iterations / elapsedSeconds
            Log.i(
                "TesseraCoreBridge",
                "direct-buffer throughput=${"%.2f".format(Locale.US, mebibytesPerSecond)} MiB/s " +
                    "calls=${"%.2f".format(Locale.US, callsPerSecond)}/s",
            )
            assertEquals(iterations, callbackCount.get())
            assertFalse("callbacks from one runtime overlapped", overlap.get())
            assertTrue("direct-buffer throughput regressed below 1 MiB/s", mebibytesPerSecond >= 1.0)
            assertTrue("coarse bridge throughput regressed below 16 calls/s", callsPerSecond >= 16.0)
        }
    }

    @Test
    fun callbackCanDestroyItsRuntimeWithoutLaterCallbacksOrStaleAccess() {
        val runtimeReference = AtomicReference<CoreRuntime>()
        val callbackLatch = CountDownLatch(1)
        val callbackCount = AtomicInteger()
        val runtime = CoreRuntime.create {
            callbackCount.incrementAndGet()
            runtimeReference.get().close()
            callbackLatch.countDown()
        }
        runtimeReference.set(runtime)

        assertEquals(CoreCallResult.Accepted, runtime.send("not-json".encodeToByteArray()))
        assertTrue("reentrant destroy callback timed out", callbackLatch.await(10, TimeUnit.SECONDS))
        assertEquals(CoreCallResult.StaleHandle, runtime.send("not-json".encodeToByteArray()))
        Thread.sleep(250)
        assertEquals(1, callbackCount.get())
        runtime.close()
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsHeapBuffersBeforeEnteringJni() {
        CoreRuntime.create { }.use { runtime ->
            runtime.send(ByteBuffer.wrap("not-direct".encodeToByteArray()))
        }
    }
}
