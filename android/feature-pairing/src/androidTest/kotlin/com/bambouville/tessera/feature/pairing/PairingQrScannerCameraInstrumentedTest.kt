package com.bambouville.tessera.feature.pairing

import android.Manifest
import android.os.Looper
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.DisplayText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference

/**
 * The production scanner reads an offer through CameraX. Needs an emulator
 * started with `-camera-back imagefile:<png of an offer>` and the offer's
 * SHA-256 in the `cameraOfferSha256` argument; skipped otherwise. Never pairs:
 * the decoded text goes no further than this test.
 */
class PairingQrScannerCameraInstrumentedTest {
    @get:Rule val compose = createComposeRule()

    @Test fun scansTheOfferTheCameraSees() {
        val expected = InstrumentationRegistry.getArguments().getString("cameraOfferSha256")
        assumeTrue("needs an imagefile back camera and cameraOfferSha256", expected != null)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, Manifest.permission.CAMERA)

        val scanned = AtomicReference<String?>()
        val failure = AtomicReference<DisplayText?>()
        val scanThread = AtomicReference<Thread?>()
        compose.setContent {
            PairingQrScanner(
                onScanned = {
                    scanThread.compareAndSet(null, Thread.currentThread())
                    scanned.compareAndSet(null, it)
                },
                onFailure = { failure.compareAndSet(null, it) },
            )
        }
        compose.waitUntil(timeoutMillis = 60_000) { scanned.get() != null || failure.get() != null }

        assertNull(failure.get())
        val offer = checkNotNull(scanned.get())
        assertTrue(offer.startsWith(PairingQrDecoder.OFFER_PREFIX))
        assertEquals(expected, MessageDigest.getInstance("SHA-256").digest(offer.toByteArray()).joinToString("") { "%02x".format(it) })
        assertSame(Looper.getMainLooper().thread, scanThread.get())
    }
}
