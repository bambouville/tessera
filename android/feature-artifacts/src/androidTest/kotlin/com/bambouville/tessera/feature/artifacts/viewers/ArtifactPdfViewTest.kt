package com.bambouville.tessera.feature.artifacts.viewers

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.artifacts.ArtifactsFixtureActivity
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ArtifactPdfViewTest {
    @get:Rule val compose = createAndroidComposeRule<ArtifactsFixtureActivity>()
    private val fixtures = mutableListOf<File>()

    @After fun removeFixtures() {
        compose.activityRule.scenario.onActivity { it.installFixture {} }
        compose.waitForIdle()
        compose.waitUntil(10_000) { fixtures.all { descriptorsFor(it) == 0 } }
        fixtures.forEach { it.delete() }
    }

    @Test fun documentViewerDrawsTheFirstPageOfALocallyGeneratedPdfInline() {
        val file = newFixture()
        writePdf(file, pages = 2, color = Color.RED)
        show(file)
        waitForPage(1)
        compose.onNodeWithContentDescription("page 1 of 2").assertIsDisplayed()
        assertPageColor(1, red = true)
        compose.onAllNodesWithText("open with…").assertCountEquals(0)
    }

    @Test fun scrollingEvictsOldPagesAndDrawsADistantPage() {
        val file = newFixture()
        writePdf(file, pages = 12, color = Color.BLUE)
        show(file)
        waitForPage(1)
        compose.onNodeWithTag("artifacts-pdf-pages").performScrollToIndex(10)
        waitForPage(11)
        compose.onNodeWithContentDescription("page 11 of 12").assertIsDisplayed()
        assertPageColor(11, red = false)
        compose.onAllNodesWithTag("artifacts-pdf-page-1").assertCountEquals(0)
    }

    @Test fun reloadReplacesTheRendererAndDisposalClosesItsFileDescriptor() {
        val file = newFixture()
        writePdf(file, pages = 1, color = Color.RED)
        val baseline = descriptorsFor(file)
        var reloadToken by mutableLongStateOf(0L)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme { ArtifactDocumentView(file, "fixture.pdf", reloadToken = reloadToken) }
            }
        }
        waitForPage(1)
        assertPageColor(1, red = true)
        val opened = descriptorsFor(file)
        assertTrue("the renderer must own the cached file", opened > baseline)
        val replacement = newFixture()
        writePdf(replacement, pages = 2, color = Color.BLUE)
        // The production cache replaces files atomically, rather than writing
        // through the inode an existing PdfRenderer is still reading.
        assertTrue(replacement.renameTo(file))
        compose.runOnIdle { reloadToken++ }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("page 1 of 2").fetchSemanticsNodes().isNotEmpty() &&
                compose.onAllNodesWithTag("artifacts-pdf-page-1").fetchSemanticsNodes().isNotEmpty()
        }
        assertPageColor(1, red = false)
        compose.waitUntil(10_000) { descriptorsFor(file) == opened }
        compose.activityRule.scenario.onActivity { it.installFixture {} }
        compose.waitUntil(10_000) { descriptorsFor(file) == baseline }
    }

    @Test fun corruptPdfKeepsTheFailureAndSecondaryOpenWithAction() {
        val file = newFixture().apply { writeText("%PDF-1.7\ncorrupt fixture\n") }
        show(file)
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("artifacts-document-failure").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("artifacts-document-failure").assertIsDisplayed()
        compose.onNodeWithTag("artifacts-open-with").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-pdf-page-1").assertCountEquals(0)
    }

    @Test fun unsupportedBinaryStillOffersOpenWith() {
        val file = newFixture().apply { writeBytes(byteArrayOf(0, 1, 2, 3)) }
        show(file, "archive.tar")
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("artifacts-open-with").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("artifacts-open-with").assertIsDisplayed()
        compose.onAllNodesWithTag("artifacts-pdf").assertCountEquals(0)
    }

    @Test fun anEvictedBitmapIsRecycledAfterTheComposedRowReleasesIt() {
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        val cached = ArtifactPdfBitmap(bitmap)
        cached.acquire()
        cached.retire()
        assertFalse(bitmap.isRecycled)
        cached.release()
        assertTrue(bitmap.isRecycled)
        val unused = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        ArtifactPdfBitmap(unused).retire()
        assertTrue(unused.isRecycled)
    }

    @Test fun renderingUsesTheColumnWidthAndBoundsOversizedAllocations() {
        val file = newFixture()
        writePdf(file, pages = 1, color = Color.RED)
        runBlocking(Dispatchers.IO) {
            ArtifactPdfDocument.open(file).use { document ->
                val fitted = document.renderPage(0, 640)
                try {
                    assertEquals(640, fitted.width)
                    assertEquals(880, fitted.height)
                } finally { fitted.recycle() }
                val bounded = document.renderPage(0, 100_000)
                try { assertTrue(bounded.width.toLong() * bounded.height <= 2 * 1024 * 1024) }
                finally { bounded.recycle() }
            }
        }
    }

    private fun show(file: File, displayName: String = "fixture.pdf") {
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture { TesseraTheme { ArtifactDocumentView(file, displayName) } }
        }
    }

    private fun waitForPage(number: Int) {
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag("artifacts-pdf-page-$number").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("artifacts-pdf-page-$number").assertIsDisplayed()
    }

    private fun assertPageColor(number: Int, red: Boolean) {
        val pixels = compose.onNodeWithTag("artifacts-pdf-page-$number").captureToImage().toPixelMap()
        val color = pixels[pixels.width / 2, pixels.height / 2]
        assertTrue("the actual PDF bitmap must be drawn", if (red) color.red > 0.8f && color.blue < 0.2f
            else color.blue > 0.8f && color.red < 0.2f)
    }

    private fun newFixture(): File = File.createTempFile("artifacts-pdf-", ".pdf", compose.activity.cacheDir)
        .also { fixtures += it }

    private fun writePdf(file: File, pages: Int, color: Int) {
        val document = PdfDocument()
        try {
            for (number in 1..pages) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(320, 440, number).create())
                page.canvas.drawColor(color)
                page.canvas.drawText("fixture page $number", 24f, 48f, Paint().apply { textSize = 20f })
                document.finishPage(page)
            }
            file.outputStream().use { document.writeTo(it) }
        } finally { document.close() }
    }

    private fun descriptorsFor(file: File): Int {
        val path = file.canonicalPath
        return File("/proc/self/fd").listFiles().orEmpty().count {
            try { File(Files.readSymbolicLink(it.toPath()).toString().removeSuffix(" (deleted)")).canonicalPath == path }
            catch (_: Exception) { false }
        }
    }
}
