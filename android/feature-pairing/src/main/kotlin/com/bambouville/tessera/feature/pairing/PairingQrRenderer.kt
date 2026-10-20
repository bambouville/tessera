package com.bambouville.tessera.feature.pairing

import android.graphics.Bitmap
import androidx.core.graphics.createBitmap
import androidx.core.graphics.set
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

internal object PairingQrRenderer {
    fun render(text: String, side: Int = 640): Bitmap {
        require(text.startsWith("tessera://pair/v1?offer="))
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, side, side, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))
        return createBitmap(side, side, Bitmap.Config.ARGB_8888).also { bitmap ->
            for (y in 0 until side) for (x in 0 until side) bitmap[x, y] = if (matrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
        }
    }
}
