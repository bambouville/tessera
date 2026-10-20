package com.bambouville.tessera.feature.session

import android.view.KeyCharacterMap
import android.view.KeyEvent

/**
 * The one authority projection the session screen renders and the input
 * gate reads (§6.5 S3′, §6.9).
 *
 * - [None]: no authority indicator; geometry admission is published separately.
 * - [Resuming]: a show or explicit open is waiting for its fresh read, or
 *   its claim is running. The terminal stays visible under a small
 *   indicator; the veil never flashes on a resume.
 * - [Veiled]: yielded to a peer with no intent and no claim.
 * - [Reclaiming]: a veil tap (or the own-write-won continuation) is running,
 *   or a tap is waiting for the control channel to come back.
 *
 * `awaitingConnection` marks an intent that cannot be decided until the
 * control channel is live again: shown as "takes control when reconnected"
 * with a cancel, because R3 expires it after about 20 s.
 */
internal sealed interface TmuxAuthorityPresentation {
    data object None : TmuxAuthorityPresentation
    data class Resuming(val awaitingConnection: Boolean = false) : TmuxAuthorityPresentation
    data class Veiled(val peerName: String?) : TmuxAuthorityPresentation
    data class Reclaiming(
        val peerName: String?,
        val awaitingConnection: Boolean = false,
    ) : TmuxAuthorityPresentation
}

/**
 * The screen's window/pane chrome stays disabled unless
 * [TmuxAuthorityPresentation.None]. (Programmatic selection and Agent Center
 * commands use the narrower yielded/reclaiming gate; typing uses
 * the shared session's cached gate.)
 */
internal val TmuxAuthorityPresentation.gatesInput: Boolean
    get() = this != TmuxAuthorityPresentation.None

/** UI spelling of the shared session's presentation; no authority policy lives here. */
internal fun com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPresentation.forAndroid(): TmuxAuthorityPresentation =
    when (this) {
        com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPresentation.None -> TmuxAuthorityPresentation.None
        is com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPresentation.Resuming ->
            TmuxAuthorityPresentation.Resuming(awaitingConnection)
        is com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPresentation.Veiled ->
            TmuxAuthorityPresentation.Veiled(peerName.takeIf { it.isNotEmpty() })
        is com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPresentation.Reclaiming ->
            TmuxAuthorityPresentation.Reclaiming(peerName.takeIf { it.isNotEmpty() }, awaitingConnection)
    }

/**
 * R4 for hardware keys on the veil: only Enter or a printable key takes
 * control back. Back, volume, media and system keys, bare modifiers, Tab,
 * Escape, dead keys and any Ctrl/Meta chord never do, and are left
 * unconsumed so Back still reaches its handler.
 */
internal object VeilKeyPolicy {
    fun admitsTakeBack(
        keyCode: Int,
        unicodeChar: Int,
        ctrlPressed: Boolean,
        metaPressed: Boolean,
    ): Boolean {
        if (ctrlPressed || metaPressed) return false
        if (keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) return true
        if (keyCode in NEVER) return false
        if (unicodeChar == 0 || (unicodeChar and KeyCharacterMap.COMBINING_ACCENT) != 0) return false
        return !Character.isISOControl(unicodeChar)
    }

    private val NEVER = setOf(
        KeyEvent.KEYCODE_BACK,
        KeyEvent.KEYCODE_ESCAPE,
        KeyEvent.KEYCODE_TAB,
        KeyEvent.KEYCODE_VOLUME_UP,
        KeyEvent.KEYCODE_VOLUME_DOWN,
        KeyEvent.KEYCODE_VOLUME_MUTE,
        KeyEvent.KEYCODE_HOME,
        KeyEvent.KEYCODE_APP_SWITCH,
        KeyEvent.KEYCODE_POWER,
        KeyEvent.KEYCODE_MENU,
    )
}
