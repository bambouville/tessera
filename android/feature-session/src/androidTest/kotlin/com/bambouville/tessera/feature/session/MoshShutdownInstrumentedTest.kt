package com.bambouville.tessera.feature.session

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.content.ComponentName
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.networking.*
import com.bambouville.tessera.networking.mosh.*
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real transport queue/driver lock/main looper. Only UDP producer/bootstrap are replaced. */
@RunWith(AndroidJUnit4::class)
class MoshShutdownInstrumentedTest {
    @Test fun backgroundCleanupCannotBlockRelaunchWithFullOutputQueue() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val emit = AtomicBoolean(false)
        val nativeClosed = AtomicBoolean(false)
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult("192.0.2.1", 60001, "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), 42)
            },
            nativeFactory = MoshNativeClientFactory { _, _, _, output ->
                object : MoshNativeClient {
                    override fun start() = Unit
                    override fun tick(): Long {
                        if (emit.compareAndSet(true, false)) repeat(17) { output("frame-$it".encodeToByteArray()) }
                        return MoshNativeClient.NO_DEADLINE
                    }
                    override fun inject(bytes: ByteArray) = Unit
                    override fun resize(columns: Int, rows: Int) = Unit
                    override fun forceFullRepaint() = Unit
                    override fun beginFullRepaintFence(): Long = 1
                    override fun fullRepaintFenceReady(token: Long): Boolean = token == 1L
                    override val connected = true
                    override val transportReachable = true
                    override val serverContactAgeMilliseconds: Long get() = 0
                    override val replyAgeMilliseconds: Long get() = 0
                    override val shutdownComplete = false
                    override fun close() { nativeClosed.set(true) }
                }
            },
        )
        val intent = Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val activity = instrumentation.startActivitySync(intent) as ComponentActivity
        instrumentation.runOnMainSync {
            activity.setContentView(TextView(activity).apply {
                text = "Mosh active — background / close / resume regression"
                textSize = 24f
                setTextColor(android.graphics.Color.WHITE)
                setBackgroundColor(android.graphics.Color.BLACK)
            })
        }
        transport.connect(MoshConnectRequest(MoshBootstrapRequest(
            route = SshRouteRequest(listOf(SshRouteHop("fixture", SshEndpoint("192.0.2.1"), "fixture", SshAuthentication.Password))),
            udpHost = "192.0.2.1",
        ), 80, 24))
        emit.set(true)
        withTimeout(5_000) { while (transport.pumpStats().backpressureBlocks == 0L) delay(10) }
        val closed = CountDownLatch(1)
        val resumed = CountDownLatch(1)
        var replacement: Activity? = null
        val drawn = CountDownLatch(1)
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(next: Activity, state: Bundle?) {
                if (next === activity) return
                replacement = next
                next.setContentView(TextView(next).apply {
                    viewTreeObserver.addOnDrawListener { drawn.countDown() }
                    text = "Mosh cleanup completed — app reopened"
                    textSize = 24f
                    setTextColor(android.graphics.Color.WHITE)
                    setBackgroundColor(android.graphics.Color.BLACK)
                })
            }
            override fun onActivityResumed(next: Activity) { if (next !== activity) resumed.countDown() }
            override fun onActivityStarted(next: Activity) = Unit
            override fun onActivityPaused(next: Activity) = Unit
            override fun onActivityStopped(next: Activity) = Unit
            override fun onActivitySaveInstanceState(next: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(next: Activity) = Unit
        }
        activity.application.registerActivityLifecycleCallbacks(callbacks)
        try {
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
            delay(300)
            Handler(Looper.getMainLooper()).post {
                activity.finish()
                transport.close()
                closed.countDown()
            }
            // Launching while teardown runs must be serviced by the app's main looper.
            instrumentation.uiAutomation.executeShellCommand(
                "am start -n ${instrumentation.targetContext.packageName}/androidx.activity.ComponentActivity",
            ).close()
            val responsive = closed.await(1, TimeUnit.SECONDS)
            if (responsive) {
                // A completed native close must leave the actual main looper usable.
                assertTrue("Relaunch must resume a new Activity", resumed.await(3, TimeUnit.SECONDS))
                assertTrue("Reopened Activity must draw", drawn.await(3, TimeUnit.SECONDS))
                instrumentation.waitForIdleSync()
                delay(1_000)
            }
            val screenshot = instrumentation.uiAutomation.takeScreenshot()
            File(instrumentation.targetContext.filesDir, "shutdown-resume.png").outputStream().use {
                screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            screenshot.recycle()
            // Rescue the known-bad build without leaving a blocked main thread or test process.
            if (!responsive) withTimeout(3_000) { transport.output.take(1).toList() }
            assertTrue("Cleanup must finish after bounded baseline rescue", closed.await(3, TimeUnit.SECONDS))
            assertTrue(nativeClosed.get())
            assertTrue("Mosh close must unblock pending send before waiting for its driver lock; main thread stalled", responsive)
        } finally {
            activity.application.unregisterActivityLifecycleCallbacks(callbacks)
            // Never enqueue synchronous UI cleanup behind the baseline deadlock.
            if (closed.count > 0) {
                withTimeout(3_000) { transport.output.take(1).toList() }
            }
            if (closed.await(3, TimeUnit.SECONDS)) {
                instrumentation.runOnMainSync {
                    replacement?.finish()
                    if (!activity.isFinishing) activity.finish()
                }
            }
        }
    }
}
