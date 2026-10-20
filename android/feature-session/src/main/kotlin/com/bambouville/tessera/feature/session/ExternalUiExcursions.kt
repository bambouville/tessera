package com.bambouville.tessera.feature.session

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Tessera's own trips out of its activity: system pickers, "Open with",
 * credential prompts for key use, the app-lock keyguard, the pairing camera
 * and permission sheets. While any is in progress an ON_STOP is not the app
 * leaving (`isRealBackgroundEdge`), so it is neither a hide for the show rule
 * nor a lock or restore edge.
 *
 * A counter rather than one boolean, because excursions nest: a single flag
 * was cleared by the first one to finish while another was still up.
 *
 * Each caller takes its own [slot]. A slot only moves the count when its own
 * state changes, so a caller that reports `false` without a matching `true`
 * (an ON_RESUME cleanup, a result callback after recreation) cannot
 * unbalance the count for everyone else.
 */
class ExternalUiExcursions {
    private val depth = AtomicInteger(0)

    /** True while at least one excursion is in progress. */
    val active: Boolean get() = depth.get() > 0

    /** The current nesting depth; for diagnostics and tests. */
    val count: Int get() = depth.get()

    /** One caller's balanced on/off switch. */
    fun slot(): (Boolean) -> Unit {
        val on = AtomicBoolean(false)
        return { active ->
            if (on.compareAndSet(!active, active)) {
                if (active) {
                    depth.incrementAndGet()
                } else {
                    depth.updateAndGet { (it - 1).coerceAtLeast(0) }
                }
            }
        }
    }
}
