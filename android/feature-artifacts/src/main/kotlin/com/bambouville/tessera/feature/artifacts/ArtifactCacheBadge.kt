package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactsCachePresentation
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheState
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType

@Composable
internal fun ArtifactCacheBadge(
    presentation: SharedArtifactsCachePresentation,
    nowMillis: Long,
    modifier: Modifier = Modifier,
) {
    val (text, icon) = when (presentation.state) {
        SharedArtifactsCacheState.Live -> stringResource(R.string.artifacts_badge_live) to TesseraIcons.Link
        SharedArtifactsCacheState.Cached -> (
            presentation.fetchedAt?.let { stringResource(R.string.artifacts_badge_cached_ago, artifactRelativeTime(it, nowMillis)) }
                ?: stringResource(R.string.artifacts_badge_cached)
        ) to TesseraIcons.Download
        SharedArtifactsCacheState.Stale -> stringResource(R.string.artifacts_badge_stale) to TesseraIcons.Alert
        SharedArtifactsCacheState.Offline -> stringResource(R.string.artifacts_offline) to TesseraIcons.Power
        SharedArtifactsCacheState.None -> return
    }
    val tokens = LocalTesseraTokens.current
    Row(
        modifier.clearAndSetSemantics { contentDescription = text },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tokens.fgMuted, modifier = Modifier.size(13.dp))
        Text(text, style = TesseraType.rowMicro, color = tokens.fgMuted)
    }
}
