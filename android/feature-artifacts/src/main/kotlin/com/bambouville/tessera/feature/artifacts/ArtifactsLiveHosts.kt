package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactsActiveForward
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.PortForwardingStatus

/** This adapter depends on capability modules, never on feature-session. */
internal class ArtifactsLiveHosts(
    private val findFiles: (String) -> ArtifactLiveFiles? = ArtifactLiveFilesRegistry::files,
    private val findContext: (String) -> ArtifactLiveFiles? = ArtifactLiveFilesRegistry::context,
    private val findForwarding: (String) -> List<ArtifactLiveForwardingRegistry.Session> = ArtifactLiveForwardingRegistry::sessions,
    private val findOpenable: (String) -> ArtifactLiveFiles? = ArtifactLiveFilesRegistry::openable,
) {
    var directory: List<SharedArtifactsQuickOpenHost> = emptyList()
        private set
    private var terminalDirectories: Map<String, String> = emptyMap()

    fun update(hosts: List<SharedArtifactsQuickOpenHost>) { directory = hosts }
    fun updateDirectories(paths: Map<String, String>) { terminalDirectories = paths.toMap() }
    fun files(hostId: String): ArtifactLiveFiles? = findFiles(hostId)?.takeIf { it.hasLiveArtifactChannel }
    fun openableFiles(hostId: String): ArtifactLiveFiles? = findOpenable(hostId)?.takeIf { it.canOpenArtifactChannel }
    fun forwarding(hostId: String): List<ArtifactLiveForwardingRegistry.Session> = findForwarding(hostId)
    fun isLive(hostId: String): Boolean = files(hostId) != null || forwarding(hostId).isNotEmpty()
    /** Saved rules listening now in a live session, read from published state. Reading never connects. */
    fun activeForwards(): List<SharedArtifactsActiveForward> = directory.flatMap { host ->
        forwarding(host.id).flatMap { session ->
            session.states.value.values.filter { it.status is PortForwardingStatus.Listening || it.status is PortForwardingStatus.Active }
                .map { SharedArtifactsActiveForward(host.id, it.rule.artifactSharedRule()) }
        }
    }
    fun cwd(hostId: String?): String? = hostId?.let { terminalDirectories[it] ?: findContext(it)?.artifactDirectory }
    fun hosts(): List<SharedArtifactsQuickOpenHost> = directory.map { host ->
        host.copy(home = host.home ?: findContext(host.id)?.artifactHome)
    }
}
