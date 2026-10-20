package com.bambouville.tessera.feature.agentcenter

import android.content.Context
import android.content.Intent
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentSessionDirectory
import com.bambouville.tessera.data.AndroidAgentMetadataRepository

/**
 * Notification routing uses a random opaque token plus carrier generation.
 * Neither an Intent extra nor a URI ever includes transcript/provider content.
 */
data class AgentNotificationRoute(val token: String, val generation: Long) {
    init {
        require(token.length in 16..256 && token.all { it.isLetterOrDigit() || it in "-_" })
        require(generation > 0)
    }
}

data class AgentNotificationIntent(val route: AgentNotificationRoute, val prearmedAnswer: Boolean)

object AgentNotificationContract {
    private const val EXTRA_ROUTE_TOKEN = "com.bambouville.tessera.agent.route_token"
    private const val EXTRA_CARRIER_GENERATION = "com.bambouville.tessera.agent.carrier_generation"
    private const val EXTRA_PREARMED_ANSWER = "com.bambouville.tessera.agent.prearmed_answer"

    /**
     * Keep the opaque route and generation in explicit extras only. The Intent
     * has no transcript, host, provider, path, prompt label, or response macro.
     */
    fun intent(context: Context, route: AgentNotificationRoute, prearmedAnswer: Boolean = false): Intent = Intent(Intent.ACTION_VIEW).apply {
        setClassName(context, "com.bambouville.tessera.MainActivity")
        putExtra(EXTRA_ROUTE_TOKEN, route.token)
        putExtra(EXTRA_CARRIER_GENERATION, route.generation)
        putExtra(EXTRA_PREARMED_ANSWER, prearmedAnswer)
        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

    fun parse(intent: Intent?): AgentNotificationIntent? {
        val token = intent?.getStringExtra(EXTRA_ROUTE_TOKEN) ?: return null
        val generation = intent.getLongExtra(EXTRA_CARRIER_GENERATION, -1L)
        val route = runCatching { AgentNotificationRoute(token, generation) }.getOrNull() ?: return null
        return AgentNotificationIntent(route, intent.getBooleanExtra(EXTRA_PREARMED_ANSWER, false))
    }

    /** Process death fails closed: an expired route or missing live endpoint never sends input. */
    suspend fun resolveForeground(
        repository: AndroidAgentMetadataRepository,
        directory: AgentSessionDirectory,
        route: AgentNotificationRoute,
        now: Long,
    ): String? {
        val stored = repository.resolveRoute(route.token, route.generation, now) ?: return null
        // Metadata proves only that Tessera issued the opaque token.  The
        // target remains usable only while the currently registered live
        // carrier has the exact generation embedded in that token.
        return stored.threadKey.takeIf {
            routeMatchesLiveCarrier(stored.threadKey, route.generation, directory.sessions.value)
        }
    }

    internal fun routeMatchesLiveCarrier(
        threadKey: String,
        generation: Long,
        bindings: List<AgentEndpointBinding>,
    ): Boolean {
        val hostID = threadKey.substringBefore(':', missingDelimiterValue = "")
        if (hostID.isBlank() || generation <= 0) return false
        return bindings.any { binding ->
            binding.hostID == hostID && binding.key.carrierGeneration == generation
        }
    }
}
