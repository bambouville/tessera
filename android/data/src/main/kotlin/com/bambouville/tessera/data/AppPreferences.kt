package com.bambouville.tessera.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.tesseraPreferences by preferencesDataStore(name = "tessera_preferences")

data class AppPreferences(
    val terminalTextSizeSp: Int = 13,
    /**
     * Selected terminal typeface, as a `TerminalFontCatalog` id (the `design`
     * module owns the catalog, and `SharedAssets/fonts/font/<id>.ttf` is the
     * file iOS ships too). Stored raw and normalized at the point of use via
     * `TerminalFontCatalog.resolve`, so an id from a newer build — or one
     * arriving over the cross-device manifest — degrades to the default face
     * instead of being rejected here.
     */
    val terminalFontId: String = "jetbrains_mono",
    val scrollbackLines: Int = 10_000,
    val resizeTerminalWithKeyboard: Boolean = false,
    /** Terminal palette; a separately stored background picture can sit behind it. */
    val terminalThemeId: String = "void",
    val terminalCursorStyle: String = "block",
    val terminalCursorBlink: Boolean = true,
    val terminalBackgroundUsesImage: Boolean = false,
    val terminalBackgroundImageId: String? = null,
    val terminalBackgroundDim: Float = 0.5f,
    val terminalBackgroundBlur: Int = 0,
    val terminalBackgroundFillMode: String = "fill",
    val smoothScrollingEnabled: Boolean = true,
    val smoothScrollingSpeed: Float = 0.5f,
    val programStatusEnabled: Boolean = true,
    /**
     * Raw stored accessory-bar slot IDs, or null when the user has never
     * edited the row. Resolve through [AccessoryBarKey.resolve]: the shared
     * codec is what turns null into the platform default, keeps a stored empty
     * row empty, and migrates legacy Android IDs. Storing the raw list keeps
     * that distinction intact all the way to the point of use.
     */
    val accessoryBarKeys: List<String>? = null,
    /**
     * How long an accessory-bar modifier stays armed: `oneShot` (the default,
     * matching iOS) applies it to exactly one key, `sticky` keeps it until it
     * is tapped off. Wire values of Swift `ModifierBehaviorMode`.
     */
    val modifierBehavior: String = "oneShot",
    /**
     * How a chord is written on screen: `glyph` (⌃C, the iOS default) or
     * `words` (ctrl-c). Display only — wire values of Swift `KeyChordNotation`.
     */
    val modifierNotation: String = "glyph",
    /** Audible terminal BEL feedback. Kept separate from Android notification-channel sound. */
    val bellSoundEnabled: Boolean = false,
    /** Highlight an off-screen session/window after a terminal BEL. */
    val bellVisualEnabled: Boolean = true,
    /** Post a silent local notification when a terminal BEL arrives in the background. */
    val bellNotificationEnabled: Boolean = true,
    val reconnectOnLaunch: Boolean = false,
    val appLockEnabled: Boolean = false,
    val agentCenterEnabled: Boolean = false,
    /**
     * Device-local opt-in, off by default: hide Tessera's content from Recents
     * previews (and, while Agent Center is visible, from screenshots and screen
     * sharing). Read [hidesContentInAppSwitcher], which app lock forces on.
     */
    val hideContentInAppSwitcher: Boolean = false,
    /** Explicit opt-in; Agent Center itself never implies OS notification permission. */
    val agentCenterNotificationsEnabled: Boolean = false,
) {
    /**
     * Effective app-switcher privacy, aligned with iOS `AppSwitcherPrivacyPolicy`.
     * App lock only locks in `onStop`, after the Recents snapshot can already be
     * taken, so a locked app would otherwise still show its last content there.
     */
    val hidesContentInAppSwitcher: Boolean
        get() = hideContentInAppSwitcher || appLockEnabled
}

class AndroidAppPreferences(private val context: Context) {
    val values: Flow<AppPreferences> = context.tesseraPreferences.data.map { preferences ->
        AppPreferences(
            terminalTextSizeSp = (preferences[TerminalTextSize] ?: 13).coerceIn(8, 40),
            terminalFontId = preferences[TerminalFontId] ?: "jetbrains_mono",
            scrollbackLines = (preferences[ScrollbackLines] ?: 10_000).coerceIn(1_000, 50_000),
            resizeTerminalWithKeyboard = preferences[ResizeTerminalWithKeyboard] ?: false,
            terminalThemeId = knownTerminalTheme(preferences[TerminalThemeId]),
            terminalCursorStyle = knownTerminalCursorStyle(preferences[TerminalCursorStyle]),
            terminalCursorBlink = preferences[TerminalCursorBlink] ?: true,
            terminalBackgroundUsesImage = preferences[TerminalBackgroundUsesImage] ?: false,
            terminalBackgroundImageId = preferences[TerminalBackgroundImageId],
            terminalBackgroundDim = (preferences[TerminalBackgroundDim] ?: 0.5f).coerceIn(0f, 0.85f),
            terminalBackgroundBlur = (preferences[TerminalBackgroundBlur] ?: 0).coerceIn(0, 24),
            terminalBackgroundFillMode = knownBackgroundFillMode(preferences[TerminalBackgroundFillMode]),
            smoothScrollingEnabled = preferences[SmoothScrollingEnabled] ?: true,
            smoothScrollingSpeed = (preferences[SmoothScrollingSpeed] ?: 0.5f).coerceIn(0.15f, 1.25f),
            programStatusEnabled = preferences[ProgramStatusEnabled] ?: true,
            accessoryBarKeys = preferences[AccessoryBarKeys]?.let(::decodeAccessoryBarSlots),
            modifierBehavior = knownModifierBehavior(preferences[ModifierBehavior]),
            modifierNotation = knownModifierNotation(preferences[ModifierNotation]),
            bellSoundEnabled = preferences[BellSoundEnabled] ?: false,
            bellVisualEnabled = preferences[BellVisualEnabled] ?: true,
            bellNotificationEnabled = preferences[BellNotificationEnabled] ?: true,
            reconnectOnLaunch = preferences[ReconnectOnLaunch] ?: false,
            appLockEnabled = preferences[AppLockEnabled] ?: false,
            agentCenterEnabled = preferences[AgentCenterEnabled] ?: false,
            // Absent means never touched: those users get the OFF default. An
            // explicit choice made under the old Agent Center toggle is kept.
            hideContentInAppSwitcher = preferences[HideContentInAppSwitcher] ?: false,
            agentCenterNotificationsEnabled = preferences[AgentCenterNotificationsEnabled] ?: false,
        )
    }

    suspend fun updateTerminalTextSize(sizeSp: Int) {
        require(sizeSp in 8..40)
        context.tesseraPreferences.edit { it[TerminalTextSize] = sizeSp }
    }

    /**
     * No allow-list check, unlike the theme id: the font catalog resolves
     * unknown ids to the default at the point of use, which is what lets a
     * manifest from a device on a newer build round-trip without failing.
     */
    suspend fun updateTerminalFontId(id: String) {
        require(id.isNotEmpty())
        context.tesseraPreferences.edit { it[TerminalFontId] = id }
    }

    suspend fun updateScrollbackLines(lines: Int) {
        require(lines in 1_000..50_000)
        context.tesseraPreferences.edit { it[ScrollbackLines] = lines }
    }

    suspend fun updateReconnectOnLaunch(enabled: Boolean) {
        context.tesseraPreferences.edit { it[ReconnectOnLaunch] = enabled }
    }

    suspend fun updateResizeTerminalWithKeyboard(enabled: Boolean) {
        context.tesseraPreferences.edit { it[ResizeTerminalWithKeyboard] = enabled }
    }

    suspend fun updateTerminalThemeId(id: String) {
        require(id in TerminalThemeIds)
        context.tesseraPreferences.edit { it[TerminalThemeId] = id }
    }

    suspend fun updateTerminalCursorStyle(style: String) {
        require(style in TerminalCursorStyles)
        context.tesseraPreferences.edit { it[TerminalCursorStyle] = style }
    }

    suspend fun updateTerminalCursorBlink(enabled: Boolean) {
        context.tesseraPreferences.edit { it[TerminalCursorBlink] = enabled }
    }

    suspend fun updateTerminalBackgroundUsesImage(enabled: Boolean) {
        context.tesseraPreferences.edit { it[TerminalBackgroundUsesImage] = enabled }
    }

    suspend fun updateTerminalBackgroundImageId(imageId: String?) {
        context.tesseraPreferences.edit {
            if (imageId == null) it.remove(TerminalBackgroundImageId) else it[TerminalBackgroundImageId] = imageId
        }
    }

    suspend fun updateTerminalBackgroundDim(dim: Float) {
        require(dim in 0f..0.85f)
        context.tesseraPreferences.edit { it[TerminalBackgroundDim] = dim }
    }

    suspend fun updateTerminalBackgroundBlur(blur: Int) {
        require(blur in 0..24)
        context.tesseraPreferences.edit { it[TerminalBackgroundBlur] = blur }
    }

    suspend fun updateTerminalBackgroundFillMode(mode: String) {
        require(mode in BackgroundFillModes)
        context.tesseraPreferences.edit { it[TerminalBackgroundFillMode] = mode }
    }

    suspend fun updateSmoothScrollingEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[SmoothScrollingEnabled] = enabled }
    }

    suspend fun updateSmoothScrollingSpeed(speed: Float) {
        require(speed in 0.15f..1.25f)
        context.tesseraPreferences.edit { it[SmoothScrollingSpeed] = speed }
    }

    suspend fun updateProgramStatusEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[ProgramStatusEnabled] = enabled }
    }

    /**
     * Stores canonical catalog slot IDs verbatim, including an empty row — the
     * editor already works in [AccessoryBarKey]s, and the shared codec drops
     * anything it does not recognise on the way back out.
     */
    suspend fun updateAccessoryBarKeys(keys: List<String>) {
        context.tesseraPreferences.edit { it[AccessoryBarKeys] = keys.joinToString("|") }
    }

    suspend fun updateModifierBehavior(value: String) {
        require(value in ModifierBehaviors)
        context.tesseraPreferences.edit { it[ModifierBehavior] = value }
    }

    suspend fun updateModifierNotation(value: String) {
        require(value in ModifierNotations)
        context.tesseraPreferences.edit { it[ModifierNotation] = value }
    }

    suspend fun updateBellSoundEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[BellSoundEnabled] = enabled }
    }

    suspend fun updateBellVisualEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[BellVisualEnabled] = enabled }
    }

    suspend fun updateBellNotificationEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[BellNotificationEnabled] = enabled }
    }

    suspend fun updateAppLockEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[AppLockEnabled] = enabled }
    }

    suspend fun updateAgentCenterEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[AgentCenterEnabled] = enabled }
    }

    suspend fun updateHideContentInAppSwitcher(enabled: Boolean) {
        context.tesseraPreferences.edit { it[HideContentInAppSwitcher] = enabled }
    }

    suspend fun updateAgentCenterNotificationsEnabled(enabled: Boolean) {
        context.tesseraPreferences.edit { it[AgentCenterNotificationsEnabled] = enabled }
    }

    private companion object {
        val TerminalTextSize = intPreferencesKey("terminal_text_size_sp")
        val TerminalFontId = stringPreferencesKey("terminal_font_id")
        val ScrollbackLines = intPreferencesKey("terminal_scrollback_lines")
        val ResizeTerminalWithKeyboard = booleanPreferencesKey("resize_terminal_with_keyboard")
        val TerminalThemeId = stringPreferencesKey("terminal_theme_id")
        val TerminalCursorStyle = stringPreferencesKey("terminal_cursor_style")
        val TerminalCursorBlink = booleanPreferencesKey("terminal_cursor_blink")
        val TerminalBackgroundUsesImage = booleanPreferencesKey("terminal_background_uses_image")
        val TerminalBackgroundImageId = stringPreferencesKey("terminal_background_image_id")
        val TerminalBackgroundDim = floatPreferencesKey("terminal_background_dim")
        val TerminalBackgroundBlur = intPreferencesKey("terminal_background_blur")
        val TerminalBackgroundFillMode = stringPreferencesKey("terminal_background_fill_mode")
        val SmoothScrollingEnabled = booleanPreferencesKey("smooth_scrolling_enabled")
        val SmoothScrollingSpeed = floatPreferencesKey("smooth_scrolling_speed")
        val ProgramStatusEnabled = booleanPreferencesKey("program_status_enabled")
        val AccessoryBarKeys = stringPreferencesKey("accessory_bar_keys")
        val ModifierBehavior = stringPreferencesKey("modifier_behavior")
        val ModifierNotation = stringPreferencesKey("modifier_notation")
        val BellSoundEnabled = booleanPreferencesKey("bell_sound_enabled")
        val BellVisualEnabled = booleanPreferencesKey("bell_visual_enabled")
        val BellNotificationEnabled = booleanPreferencesKey("bell_notification_enabled")
        val ReconnectOnLaunch = booleanPreferencesKey("reconnect_on_launch")
        val AppLockEnabled = booleanPreferencesKey("app_lock_enabled")
        /** Historical key from the Agent Center-only capture toggle; kept so explicit choices survive. */
        val HideContentInAppSwitcher = booleanPreferencesKey("agent_center_capture_protection_enabled")
        val AgentCenterEnabled = booleanPreferencesKey("agent_center_enabled")
        val AgentCenterNotificationsEnabled = booleanPreferencesKey("agent_center_notifications_enabled")
        val TerminalThemeIds = setOf("void", "graphite", "amber", "paper", "dracula", "nord")
        val TerminalCursorStyles = setOf("block", "bar", "underline")
        val BackgroundFillModes = setOf("fill", "fit")
        val ModifierBehaviors = setOf("oneShot", "sticky")
        val ModifierNotations = setOf("glyph", "words")

        /**
         * The `|` join is this store's own encoding, so an empty string is a
         * stored empty row rather than a row holding one blank slot. Absence
         * of the key entirely is the separate "never edited" case and is
         * carried as null.
         */
        fun decodeAccessoryBarSlots(value: String): List<String> =
            if (value.isEmpty()) emptyList() else value.split('|')

        fun knownModifierBehavior(value: String?): String =
            value?.takeIf { it in ModifierBehaviors } ?: "oneShot"
        fun knownModifierNotation(value: String?): String =
            value?.takeIf { it in ModifierNotations } ?: "glyph"

        fun knownTerminalTheme(value: String?): String =
            value?.takeIf { it in TerminalThemeIds } ?: "void"
        fun knownTerminalCursorStyle(value: String?): String =
            value?.takeIf { it in TerminalCursorStyles } ?: "block"
        fun knownBackgroundFillMode(value: String?): String =
            value?.takeIf { it in BackgroundFillModes } ?: "fill"
    }
}
