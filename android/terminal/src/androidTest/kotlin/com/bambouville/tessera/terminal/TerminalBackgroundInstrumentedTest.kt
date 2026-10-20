package com.bambouville.tessera.terminal

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TerminalBackgroundInstrumentedTest {
    @Test
    fun importsOwnedImageCachesBlurVariantAndDeletesItsWholeLifecycle() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = TerminalBackgroundImageStore(context)
        val imported = store.importImage(twoToneJpeg())
        assertNotNull(imported)
        imported ?: return

        try {
            assertTrue(store.imageExists(imported.imageId))
            assertTrue((store.byteCount(imported.imageId) ?: 0) > 0)
            val base = store.image(imported.imageId)
            val blurred = store.image(imported.imageId, blurRadiusDp = 2f)
            assertNotNull(base)
            assertNotNull(blurred)
            assertEquals(base!!.width, blurred!!.width)
            assertEquals(base.height, blurred.height)
        } finally {
            store.delete(imported.imageId)
        }
        assertFalse(store.imageExists(imported.imageId))
        assertEquals(null, store.image(imported.imageId))
    }

    @Test
    fun fitLetterboxesAndDimUsesTheThemeColorAsScrim() {
        val image = Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888).apply {
            setPixel(0, 0, Color.RED)
            setPixel(1, 0, Color.BLUE)
        }
        val output = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        TerminalBackgroundDrawable(
            bitmap = image,
            baseColor = Color.BLACK,
            dim = 0.5f,
            fillMode = TerminalBackgroundFillMode.Fit,
        ).apply {
            setBounds(0, 0, 100, 100)
            draw(Canvas(output))
        }

        assertEquals("fit must retain terminal-color letterboxing", Color.BLACK, output.getPixel(50, 10))
        val center = output.getPixel(25, 50)
        assertTrue("theme-color dim must darken the image", Color.red(center) in 120..135)
        assertTrue(Color.blue(center) < 10)
    }

    private fun twoToneJpeg(): ByteArray {
        val bitmap = Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888)
        repeat(bitmap.height) { y ->
            repeat(bitmap.width) { x -> bitmap.setPixel(x, y, if (x < 16) Color.RED else Color.BLUE) }
        }
        return ByteArrayOutputStream().use { bytes ->
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, bytes))
            bytes.toByteArray()
        }
    }
}
