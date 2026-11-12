package com.bambouville.tessera.feature.pairing

import android.graphics.Bitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.random.Random

/** The native reader on camera-like frames; no camera or pairing involved. */
class PairingQrDecoderInstrumentedTest {
    // Real offers are about 900 characters, which makes a dense code; a short
    // one would pass at sizes where real offers fail.
    private val offer = PairingQrDecoder.OFFER_PREFIX + Random(7).let { random ->
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        (1..880).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
    }
    private val decoder = PairingQrDecoder()

    @Test fun readsADenseOfferAtThreePixelsPerModule() {
        assertEquals(offer, decoder.decode(frame(code(offer), moduleSize = 3).bitmap()))
    }

    // ZXing's Java port fails this frame; it is why the reader is zxing-cpp.
    @Test fun readsAnOfferThroughCameraBlurAndSensorNoise() {
        assertEquals(offer, decoder.decode(frame(code(offer), moduleSize = 4).blurred().noisy(amplitude = 24).bitmap()))
    }

    @Test fun readsAnOfferSideways() {
        assertEquals(offer, decoder.decode(frame(code(offer).rotated(), moduleSize = 3).bitmap()))
    }

    @Test fun ignoresCodesThatAreNotPairingOffers() {
        assertNull(decoder.decode(frame(code("https://example.com/tessera"), moduleSize = 6).bitmap()))
    }

    @Test fun aFrameWithoutACodeIsNotAnError() {
        assertNull(decoder.decode(Frame(IntArray(WIDTH * HEIGHT) { BACKGROUND }).noisy(amplitude = 24).bitmap()))
    }

    private class Frame(val luminance: IntArray) {
        fun blurred() = Frame(IntArray(luminance.size) { i ->
            val x = i % WIDTH
            val y = i / WIDTH
            var sum = 0
            var count = 0
            for (dy in -1..1) for (dx in -1..1) {
                if (x + dx in 0 until WIDTH && y + dy in 0 until HEIGHT) { sum += luminance[i + dy * WIDTH + dx]; count++ }
            }
            sum / count
        })

        fun noisy(amplitude: Int) = Random(11).let { random ->
            Frame(IntArray(luminance.size) { (luminance[it] + random.nextInt(-amplitude, amplitude + 1)).coerceIn(0, 255) })
        }

        fun bitmap(): Bitmap = Bitmap.createBitmap(
            IntArray(luminance.size) { 0xFF shl 24 or (luminance[it] * 0x010101) }, WIDTH, HEIGHT, Bitmap.Config.ARGB_8888,
        )
    }

    /** One module per matrix cell, no quiet zone; [frame] adds the margin. */
    private fun code(text: String): BitMatrix = QRCodeWriter().encode(
        text, BarcodeFormat.QR_CODE, 0, 0,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0),
    )

    private fun BitMatrix.rotated() = BitMatrix(height, width).also { out ->
        for (y in 0 until height) for (x in 0 until width) if (this[x, y]) out.set(height - 1 - y, x)
    }

    /**
     * A camera analysis frame with the code centred on screen grey, dark
     * modules a little lighter than black, as a camera sees a display.
     */
    private fun frame(code: BitMatrix, moduleSize: Int): Frame {
        val luminance = IntArray(WIDTH * HEIGHT) { BACKGROUND }
        val left = (WIDTH - code.width * moduleSize) / 2
        val top = (HEIGHT - code.height * moduleSize) / 2
        for (y in 0 until code.height * moduleSize) for (x in 0 until code.width * moduleSize) {
            if (code[x / moduleSize, y / moduleSize]) luminance[(top + y) * WIDTH + left + x] = MODULE
        }
        return Frame(luminance)
    }

    private companion object {
        const val WIDTH = 1280
        const val HEIGHT = 960
        const val BACKGROUND = 0xEA
        const val MODULE = 0x20
    }
}
