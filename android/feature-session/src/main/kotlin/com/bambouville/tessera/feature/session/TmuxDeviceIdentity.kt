package com.bambouville.tessera.feature.session

import android.content.Context
import androidx.core.content.edit
import com.bambouville.tessera.data.isTabletLayout
import java.util.UUID

/** Stable per-install identity compatible with TmuxGridAuthorityStamp. */
internal data class TmuxDeviceIdentity(val id: String, val displayName: String)

internal fun tmuxDeviceIdentity(context: Context): TmuxDeviceIdentity {
    val preferences = context.applicationContext.getSharedPreferences(
        "tessera_tmux_authority",
        Context.MODE_PRIVATE,
    )
    val id = preferences.getString(DEVICE_ID_KEY, null)?.takeIf(String::isNotBlank) ?: UUID.randomUUID()
        .toString()
        .also { id -> preferences.edit { putString(DEVICE_ID_KEY, id) } }
    val isTablet = context.resources.configuration.isTabletLayout()
    return TmuxDeviceIdentity(id.sanitizedTmuxToken(), if (isTablet) "Android-Tablet" else "Android-Phone")
}

private fun String.sanitizedTmuxToken(): String = map { character ->
    if (character.isLetterOrDigit() || character == '-' || character == '_' || character == '.') character else '-'
}.joinToString("").ifEmpty { "-" }

private const val DEVICE_ID_KEY = "device_id"
