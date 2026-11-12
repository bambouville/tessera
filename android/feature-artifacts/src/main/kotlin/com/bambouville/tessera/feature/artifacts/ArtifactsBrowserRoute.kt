package com.bambouville.tessera.feature.artifacts

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The browser's route: the tab it shows, or null for its overview. The
 * process-owned store holds it, so an app-tab switch that disposes the
 * screen comes back to what the user left. Only a selection the route has
 * not seen yet (an open or select, here or elsewhere) reveals a tab; back
 * changes the route alone, and the tab stays the persisted selection.
 */
internal class ArtifactsBrowserRoute {
    private data class Seen(val selectedId: String?, val viewedAt: Long?)

    private var detailId by mutableStateOf<String?>(null)
    private var seen by mutableStateOf<Seen?>(null)

    /** What to show for this selection. An unseen selection shows at once, before [follow] records it. */
    fun displayedId(selectedId: String?, viewedAt: Long?): String? =
        if (seen == Seen(selectedId, viewedAt)) detailId else selectedId

    fun follow(selectedId: String?, viewedAt: Long?) {
        val current = Seen(selectedId, viewedAt)
        if (seen != current) {
            detailId = selectedId
            seen = current
        }
    }

    /** Shows a tab, or the overview for null. */
    fun show(tabId: String?) { detailId = tabId }
}
