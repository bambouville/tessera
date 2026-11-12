package com.bambouville.tessera.design

import android.content.res.Resources
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource

/**
 * Text a controller publishes for the UI to show. The app's own words are a
 * resource resolved where they are shown, so a language change while the
 * activity lives (it handles locale changes itself) re-renders them; a host's
 * or the system's words stay [Verbatim]. Diagnostics never read it.
 */
sealed interface DisplayText {
    data class Verbatim(val text: String) : DisplayText

    /** [args] are formatted as they are: a nested resource must be resolved by the caller first. */
    data class Resource(@param:StringRes val id: Int, val args: List<Any> = emptyList()) : DisplayText

    /** [count] picks the plural form; [args] are formatted as for [Resource]. */
    data class Plural(@param:PluralsRes val id: Int, val count: Int, val args: List<Any> = listOf(count)) : DisplayText

    fun resolve(resources: Resources): String = when (this) {
        is Verbatim -> text
        is Resource -> if (args.isEmpty()) resources.getString(id) else resources.getString(id, *args.toTypedArray())
        is Plural -> resources.getQuantityString(id, count, *args.toTypedArray())
    }
}

@Composable
fun DisplayText.text(): String = when (this) {
    is DisplayText.Verbatim -> text
    is DisplayText.Resource -> if (args.isEmpty()) stringResource(id) else stringResource(id, *args.toTypedArray())
    is DisplayText.Plural -> pluralStringResource(id, count, *args.toTypedArray())
}
