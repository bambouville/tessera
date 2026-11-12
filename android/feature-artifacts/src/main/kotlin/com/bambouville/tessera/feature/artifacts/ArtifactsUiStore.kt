package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsCachePresentation
import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsOverview
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import kotlinx.coroutines.flow.StateFlow

internal interface ArtifactsUiStore {
    val state: StateFlow<SharedArtifactsState>
    val revision: StateFlow<Long>
    /** Outlives the screen, so leaving the Artifacts tab keeps the overview or tab the user was on. */
    val route: ArtifactsBrowserRoute
    fun overview(query: String): SharedArtifactsOverview
    fun content(tabId: String): ArtifactContent
    fun presentation(tabId: String): SharedArtifactsCachePresentation
    fun filesReconnect(tabId: String): ArtifactFilesReconnect?
    fun isLive(hostId: String): Boolean
    fun select(tabId: String)
    fun close(tabId: String)
    fun closeAll(hostId: String)
    fun setPinned(tabId: String, pinned: Boolean)
    fun setFilter(filter: SharedArtifactsFilter)
    fun refresh(tabId: String)
    fun connectFiles(tabId: String)
    fun noteVisible(tabId: String?)
    fun noteOverviewVisible(owner: Any, visible: Boolean) {}
    fun titleLearned(tabId: String, title: String)
    fun canKeepAsRule(tabId: String): Boolean
    fun keepAsRule(tabId: String)
    val quickOpenHosts: List<SharedArtifactsQuickOpenHost>
    fun quickOpenSuggestions(input: String, currentHostId: String?): List<SharedArtifactsSuggestion>
    suspend fun quickOpen(
        input: String, currentHostId: String?, placement: ArtifactOpenPlacement = ArtifactOpenPlacement.NewTab,
    ): ArtifactQuickOpenOutcome
    /** Reopens the most recently closed tab, if any, as a new selected tab. */
    fun reopenClosed()
    fun share(tabId: String): ArtifactShare?
}

internal class LiveArtifactsUiStore(private val store: ArtifactsStore) : ArtifactsUiStore, ArtifactQuickOpenSuggestionSource {
    override val state get() = store.state
    override val revision get() = store.revision
    override val route get() = store.browserRoute
    override fun overview(query: String) = store.overview(query)
    override fun content(tabId: String) = store.content(tabId)
    override fun presentation(tabId: String) = store.presentation(tabId)
    override fun filesReconnect(tabId: String) = store.filesReconnect(tabId)
    override fun isLive(hostId: String) = store.isLive(hostId)
    override fun select(tabId: String) = store.select(tabId)
    override fun close(tabId: String) = store.close(tabId)
    override fun closeAll(hostId: String) = store.closeAll(hostId)
    override fun setPinned(tabId: String, pinned: Boolean) = store.setPinned(tabId, pinned)
    override fun setFilter(filter: SharedArtifactsFilter) = store.setFilter(filter)
    override fun refresh(tabId: String) = store.refresh(tabId)
    override fun connectFiles(tabId: String) = store.connectFiles(tabId)
    override fun noteVisible(tabId: String?) = store.noteVisible(tabId)
    override fun noteOverviewVisible(owner: Any, visible: Boolean) = store.noteOverviewVisible(owner, visible)
    override fun titleLearned(tabId: String, title: String) = store.titleLearned(tabId, title)
    override fun canKeepAsRule(tabId: String) = store.canKeepAsRule(tabId)
    override fun keepAsRule(tabId: String) = store.keepAsRule(tabId)
    override val quickOpenHosts get() = store.quickOpenHosts
    override fun quickOpenSuggestions(input: String, currentHostId: String?) =
        store.quickOpenSuggestions(input, currentHostId)
    override fun prepareQuickOpenSuggestions(input: String, currentHostId: String?) =
        store.prepareQuickOpenSuggestions(input, currentHostId)
    override suspend fun quickOpen(input: String, currentHostId: String?, placement: ArtifactOpenPlacement) =
        store.quickOpen(input, currentHostId, placement)
    override fun reopenClosed() = store.reopenClosed()
    override fun share(tabId: String) = store.share(tabId)
}

internal fun artifactTabAddress(tab: SharedArtifactTab): String = when (val target = tab.target) {
    is SharedArtifactsTarget.Page -> "${target.scheme}://localhost:${target.port}${target.path}"
    else -> target.path
}
