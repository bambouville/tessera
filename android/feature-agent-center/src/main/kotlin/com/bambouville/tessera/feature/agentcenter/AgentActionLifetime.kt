package com.bambouville.tessera.feature.agentcenter

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext

/** Rechecked after suspending observations and immediately before native writes. */
internal suspend fun requireAgentActionLifetime(enabled: Boolean, runtimeAvailable: Boolean) {
    if (!enabled || !runtimeAvailable || currentCoroutineContext()[Job]?.isActive != true) {
        throw CancellationException("Agent action no longer active")
    }
}
