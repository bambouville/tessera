package com.bambouville.tessera.design

import android.content.Context
import android.graphics.Typeface
import androidx.annotation.FontRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.res.ResourcesCompat

/**
 * The selectable terminal typefaces, mirroring
 * `Tessera/Design/TerminalFontCatalog.swift` entry for entry — same ids, same
 * order, same copy. The `.ttf` files are literally the same bytes: both
 * platforms build from `SharedAssets/fonts/font/`, which this module adds as a
 * resource source directory, so `R.font.<id>` and the id are the same word.
 *
 * Chrome typography (`TesseraType`) deliberately stays on JetBrains Mono
 * whatever is picked here — this setting governs the terminal grid, not the
 * app's own text, and iOS draws the same line.
 */
data class TerminalFontOption(
    /** Persisted identity, cross-device wire value, and Android resource name. */
    val id: String,
    /** Proper noun — the foundry's name for the family. Never localized. */
    val name: String,
    /** `null` selects the OS monospace face, the one option that bundles nothing. */
    @param:FontRes val fontRes: Int?,
    /**
     * PostScript name baked into the same `.ttf`. Android never resolves a font
     * this way, but iOS does, and older iOS builds sent it as the manifest's
     * `monospacedFontName` — [TerminalFontCatalog.resolve] needs it to map
     * those onto ids.
     */
    val postScriptName: String?,
    /** One-line character note shown under the family name in the picker. */
    val note: String,
)

object TerminalFontCatalog {
    const val DEFAULT_ID = "jetbrains_mono"

    /**
     * Picker order: the default first, then the families most people arrive
     * already using, then the more particular ones.
     */
    val all: List<TerminalFontOption> = listOf(
        TerminalFontOption(
            id = "jetbrains_mono",
            name = "JetBrains Mono",
            fontRes = R.font.jetbrains_mono,
            postScriptName = "JetBrainsMono-Regular",
            note = "tall x-height, coding ligatures",
        ),
        TerminalFontOption(
            id = "fira_code",
            name = "Fira Code",
            fontRes = R.font.fira_code,
            postScriptName = "FiraCode-Regular",
            note = "the widest ligature set",
        ),
        TerminalFontOption(
            id = "hack",
            name = "Hack",
            fontRes = R.font.hack,
            postScriptName = "Hack-Regular",
            note = "wide, plain, built for small sizes",
        ),
        TerminalFontOption(
            id = "cascadia_mono",
            name = "Cascadia Mono",
            fontRes = R.font.cascadia_mono,
            postScriptName = "CascadiaMono-Regular",
            note = "Windows Terminal's face, no ligatures",
        ),
        TerminalFontOption(
            id = "source_code_pro",
            name = "Source Code Pro",
            fontRes = R.font.source_code_pro,
            postScriptName = "SourceCodePro-Regular",
            note = "Adobe's classic, humanist shapes",
        ),
        TerminalFontOption(
            id = "ibm_plex_mono",
            name = "IBM Plex Mono",
            fontRes = R.font.ibm_plex_mono,
            postScriptName = "IBMPlexMono-Regular",
            note = "warm and slightly narrow",
        ),
        TerminalFontOption(
            id = "geist_mono",
            name = "Geist Mono",
            fontRes = R.font.geist_mono,
            postScriptName = "GeistMono-Regular",
            note = "geometric, very open counters",
        ),
        TerminalFontOption(
            id = "ubuntu_mono",
            name = "Ubuntu Mono",
            fontRes = R.font.ubuntu_mono,
            postScriptName = "UbuntuMono-Regular",
            note = "narrow — fits the most columns",
        ),
        TerminalFontOption(
            id = "inconsolata",
            name = "Inconsolata",
            fontRes = R.font.inconsolata,
            postScriptName = "Inconsolata-Regular",
            note = "light and compact",
        ),
        TerminalFontOption(
            id = "dejavu_sans_mono",
            name = "DejaVu Sans Mono",
            fontRes = R.font.dejavu_sans_mono,
            postScriptName = "DejaVuSansMono",
            note = "the broadest Unicode coverage",
        ),
        TerminalFontOption(
            id = "system",
            name = "System",
            fontRes = null,
            postScriptName = null,
            note = "whatever monospace the OS ships",
        ),
    )

    fun find(id: String): TerminalFontOption =
        all.firstOrNull { it.id == id } ?: all.first { it.id == DEFAULT_ID }

    /**
     * Normalizes a stored or received value to a catalog id.
     *
     * Two shapes reach this. iOS builds from before the picker existed sent a
     * PostScript name as the manifest's `monospacedFontName`, and Android sent
     * the literal placeholder `"monospace"`, so both have to land somewhere
     * sane. Anything else unrecognized — a family a newer build added — falls
     * back to the default rather than leaving the grid with no face.
     */
    fun resolve(raw: String?): String {
        if (raw == null) return DEFAULT_ID
        all.firstOrNull { it.id == raw }?.let { return it.id }
        all.firstOrNull { it.postScriptName == raw }?.let { return it.id }
        return DEFAULT_ID
    }

    /**
     * The face the terminal renders with. Falls back to the OS monospace when
     * a bundled font fails to load, which is also what the `"system"` entry
     * selects on purpose.
     */
    fun typeface(context: Context, id: String): Typeface {
        val fontRes = find(id).fontRes ?: return Typeface.MONOSPACE
        return runCatching { ResourcesCompat.getFont(context, fontRes) }.getOrNull()
            ?: Typeface.MONOSPACE
    }
}

/**
 * Compose face for a catalog entry, used by the picker's own samples. The
 * terminal itself never goes through this — it draws on a [Typeface] handed to
 * the Termux renderer — but both come off the same catalog row, so the sample
 * and the grid cannot disagree.
 */
@Composable
fun rememberTerminalFontFamily(id: String): FontFamily {
    val option = TerminalFontCatalog.find(id)
    return remember(option.id) {
        option.fontRes?.let { FontFamily(Font(it)) } ?: FontFamily.Monospace
    }
}

/**
 * Terminal typeface picker, mirroring the iOS Appearance list. Both lines of a
 * row render in the face they name — a terminal font is chosen on how `0O1lI`
 * and bracket pairs separate, so the sample carries more than the name does.
 */
@Composable
fun TesseraTerminalFontPicker(
    selectedId: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        TerminalFontCatalog.all.forEach { option ->
            val selected = option.id == selectedId
            val family = rememberTerminalFontFamily(option.id)
            // Name and note share the first line and the sample gets the whole
            // second one — same shape as the iOS list, and it keeps the sample
            // uncropped on a phone without a width branch.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) tokens.accentSoft else tokens.inputBgSoft)
                    .border(
                        1.dp,
                        if (selected) tokens.accent.copy(alpha = 0.45f) else tokens.border,
                        RoundedCornerShape(8.dp),
                    )
                    .semantics { role = Role.RadioButton }
                    .clickable { onSelect(option.id) }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Text(
                        option.name,
                        style = TesseraType.rowTitle.copy(fontFamily = family),
                        color = if (selected) tokens.accent else tokens.fg,
                        maxLines = 1,
                    )
                    Text(
                        option.note,
                        style = TesseraType.rowMicro,
                        color = tokens.fgDim,
                        textAlign = TextAlign.End,
                        maxLines = 2,
                        modifier = Modifier.weight(1f),
                    )
                }
                Text(
                    "0O1lI  {}[]()  ->  ~\u0024#",
                    style = TesseraType.rowMeta.copy(fontFamily = family),
                    color = tokens.fgMuted,
                    maxLines = 1,
                )
            }
        }
    }
}
