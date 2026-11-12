package com.bambouville.tessera

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.net.toUri
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraBannerTone
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraLogoMark
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.onboarding.LocalOnboardingController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * A licence document packed into the APK. GPLv3 §6 requires conveying the
 * licence text with the object code, so these open from assets rather than as
 * links; `legal/` is copied from the repository root at build time.
 */
internal enum class BundledDocument(
    /** Null where the title is a proper name that is never translated. */
    @param:StringRes val titleRes: Int?,
    val asset: String,
) {
    // "GNU GPL v3" is the licence's proper name.
    Gpl(null, "legal/LICENSE"),
    AdditionalTerms(R.string.app_about_doc_additional_terms, "legal/COPYING.iOS"),
    ThirdPartyNotices(R.string.app_about_doc_third_party, "ThirdPartyNotices.txt"),
    AgentHostNotices(R.string.app_about_doc_agent_host, "THIRD-PARTY-NOTICES.txt"),
    ;

    @Composable
    fun title(): String = titleRes?.let { stringResource(it) } ?: "GNU GPL v3"

    /** The document's text, or null when the build did not pack it. */
    fun load(context: Context): String? = runCatching {
        context.assets.open(asset).bufferedReader().use { it.readText() }
    }.getOrNull()
}

private const val SOURCE_URL = "https://github.com/bambouville/tessera"
private const val PRIVACY_POLICY_URL = "https://bambouville.github.io/tessera/privacy-policy"
private const val GPL_URL = "https://www.gnu.org/licenses/gpl-3.0.html"
private const val ISSUES_URL = "https://github.com/bambouville/tessera/issues"

/**
 * Settings → About, matching iOS: version, the licence and where the source
 * lives, and what Tessera is built on. Nothing here touches the network until
 * a link is tapped, and then only the browser does.
 */
@Composable
internal fun AboutSettings(modifier: Modifier = Modifier) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val onboarding = LocalOnboardingController.current
    var presented by rememberSaveable { mutableStateOf<BundledDocument?>(null) }
    var unopenedLink by rememberSaveable { mutableStateOf<String?>(null) }
    val open: (String) -> Unit = { url -> unopenedLink = if (context.openLink(url)) null else url }

    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            TesseraLogoMark(size = 64.dp)
            Spacer(Modifier.height(16.dp))
            Text("tessera · v${BuildConfig.VERSION_NAME}", style = TesseraType.rowMeta, color = tokens.fgMuted)
            Text(
                "build ${BuildConfig.VERSION_CODE}",
                modifier = Modifier.padding(top = 4.dp),
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
            )
        }

        if (onboarding != null) {
            Column {
                AboutRow(stringResource(R.string.app_about_replay_walkthrough), TesseraIcons.Agents, monochrome = true, onClick = onboarding::replayWalkthrough)
                AboutRow(stringResource(R.string.app_whats_new_title), TesseraIcons.File, monochrome = true, onClick = onboarding::showWhatsNew)
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TesseraKicker(stringResource(R.string.app_about_license))
            Text(
                stringResource(R.string.app_about_license_body),
                // A tablet-wide single line is hard to read.
                modifier = Modifier.widthIn(max = 560.dp),
                style = TesseraType.rowMeta,
                color = tokens.fgMuted,
            )
            Text("© 2026 Bambouville Inc.", style = TesseraType.rowMeta, color = tokens.fgMuted)
            Column {
                AboutRow(stringResource(R.string.app_about_view_source), TesseraIcons.Link) { open(SOURCE_URL) }
                AboutRow(stringResource(R.string.app_about_privacy_policy), TesseraIcons.Shield) { open(PRIVACY_POLICY_URL) }
                AboutRow(stringResource(R.string.app_about_view_license), TesseraIcons.File) { presented = BundledDocument.Gpl }
                // COPYING.iOS carries the §7 trademark terms that bind every
                // distribution; its App Store permission is moot here.
                AboutRow(stringResource(R.string.app_about_view_additional_terms), TesseraIcons.File) {
                    presented = BundledDocument.AdditionalTerms
                }
                AboutRow(stringResource(R.string.app_about_gpl_at_gnu), TesseraIcons.Link) { open(GPL_URL) }
            }
            unopenedLink?.let { url ->
                SelectionContainer {
                    TesseraBanner(stringResource(R.string.app_about_no_browser, url), tone = TesseraBannerTone.Info)
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TesseraKicker(stringResource(R.string.app_about_acknowledgments))
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Credits.forEach { (what, license) -> CreditLine(what, license) }
            }
            Column(Modifier.padding(top = 6.dp)) {
                AboutRow(stringResource(R.string.app_about_view_third_party), TesseraIcons.Copy) {
                    presented = BundledDocument.ThirdPartyNotices
                }
                AboutRow(stringResource(R.string.app_about_view_agent_host), TesseraIcons.Copy) {
                    presented = BundledDocument.AgentHostNotices
                }
            }
        }
    }

    presented?.let { document -> BundledDocumentDialog(document, onDismiss = { presented = null }) }
}

/**
 * What the Android build ships, native and JVM. Names and licence names stay
 * verbatim; ThirdPartyNotices.txt has versions, copyright lines and texts.
 */
private val Credits = listOf(
    "Termux terminal emulator" to "Apache License 2.0",
    "wcwidth tables (in Termux)" to "MIT License",
    "Mosh (mobile shell)" to "GNU GPL v3",
    "OCB3 reference code (in Mosh)" to "ISC-style license",
    "Protocol Buffers" to "BSD 3-Clause License",
    "OpenSSL" to "Apache License 2.0",
    "sshj" to "Apache License 2.0",
    "Conscrypt & BoringSSL" to "Apache License 2.0",
    "Swift standard library & Foundation" to "Apache License 2.0 with Runtime Library Exception",
    "ICU" to "Unicode License V3",
    "Swift Crypto" to "Apache License 2.0",
    "swift-markdown" to "Apache License 2.0",
    "swift-cmark" to "BSD 2-Clause License, MIT License",
    "LLVM libc++" to "Apache License 2.0 with LLVM Exceptions",
    "zxing-cpp & ZXing" to "Apache License 2.0",
    "AndroidX, Jetpack Compose & Kotlin libraries" to "Apache License 2.0",
    "JetBrains Mono & bundled terminal fonts" to "SIL Open Font License 1.1 and others",
)

@Composable
private fun CreditLine(what: String, license: String) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(what, style = TesseraType.rowMeta, color = tokens.fgMuted)
        Text(license, style = TesseraType.rowMicro, color = tokens.fgDim)
    }
}

/** An accent link-style row, 48dp tall so the whole line is the touch target. */
@Composable
private fun AboutRow(title: String, icon: ImageVector, monochrome: Boolean = false, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = if (monochrome) tokens.fgMuted else tokens.accent, modifier = Modifier.size(16.dp))
        Text(title, style = TesseraType.rowMeta, color = if (monochrome) tokens.fg else tokens.accent)
    }
}

/**
 * Full-screen viewer for a bundled document: plain monospace text, selectable,
 * because these are required reading rather than UI. Paragraphs are lazy items
 * so the hundred-kilobyte notices file lays out a screen at a time.
 */
@Composable
private fun BundledDocumentDialog(document: BundledDocument, onDismiss: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val loadFailure = stringResource(R.string.app_about_document_failed, ISSUES_URL)
    val paragraphs by produceState<List<String>?>(null, document) {
        val text = withContext(Dispatchers.IO) { document.load(context) }
            ?: loadFailure
        value = text.trimEnd().split(Regex("\n[ \t]*\n"))
    }
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = tokens.bg) {
            Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 60.dp)
                        .padding(start = 18.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(document.title(), Modifier.weight(1f), style = TesseraType.section, color = tokens.fg)
                    TesseraButton(text = stringResource(R.string.app_done), onClick = onDismiss, compact = true)
                }
                TesseraHairline()
                SelectionContainer(Modifier.weight(1f)) {
                    LazyColumn(
                        Modifier.fillMaxSize().testTag(DOCUMENT_TEXT_TAG),
                        contentPadding = PaddingValues(18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                        horizontalAlignment = Alignment.Start,
                    ) {
                        itemsIndexed(paragraphs.orEmpty()) { _, paragraph ->
                            Text(
                                paragraph,
                                Modifier.widthIn(max = 720.dp),
                                style = TesseraType.rowMicro,
                                color = tokens.fgMuted,
                            )
                        }
                    }
                }
            }
        }
    }
}

internal const val DOCUMENT_TEXT_TAG = "about-document-text"

/** Opens [url] in the user's browser; false when nothing on the device can. */
private fun Context.openLink(url: String): Boolean = try {
    startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addCategory(Intent.CATEGORY_BROWSABLE))
    true
} catch (_: ActivityNotFoundException) {
    false
}
