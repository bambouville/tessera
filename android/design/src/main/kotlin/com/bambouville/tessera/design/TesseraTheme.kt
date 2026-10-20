package com.bambouville.tessera.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Semantic colour roles, mirroring iOS `Tessera/Design/DesignTokens.swift` so the
 * two platforms share one vocabulary. Material's own `ColorScheme` is derived from
 * these below and stays populated for stock Material components, but Tessera code
 * should reach for the token whose *meaning* it wants (`fgMuted`, `border`) rather
 * than the Material slot that happens to carry the same value today.
 *
 * The one deliberate divergence from iOS: `bg` is opaque in light mode. iOS uses a
 * clear page background so the system material shows through; Android composes over
 * an activity window with no such backdrop.
 */
@Immutable
data class TesseraTokens(
    val bg: Color,
    val panelBg: Color,
    val inputBg: Color,
    val inputBgSoft: Color,
    val fg: Color,
    val fgMuted: Color,
    val fgDim: Color,
    val fgFaint: Color,
    val accent: Color,
    val accentSoft: Color,
    val green: Color,
    val red: Color,
    val amber: Color,
    val border: Color,
    val borderStrong: Color,
    val isLight: Boolean,
)

private val DarkTokens = TesseraTokens(
    bg = Color(0xFF000000),
    panelBg = Color(0xFF0A0A0A),
    inputBg = Color(0xFF141414),
    inputBgSoft = Color(0xFF1C1C1E),
    fg = Color(0xFFFFFFFF),
    fgMuted = Color(0x99EBEBF5),
    fgDim = Color(0x59EBEBF5),
    fgFaint = Color(0x2EEBEBF5),
    accent = Color(0xFF5B9FFF),
    accentSoft = Color(0x245B9FFF),
    green = Color(0xFF30D158),
    red = Color(0xFFFF453A),
    amber = Color(0xFFFF9F0A),
    border = Color(0x14FFFFFF),
    borderStrong = Color(0x24FFFFFF),
    isLight = false,
)

private val LightTokens = TesseraTokens(
    bg = Color(0xFFF8F8FA),
    panelBg = Color(0xFFFFFFFF),
    inputBg = Color(0xFFFFFFFF),
    inputBgSoft = Color(0xFFF1F1F3),
    fg = Color(0xFF1A1A1A),
    fgMuted = Color(0x99000000),
    fgDim = Color(0x66000000),
    fgFaint = Color(0x2E000000),
    accent = Color(0xFF0060DF),
    accentSoft = Color(0x1A0060DF),
    green = Color(0xFF00A63C),
    red = Color(0xFFD70015),
    amber = Color(0xFFB26B00),
    border = Color(0x14000000),
    borderStrong = Color(0x24000000),
    isLight = true,
)

val LocalTesseraTokens: ProvidableCompositionLocal<TesseraTokens> =
    staticCompositionLocalOf { DarkTokens }

private val TesseraMono = FontFamily(Font(R.font.jetbrains_mono))
private val TesseraSans = FontFamily.SansSerif

/**
 * Semantic text roles, mirroring `Tessera/Design/Typography.swift`.
 *
 * The split is the point: **mono carries identity and structure** — titles,
 * hostnames, fingerprints, values, control labels — and **sans carries prose**,
 * the explanatory copy under a heading or beside a switch. Reproducing that split
 * is what keeps the app from reading as one undifferentiated terminal dump, so
 * pick the role by what the text *is*, never by the size you happen to want.
 */
object TesseraType {
    /** Oversized landing header. Hosts landing only, matching iOS `heroTitle`. */
    val hero = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 28.sp, lineHeight = 34.sp)

    /** Top-level page title: sessions, keys, settings, known hosts, files. */
    val page = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 24.sp, lineHeight = 30.sp)

    /** Sheet, dialog, and sub-page title. */
    val sheet = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 18.sp, lineHeight = 24.sp)

    /** Grouping title inside a page or card. */
    val section = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 15.sp, lineHeight = 20.sp)

    /** Primary line of a list row: host name, key name, file name. */
    val rowTitle = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 15.sp, lineHeight = 20.sp)

    /** Secondary line of a list row: endpoint, algorithm, size. */
    val rowMeta = TextStyle(fontFamily = TesseraMono, fontSize = 12.sp, lineHeight = 16.sp)

    /** Tertiary row detail and inline status. */
    val rowMicro = TextStyle(fontFamily = TesseraMono, fontSize = 11.sp, lineHeight = 15.sp)

    /**
     * Uppercase micro section label. Pair with [TesseraKicker], which applies the
     * case change and the muted colour so every kicker reads identically.
     */
    val kicker = TextStyle(
        fontFamily = TesseraMono,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 15.sp,
        letterSpacing = 0.8.sp,
    )

    /** Button, chip, and accessory-key label. */
    val button = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 18.sp)

    /** Field label above an input. */
    val fieldLabel = TextStyle(fontFamily = TesseraMono, fontSize = 12.sp, lineHeight = 16.sp)

    /** Verbatim machine text: fingerprints, public keys, log bodies, paths. */
    val code = TextStyle(fontFamily = TesseraMono, fontSize = 12.sp, lineHeight = 18.sp)

    /** Supporting prose. Sans, because it is sentences rather than identity. */
    val body = TextStyle(fontFamily = TesseraSans, fontSize = 15.sp, lineHeight = 21.sp)

    /** Dense supporting prose: row subtitles, helper text under a control. */
    val bodySmall = TextStyle(fontFamily = TesseraSans, fontSize = 13.sp, lineHeight = 18.sp)

    /** Bottom-navigation caption. Sans so it does not compete with page titles. */
    val navLabel = TextStyle(fontFamily = TesseraSans, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp)
}

/**
 * Material slots are populated so stock components (AlertDialog, DropdownMenuItem,
 * TextButton) inherit Tessera's roles without every one of them needing a wrapper.
 * The mapping follows Material 3's own usage: dialog titles read `headlineSmall`,
 * dialog bodies `bodyMedium`, and button labels `labelLarge`.
 */
private val TesseraTypography = Typography(
    displaySmall = TesseraType.hero,
    headlineMedium = TesseraType.page,
    headlineSmall = TesseraType.sheet,
    titleLarge = TesseraType.sheet,
    titleMedium = TesseraType.rowTitle,
    titleSmall = TextStyle(fontFamily = TesseraMono, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 18.sp),
    bodyLarge = TextStyle(fontFamily = TesseraSans, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TesseraType.body,
    bodySmall = TesseraType.bodySmall,
    labelLarge = TesseraType.button,
    labelMedium = TesseraType.rowMeta,
    labelSmall = TesseraType.rowMicro,
)

private fun colorSchemeFor(tokens: TesseraTokens) = if (tokens.isLight) {
    lightColorScheme(
        primary = tokens.accent,
        onPrimary = Color.White,
        primaryContainer = tokens.accentSoft,
        onPrimaryContainer = tokens.accent,
        secondary = tokens.fgMuted,
        onSecondary = Color.White,
        background = tokens.bg,
        onBackground = tokens.fg,
        surface = tokens.panelBg,
        onSurface = tokens.fg,
        surfaceVariant = tokens.inputBgSoft,
        onSurfaceVariant = tokens.fgMuted,
        // `DropdownMenu` reads `surfaceContainer`, not the High step the
        // dialogs use. Leaving it unmapped is what rendered every row menu in
        // Material's own lavender instead of Tessera's panel.
        surfaceContainer = tokens.panelBg,
        surfaceContainerHigh = tokens.panelBg,
        outline = tokens.borderStrong,
        outlineVariant = tokens.border,
        error = tokens.red,
        onError = Color.White,
    )
} else {
    darkColorScheme(
        primary = tokens.accent,
        onPrimary = Color.Black,
        primaryContainer = tokens.accentSoft,
        onPrimaryContainer = tokens.accent,
        secondary = tokens.fgMuted,
        onSecondary = Color.Black,
        background = tokens.bg,
        onBackground = tokens.fg,
        surface = tokens.panelBg,
        onSurface = tokens.fg,
        surfaceVariant = tokens.inputBg,
        onSurfaceVariant = tokens.fgMuted,
        surfaceContainer = tokens.inputBg,
        surfaceContainerHigh = tokens.inputBg,
        outline = tokens.borderStrong,
        outlineVariant = tokens.border,
        error = tokens.red,
        onError = Color.Black,
    )
}

@Composable
fun TesseraTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val tokens = if (darkTheme) DarkTokens else LightTokens
    CompositionLocalProvider(LocalTesseraTokens provides tokens) {
        MaterialTheme(
            colorScheme = colorSchemeFor(tokens),
            typography = TesseraTypography,
            shapes = MaterialTheme.shapes.copy(
                extraSmall = RoundedCornerShape(6.dp),
                small = RoundedCornerShape(8.dp),
                medium = RoundedCornerShape(12.dp),
                large = RoundedCornerShape(16.dp),
            ),
            content = content,
        )
    }
}
