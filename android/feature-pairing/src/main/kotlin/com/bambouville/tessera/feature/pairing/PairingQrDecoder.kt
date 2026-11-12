package com.bambouville.tessera.feature.pairing

import android.graphics.Bitmap
import androidx.camera.core.ImageProxy
import zxingcpp.BarcodeReader

/**
 * Finds a pairing offer in a camera frame.
 *
 * zxing-cpp rather than ML Kit, which reports usage to Google; Tessera sends
 * nothing anywhere. ZXing's Java port, already here to draw offers, misses
 * these dense codes once a frame is slightly blurred or noisy. Both apps draw
 * offers dark on light, so inverted codes are not searched for.
 *
 * Not thread-safe: give each analyzer its own.
 */
internal class PairingQrDecoder {
    private val reader = BarcodeReader(
        BarcodeReader.Options(
            formats = setOf(BarcodeReader.Format.QR_CODE),
            tryHarder = true,
            tryDownscale = true,
        ),
    )

    /** The offer in a camera frame, or null when it shows none. */
    fun decode(frame: ImageProxy): String? = reader.read(frame).offer()

    /** The offer in a still image, or null when it shows none. */
    fun decode(image: Bitmap): String? = reader.read(image).offer()

    private fun List<BarcodeReader.Result>.offer() =
        firstNotNullOfOrNull { result -> result.text?.takeIf { it.startsWith(OFFER_PREFIX) } }

    companion object {
        const val OFFER_PREFIX = "tessera://pair/v1?offer="
    }
}
