package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxRenderStage
import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import com.bambouville.tessera.terminal.RenderOwner

/** A concrete surface identity that must be repainted before authority stamps. */
internal data class InlineAuthorityRepaintTarget(
    val surfaceId: String,
    val windowId: Int,
    val paneId: Int,
)

/**
 * Resolves authority repaint targets only when Compose's last declaration is
 * an exact description of the current shared snapshot.  Returning an empty
 * list makes the caller abort/defer rather than repaint a previous window or
 * accept a partially mounted pane grid as authoritative.
 */
internal fun validatedInlineAuthorityRepaintTargets(
    declarations: List<SharedTmuxSurfaceDeclaration>,
    presentation: TmuxScreenRenderPresentation,
    activeWindowId: Int?,
    activePaneId: Int?,
    activePaneIds: Set<Int>,
    mountedSurfaceIds: Set<String>,
): List<InlineAuthorityRepaintTarget> {
    val windowId = activeWindowId ?: return emptyList()
    val paneId = activePaneId?.takeIf { it in activePaneIds } ?: return emptyList()
    if (activePaneIds.isEmpty()) return emptyList()

    val candidates = declarations.filter {
        it.presentation != SharedTmuxSurfacePresentation.Overlay
    }
    if (candidates.isEmpty() || candidates.any { it.surfaceId !in mountedSurfaceIds }) {
        return emptyList()
    }

    val expectedBySurface = when (presentation) {
        TmuxScreenRenderPresentation.None -> return emptyList()
        TmuxScreenRenderPresentation.Single -> mapOf(
            TMUX_RENDER_LIVE_SURFACE_ID to paneId,
        )
        TmuxScreenRenderPresentation.Grid -> activePaneIds.associateBy(
            keySelector = { "$TMUX_RENDER_PANE_SURFACE_PREFIX$it" },
            valueTransform = { it },
        )
    }
    if (candidates.size != expectedBySurface.size ||
        candidates.mapTo(mutableSetOf()) { it.surfaceId } != expectedBySurface.keys
    ) {
        return emptyList()
    }

    val requiredPresentation = when (presentation) {
        TmuxScreenRenderPresentation.None -> return emptyList()
        TmuxScreenRenderPresentation.Single -> SharedTmuxSurfacePresentation.Single
        TmuxScreenRenderPresentation.Grid -> SharedTmuxSurfacePresentation.Grid
    }
    val targets = candidates.mapNotNull { declaration ->
        val expectedPaneId = expectedBySurface[declaration.surfaceId] ?: return@mapNotNull null
        if (declaration.presentation != requiredPresentation ||
            declaration.windowId != windowId ||
            declaration.paneId != expectedPaneId
        ) {
            return@mapNotNull null
        }
        InlineAuthorityRepaintTarget(declaration.surfaceId, windowId, expectedPaneId)
    }
    return targets.sortedBy(InlineAuthorityRepaintTarget::surfaceId)
        .takeIf { it.size == candidates.size }
        ?: emptyList()
}

/**
 * Exact, claim-scoped join between the authority lifecycle and render ledger.
 *
 * The ledger's correlation token proves that a completion belongs to the
 * refresh requested by this claim. The platform admission bit and bound owner
 * prove that the corresponding bytes actually entered the intended emulator.
 * A grid claim completes only after every mounted pane surface proves both.
 *
 * P8: the claim unveils on visible rows. A surface already painted with its
 * pane on this connection is refreshed at visible rows, which the ledger
 * turns into a rebuild (and a history deepening once no peer holds the grid)
 * if a relayout went by while yielded. Only a surface's first fill must be
 * deep: it is the capture that gives that surface its history at all.
 *
 * Each [begin] opens a new [epoch]. A claim that lost its geometry repaints
 * again under the same generation, so the generation alone cannot tell the
 * lost repaint's completion from the new one's; the render batch a
 * completion arrives in carries the epoch it was queued under.
 */
internal class InlineAuthorityRepaintFence {
    internal sealed interface Receipt {
        data object Ignored : Receipt
        data object Pending : Receipt
        data object Complete : Receipt
        data class Rejected(val detail: String) : Receipt
    }

    private data class State(
        val generation: Long,
        val epoch: Long,
        val targets: Map<String, InlineAuthorityRepaintTarget>,
        val remainingSurfaceIds: MutableSet<String>,
        val firstFillSurfaceIds: Set<String>,
    )

    private var state: State? = null

    val generation: Long?
        get() = state?.generation

    /** The latest repaint begun; never reset, so a later one is always newer. */
    var epoch: Long = 0L
        private set

    /** [firstFillSurfaceIds]: the targets that hold no frame of their pane yet, and so need a deep capture. */
    fun begin(
        generation: Long,
        targets: List<InlineAuthorityRepaintTarget>,
        firstFillSurfaceIds: Set<String> = targets.mapTo(mutableSetOf(), InlineAuthorityRepaintTarget::surfaceId),
    ): Boolean {
        if (generation <= 0 || targets.isEmpty()) return false
        val keyed = targets.associateBy(InlineAuthorityRepaintTarget::surfaceId)
        if (keyed.size != targets.size || keyed.keys.any(String::isBlank)) return false
        epoch += 1
        state = State(generation, epoch, keyed, keyed.keys.toMutableSet(), firstFillSurfaceIds.intersect(keyed.keys))
        return true
    }

    /** The stage this claim asks of [surfaceId]: deep for a first fill, visible rows otherwise (P8). */
    fun stage(surfaceId: String): SharedTmuxRenderStage =
        if (state?.firstFillSurfaceIds?.contains(surfaceId) != false) SharedTmuxRenderStage.Deep
        else SharedTmuxRenderStage.ViewportOnly

    fun matches(
        generation: Long,
        targets: List<InlineAuthorityRepaintTarget>,
    ): Boolean {
        val current = state ?: return false
        return current.generation == generation &&
            current.targets == targets.associateBy(InlineAuthorityRepaintTarget::surfaceId)
    }

    /** Whether [correlation], from a batch queued under [batchEpoch], belongs to the repaint in flight. */
    fun isCurrent(correlation: Long, batchEpoch: Long): Boolean {
        val current = state ?: return false
        return current.generation == correlation && current.epoch == batchEpoch
    }

    fun expects(generation: Long, surfaceId: String): Boolean {
        val current = state ?: return false
        return current.generation == generation && surfaceId in current.remainingSurfaceIds
    }

    fun noteCompletion(
        correlation: Long,
        surfaceId: String,
        owner: SharedTmuxRenderOwner,
        stage: SharedTmuxRenderStage,
        frameAdmitted: Boolean,
        boundOwner: RenderOwner?,
        batchEpoch: Long,
    ): Receipt {
        val current = state ?: return Receipt.Ignored
        if (correlation != current.generation || batchEpoch != current.epoch) return Receipt.Ignored
        val target = current.targets[surfaceId] ?: return Receipt.Ignored
        if (surfaceId !in current.remainingSurfaceIds) return Receipt.Ignored
        if (surfaceId in current.firstFillSurfaceIds && stage != SharedTmuxRenderStage.Deep) {
            return Receipt.Rejected("authority first fill was not deep")
        }
        if (owner.windowId != target.windowId || owner.paneId != target.paneId) {
            return Receipt.Rejected("authority refresh owner changed")
        }
        val ownerMatches = boundOwner != null &&
            boundOwner.windowId == target.windowId &&
            boundOwner.paneId == target.paneId &&
            boundOwner.epoch == owner.epoch
        if (!frameAdmitted || !ownerMatches) {
            return Receipt.Rejected("authority refresh was not admitted by its bound owner")
        }
        current.remainingSurfaceIds.remove(surfaceId)
        return if (current.remainingSurfaceIds.isEmpty()) Receipt.Complete else Receipt.Pending
    }

    fun reset() {
        state = null
    }
}

/**
 * One render-effect batch's proof that a refresh's bytes entered its bound
 * emulator: the capture itself, then every scrub and live-output feed after
 * it under the same owner. A capture at any stage opens the tally, so a
 * claim's visible-rows refresh (P8) is proven exactly as a deep one was.
 */
internal class RefreshFeedAdmissions {
    private val admissions = mutableMapOf<String, Pair<SharedTmuxRenderOwner, Boolean>>()

    fun noteFeed(surfaceId: String, owner: SharedTmuxRenderOwner, source: SharedTmuxRenderFeedSource, admitted: Boolean) {
        if (source in CAPTURE_SOURCES) {
            admissions[surfaceId] = owner to admitted
            return
        }
        val (captureOwner, priorAdmission) = admissions[surfaceId] ?: return
        if (captureOwner == owner) admissions[surfaceId] = captureOwner to (priorAdmission && admitted)
    }

    /** Ends [surfaceId]'s tally: true only for a capture fed under [owner] and admitted with all that followed it. */
    fun take(surfaceId: String, owner: SharedTmuxRenderOwner): Boolean =
        admissions.remove(surfaceId)?.let { (captureOwner, admitted) -> captureOwner == owner && admitted } == true

    fun forget(surfaceId: String) {
        admissions.remove(surfaceId)
    }

    private companion object {
        val CAPTURE_SOURCES = setOf(
            SharedTmuxRenderFeedSource.DeepRepaint,
            SharedTmuxRenderFeedSource.ViewportRepaint,
            SharedTmuxRenderFeedSource.ViewportRefresh,
        )
    }
}
