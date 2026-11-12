package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraType

@Composable
internal fun ArtifactsOverview(
    store: ArtifactsUiStore,
    state: SharedArtifactsState,
    revision: Long,
    query: String,
    onQueryChange: (String) -> Unit,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onQuickOpen: () -> Unit,
    nowMillis: Long,
    modifier: Modifier = Modifier,
    searchModifier: Modifier = Modifier,
) {
    val locked = LocalArtifactsLocked.current
    DisposableEffect(store, locked) {
        val owner = Any()
        store.noteOverviewVisible(owner, !locked)
        onDispose { store.noteOverviewVisible(owner, false) }
    }
    val tokens = LocalTesseraTokens.current
    val overview = remember(store, state, revision, query) { store.overview(query) }
    val tabs = remember(state.tabs) { state.tabs.associateBy { it.id } }
    Column(modifier.testTag("artifacts-overview")) {
        TesseraPageHeader(stringResource(R.string.artifacts_title)) {
            // The browser's only + control: a phone's tab reaches new tab from its menu.
            TesseraIconButton(TesseraIcons.Plus, stringResource(R.string.artifacts_new_tab), onQuickOpen, Modifier.testTag("artifacts-quick-open"))
        }
        if (state.tabs.isNotEmpty()) {
            TesseraTextField(
                value = query, onValueChange = onQueryChange,
                placeholder = pluralStringResource(R.plurals.artifacts_search_tabs, state.tabs.size, state.tabs.size), leading = TesseraIcons.Search,
                inputModifier = Modifier.heightIn(min = 24.dp).then(searchModifier),
                inputTestTag = "artifacts-search",
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                trailing = if (query.isBlank()) null else {
                    { TesseraIconButton(TesseraIcons.Close, stringResource(R.string.artifacts_clear_search), { onQueryChange("") }) }
                },
            )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                for (filter in SharedArtifactsFilter.entries) {
                    val count = when (filter) {
                        SharedArtifactsFilter.All -> overview.totalCount
                        else -> overview.countsByKind[SharedArtifactsKind.entries.first { it.wireValue == filter.wireValue }] ?: 0
                    }
                    val active = state.filter == filter
                    Row(
                        Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (active) tokens.inputBgSoft else tokens.bg)
                            .border(1.dp, if (active) tokens.borderStrong else tokens.border, RoundedCornerShape(8.dp))
                            .semantics { selected = active }
                            .clickable(role = Role.Tab) { store.setFilter(filter) }
                            .testTag("artifacts-filter-${filter.wireValue}")
                            .padding(horizontal = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(stringResource(artifactFilterLabel(filter)), style = TesseraType.button, color = if (active) tokens.fg else tokens.fgMuted)
                        Text(count.toString(), style = TesseraType.rowMicro, color = tokens.fgDim)
                    }
                }
            }
        }
        TesseraHairline()
        if (state.tabs.isEmpty()) {
            ArtifactBrowserEmptyState(Modifier.fillMaxWidth().weight(1f))
        } else if (overview.groups.isEmpty()) {
            TesseraEmptyState(
                title = stringResource(R.string.artifacts_no_matching_tabs), body = stringResource(R.string.artifacts_no_matching_tabs_hint),
                icon = TesseraIcons.Search, modifier = Modifier.fillMaxWidth().weight(1f),
            )
        } else {
            LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("artifacts-host-list")) {
                for (group in overview.groups) {
                    item(key = "host-${group.hostId}", contentType = "host") {
                        val live = store.isLive(group.hostId)
                        val liveLabel = stringResource(if (live) R.string.artifacts_live_session else R.string.artifacts_offline)
                        Row(
                            Modifier.fillMaxWidth().background(tokens.panelBg)
                                .padding(horizontal = 18.dp, vertical = 12.dp)
                                .semantics(mergeDescendants = true) { heading() },
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            TesseraStatusDot(
                                if (live) tokens.green else tokens.fgDim,
                                Modifier.semantics { contentDescription = liveLabel },
                            )
                            Text(group.hostLabel, Modifier.weight(1f), style = TesseraType.section, color = tokens.fg,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(pluralStringResource(R.plurals.artifacts_tab_count, group.tabIds.size, group.tabIds.size),
                                style = TesseraType.rowMicro, color = tokens.fgDim)
                        }
                    }
                    items(group.tabIds, key = { "tab-$it" }, contentType = { "tab" }) { id ->
                        tabs[id]?.let { tab ->
                            ArtifactOverviewRow(tab, store, nowMillis, selectedId == id, { onSelect(id) })
                            TesseraHairline(Modifier.padding(start = 50.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ArtifactOverviewRow(
    tab: SharedArtifactTab,
    store: ArtifactsUiStore,
    nowMillis: Long,
    active: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val unseenLabel = stringResource(R.string.artifacts_unseen_change)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 80.dp)
            .background(if (active) tokens.inputBgSoft else tokens.bg)
            .semantics { selected = active }
            .clickable(role = Role.Button, onClick = onClick)
            .testTag("artifacts-row-${tab.id}")
            .padding(horizontal = 18.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(artifactKindIcon(tab.kind), stringResource(artifactKindLabel(tab.kind)), Modifier.size(20.dp), tint = tokens.fgMuted)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(tab.title, Modifier.weight(1f), style = TesseraType.rowTitle, color = tokens.fg,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (tab.pinned) Icon(TesseraIcons.Lock, stringResource(R.string.artifacts_pinned), Modifier.size(13.dp), tint = tokens.fgMuted)
                if (tab.unseenChange) TesseraStatusDot(
                    tokens.amber, Modifier.semantics { contentDescription = unseenLabel }, size = 6.dp,
                )
            }
            Text(artifactTabAddress(tab), style = TesseraType.rowMeta, color = tokens.fgMuted,
                maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            ArtifactCacheBadge(store.presentation(tab.id), nowMillis)
            Text(artifactMessageText(artifactOpenedFrom(tab.origin)), style = TesseraType.rowMicro, color = tokens.fgDim,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}
