package com.bambouville.tessera

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * About must carry the licence texts themselves (GPLv3 §6), so each viewer is
 * opened and checked for its real text, not just its row. The links are only
 * checked for presence: tapping one would leave the app for a browser.
 */
@RunWith(AndroidJUnit4::class)
class AboutSettingsInstrumentedTest {
    @get:Rule
    val compose = createComposeRule()

    private fun showAbout() {
        compose.setContent {
            TesseraTheme(darkTheme = true) {
                AboutSettings(Modifier.verticalScroll(rememberScrollState()))
            }
        }
    }

    @Test
    fun showsVersionLicenseAndEveryRow() {
        showAbout()
        compose.onNodeWithText("tessera · v${BuildConfig.VERSION_NAME}").assertIsDisplayed()
        compose.onNodeWithText("build ${BuildConfig.VERSION_CODE}").assertIsDisplayed()
        compose.onNodeWithText("GNU General Public License v3", substring = true).assertIsDisplayed()
        compose.onNodeWithText("© 2026 Bambouville Inc.").assertIsDisplayed()
        listOf(
            "view source code",
            "privacy policy",
            "view license (GPL-3.0)",
            "additional terms & trademark notice",
            "gpl-3.0 at gnu.org",
            "Mosh (mobile shell)",
            "zxing-cpp & ZXing",
            "view third-party licenses & notices",
            "view Agent Host licenses & notices",
        ).forEach { compose.onNodeWithText(it).performScrollTo().assertIsDisplayed() }
    }

    @Test
    fun theLicenseViewerShowsTheGpl() {
        open("view license (GPL-3.0)", firstText = "GNU GENERAL PUBLIC LICENSE")
        scrollTo("END OF TERMS AND CONDITIONS")
        closeViewer()
    }

    @Test
    fun theAdditionalTermsViewerShowsTheTrademarkReservation() {
        open("additional terms & trademark notice", firstText = "Mosh App Store distribution exception")
        scrollTo("Trademark reservation")
        closeViewer()
    }

    @Test
    fun theNoticesViewerCoversNativeAndJvmComponents() {
        open("view third-party licenses & notices", firstText = "Third-Party Notices for Tessera for Android")
        scrollTo("Mosh (mobile shell)")
        scrollTo("Copyright (c) 2012 Ted Krovetz.") // OCB3, inside Mosh
        scrollTo("Copyright (c) 2014 Jeff Quast") // wcwidth, inside Termux
        scrollTo("zxing-cpp 3.1.1")
        scrollTo("Copyright (C) 2022 gitlost") // libzueci, inside zxing-cpp
        scrollTo("BEGIN MAVEN INVENTORY")
        scrollTo("SIL OPEN FONT LICENSE Version 1.1")
        scrollTo("As an exception, if you use this Software to compile your source code")
        closeViewer()
    }

    @Test
    fun theAgentHostViewerShowsTheHelpersNotices() {
        val expected = InstrumentationRegistry.getInstrumentation().targetContext.assets
            .open(BundledDocument.AgentHostNotices.asset).bufferedReader().use { it.readText() }
        val firstLine = expected.lineSequence().first { it.isNotBlank() }.trim()
        assertTrue("Agent Host notices are empty", firstLine.isNotEmpty())
        open("view Agent Host licenses & notices", firstText = firstLine)
        closeViewer()
    }

    @Test
    fun everyBundledDocumentIsPacked() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        BundledDocument.entries.forEach { document ->
            assertNotNull("${document.asset} is missing from the APK", document.load(context))
        }
    }

    /** Opens [row]'s viewer and waits for the document's opening text. */
    private fun open(row: String, firstText: String) {
        showAbout()
        compose.onNodeWithText(row).performScrollTo().performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasText(firstText, substring = true) and inViewer).fetchSemanticsNodes().isNotEmpty() ||
                compose.onAllNodes(hasText("failed to load", substring = true) and inViewer).fetchSemanticsNodes().isNotEmpty()
        }
        inDocument("failed to load").assertDoesNotExist()
        inDocument(firstText).assertIsDisplayed()
    }

    /** [text] must occur once in the document: a taller screen lays out more paragraphs. */
    private fun scrollTo(text: String) {
        compose.onNodeWithTag(DOCUMENT_TEXT_TAG).performScrollToNode(hasText(text, substring = true))
        inDocument(text).assertIsDisplayed()
    }

    private fun closeViewer() {
        compose.onNodeWithText("done").performClick()
        compose.onNodeWithTag(DOCUMENT_TEXT_TAG).assertDoesNotExist()
        compose.onNodeWithText("view source code").assertExists()
    }

    // The page behind the viewer names some of the same components.
    private val inViewer = hasAnyAncestor(hasTestTag(DOCUMENT_TEXT_TAG))

    private fun inDocument(text: String): SemanticsNodeInteraction =
        compose.onNode(hasText(text, substring = true) and inViewer)
}
