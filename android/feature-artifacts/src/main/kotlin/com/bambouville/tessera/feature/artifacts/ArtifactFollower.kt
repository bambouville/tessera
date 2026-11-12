package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal class ArtifactFollower(
    private val scope: CoroutineScope,
    private val live: (String) -> Boolean,
    private val stat: suspend (String) -> Unit,
    private val intervalMillis: Long = 3_000,
) {
    private var identity: Pair<String, String>? = null
    private var job: Job? = null

    fun update(tab: SharedArtifactTab?, foreground: Boolean) {
        val next = tab?.takeIf { foreground && it.target is SharedArtifactsTarget.File && live(it.hostId) }
            ?.let { it.id to it.hostId }
        if (identity == next && (next == null || job?.isActive == true)) return
        job?.cancel()
        identity = next
        job = next?.let { (id, hostId) ->
            scope.launch {
                while (isActive && live(hostId)) {
                    delay(intervalMillis)
                    if (!live(hostId)) break
                    try { stat(id) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                        // A missing file or transient stat failure is retried on the next visible tick.
                    }
                }
            }
        }
    }
}
