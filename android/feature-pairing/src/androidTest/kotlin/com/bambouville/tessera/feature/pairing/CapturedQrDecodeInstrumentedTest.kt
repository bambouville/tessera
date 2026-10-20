package com.bambouville.tessera.feature.pairing

import android.graphics.BitmapFactory
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Diagnostic oracle only: never pairs or supplies decoded text to the app. */
class CapturedQrDecodeInstrumentedTest {
    @Test fun capturedPixelsAreDecodable() {
        val path = InstrumentationRegistry.getArguments().getString("capturedImage") ?: return
        val bitmap = checkNotNull(BitmapFactory.decodeFile(path))
        val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
        try {
            val results = Tasks.await(scanner.process(InputImage.fromBitmap(bitmap, 0)), 30, TimeUnit.SECONDS)
            assertTrue("Captured QR must decode with the production ML Kit engine",
                results.any { it.rawValue?.startsWith("tessera://pair/v1?offer=") == true })
        } finally {
            scanner.close()
            bitmap.recycle()
        }
    }
}
