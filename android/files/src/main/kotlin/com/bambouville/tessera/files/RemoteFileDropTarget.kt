package com.bambouville.tessera.files

import android.app.Activity
import android.content.ClipDescription
import android.net.Uri
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens

/**
 * Drop target for files dragged in from another app — the Android counterpart of
 * the iOS panel's and terminal's `onDrop`.
 *
 * Cross-app drag needs two windows on screen, so on a phone this is reachable
 * only in split-screen; on a tablet or in desktop mode it is the ordinary way
 * to move a file onto a host. The gesture is the same one the share sheet
 * serves, so it lands on the same upload path rather than a parallel one.
 */
object RemoteFileDrop {
    /**
     * A drag is worth accepting when it advertises anything that can resolve to
     * a content URI. `text/uri-list` is what a well-behaved source declares;
     * senders that only declare the file's own type (`image/png`) still deliver
     * a URI in the clip, so those are accepted too and filtered on drop.
     */
    fun accepts(mimeTypes: Collection<String>): Boolean = mimeTypes.any { mime ->
        mime == ClipDescription.MIMETYPE_TEXT_URILIST || !mime.startsWith("text/")
    }

    /** Content URIs in a dropped clip. Anything else is dropped on the floor. */
    fun contentUris(event: DragAndDropEvent): List<Uri> {
        val clip = event.toAndroidDragEvent().clipData ?: return emptyList()
        return buildList {
            repeat(clip.itemCount) { index ->
                clip.getItemAt(index).uri
                    ?.takeIf { it.scheme.equals("content", ignoreCase = true) }
                    ?.let(::add)
            }
        }.distinct()
    }
}

/**
 * Accepts dragged-in files and hands their content URIs to [onDropped].
 *
 * The read grant is requested against the activity, so it outlives the drop
 * callback and covers the upload that follows — an upload reading the URI a
 * second later would otherwise hit a SecurityException.
 */
@Composable
fun Modifier.remoteFileDropTarget(
    enabled: Boolean,
    onDropped: (List<Uri>) -> Unit,
): Modifier = composed {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }
    var targeted by remember { mutableStateOf(false) }
    val tokens = LocalTesseraTokens.current
    // The target object outlives recomposition, so it must not close over the
    // lambda it was born with — that one still points at the previous
    // composition's controller and session state.
    val currentOnDropped by rememberUpdatedState(onDropped)

    val target = remember(activity) {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                targeted = false
                if (activity != null) {
                    runCatching {
                        activity.requestDragAndDropPermissions(event.toAndroidDragEvent())
                    }
                }
                val uris = RemoteFileDrop.contentUris(event)
                if (uris.isEmpty()) return false
                currentOnDropped(uris)
                return true
            }

            override fun onEntered(event: DragAndDropEvent) { targeted = true }
            override fun onExited(event: DragAndDropEvent) { targeted = false }
            override fun onEnded(event: DragAndDropEvent) { targeted = false }
        }
    }

    this
        .dragAndDropTargetCompat(
            enabled = enabled,
            shouldStart = { event -> RemoteFileDrop.accepts(event.mimeTypes()) },
            target = target,
        )
        .then(
            if (targeted) {
                Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .border(2.dp, tokens.accent, RoundedCornerShape(8.dp))
            } else {
                Modifier
            },
        )
}

/**
 * `dragAndDropTarget` has no disabled form, and attaching it unconditionally
 * would let a disconnected session advertise a drop it cannot honour.
 */
private fun Modifier.dragAndDropTargetCompat(
    enabled: Boolean,
    shouldStart: (DragAndDropEvent) -> Boolean,
    target: DragAndDropTarget,
): Modifier = if (!enabled) this else this.then(
    Modifier.dragAndDropTarget(shouldStartDragAndDrop = shouldStart, target = target),
)

private tailrec fun android.content.Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is android.content.ContextWrapper -> baseContext.findActivity()
    else -> null
}
