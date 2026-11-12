package com.bambouville.tessera.forwarding

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import java.util.UUID

/**
 * What the session top bar shows for forwarding.
 *
 * The glyph is chrome for a feature most sessions never use, so a host with no
 * rules gets none, matching iOS: `ForwardingStatusChip` renders an empty body
 * when its manager holds no forwarders, and `CompactForwardingStatusButton`
 * does the same on iPhone.
 *
 * The two platforms deliberately ask that question of different inputs. The
 * iOS chip is a read-only status readout — rules are created on the host's
 * tunnels page, never in-session — so "has a live forwarder" is the whole
 * question there. This glyph is also the toggle for the in-session editor
 * panel, so it answers "is a rule configured": a rule that is disabled, or
 * failing because mosh has no SSH side channel, still needs a way back to the
 * panel that explains it. Creating the first rule stays on the hosts screen
 * (`HostForwardingEditor`), which is the iOS arrangement.
 *
 * [panelOpen] keeps the glyph alive for a separate reason: deleting the last
 * rule from inside the panel must not stand the user in an open panel with no
 * way to toggle back to the terminal.
 *
 * [servingCount] is what colours the glyph: a listener being up on this device
 * says nothing about whether anything answers at the far end of the tunnel.
 */
data class ForwardingChromePresentation(
    val visible: Boolean,
    val activeCount: Int,
    val servingCount: Int = 0,
) {
    /** Whether the glyph shows that something answers behind a tunnel. */
    val serving: Boolean get() = servingCount > 0

    /**
     * The glyph's content description in English: "2 active tunnels, 1
     * serving". The glyph itself reads [localizedAccessibilityLabel].
     */
    val accessibilityLabel: String
        get() {
            val base = when (activeCount) {
                0 -> "Port forwarding"
                1 -> "1 active tunnel"
                else -> "$activeCount active tunnels"
            }
            return if (servingCount > 0) "$base, $servingCount serving" else base
        }

    /** [accessibilityLabel] in the user's language. */
    @Composable
    fun localizedAccessibilityLabel(): String = when {
        activeCount == 0 && servingCount == 0 -> stringResource(R.string.forwarding_chrome_label)
        activeCount == 0 -> pluralStringResource(R.plurals.forwarding_chrome_label_serving, servingCount, servingCount)
        servingCount == 0 -> pluralStringResource(R.plurals.forwarding_chrome_active_tunnels, activeCount, activeCount)
        else -> pluralStringResource(
            R.plurals.forwarding_chrome_active_tunnels_serving,
            activeCount,
            activeCount,
            servingCount,
        )
    }

    companion object {
        /** A session with no forwarding rules and no open panel. */
        val Hidden = ForwardingChromePresentation(visible = false, activeCount = 0)

        fun of(
            rules: List<PortForwardRule>,
            states: Map<UUID, PortForwardingState>,
            panelOpen: Boolean,
        ): ForwardingChromePresentation = ForwardingChromePresentation(
            visible = rules.isNotEmpty() || panelOpen,
            // A rule that is starting, idle, or failed is configured but not
            // carrying traffic, so it stays out of the count the glyph reads
            // out; the panel is where a failure is explained.
            activeCount = states.values.count { it.status.isCarrying() },
            servingCount = states.values.count { it.isServing() },
        )
    }
}

/**
 * Something answers behind this rule: its remote end was confirmed, or it is
 * carrying connections right now, which a refused open never counts as.
 */
fun PortForwardingState.isServing(): Boolean =
    status is PortForwardingStatus.Active ||
        (status is PortForwardingStatus.Listening && service == ForwardedServiceState.Serving)
