package com.bambouville.tessera.files

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

class RemoteMarkdownImagesInstrumentedTest {
    @Test fun localImagesStageAndRenderInQuickLook() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val cache = RemoteFilePresentationCache(context)
        val document = cache.create("images.md")
        document.writeText("""
            # Local images

            Relative path:

            ![Relative image][plot]

            Absolute path:

            [![Absolute image](/opt/red.png)](https://example.com/details)

            | In a table |
            | --- |
            | ![Table image](<images/my plot.png>) |

            ![Missing image](missing.png)

            [plot]: ../images/blue%20plot.png
        """.trimIndent())
        fun png(color: Int, label: String): ByteArray {
            val bitmap = Bitmap.createBitmap(300, 48, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(color)
            canvas.drawText(label, 14f, 32f, Paint().apply { this.color = Color.WHITE; textSize = 20f; isFakeBoldText = true })
            return ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                bitmap.recycle()
                output.toByteArray()
            }
        }
        val remote = mapOf(
            "/docs/../images/blue plot.png" to png(Color.BLUE, "RELATIVE IMAGE"),
            "/opt/red.png" to png(Color.RED, "ABSOLUTE IMAGE"),
            "/docs/images/my plot.png" to png(Color.GREEN, "TABLE IMAGE"),
        )
        val requested = mutableListOf<String>()
        val images = RemoteMarkdownImages.stage(document, "/docs/readme.md", cache::create) { path, output ->
            requested += path
            output.write(remote[path] ?: error("No such remote image"))
        }
        assertEquals(remote.keys + "/docs/missing.png", requested.toSet())
        assertEquals(3, images.size)
        cache.dispatch(document, "images.md", RemoteFilePresentationAction.OPEN, images)
        var screenshot: Bitmap? = null
        var rendered = false
        repeat(80) {
            if (!rendered) {
                Thread.sleep(250)
                screenshot?.recycle()
                screenshot = instrumentation.uiAutomation.takeScreenshot()
                val bitmap = screenshot ?: return@repeat
                val pixels = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                rendered = pixels.count { it == Color.BLUE } > 1000 && pixels.count { it == Color.RED } > 1000 && pixels.count { it == Color.GREEN } > 500
            }
        }
        screenshot?.let { bitmap ->
            File(context.filesDir, "markdown-images.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        assertTrue("All three staged image colors must be visible", rendered)
        images.values.forEach { it.delete() }
        document.delete()
    }
}
