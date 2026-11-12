package com.bambouville.tessera.feature.agentcenter

/**
 * The middle tier of the title waterfall: a short title written on device from
 * a session opening prompt, for the agents that do not name their own sessions.
 *
 * Shared Core decides whether a generated title is wanted and whether it is
 * still current when it comes back; this only produces one, or reports that it
 * cannot.
 *
 * Android ships no generator. Gemini Nano is reachable only through ML Kit,
 * which reports usage to Google, and Tessera sends nothing anywhere; rows keep
 * Core's clipped opening prompt instead.
 */
interface AgentTitleGenerator {
    /** A short title for `seed`, or null when no on-device model can write one. */
    suspend fun title(seed: String): String?

    /** Releases the native model session, if one was ever opened. */
    fun close() {}
}
