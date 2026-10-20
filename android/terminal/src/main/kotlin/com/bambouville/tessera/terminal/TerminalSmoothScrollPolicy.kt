package com.bambouville.tessera.terminal

import com.bambouville.tessera.core.bridge.SharedScrollRoute
import kotlin.math.abs

/**
 * Shared policy for the terminal surface's post-gesture momentum.
 *
 * This deliberately has no transport input: SSH, tmux, Mosh, and Mosh+tmux
 * all render through the same Termux surface. The shared scroll route
 * (`SharedScrollRouting`, the core's `TerminalScrollRouting`) is the only
 * thing that changes scroll semantics. Local scrollback can glide; the routes
 * that forward to the remote program — wheel reports, arrow keys — remain
 * discrete and receive no synthesized momentum after the gesture ends.
 */
object TerminalSmoothScrollPolicy {
    const val DEFAULT_ENABLED: Boolean = true
    const val DEFAULT_SPEED: Float = 0.5f
    const val MIN_SPEED: Float = 0.15f
    const val MAX_SPEED: Float = 1.25f

    /** iOS matches UIScrollView's "do not glide a deliberate drag" floor. */
    const val MINIMUM_RELEASE_SPEED_DP_PER_SECOND: Float = 25f

    /** Keeps a pathological velocity sample from producing a giant fling. */
    const val MAXIMUM_RELEASE_SPEED_DP_PER_SECOND: Float = 4_500f

    @JvmStatic
    fun normalizedSpeed(speed: Float): Float =
        if (speed.isFinite()) speed.coerceIn(MIN_SPEED, MAX_SPEED) else DEFAULT_SPEED

    @JvmStatic
    fun canGlide(enabled: Boolean, route: SharedScrollRoute): Boolean =
        enabled && route == SharedScrollRoute.LocalScrollback

    /**
     * Applies the preference relative to the native fling velocity at the default.
     * The caller passes density-independent pixels per second for a density-stable cap.
     * The sign is preserved: Termux maps it to its scrollback coordinate system
     * at the call site.
     */
    @JvmStatic
    fun scaledReleaseVelocity(
        releaseVelocityDpPerSecond: Float,
        speed: Float,
    ): Float? {
        if (!releaseVelocityDpPerSecond.isFinite() ||
            abs(releaseVelocityDpPerSecond) < MINIMUM_RELEASE_SPEED_DP_PER_SECOND
        ) {
            return null
        }
        val bounded = releaseVelocityDpPerSecond.coerceIn(
            -MAXIMUM_RELEASE_SPEED_DP_PER_SECOND,
            MAXIMUM_RELEASE_SPEED_DP_PER_SECOND,
        )
        return bounded * (normalizedSpeed(speed) / DEFAULT_SPEED)
    }
}
